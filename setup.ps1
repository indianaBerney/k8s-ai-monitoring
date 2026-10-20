# =====================================================================
#  Kubernetes AI Monitoring - Projet 5 (groupe 19)
#  Installe et démarre tout le projet sur un PC Windows.
#
#  Utilisation (depuis le dossier du projet) :
#     powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
#  Options (facultatives) :
#     -MinikubeMemory 6144   mémoire du cluster en Mo (4000 par défaut, pour un PC à 8 Go)
#     -MinikubeCpus 4        processeurs du cluster (3 par défaut)
#     -WebUiPort 8080        port d'Open WebUI (8081 par défaut)
#     -AgentPort 8001        port de l'agent
#     -Model qwen2.5:7b      modèle d'IA (qwen2.5:3b par défaut)
#
#  Le script peut être relancé sans risque : il ne refait que ce qui manque.
# =====================================================================

param(
    [int]$MinikubeMemory = 4000,
    [int]$MinikubeCpus = 3,
    [int]$WebUiPort = 8081,
    [int]$AgentPort = 8001,
    [string]$Model = "qwen2.5:3b"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$Namespace = "monitoring"

function Step($message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

# Lance une commande et arrête le script si elle échoue.
function Run([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "La commande a échoué : $Command $($Arguments -join ' ')"
    }
}

# Lance une commande en silence et renvoie $true si elle réussit.
function Succeeds([string]$Command, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Command @Arguments *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $previous
    return $ok
}

# Attend qu'une adresse web réponde (code 200), pendant $Seconds secondes au maximum.
function Wait-Http([string]$Url, [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return $true }
        }
        catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

function Port-InUse([int]$Port) {
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------
Step "1/9 Vérification des outils"
# ---------------------------------------------------------------------
foreach ($tool in "docker", "kubectl", "minikube", "helm", "python", "ollama") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Outil manquant : $tool. Installez-le (voir README.md), puis relancez le script."
    }
}
if (-not (Succeeds "docker" @("info"))) {
    throw "Docker ne répond pas. Lancez Docker Desktop, attendez 'Engine running', puis relancez le script."
}
Write-Host "Tous les outils sont présents."

# ---------------------------------------------------------------------
Step "2/9 Démarrage du cluster Kubernetes (minikube)"
# ---------------------------------------------------------------------
if (-not (Succeeds "minikube" @("status"))) {
    Run "minikube" @("start", "--driver=docker", "--cpus=$MinikubeCpus", "--memory=$MinikubeMemory")
}
Run "kubectl" @("config", "use-context", "minikube")
Run "kubectl" @("wait", "--for=condition=Ready", "node", "--all", "--timeout=300s")

if (-not (Succeeds "kubectl" @("get", "namespace", $Namespace))) {
    Run "kubectl" @("create", "namespace", $Namespace)
}

# ---------------------------------------------------------------------
Step "3/9 Installation de Prometheus et Grafana (10 à 20 min la première fois)"
# ---------------------------------------------------------------------
Run "helm" @("upgrade", "--install", "monitoring",
    "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack", "--version", "92.3.1",
    "--namespace", $Namespace, "-f", "helm/prometheus-values.yaml",
    "--wait", "--timeout", "30m")

# ---------------------------------------------------------------------
Step "4/9 Installation de Garage (stockage objet S3), puis Loki et Alloy (logs)"
# ---------------------------------------------------------------------
# Identifiants de Garage : générés au hasard une seule fois, gardés dans un Secret Kubernetes.
if (-not (Succeeds "kubectl" @("get", "secret", "garage-credentials", "-n", $Namespace))) {
    $hex = { [guid]::NewGuid().ToString("N") }
    Run "kubectl" @("create", "secret", "generic", "garage-credentials", "-n", $Namespace,
        "--from-literal=GARAGE_RPC_SECRET=$(& $hex)$(& $hex)",
        "--from-literal=GARAGE_DEFAULT_ACCESS_KEY=GK$(& $hex)",
        "--from-literal=GARAGE_DEFAULT_SECRET_KEY=$(& $hex)$(& $hex)",
        "--from-literal=GARAGE_DEFAULT_BUCKET=loki")
}
Run "kubectl" @("apply", "-f", "k8s/garage.yaml")
Run "kubectl" @("rollout", "status", "statefulset/garage", "-n", $Namespace, "--timeout=300s")

Run "helm" @("repo", "add", "grafana", "https://grafana.github.io/helm-charts", "--force-update")
Run "helm" @("repo", "update", "grafana")
Run "helm" @("upgrade", "--install", "loki", "grafana/loki",
    "--namespace", $Namespace, "-f", "helm/loki-values.yaml", "--wait", "--timeout", "30m")
Run "helm" @("upgrade", "--install", "alloy", "grafana/alloy",
    "--namespace", $Namespace, "-f", "helm/alloy-values.yaml", "--wait", "--timeout", "20m")

# ---------------------------------------------------------------------
Step "5/9 Préparation de l'agent Python"
# ---------------------------------------------------------------------
$Python = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    Run "python" @("-m", "venv", ".venv")
}
Run $Python @("-m", "pip", "install", "--quiet", "-r", "agent\requirements.txt")

# ---------------------------------------------------------------------
Step "6/9 Démarrage d'Ollama et du modèle $Model"
# ---------------------------------------------------------------------
if (-not (Wait-Http "http://localhost:11434" 5)) {
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Minimized
    if (-not (Wait-Http "http://localhost:11434" 60)) { throw "Ollama ne démarre pas." }
}
if (-not (Succeeds "ollama" @("show", $Model))) {
    Run "ollama" @("pull", $Model)   # environ 2 Go pour qwen2.5:3b
}

# ---------------------------------------------------------------------
Step "7/9 Ouverture des tunnels vers Prometheus et Loki"
# ---------------------------------------------------------------------
function Open-Tunnel([string]$Service, [int]$Port) {
    if (Port-InUse $Port) {
        Write-Host "Le port $Port est déjà ouvert : tunnel $Service déjà actif."
        return
    }
    Start-Process "kubectl" -WindowStyle Minimized `
        -ArgumentList @("port-forward", "-n", $Namespace, "svc/$Service", "${Port}:${Port}")
}
Open-Tunnel "monitoring-kube-prometheus-prometheus" 9090
Open-Tunnel "loki" 3100
if (-not (Wait-Http "http://localhost:9090/-/ready" 90)) { throw "Prometheus ne répond pas sur le port 9090." }
if (-not (Wait-Http "http://localhost:3100/ready" 90))   { throw "Loki ne répond pas sur le port 3100." }

# ---------------------------------------------------------------------
Step "8/9 Démarrage de l'agent (port $AgentPort)"
# ---------------------------------------------------------------------
$KeyFile = Join-Path $PSScriptRoot ".agent-api-key"
if (-not (Test-Path $KeyFile)) {
    Set-Content -Path $KeyFile -Value ([guid]::NewGuid().ToString("N")) -Encoding Ascii
}
$env:AGENT_API_KEY = (Get-Content $KeyFile -Raw).Trim()

if (-not (Wait-Http "http://localhost:$AgentPort/health" 3)) {
    $Uvicorn = Join-Path $PSScriptRoot ".venv\Scripts\uvicorn.exe"
    Start-Process $Uvicorn -WorkingDirectory (Join-Path $PSScriptRoot "agent") -WindowStyle Minimized `
        -ArgumentList @("api:app", "--host", "0.0.0.0", "--port", "$AgentPort")
    if (-not (Wait-Http "http://localhost:$AgentPort/health" 60)) { throw "L'agent ne démarre pas." }
}

# ---------------------------------------------------------------------
Step "9/9 Démarrage d'Open WebUI (port $WebUiPort)"
# ---------------------------------------------------------------------
$container = docker ps -a --filter "name=^/open-webui$" --format "{{.Names}}"
if ($container -eq "open-webui") {
    Run "docker" @("start", "open-webui")
}
else {
    if (Port-InUse $WebUiPort) {
        throw "Le port $WebUiPort est déjà utilisé. Relancez avec un autre port, par exemple : -WebUiPort 3080"
    }
    Run "docker" @("run", "-d", "--name", "open-webui", "-p", "${WebUiPort}:8080",
        "-e", "OLLAMA_BASE_URL=http://host.docker.internal:11434",
        "-e", "RAG_EMBEDDING_ENGINE=openai", "-e", "HF_HUB_OFFLINE=1",
        "-v", "open-webui:/app/backend/data", "--restart", "unless-stopped",
        "ghcr.io/open-webui/open-webui:main")
}

# ---------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Tout est prêt !" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Open WebUI :  http://localhost:$WebUiPort  (la première fois, attendez 1 à 2 minutes)"
Write-Host "Agent      :  http://localhost:$AgentPort/health"
Write-Host ""
Write-Host "À faire une seule fois dans Open WebUI :"
Write-Host "  Panneau d'administration > Réglages > Connexions > + (API OpenAI)"
Write-Host "    URL : http://host.docker.internal:$AgentPort/v1"
Write-Host "    Clé : $($env:AGENT_API_KEY)"
Write-Host "  Puis choisissez le modèle 'k8s-agent' dans une nouvelle conversation."
Write-Host ""
Write-Host "Grafana (facultatif) : kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
Write-Host "                       puis http://localhost:3000  (admin / change-me)"

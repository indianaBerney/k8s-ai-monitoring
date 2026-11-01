# =====================================================================
#  Kubernetes AI Monitoring - Projet 5 (groupe 19)
#  Installe et démarre tout le projet sur un PC Windows (minikube).
#  Sur une machine Linux (AWS EC2) : utiliser setup.sh.
#
#  Utilisation (depuis le dossier du projet) :
#     powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
#  Options (facultatives) :
#     -MinikubeMemory 6144   mémoire du cluster en Mo (4000 par défaut, pour un PC à 8 Go)
#     -MinikubeCpus 4        processeurs du cluster (3 par défaut)
#     -WebUiPort 3080        port d'Open WebUI sur le PC (8081 par défaut)
#     -AgentPort 8001        port de l'agent sur le PC
#     -Provider ollama       modèle d'IA local (Ollama) au lieu d'AWS Bedrock (par défaut)
#     -Model qwen2.5:7b      modèle Ollama (qwen2.5:3b par défaut), seulement avec -Provider ollama
#
#  Avec Bedrock (par défaut), les identifiants AWS doivent être disponibles AVANT de lancer
#  le script : variables $env:AWS_ACCESS_KEY_ID et $env:AWS_SECRET_ACCESS_KEY
#  (+ $env:AWS_SESSION_TOKEN pour des clés temporaires), ou « aws configure ».
#  Région et modèle : $env:AWS_REGION (us-east-1 par défaut) et $env:BEDROCK_MODEL_ID.
#
#  Tout tourne DANS le cluster : Prometheus, Grafana, Loki, Alloy, Garage, l'agent et Open WebUI.
#  Le script peut être relancé sans risque : il ne refait que ce qui manque.
# =====================================================================

param(
    [int]$MinikubeMemory = 4000,
    [int]$MinikubeCpus = 3,
    [int]$WebUiPort = 8081,
    [int]$AgentPort = 8001,
    [ValidateSet("bedrock", "ollama")]
    [string]$Provider = "bedrock",
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

# Crée ou met à jour un objet Kubernetes (Secret, ConfigMap) : « kubectl create » puis « apply ».
function Apply-Generated([string[]]$Arguments) {
    $yaml = & kubectl create @Arguments --dry-run=client -o yaml
    if ($LASTEXITCODE -ne 0) { throw "kubectl create a échoué : $($Arguments -join ' ')" }
    $yaml | kubectl apply -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply a échoué : $($Arguments[0..2] -join ' ')" }
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

function Port-Process([int]$Port) {
    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($connection) { return Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue }
    return $null
}

function New-Secret {
    return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
}

# ---------------------------------------------------------------------
Step "1/8 Vérification des outils"
# ---------------------------------------------------------------------
$tools = @("docker", "kubectl", "minikube", "helm")
if ($Provider -eq "ollama") { $tools += "ollama" }
foreach ($tool in $tools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Outil manquant : $tool. Installez-le (voir README.md), puis relancez le script."
    }
}
if (-not (Succeeds "docker" @("info"))) {
    throw "Docker ne répond pas. Lancez Docker Desktop, attendez 'Engine running', puis relancez le script."
}
$AwsCredentialsFile = Join-Path $HOME ".aws\credentials"
if ($Provider -eq "bedrock" -and -not $env:AWS_ACCESS_KEY_ID -and -not (Test-Path $AwsCredentialsFile)) {
    throw "Aucun identifiant AWS trouvé. Définissez `$env:AWS_ACCESS_KEY_ID et `$env:AWS_SECRET_ACCESS_KEY (ou lancez 'aws configure'), ou relancez avec -Provider ollama."
}
Write-Host "Tous les outils sont présents. Modèle d'IA : $Provider"

# ---------------------------------------------------------------------
Step "2/8 Démarrage du cluster Kubernetes (minikube)"
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
Step "3/8 Installation de Prometheus et Grafana (10 à 20 min la première fois)"
# ---------------------------------------------------------------------
Run "helm" @("upgrade", "--install", "monitoring",
    "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack", "--version", "92.3.1",
    "--namespace", $Namespace, "-f", "helm/prometheus-values.yaml",
    "--wait", "--timeout", "30m")

# ---------------------------------------------------------------------
Step "4/8 Installation de Garage (stockage objet S3), puis Loki et Alloy (logs)"
# ---------------------------------------------------------------------
# Identifiants de Garage : générés au hasard une seule fois, gardés dans un Secret Kubernetes.
if (-not (Succeeds "kubectl" @("get", "secret", "garage-credentials", "-n", $Namespace))) {
    Run "kubectl" @("create", "secret", "generic", "garage-credentials", "-n", $Namespace,
        "--from-literal=GARAGE_RPC_SECRET=$(New-Secret)",
        "--from-literal=GARAGE_DEFAULT_ACCESS_KEY=GK$([guid]::NewGuid().ToString('N'))",
        "--from-literal=GARAGE_DEFAULT_SECRET_KEY=$(New-Secret)",
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
Step "5/8 Construction de l'image de l'agent (Dockerfile)"
# ---------------------------------------------------------------------
# L'image est construite avec Docker sur le PC, puis copiée dans minikube : pas besoin de registre.
# Chaque construction reçoit un nom unique (date et heure) : minikube n'a jamais à remplacer
# une image déjà utilisée par le pod (ce qui peut bloquer).
$AgentImage = "k8s-agent:" + (Get-Date -Format "yyyyMMdd-HHmmss")
Run "docker" @("build", "-t", $AgentImage, "agent")
Write-Host "Copie de l'image dans minikube (environ 1 minute)..."
Run "minikube" @("image", "load", $AgentImage)

# ---------------------------------------------------------------------
Step "6/8 Réglages et secrets de l'agent"
# ---------------------------------------------------------------------
# Clé de l'agent : créée une seule fois, gardée dans .agent-api-key (ignoré par Git).
$KeyFile = Join-Path $PSScriptRoot ".agent-api-key"
if (-not (Test-Path $KeyFile)) {
    Set-Content -Path $KeyFile -Value ([guid]::NewGuid().ToString("N")) -Encoding Ascii
}
$AgentKey = (Get-Content $KeyFile -Raw).Trim()

$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$BedrockModel = if ($env:BEDROCK_MODEL_ID) { $env:BEDROCK_MODEL_ID } else { "amazon.nova-lite-v1:0" }

Apply-Generated @("configmap", "agent-settings", "-n", $Namespace,
    "--from-literal=LLM_PROVIDER=$Provider",
    "--from-literal=AWS_REGION=$Region",
    "--from-literal=BEDROCK_MODEL_ID=$BedrockModel",
    "--from-literal=OLLAMA_URL=http://host.minikube.internal:11434",
    "--from-literal=LLM_MODEL=$Model")
Apply-Generated @("secret", "generic", "agent-api-key", "-n", $Namespace,
    "--from-literal=AGENT_API_KEY=$AgentKey")

# Clés AWS pour Bedrock : copiées dans un Secret Kubernetes (jamais dans Git).
if ($Provider -eq "bedrock") {
    $awsArgs = @("secret", "generic", "aws-credentials", "-n", $Namespace)
    if ($env:AWS_ACCESS_KEY_ID) {
        $awsArgs += "--from-literal=AWS_ACCESS_KEY_ID=$($env:AWS_ACCESS_KEY_ID)"
        $awsArgs += "--from-literal=AWS_SECRET_ACCESS_KEY=$($env:AWS_SECRET_ACCESS_KEY)"
        if ($env:AWS_SESSION_TOKEN) { $awsArgs += "--from-literal=AWS_SESSION_TOKEN=$($env:AWS_SESSION_TOKEN)" }
    }
    else {
        $awsArgs += "--from-file=credentials=$AwsCredentialsFile"
    }
    Apply-Generated $awsArgs
}
else {
    # Ollama tourne sur le PC ; il doit accepter les connexions venant du cluster.
    if (-not (Wait-Http "http://localhost:11434" 5)) {
        $env:OLLAMA_HOST = "0.0.0.0"
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Minimized
        if (-not (Wait-Http "http://localhost:11434" 60)) { throw "Ollama ne démarre pas." }
    }
    if (-not (Succeeds "ollama" @("show", $Model))) {
        Run "ollama" @("pull", $Model)   # environ 2 Go pour qwen2.5:3b
    }
}

# Open WebUI : sa connexion vers l'agent utilise la même clé.
$webuiKey = ""
if (Succeeds "kubectl" @("get", "secret", "open-webui-secrets", "-n", $Namespace)) {
    $encoded = kubectl get secret open-webui-secrets -n $Namespace -o "jsonpath={.data.WEBUI_SECRET_KEY}"
    $webuiKey = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($encoded))
}
if (-not $webuiKey) { $webuiKey = New-Secret }
Apply-Generated @("secret", "generic", "open-webui-secrets", "-n", $Namespace,
    "--from-literal=OPENAI_API_KEYS=$AgentKey",
    "--from-literal=WEBUI_SECRET_KEY=$webuiKey")

# ---------------------------------------------------------------------
Step "7/8 Déploiement de l'agent et d'Open WebUI dans le cluster"
# ---------------------------------------------------------------------
$manifest = (Get-Content "k8s/agent.yaml" -Raw) -replace "image: k8s-agent:local", "image: $AgentImage"
$manifest | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "kubectl apply de k8s/agent.yaml a échoué" }
Run "kubectl" @("apply", "-f", "k8s/open-webui.yaml")
# Redémarre l'agent pour qu'il prenne aussi les nouveaux réglages (ConfigMap, Secrets).
Run "kubectl" @("rollout", "restart", "deployment/k8s-agent", "-n", $Namespace)
Run "kubectl" @("rollout", "status", "deployment/k8s-agent", "-n", $Namespace, "--timeout=300s")
Write-Host "Open WebUI : la première fois, téléchargement d'environ 2 Go, patience..."
Run "kubectl" @("rollout", "status", "statefulset/open-webui", "-n", $Namespace, "--timeout=30m")

# ---------------------------------------------------------------------
Step "8/8 Ouverture des accès depuis le PC"
# ---------------------------------------------------------------------
# Anciennes versions du projet : agent lancé sur le PC et Open WebUI dans Docker. On les arrête
# (sans rien supprimer : le conteneur et ses données restent, il ne redémarre juste plus tout seul).
$old = Port-Process $AgentPort
if ($old -and $old.ProcessName -ne "kubectl") {
    Write-Host "Arrêt de l'ancien agent lancé sur le PC ($($old.ProcessName))."
    Stop-Process -Id $old.Id -Force
}
$oldWebUi = docker ps --filter "name=^/open-webui$" --format "{{.Names}}"
if ($oldWebUi -eq "open-webui") {
    Write-Host "Arrêt de l'ancien conteneur Docker open-webui (il est remplacé par celui du cluster)."
    Succeeds "docker" @("update", "--restart=no", "open-webui") | Out-Null
    Succeeds "docker" @("stop", "open-webui") | Out-Null
}

# Un tunnel kubectl reste accroché à l'ANCIEN pod quand le pod redémarre : on le recrée à chaque fois.
function Open-Tunnel([string]$Service, [int]$LocalPort, [int]$RemotePort) {
    $process = Port-Process $LocalPort
    if ($process -and $process.ProcessName -eq "kubectl") {
        Stop-Process -Id $process.Id -Force
        Start-Sleep -Seconds 1
    }
    elseif ($process) {
        throw "Le port $LocalPort est utilisé par $($process.ProcessName). Fermez ce programme, ou relancez avec un autre port (-AgentPort / -WebUiPort)."
    }
    Start-Process "kubectl" -WindowStyle Minimized `
        -ArgumentList @("port-forward", "-n", $Namespace, "svc/$Service", "${LocalPort}:${RemotePort}")
}
Open-Tunnel "k8s-agent" $AgentPort 8001
Open-Tunnel "open-webui" $WebUiPort 8080
if (-not (Wait-Http "http://localhost:$AgentPort/health" 60)) { throw "L'agent ne répond pas sur le port $AgentPort." }
if (-not (Wait-Http "http://localhost:$WebUiPort/health" 180)) { throw "Open WebUI ne répond pas sur le port $WebUiPort." }

# ---------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Tout est prêt !" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Open WebUI : http://localhost:$WebUiPort"
Write-Host "             (la première fois : créez le compte administrateur, puis choisissez le modèle 'k8s-agent')"
Write-Host "Agent      : http://localhost:$AgentPort/health  et  http://localhost:$AgentPort/health/sources"
Write-Host "Clé de l'agent (pour /v1/models) : dans le fichier .agent-api-key"
Write-Host ""
Write-Host "Grafana (facultatif) : kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
Write-Host "                       puis http://localhost:3000  (admin / change-me)"

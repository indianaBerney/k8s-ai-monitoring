#!/usr/bin/env bash
# =====================================================================
#  Kubernetes AI Monitoring - Projet 5 (groupe 19)
#  Installe et démarre tout le projet sur une machine Linux Ubuntu (AWS EC2).
#  Même chose que setup.ps1 (Windows), avec en plus l'installation des outils.
#
#  Utilisation (depuis le dossier du projet, en utilisateur normal « ubuntu », PAS en root) :
#     bash setup.sh
#
#  Réglages (facultatifs), à mettre devant la commande, par exemple :
#     MINIKUBE_MEMORY=12000 MINIKUBE_CPUS=4 bash setup.sh
#
#     MINIKUBE_MEMORY   mémoire du cluster en Mo (12000 par défaut, pour une t3.xlarge à 16 Go)
#     MINIKUBE_CPUS     processeurs du cluster (4 par défaut)
#     LLM_PROVIDER      bedrock (par défaut) ou ollama
#     AWS_REGION        région de Bedrock (eu-central-1 par défaut)
#     BEDROCK_MODEL_ID  modèle (eu.amazon.nova-lite-v1:0 par défaut)
#
#  Accès à Bedrock : de préférence avec le RÔLE IAM de la machine EC2 (aucune clé à copier).
#  Sinon : export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... (AWS_SESSION_TOKEN=...)
#
#  Le script peut être relancé sans risque : il ne refait que ce qui manque.
# =====================================================================

set -euo pipefail
cd "$(dirname "$0")"

MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-12000}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
LLM_PROVIDER="${LLM_PROVIDER:-bedrock}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-eu.amazon.nova-lite-v1:0}"
LLM_MODEL="${LLM_MODEL:-qwen2.5:3b}"
NS=monitoring
AGENT_PORT=8001
WEBUI_PORT=8081

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mERREUR : %s\033[0m\n' "$1" >&2; exit 1; }
new_secret() { openssl rand -hex 32; }

# Crée ou met à jour un objet Kubernetes (Secret, ConfigMap).
apply_generated() { kubectl create "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

wait_http() {  # wait_http URL SECONDES
    local deadline=$((SECONDS + $2))
    while ((SECONDS < deadline)); do
        curl -fsS -o /dev/null --max-time 5 "$1" && return 0
        sleep 3
    done
    return 1
}

[[ $EUID -ne 0 ]] || fail "Ne lancez pas ce script en root (minikube le refuse). Utilisez l'utilisateur ubuntu."

# ---------------------------------------------------------------------
step "1/9 Installation des outils (Docker, kubectl, minikube, Helm)"
# ---------------------------------------------------------------------
if ! command -v docker >/dev/null; then
    sudo apt-get update -q
    sudo apt-get install -y -q docker.io curl openssl
    sudo usermod -aG docker "$USER"
fi
# Le groupe docker n'est actif qu'après une nouvelle connexion : on relance le script avec ce groupe.
if ! docker info >/dev/null 2>&1; then
    if [[ -z "${SETUP_RELAUNCHED:-}" ]]; then
        echo "Relance du script avec les droits Docker..."
        exec sg docker -c "SETUP_RELAUNCHED=1 bash $(printf '%q ' "$0" "$@")"
    fi
    fail "Docker ne répond pas (sudo systemctl status docker)."
fi
if ! command -v kubectl >/dev/null; then
    version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
    sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! command -v minikube >/dev/null; then
    curl -fsSLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install -m 0755 /tmp/minikube /usr/local/bin/minikube
fi
if ! command -v helm >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "Outils prêts. Modèle d'IA : $LLM_PROVIDER"

# ---------------------------------------------------------------------
step "2/9 Démarrage du cluster Kubernetes (minikube)"
# ---------------------------------------------------------------------
if ! minikube status >/dev/null 2>&1; then
    minikube start --driver=docker --cpus="$MINIKUBE_CPUS" --memory="$MINIKUBE_MEMORY"
fi
kubectl config use-context minikube
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# ---------------------------------------------------------------------
step "3/9 Installation de Prometheus et Grafana"
# ---------------------------------------------------------------------
helm upgrade --install monitoring \
    oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version 92.3.1 \
    --namespace "$NS" -f helm/prometheus-values.yaml --wait --timeout 30m

# ---------------------------------------------------------------------
step "4/9 Installation de Garage (stockage objet S3), puis Loki et Alloy (logs)"
# ---------------------------------------------------------------------
if ! kubectl get secret garage-credentials -n "$NS" >/dev/null 2>&1; then
    kubectl create secret generic garage-credentials -n "$NS" \
        --from-literal=GARAGE_RPC_SECRET="$(new_secret)" \
        --from-literal=GARAGE_DEFAULT_ACCESS_KEY="GK$(openssl rand -hex 16)" \
        --from-literal=GARAGE_DEFAULT_SECRET_KEY="$(new_secret)" \
        --from-literal=GARAGE_DEFAULT_BUCKET=loki
fi
kubectl apply -f k8s/garage.yaml
kubectl rollout status statefulset/garage -n "$NS" --timeout=300s

helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana
helm upgrade --install loki grafana/loki \
    --namespace "$NS" -f helm/loki-values.yaml --wait --timeout 30m
helm upgrade --install alloy grafana/alloy \
    --namespace "$NS" -f helm/alloy-values.yaml --wait --timeout 20m

# ---------------------------------------------------------------------
step "5/9 Construction de l'image de l'agent (Dockerfile)"
# ---------------------------------------------------------------------
# Construite avec Docker sur la machine, puis copiée dans minikube : pas besoin de registre.
# Nom unique à chaque construction : minikube n'a jamais à remplacer une image utilisée par le pod.
AGENT_IMAGE="k8s-agent:$(date +%Y%m%d-%H%M%S)"
docker build -t "$AGENT_IMAGE" agent
echo "Copie de l'image dans minikube (environ 1 minute)..."
minikube image load "$AGENT_IMAGE"

# ---------------------------------------------------------------------
step "6/9 Réglages et secrets de l'agent"
# ---------------------------------------------------------------------
[[ -f .agent-api-key ]] || new_secret > .agent-api-key
chmod 600 .agent-api-key
AGENT_KEY="$(tr -d '[:space:]' < .agent-api-key)"

apply_generated configmap agent-settings -n "$NS" \
    --from-literal=LLM_PROVIDER="$LLM_PROVIDER" \
    --from-literal=AWS_REGION="$AWS_REGION" \
    --from-literal=BEDROCK_MODEL_ID="$BEDROCK_MODEL_ID" \
    --from-literal=OLLAMA_URL=http://host.minikube.internal:11434 \
    --from-literal=LLM_MODEL="$LLM_MODEL"
apply_generated secret generic agent-api-key -n "$NS" --from-literal=AGENT_API_KEY="$AGENT_KEY"

if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    # Clés données à la main : copiées dans un Secret Kubernetes (jamais dans Git).
    args=(--from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
          --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY manque}")
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && args+=(--from-literal=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN")
    apply_generated secret generic aws-credentials -n "$NS" "${args[@]}"
else
    # Pas de clé : l'agent utilisera le rôle IAM de la machine EC2.
    kubectl delete secret aws-credentials -n "$NS" --ignore-not-found >/dev/null
    if [[ "$LLM_PROVIDER" == "bedrock" ]]; then
        token="$(curl -fsS -X PUT --max-time 3 http://169.254.169.254/latest/api/token \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
        role="$(curl -fsS --max-time 3 -H "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/iam/security-credentials/ || true)"
        [[ -n "$role" ]] || fail "Aucune clé AWS et aucun rôle IAM sur cette machine. Voir docs/deploiement-aws.md."
        echo "Rôle IAM de la machine : $role"
    fi
fi

if kubectl get secret open-webui-secrets -n "$NS" >/dev/null 2>&1; then
    WEBUI_KEY="$(kubectl get secret open-webui-secrets -n "$NS" -o jsonpath='{.data.WEBUI_SECRET_KEY}' | base64 -d)"
else
    WEBUI_KEY="$(new_secret)"
fi
apply_generated secret generic open-webui-secrets -n "$NS" \
    --from-literal=OPENAI_API_KEYS="$AGENT_KEY" \
    --from-literal=WEBUI_SECRET_KEY="$WEBUI_KEY"

# ---------------------------------------------------------------------
step "7/9 Déploiement de l'agent et d'Open WebUI dans le cluster"
# ---------------------------------------------------------------------
sed "s|image: k8s-agent:local|image: $AGENT_IMAGE|" k8s/agent.yaml | kubectl apply -f -
kubectl apply -f k8s/open-webui.yaml
kubectl rollout restart deployment/k8s-agent -n "$NS"
kubectl rollout status deployment/k8s-agent -n "$NS" --timeout=300s
echo "Open WebUI : la première fois, téléchargement d'environ 2 Go, patience..."
kubectl rollout status statefulset/open-webui -n "$NS" --timeout=30m

# ---------------------------------------------------------------------
step "8/9 Ouverture des accès (sur cette machine uniquement, jamais sur Internet)"
# ---------------------------------------------------------------------
# Les tunnels écoutent sur 127.0.0.1 : on y accède depuis son PC par un tunnel SSH.
# Ils se relancent tout seuls si la connexion au pod est coupée.
mkdir -p logs
open_tunnel() {  # open_tunnel SERVICE PORT_LOCAL PORT_DISTANT
    # Un tunnel reste accroché à l'ANCIEN pod quand le pod redémarre : on le recrée à chaque fois.
    pkill -f "port-forward -n $NS svc/$1 " 2>/dev/null || true
    pkill -f "kubectl port-forward -n $NS svc/$1 " 2>/dev/null || true
    sleep 1
    nohup bash -c "while true; do kubectl port-forward -n $NS svc/$1 $2:$3 --address 127.0.0.1; sleep 2; done" \
        > "logs/tunnel-$1.log" 2>&1 &
}
open_tunnel k8s-agent "$AGENT_PORT" 8001
open_tunnel open-webui "$WEBUI_PORT" 8080
wait_http "http://127.0.0.1:$AGENT_PORT/health" 60 || fail "L'agent ne répond pas sur le port $AGENT_PORT."
wait_http "http://127.0.0.1:$WEBUI_PORT/health" 180 || fail "Open WebUI ne répond pas sur le port $WEBUI_PORT."

# ---------------------------------------------------------------------
step "9/9 Vérification des sources de l'agent"
# ---------------------------------------------------------------------
curl -fsS "http://127.0.0.1:$AGENT_PORT/health/sources"; echo

if [[ "$LLM_PROVIDER" == "bedrock" ]]; then
    # L'agent arrive-t-il à s'identifier auprès d'AWS depuis son pod ?
    if identity="$(kubectl exec -n "$NS" deploy/k8s-agent -- python -c \
        "import boto3; print(boto3.client('sts', region_name='$AWS_REGION').get_caller_identity()['Arn'])" 2>&1)"; then
        echo "Identité AWS de l'agent : $identity"
    else
        echo "ATTENTION : l'agent n'obtient pas d'identifiants AWS depuis son pod."
        echo "Sur EC2 : réglez « Metadata response hop limit » à 3 (voir docs/deploiement-aws.md)."
        echo "$identity" | tail -2
    fi
fi

cat <<EOF

==============================================
  Tout est prêt !
==============================================

Depuis VOTRE PC, ouvrez un tunnel SSH vers cette machine :
  ssh -i <votre-cle.pem> -L $WEBUI_PORT:localhost:$WEBUI_PORT -L $AGENT_PORT:localhost:$AGENT_PORT ubuntu@<adresse-EC2>

Puis, sur votre PC :
  Open WebUI : http://localhost:$WEBUI_PORT   (créez le compte, puis modèle 'k8s-agent')
  Agent      : http://localhost:$AGENT_PORT/health  et  /health/sources

Pensez à ARRÊTER l'instance EC2 après votre séance (elle coûte à chaque heure).
EOF

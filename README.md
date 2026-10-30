# Kubernetes AI Monitoring — Projet 5 (groupe 19)

Assistant IA qui répond en langage naturel à des questions de surveillance et de dépannage
d'un cluster Kubernetes : « Comment va mon cluster ? », « Que se passe-t-il avec ce pod ? »,
« Quelle est la cause du problème ? ».

Projet du cours CloudSys (MSE), inspiré d'un cas d'usage des HUG (Hôpitaux Universitaires de Genève).
C'est une preuve de concept (PoC) : un pipeline complet, de la collecte des données jusqu'à la réponse de l'IA.

## Architecture

Tout tourne **dans le cluster Kubernetes**, sur un PC (minikube) ou sur une machine **AWS EC2**.
Seul le modèle de langage est un service AWS : **Amazon Nova Lite sur AWS Bedrock**.

```
                         ┌──────────────── Cluster Kubernetes (namespace monitoring) ───────────────┐
Utilisateur ──> Open WebUI ──> Agent FastAPI ──> Prometheus   (métriques : CPU, mémoire, disque, restarts)
                         │         │        ├─> Loki         (logs, collectés par Alloy)
                         │         │        │     └─> Garage (stockage objet compatible S3)
                         │         │        └─> API Kubernetes (état actuel : nœuds, pods, événements)
                         │         │
Utilisateur ──> Grafana (tableaux de bord)  │
                         └─────────│────────────────────────────────────────────────────────────────┘
                                   └──> AWS Bedrock : Amazon Nova Lite (température 0) ──> diagnostic
```

L'agent rassemble les preuves, les sépare en **état actuel** (`now`) et **historique récent** (`history`,
avec l'âge de chaque événement), puis demande au modèle de rédiger un diagnostic à partir de ces seules preuves.
L'agent est en **lecture seule** : son compte de service Kubernetes ne peut que lire le cluster.

## Cas d'usage

| Cas d'usage | Exemple de question |
|---|---|
| Santé du cluster et des nœuds (CPU, mémoire, disque, pods par namespace) | `How healthy is my cluster?` |
| Pods d'un namespace, avec leurs ressources | `Show the pods in namespace ai-testing` |
| Investigation d'un pod | `Investigate pod <nom> in namespace <namespace>` |
| Analyse de cause racine | `Root-cause analysis of pod <nom> in namespace <namespace>` |

## Installation sur un PC Windows (minikube)

Prérequis : **8 Go de RAM minimum**, **Docker Desktop** avec WSL 2 à jour (`wsl --update`), et :

```powershell
winget install Git.Git
winget install Kubernetes.minikube
winget install Kubernetes.kubectl
winget install Helm.Helm
```

Fermez et rouvrez PowerShell. Donnez ensuite **vos propres** identifiants AWS (jamais ceux d'un autre,
jamais par message ni dans Git), puis lancez le script :

```powershell
git clone https://github.com/indianaBerney/k8s-ai-monitoring.git
cd k8s-ai-monitoring
$env:AWS_ACCESS_KEY_ID = "<votre clé>"
$env:AWS_SECRET_ACCESS_KEY = "<votre clé secrète>"
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

La première installation prend 30 à 60 minutes (téléchargement des images). Le script peut être relancé
à tout moment : il ne refait que ce qui manque. C'est aussi la commande pour **tout redémarrer**.

Options utiles :

```powershell
# Sans compte AWS : modèle local Qwen via Ollama (lent sur un PC sans carte graphique)
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Provider ollama

# Région AWS : eu-central-1 (Francfort) par défaut. Autre région, par exemple :
$env:AWS_REGION = "us-east-1"; $env:BEDROCK_MODEL_ID = "amazon.nova-lite-v1:0"
```

## Installation sur AWS EC2

Voir **[docs/deploiement-aws.md](docs/deploiement-aws.md)** : création de la machine, rôle IAM pour Bedrock,
lancement de `setup.sh`, accès par tunnel SSH, et arrêt pour limiter les coûts.

## Utilisation

1. Ouvrez http://localhost:8081 et créez le compte administrateur (la première fois).
2. Nouvelle conversation > modèle **k8s-agent** : la connexion vers l'agent est déjà configurée.

Adresses de l'agent (http://localhost:8001) :

| Adresse | Rôle |
|---|---|
| `/health` | L'agent répond, et quel modèle il utilise |
| `/health/sources` | L'agent joint-il Prometheus, Loki et l'API Kubernetes ? |
| `/v1/models` | Liste des modèles (clé API obligatoire) |
| `/v1/chat/completions` | Poser une question (clé API obligatoire) |

```powershell
$key = (Get-Content .agent-api-key -Raw).Trim()
Invoke-RestMethod http://localhost:8001/v1/models -Headers @{ Authorization = "Bearer $key" }
```

Grafana (facultatif) : `kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80`,
puis http://localhost:3000 (admin / change-me).

## Tester avec des pannes connues

`tests/test-pannes.yaml` lance trois applications volontairement en panne, chacune avec une cause connue :

| Application | Panne | Cause réelle |
|---|---|---|
| `crash-app` | CrashLoopBackOff, exit code 1 | connexion à la base de données refusée |
| `memory-app` | OOMKilled | utilise plus de mémoire que sa limite (32 Mio) |
| `image-app` | ImagePullBackOff | l'image demandée n'existe pas |

```powershell
kubectl apply -f tests/test-pannes.yaml
kubectl get pods -n ai-testing
```

Demandez ensuite à l'agent une analyse de cause racine pour chaque pod, et comparez avec la cause réelle.
Pour tout supprimer : `kubectl delete namespace ai-testing`.

## Stockage

Prometheus garde ses métriques sur disque (2 jours). Les logs de Loki sont stockés dans **Garage**,
un stockage objet open source compatible S3, à la place de MinIO (dont l'édition communautaire n'est plus
distribuée). Garage est lancé avec `--single-node --default-bucket` : il crée seul son cluster d'un nœud,
le bucket `loki` et la clé d'accès. Prometheus est utilisé à la place de Mimir : même langage de requête
(PromQL), plus léger pour un proof of concept.

## Sécurité

- Aucun secret dans Git : clés Garage, clé de l'agent, clés AWS sont des Secrets Kubernetes créés par le script.
- Sur EC2, l'agent utilise le **rôle IAM** de la machine : aucune clé AWS à copier.
- L'agent exige une clé API ; Open WebUI la reçoit automatiquement.
- L'agent ne peut que **lire** le cluster (ClusterRole `k8s-agent-read-only`).
- Sur EC2, seul le port SSH est ouvert ; Open WebUI et l'agent passent par un tunnel SSH.

## Organisation du dépôt

| Fichier | Rôle |
|---|---|
| `setup.ps1` | Installe et démarre tout sur Windows (minikube) |
| `setup.sh` | Installe et démarre tout sur Linux / AWS EC2 |
| `docs/deploiement-aws.md` | Guide de déploiement sur AWS, étape par étape |
| `helm/prometheus-values.yaml` | Configuration de Prometheus et Grafana |
| `helm/loki-values.yaml` | Configuration de Loki, branché sur Garage |
| `helm/alloy-values.yaml` | Configuration d'Alloy (collecte des logs des pods) |
| `k8s/garage.yaml` | Garage : stockage objet compatible S3 |
| `k8s/agent.yaml` | L'agent dans le cluster : Deployment, Service, droits en lecture seule |
| `k8s/open-webui.yaml` | Open WebUI dans le cluster, déjà connecté à l'agent |
| `agent/Dockerfile` | Image de l'agent |
| `agent/sources.py` | Accès à Prometheus, Loki et à l'API Kubernetes |
| `agent/evidence.py` | Rassemble les preuves pour chaque cas d'usage |
| `agent/llm.py` | Envoie la question et les preuves au modèle (Bedrock ou Ollama) |
| `agent/agent.py` | Choisit le cas d'usage selon la question |
| `agent/api.py` | API compatible OpenAI pour Open WebUI |
| `tests/test-pannes.yaml` | Applications en panne pour l'évaluation |

## Limites connues

- Les diagnostics de l'IA peuvent être faux : il faut toujours les vérifier avec `kubectl`.
- L'absence de données n'est jamais une preuve de bonne santé.
- Les données du cluster (état, extraits de logs) sont envoyées à AWS Bedrock pour l'analyse. Pour des
  données réelles d'hôpital, il faudrait valider ce point (région européenne utilisée par défaut).
- Un seul nœud, et Garage sans copie des données : suffisant pour un proof of concept, pas pour la production.
- Les traces ne sont pas couvertes.

## Dépannage

| Problème | Solution |
|---|---|
| `Docker ne répond pas` | Lancer Docker Desktop et attendre « Engine running » |
| `Aucun identifiant AWS trouvé` | Définir `$env:AWS_ACCESS_KEY_ID` et `$env:AWS_SECRET_ACCESS_KEY`, ou `-Provider ollama` |
| L'agent répond `AccessDeniedException` | Activer Amazon Nova Lite dans la console Bedrock, dans la bonne région |
| `/health/sources` indique `UNAVAILABLE` | `kubectl get pods -n monitoring` : la source concernée doit être `Running` |
| Port 8081 déjà utilisé | Relancer avec `-WebUiPort 3080` |
| Les pods redémarrent en boucle | Le PC manque de mémoire : fermer les autres applications |

## Remarque

Développé dans le cadre du cours par le groupe 19, avec l'aide d'un assistant IA pour le code.

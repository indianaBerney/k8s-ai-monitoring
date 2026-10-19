# Kubernetes AI Monitoring — Projet 5 (groupe 19)

Assistant IA qui répond en langage naturel à des questions de surveillance et de dépannage
d'un cluster Kubernetes : « Comment va mon cluster ? », « Que se passe-t-il avec ce pod ? »,
« Quelle est la cause du problème ? ».

Projet du cours CloudSys (MSE), inspiré d'un cas d'usage des HUG (Hôpitaux Universitaires de Genève).

## Fonctionnement

```
Utilisateur ──> Open WebUI ──> Agent (FastAPI) ──> Prometheus  (métriques, historique récent)
                                    │          ├─> Loki        (logs, collectés par Alloy)
                                    │          └─> API Kubernetes (état actuel des pods)
                                    └──> LLM Qwen 2.5 via Ollama ──> diagnostic
```

L'agent rassemble les preuves, les sépare en **état actuel** (`now`) et **historique récent** (`history`,
avec l'âge de chaque événement), puis demande au modèle de rédiger un diagnostic.
L'agent est en **lecture seule** : il ne modifie jamais le cluster.

Trois cas d'usage :

| Cas d'usage | Exemple de question |
|---|---|
| Santé du cluster | `How healthy is my cluster?` |
| Investigation d'un pod | `Investigate pod loki-0 in namespace monitoring` |
| Analyse de cause racine | `Root-cause analysis of pod <nom> in namespace <namespace>` |

## Prérequis (Windows)

- **8 Go de RAM minimum** (16 Go recommandés)
- **Docker Desktop**, avec WSL 2 à jour (`wsl --update`). `docker info` doit afficher `Cgroup Version: 2`.
- Les outils suivants, installables avec `winget` :

```powershell
winget install Git.Git
winget install Kubernetes.minikube
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Python.Python.3.12
winget install Ollama.Ollama
```

Fermez et rouvrez PowerShell après l'installation.

## Installation

```powershell
git clone https://github.com/indianaBerney/k8s-ai-monitoring.git
cd k8s-ai-monitoring
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

La première installation prend 30 à 60 minutes (téléchargement des images et du modèle d'IA).
Le script peut être relancé à tout moment : il ne refait que ce qui manque. C'est aussi
la commande à utiliser pour **tout redémarrer** après un redémarrage du PC (lancez d'abord Docker Desktop).

Options utiles :

```powershell
# PC avec 16 Go de RAM : un cluster plus grand et un modèle plus précis
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -MinikubeMemory 6144 -MinikubeCpus 4 -Model qwen2.5:7b

# Le port 8081 est déjà utilisé sur votre PC
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -WebUiPort 3080
```

### Brancher l'agent dans Open WebUI (une seule fois)

1. Ouvrez http://localhost:8081 et créez le compte administrateur.
2. Profil > **Panneau d'administration** > **Réglages** > **Connexions**.
3. Cliquez sur **+** à côté de « Gérer les connexions API OpenAI » :
   - URL : `http://host.docker.internal:8001/v1`
   - Clé : celle affichée à la fin du script (elle est aussi dans le fichier `.agent-api-key`)
4. Désactivez la connexion `https://api.openai.com/v1` (inutile).
5. Nouvelle conversation > modèle **k8s-agent**.

## Tester avec des pannes connues

Le fichier `tests/test-pannes.yaml` lance trois applications volontairement en panne, chacune avec une cause connue :

| Application | Panne | Cause réelle |
|---|---|---|
| `crash-app` | CrashLoopBackOff, exit code 1 | connexion à la base de données refusée |
| `memory-app` | OOMKilled | utilise plus de mémoire que sa limite (32 Mio) |
| `image-app` | ImagePullBackOff | l'image demandée n'existe pas |

```powershell
kubectl apply -f tests/test-pannes.yaml
kubectl get pods -n ai-testing
```

Puis demandez à l'agent une analyse de cause racine pour chaque pod, et comparez avec la cause réelle.
Pour tout supprimer : `kubectl delete namespace ai-testing`.

## Organisation du dépôt

| Fichier | Rôle |
|---|---|
| `setup.ps1` | Installe et démarre tout le projet |
| `helm/prometheus-values.yaml` | Configuration de Prometheus et Grafana |
| `helm/loki-values.yaml` | Configuration de Loki (stockage des logs, sans MinIO) |
| `helm/alloy-values.yaml` | Configuration d'Alloy (collecte des logs des pods) |
| `agent/sources.py` | Accès à Prometheus, Loki et à l'API Kubernetes |
| `agent/evidence.py` | Rassemble les preuves pour chaque cas d'usage |
| `agent/llm.py` | Envoie la question et les preuves au modèle (Ollama) |
| `agent/agent.py` | Choisit le cas d'usage ; testable seul : `python agent.py "How healthy is my cluster?"` |
| `agent/api.py` | API compatible OpenAI pour Open WebUI |
| `tests/test-pannes.yaml` | Applications en panne pour l'évaluation |

## Limites connues

- Les diagnostics de l'IA peuvent être faux : il faut toujours les vérifier avec `kubectl`.
- L'absence de données n'est jamais une preuve de bonne santé.
- Sur un PC sans carte graphique, une réponse peut prendre plusieurs minutes.
- Version locale (minikube) ; le déploiement sur AWS est l'étape suivante.

## Dépannage

| Problème | Solution |
|---|---|
| `Docker ne répond pas` | Lancer Docker Desktop et attendre « Engine running » |
| Port 8081 déjà utilisé | Relancer avec `-WebUiPort 3080` |
| `k8s-agent` n'apparaît pas dans Open WebUI | Vérifier http://localhost:8001/health et la clé dans la connexion |
| Les pods redémarrent en boucle | Le PC manque de mémoire : fermer les autres applications |

## Remarque

Développé dans le cadre du cours, avec l'aide d'un assistant IA pour le code.

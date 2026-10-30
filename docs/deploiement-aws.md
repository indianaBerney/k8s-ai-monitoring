# Déploiement sur AWS EC2, étape par étape

Le projet tourne sur **une seule machine EC2** : minikube, Prometheus, Grafana, Loki, Alloy, Garage,
l'agent et Open WebUI, exactement comme sur un PC. Le modèle de langage est **Amazon Nova Lite sur Bedrock**.
L'EC2 a un **rôle IAM** qui l'autorise à utiliser Bedrock : aucune clé AWS n'est copiée sur la machine.

```
Votre PC ──(tunnel SSH, port 22 seulement)──> EC2 Ubuntu : minikube + tout le projet
                                                             │
                                                             └──(rôle IAM)──> AWS Bedrock : Nova Lite
```

Pourquoi EC2 plutôt qu'EKS : pour un proof of concept, une machine suffit, coûte moins cher et se configure
comme le PC. EKS facture en plus le plan de contrôle et demande beaucoup plus de configuration.

## 1. Vérifier l'accès à Nova Lite dans Bedrock

1. Console AWS > en haut à droite, région **Europe (Francfort) eu-central-1**.
2. Service **Amazon Bedrock** > **Model access** (Accès aux modèles).
3. **Amazon Nova Lite** doit être « Access granted ». Sinon, demandez l'accès (immédiat pour Nova).

Si vous travaillez dans une autre région, gardez-la en tête pour l'étape 6 (`AWS_REGION`).

## 2. Créer le rôle IAM pour Bedrock

1. Service **IAM** > **Rôles** > **Créer un rôle**.
2. Entité de confiance : **Service AWS**, cas d'utilisation **EC2**. Suivant.
3. Ne cochez aucune stratégie, Suivant. Nom du rôle : `k8s-agent-bedrock`. Créer.
4. Ouvrez le rôle > **Ajouter des autorisations** > **Créer une stratégie en ligne** > onglet **JSON** :

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
        "arn:aws:bedrock:*:*:inference-profile/*.amazon.nova-lite-v1:0"
      ]
    }
  ]
}
```

5. Nom : `bedrock-nova-lite`. Créer.

Le rôle ne peut **que** utiliser Nova Lite : c'est le principe du moindre privilège.

> **AWS Academy (Learner Lab)** : la création de rôles est souvent interdite. Utilisez alors le profil
> d'instance existant **LabInstanceProfile** (rôle `LabRole`) à l'étape 3.

## 3. Créer la machine EC2

Service **EC2** > **Lancer une instance** :

| Réglage | Valeur |
|---|---|
| Nom | `k8s-ai-monitoring-groupe19` |
| Image (AMI) | **Ubuntu Server 24.04 LTS** (64 bits x86) |
| Type d'instance | **t3.xlarge** (4 vCPU, 16 Go) |
| Paire de clés | la vôtre (fichier `.pem`, gardé pour vous seul) |
| Réseau | Créer un groupe de sécurité : **SSH (22) uniquement, source « Mon IP »** |
| Stockage | **40 Go** gp3 |
| Détails avancés > Profil d'instance IAM | `k8s-agent-bedrock` (ou `LabInstanceProfile`) |
| Détails avancés > Limite de sauts de réponse des métadonnées | **3** |

La limite de sauts à **3** permet au pod de l'agent, qui tourne dans minikube, d'obtenir les identifiants
du rôle IAM. Si l'instance existe déjà : sélectionnez-la > **Actions** > **Paramètres de l'instance** >
**Modifier les options de métadonnées de l'instance** > limite de sauts = 3.

Coût : une t3.xlarge coûte de l'ordre de 0,2 USD par heure allumée (à vérifier sur la page des prix EC2),
plus le disque. **Arrêtez l'instance après chaque séance** (étape 9).

## 4. Se connecter à la machine

Dans PowerShell, sur votre PC (OpenSSH est inclus dans Windows) :

```powershell
ssh -i C:\chemin\vers\votre-cle.pem ubuntu@<adresse-IPv4-publique>
```

L'adresse IPv4 publique est affichée dans le détail de l'instance. Elle **change à chaque redémarrage**.

## 5. Récupérer le projet sur la machine

Le dépôt est privé : GitHub demande un **jeton d'accès** à la place du mot de passe.

1. Sur GitHub : photo de profil > **Settings** > **Developer settings** > **Personal access tokens** >
   **Fine-grained tokens** > **Generate new token**.
2. Repository access : **Only select repositories** > `k8s-ai-monitoring`. Permissions > **Contents : Read-only**.
   Expiration : 7 jours. Générer, puis copiez le jeton.
3. Sur l'EC2 :

```bash
git clone https://github.com/indianaBerney/k8s-ai-monitoring.git
cd k8s-ai-monitoring
```

Nom d'utilisateur : votre nom GitHub. Mot de passe : **le jeton**.

## 6. Lancer l'installation

```bash
bash setup.sh
```

Le script installe Docker, kubectl, minikube et Helm, puis tout le projet (20 à 40 minutes la première fois).
Région ou modèle différents :

```bash
AWS_REGION=us-east-1 BEDROCK_MODEL_ID=amazon.nova-lite-v1:0 bash setup.sh
```

À la fin, le script affiche :
- `/health/sources` : Prometheus, Loki et Kubernetes doivent être `ok` ;
- `Identité AWS de l'agent : arn:aws:sts::…:assumed-role/k8s-agent-bedrock/…` : l'agent utilise bien le rôle IAM.

## 7. Ouvrir Open WebUI depuis votre PC

Dans un **nouveau** PowerShell sur votre PC, à laisser ouvert :

```powershell
ssh -i C:\chemin\vers\votre-cle.pem -L 8081:localhost:8081 -L 8001:localhost:8001 ubuntu@<adresse-IPv4-publique>
```

Puis, sur votre PC : http://localhost:8081 (Open WebUI) et http://localhost:8001/health (agent).
Rien n'est exposé sur Internet : tout passe par le tunnel SSH.

Pour Grafana, ajoutez `-L 3000:localhost:3000` au tunnel, et sur l'EC2 :
`kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80`.

## 8. Tester avec les pannes

Sur l'EC2 :

```bash
kubectl apply -f tests/test-pannes.yaml
kubectl get pods -n ai-testing
```

Puis posez les questions dans Open WebUI (voir le README).

## 9. Arrêter, redémarrer, supprimer

- **Arrêter** après chaque séance : EC2 > instance > **État de l'instance** > **Arrêter**.
  Vous ne payez plus la machine, seulement le disque.
- **Redémarrer** : **Démarrer l'instance**, reconnectez-vous (nouvelle adresse IP), puis
  `cd k8s-ai-monitoring && bash setup.sh` (quelques minutes : tout est déjà installé).
- **À la fin du projet** : **Résilier** (supprimer) l'instance, puis supprimez le rôle `k8s-agent-bedrock`.

## En cas de problème

| Problème | Solution |
|---|---|
| `Aucune clé AWS et aucun rôle IAM` | Attacher le profil d'instance IAM (étape 3), puis relancer `bash setup.sh` |
| `l'agent n'obtient pas d'identifiants AWS` | Limite de sauts des métadonnées à 3 (étape 3) |
| L'agent répond `AccessDeniedException` | Accès à Nova Lite (étape 1), ou autorisations du rôle (étape 2) |
| `ssh: Connection timed out` | Groupe de sécurité : SSH depuis « Mon IP » (votre IP a peut-être changé) |
| `Permission denied (publickey)` | Mauvais fichier `.pem`, ou utilisateur autre que `ubuntu` |

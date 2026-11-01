# Déploiement sur AWS EC2, étape par étape

Ce guide décrit le déploiement réellement fait par le groupe 19 le 1er novembre 2026, dans le compte AWS
du cours, région **us-east-1 (Virginie du Nord)**.

Le projet tourne sur **une seule machine EC2** : minikube, Prometheus, Grafana, Loki, Alloy, Garage,
l'agent et Open WebUI, exactement comme sur un PC. Le modèle de langage est **Amazon Nova Lite sur Bedrock**.
L'EC2 a un **rôle IAM** qui l'autorise à utiliser uniquement Nova Lite : aucune clé AWS n'est copiée sur la machine.

```
Votre PC ──(tunnel SSH, port 22 seulement)──> EC2 Ubuntu : minikube + tout le projet
                                                             │
                                                             └──(rôle IAM)──> AWS Bedrock : Nova Lite
```

Pourquoi EC2 plutôt qu'EKS : pour un proof of concept, une machine suffit, coûte moins cher et se configure
comme le PC. EKS facture en plus le plan de contrôle et demande beaucoup plus de configuration.

Durée totale : environ 1 heure, dont 10 minutes d'installation automatique.

## 1. Créer le rôle IAM pour Bedrock

Console AWS, région **us-east-1** (en haut à droite).

1. **IAM** > **Rôles** > **Créer un rôle**.
2. Entité de confiance : **Service AWS**, cas d'utilisation **EC2**. Suivant.
3. Ne cochez aucune politique. Suivant. Nom du rôle : `k8s-agent-bedrock-groupe19`. **Créer le rôle**.
4. Ouvrez le rôle > **Ajouter des autorisations** > **Créer une politique en ligne** > onglet **JSON** :

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

5. Suivant. Nom de la politique : `bedrock-nova-lite`. **Créer une politique**.

Le rôle ne peut **que** appeler Nova Lite : c'est le principe du moindre privilège. Les identifiants qu'il
donne à la machine sont temporaires et renouvelés automatiquement par AWS.

## 2. Créer la machine EC2

**EC2** > **Lancer une instance**. Choisissez l'image **en premier** : changer d'image remet à zéro le réseau
et le stockage (AWS le signale, il suffit de confirmer).

| Réglage | Valeur utilisée |
|---|---|
| Nom | `k8s-ai-monitoring-groupe19` |
| Image (AMI) | **Ubuntu Server 24.04 LTS**, 64 bits (x86) |
| Type d'instance | **t3.xlarge** (4 vCPU, 16 Gio) |
| Paire de clés | **Créer une paire de clés** : nom `indiana-groupe19`, type RSA, format `.pem` |
| Paramètres réseau > Modifier | Nouveau groupe de sécurité, **SSH (22) uniquement, source « Mon IP »**, ni HTTP ni HTTPS |
| Stockage | **40 Gio**, gp3 |
| Détails avancés > Profil d'instance IAM | `k8s-agent-bedrock-groupe19` |
| Détails avancés > Limite de sauts de réponse des métadonnées | **3** |

La limite de sauts à **3** permet au pod de l'agent, qui tourne dans minikube, d'obtenir les identifiants
du rôle IAM ; avec la valeur par défaut, ils ne l'atteignent pas.

Coût : de l'ordre de 0,15 à 0,2 USD par heure allumée (à vérifier sur la page des prix EC2), plus le disque.

## 3. Protéger la clé et se connecter

Dans PowerShell, sur le PC (OpenSSH est inclus dans Windows). La clé est rangée hors du dossier du projet,
et rendue lisible par son seul propriétaire (sinon SSH la refuse) :

```powershell
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
Move-Item "$HOME\Downloads\indiana-groupe19.pem" "$HOME\.ssh\" -Force
icacls "$HOME\.ssh\indiana-groupe19.pem" /inheritance:r
icacls "$HOME\.ssh\indiana-groupe19.pem" /grant:r "$($env:USERNAME):(R)"
ssh -i "$HOME\.ssh\indiana-groupe19.pem" ubuntu@<adresse-IPv4-publique>
```

L'adresse IPv4 publique est affichée dans le détail de l'instance. Elle **change à chaque redémarrage**.

## 4. Envoyer le projet sur la machine

Depuis le PC, dans le dossier du projet. `git archive` ne prend que les fichiers suivis par Git : aucune clé
(`.agent-api-key`, fichiers `.csv`) ne part sur la machine.

```powershell
git archive --format=tar.gz -o "$HOME\Desktop\projet.tar.gz" HEAD
scp -i "$HOME\.ssh\indiana-groupe19.pem" "$HOME\Desktop\projet.tar.gz" ubuntu@<adresse-IPv4-publique>:~
```

Puis, sur l'EC2 :

```bash
mkdir -p k8s-ai-monitoring && tar xzf projet.tar.gz -C k8s-ai-monitoring
cd k8s-ai-monitoring
```

Autre possibilité : `git clone` du dépôt sur l'EC2, avec un jeton GitHub en lecture seule
(GitHub > Settings > Developer settings > Fine-grained tokens) à la place du mot de passe.

## 5. Lancer l'installation

Sur l'EC2 :

```bash
bash setup.sh
```

Le script installe Docker, kubectl, minikube et Helm, puis tout le projet. Il a pris environ 10 minutes sur
la t3.xlarge. La région et le modèle par défaut sont `us-east-1` et `amazon.nova-lite-v1:0` ; pour une autre
région, par exemple l'Europe :

```bash
AWS_REGION=eu-central-1 BEDROCK_MODEL_ID=eu.amazon.nova-lite-v1:0 bash setup.sh
```

À la fin, le script affiche deux vérifications :

```
{"prometheus":"ok","loki":"ok","kubernetes":"ok (1 node(s))","status":"ok"}
Identité AWS de l'agent : arn:aws:sts::…:assumed-role/k8s-agent-bedrock-groupe19/i-…
```

La seconde ligne prouve que l'agent, depuis son pod, utilise bien le rôle IAM de la machine.

## 6. Ouvrir Open WebUI et Grafana depuis le PC

Sur le PC, **arrêtez d'abord le cluster local** s'il tourne : il utilise les mêmes ports, et on verrait le PC
au lieu d'AWS.

```powershell
Get-Process kubectl -ErrorAction SilentlyContinue | Stop-Process -Force
minikube stop
```

Puis connectez-vous **avec le tunnel**. Cette fenêtre sert à la fois de terminal sur l'EC2 et de tunnel :
gardez-la ouverte.

```powershell
ssh -i "$HOME\.ssh\indiana-groupe19.pem" -L 8081:localhost:8081 -L 8001:localhost:8001 -L 3000:localhost:3000 ubuntu@<adresse-IPv4-publique>
```

Sur l'EC2, ouvrez Grafana :

```bash
cd ~/k8s-ai-monitoring
nohup kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 > logs/grafana.log 2>&1 &
```

Sur le PC :

| Adresse | Contenu |
|---|---|
| http://localhost:8081 | Open WebUI (créez le compte la première fois, puis modèle **k8s-agent**) |
| http://localhost:8001/health/sources | L'agent joint-il Prometheus, Loki et Kubernetes ? |
| http://localhost:3000 | Grafana (admin / change-me) : **Dashboards** > **Kubernetes / Compute Resources / Cluster** ; **Explore** > Loki > `{namespace="ai-testing"}` |

Rien n'est exposé sur Internet : tout passe par le tunnel SSH.

## 7. Tester avec les pannes

Sur l'EC2 :

```bash
kubectl apply -f tests/test-pannes.yaml
kubectl get pods -n ai-testing
```

Cette commande écrit les questions de cause racine avec les vrais noms des pods, prêtes à copier dans Open WebUI :

```bash
for p in $(kubectl get pods -n ai-testing -o name); do echo "Root-cause analysis of pod ${p#pod/} in namespace ai-testing"; done
```

Pour revenir à un cluster sain : `kubectl delete namespace ai-testing`.

## 8. Supprimer les ressources (fin du projet)

Une fois la démonstration enregistrée, tout est supprimé pour ne plus payer :

1. EC2 > instance `k8s-ai-monitoring-groupe19` > **État de l'instance** > **Résilier (supprimer)**.
   « Arrêter » ne suffit pas : le disque reste facturé.
2. EC2 > **Volumes** : vérifier qu'il ne reste aucun disque de 40 Gio.
3. EC2 > **Paires de clés** : supprimer `indiana-groupe19`, et le fichier `.pem` sur le PC.
4. IAM > **Rôles** : supprimer `k8s-agent-bedrock-groupe19`.

Pour une pause de quelques heures, **Arrêter** l'instance suffit ; au redémarrage (nouvelle adresse IP),
relancer `bash setup.sh` remet tout en route en quelques minutes.

## En cas de problème

| Problème | Solution |
|---|---|
| `Aucune clé AWS et aucun rôle IAM` | Attacher le profil d'instance IAM (étape 2), puis relancer `bash setup.sh` |
| `l'agent n'obtient pas d'identifiants AWS` | Limite de sauts des métadonnées à 3 (étape 2 ; modifiable ensuite : Actions > Paramètres de l'instance > Modifier les options de métadonnées) |
| L'agent répond `AccessDeniedException` | Autorisations du rôle (étape 1), ou Nova Lite non disponible dans la région choisie |
| `ssh: Connection timed out` | Groupe de sécurité : SSH depuis « Mon IP » (votre IP a peut-être changé) |
| `Permission denied (publickey)` | Mauvais fichier `.pem`, droits du fichier (étape 3), ou utilisateur autre que `ubuntu` |
| `bind: Address already in use` à l'ouverture du tunnel | Le cluster local tourne encore sur le PC (étape 6) |
| La question de cause racine donne un résumé du namespace | Le nom du pod n'a pas été reconnu : copier le nom exact, sans `<` ni `>` |

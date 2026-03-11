# Guide d'installation de Minikube sur Debian

Ce guide fournit des instructions pas-à-pas pour installer Minikube sur Debian.  
Minikube vous permet de faire tourner un cluster Kubernetes à nœud unique en local, à des fins de formation, de développementet et de test.

---

## Prérequis

- Debian (version récente recommandée)
- Accès sudo
- Virtualisation activée
- Machine virtuelle
  - Ram: 8Go (minimum)
  - HDD: 40 (minimum)
  - Virtualisation IntelVT-x/EPT ou AMD-V/RVI activée

Vérifiez que la virtualisation est activée sur la machine :

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

> Résultat `0` = désactivée · Résultat `1` ou plus = activée

---

## Étape 1 — Mise à jour des paquets

Mettez à jour vos listes de paquets pour obtenir les dernières versions et dépendances :

```bash
sudo apt-get update -y
sudo apt-get upgrade -y
```

---

## Étape 2 — Installation des paquets de base

Installez les outils indispensables :

```bash
sudo apt-get install -y \
  curl wget apt-transport-https \
  ca-certificates gnupg lsb-release
```

---

## Étape 3 — Installation de Docker

Minikube peut faire tourner un cluster Kubernetes dans une VM ou en local via Docker.  
**Ce guide utilise la méthode Docker**, qui est la plus simple et la plus recommandée.

```bash
sudo apt-get install -y docker.io
```

### Démarrage et activation de Docker

```bash
sudo systemctl start docker
sudo systemctl enable docker
```

### Ajout de votre utilisateur au groupe docker

Pour exécuter Docker sans `sudo` :

```bash
sudo usermod -aG docker $USER && newgrp docker
```

> **Important :** Déconnectez-vous puis reconnectez-vous pour que le changement de groupe prenne effet.

---

## Étape 4 — Installation de kubectl

kubectl est l'outil en ligne de commande pour interagir avec les clusters Kubernetes.

### Téléchargement de la dernière version stable

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
```

### Rendre kubectl exécutable et le déplacer dans le PATH

```bash
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### Vérification

```bash
kubectl version --client
```

---

## Étape 5 — Installation de Minikube

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64
```

### Vérification

```bash
minikube version
```

---

## Étape 6 — Démarrage/Arrêt du cluster

Cette commande démarre un cluster Kubernetes à nœud unique dans un conteneur Docker :

```bash
minikube start --driver=docker
```

> En cas d'erreur de privilèges root, ajoutez `--force` :
> ```bash
> minikube start --driver=docker --force
> ```

```bash
minikube start --driver=docker --nodes=2
```

### 6.b - Arrêt
```bash
minikube stop
✋  Arrêt du nœud  "minikube" ...
🛑  Mise hors tension du profil "minikube" via SSH…
🛑  1 nœud arrêté.
```

### 6.c - Vérification
Vérifier les nœuds après démarrage :
```bash
kubectl get nodes
```

Résultat attendu :
```
NAME          STATUS   ROLES           AGE   VERSION
minikube      Ready    control-plane   1m    v1.35.x
minikube-m02  Ready    <none>          1m    v1.35.x
```

---

## Étape 7 — Vérification de l'installation

```bash
# État du cluster Minikube
minikube status

# Informations sur le cluster
kubectl cluster-info

# Liste des nœuds
kubectl get nodes

# Tous les pods système
kubectl get pods -A
```

---

## Étape 8 — Configuration du proxy
Le serveur proxy HTTP local fait le pont entre votre navigateur et l'API server Kubernetes. Sans ce proxy, l'API Kubernetes n'est pas accessible directement (elle exige des certificats TLS et une authentification). Le proxy s'en charge à votre place.

```
Navigateur → kubectl proxy → API Server Kubernetes
  (HTTP)       (traduction)      (HTTPS + auth)
```

**Vérifier si le processus tourne**
```bash
ps aux | grep "kubectl proxy" | grep -v grep
```
Si rien ne répond → le proxy est arrêté, relancez-le (en arrière plan):
```bash
bashkubectl proxy --port=8001 --address='0.0.0.0' --accept-hosts='.*' &
```
- **`--port=8001`**: Port d'écoute du proxy sur la machine. (`8001` est le port habituel pour kubectl proxy.)
- **`--address='0.0.0.0'`**: 
  - Par défaut, le proxy n'écoute que sur `127.0.0.1` (loopback) — donc uniquement accessible depuis la VM elle-même.
  - `0.0.0.0` signifie **toutes les interfaces réseau**, ce qui rend le proxy accessible depuis l'extérieur, c'est-à-dire depuis votre hôte Windows via l'IP de la VM.
```
Sans --address     → accessible uniquement depuis la VM
Avec 0.0.0.0       → accessible depuis n'importe quelle machine du réseau
```

Pour arrêter le proxy lancé en arrière-plan :
```bash
# kill $(lsof -t -i :8001)
```

---

## Étape 9 — Addons

Afficher les addons
```bash
minikube addons list
┌─────────────────────────────┬──────────┬────────────┬────────────────────────────────────────┐
│         ADDON NAME          │ PROFILE  │   STATUS   │               MAINTAINER               │
├─────────────────────────────┼──────────┼────────────┼────────────────────────────────────────┤
│ ambassador                  │ minikube │ disabled   │ 3rd party (Ambassador)                 │
│ amd-gpu-device-plugin       │ minikube │ disabled   │ 3rd party (AMD)                        │
...
│ ingress                     │ minikube │ disabled   │ Kubernetes                             │
...
│ yakd                        │ minikube │ disabled   │ 3rd party (marcnuri.com)               │
└─────────────────────────────┴──────────┴────────────┴────────────────────────────────────────┘
...

```

Activer un addon
```bash
minikube addons enable ingress
minikube addons list
...
│ ingress                     │ minikube │ enabled ✅   │ Kubernetes                             │
...
```
Désactiver un addon
```bash
minikube addons disable ingress
```
### par défaut

```bash
minikube addons enable default-storageclass
minikube addons enable ingress
minikube addons enable storage-provisioner
minikube addons enable metrics-server
minikube addons enable dashboard
```

---

## Étape 10 — Accès au dashboard

# Ouvrir le tableau de bord Kubernetes dans le navigateur
minikube dashboard

# Obtenir l'URL du dashboard (sans ouvrir le navigateur)
minikube dashboard --url & 
🤔  Vérification de l'état du tableau de bord...
🚀  Lancement du proxy...
🤔  Vérification de l'état du proxy...
http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/
# Remplacer 127.0.0.1 par l'ip de la machine et ouvrez cette url avec un navigateur
# Exemple: http://192.168.1.204:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/

---

## Commandes utiles

```bash
# démarrer le cluster ( en arrière plan )
minikube start --driver=docker &

# Vérifier le status
minikube status

# Mettre en pause le cluster (sans supprimer les déploiements)
minikube pause

# Reprendre le cluster
minikube unpause

# Arrêter le cluster
minikube stop

# Supprimer le cluster
minikube delete

# Lister les addons disponibles
minikube addons list
```

---

## A faire
- Sécuriser
- Configurer
- Pratiquer
- Faire des snapshots régulierment ( à froid pour labo)

## C'est tout !

Vous avez installé Minikube sur Debian avec succès.  
Vous pouvez maintenant déployer des applications Kubernetes pour vos besoins de développement et de test.

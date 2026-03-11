# 01 — Déployer un pod Hello World HTML et tester via navigateur

Ce guide explique comment créer une image Docker custom avec une page HTML
personnalisée, la déployer dans Minikube et y accéder depuis un navigateur
sur un hôte distant (ex : Windows avec VMware Workstation).

---

## Prérequis

- Minikube démarré : `minikube status`
- kubectl fonctionnel : `kubectl get nodes`
- Docker disponible : `docker version`

---

## Étape 1 — Créer la page HTML et le Dockerfile

```bash
# Structure créée lors de l'installation
sudo mkdir -pv /srv/labo/{k8s,hello-html,scripts}

ls /srv/labo/hello-html/
```

### Page HTML (`index.html`)

```bash
vi /srv/labo/hello-html/index.html <<'HTML'
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8"/>
  <title>Hello Kubernetes</title>
  <style>
    body { font-family: sans-serif; background:#1a1a2e; color:#e0e0e0;
           display:flex; align-items:center; justify-content:center;
           height:100vh; margin:0; }
    .card { background:rgba(255,255,255,0.08); border-radius:16px;
            padding:3rem; text-align:center; }
    h1   { font-size:2.5rem; color:#53d8fb; }
    p    { color:#94a3b8; }
  </style>
</head>
<body>
  <div class="card">
    <h1>&#9096; Hello Kubernetes !</h1>
    <p>Pod custom — servi par nginx</p>
    <p>Namespace : <strong>default</strong></p>
  </div>
</body>
</html>
HTML
```

### Dockerfile

```bash
vi /srv/labo/hello-html/Dockerfile
FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Étape 2 — Construire l'image

### Cluster à 1 nœud

Pointer Docker vers le daemon interne de Minikube — l'image est directement
disponible pour Kubernetes sans registry :

```bash
eval $(minikube docker-env)
docker build -t hello-html:1.0 /srv/labo/hello-html/
docker images | grep hello-html
```

> ⚠️ Cette redirection est valable uniquement dans le terminal courant.

### Cluster multi-nœuds (2 nœuds ou plus)

`docker-env` est **incompatible avec les clusters multi-nœuds**. Utiliser
`minikube image load` qui copie l'image dans chaque nœud du cluster :

```bash
# Construire avec le Docker de l'hôte (pas minikube)
docker build -t hello-html:1.0 /srv/labo/hello-html/

# Charger dans tous les nœuds Minikube
minikube image load hello-html:1.0

# Vérifier la présence sur tous les nœuds
minikube image ls | grep hello-html
```

---

## Étape 3 — Manifeste Kubernetes (`01-kube-manifest.yml`)

Les ressources Deployment et Service sont définies dans un fichier YAML externe.

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-html
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-html
  template:
    metadata:
      labels:
        app: hello-html
    spec:
      containers:
        - name: hello-html
          image: hello-html:1.0
          imagePullPolicy: Never    # image locale, ne pas chercher sur Docker Hub
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-html
spec:
  selector:
    app: hello-html
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30090
```

### Appliquer le manifeste

```bash
kubectl apply -f /srv/labo/k8s/01-kube-manifest.yml
```

### Supprimer les ressources

```bash
kubectl delete -f /srv/labo/k8s/01-kube-manifest.yml
```

---

## Étape 4 — Vérifier le déploiement

```bash
# Pod en cours d'exécution ?
kubectl get pods -l app=hello-html

# Service NodePort créé ?
kubectl get svc hello-html

# Attendre que le pod soit Ready
kubectl wait pod -l app=hello-html --for=condition=Ready --timeout=60s

# Détail complet (events, erreurs éventuelles)
kubectl describe pod -l app=hello-html

# Logs nginx
kubectl logs -l app=hello-html
```

Résultat attendu :

```
NAME                          READY   STATUS    RESTARTS   AGE
hello-html-6d8f9c7b4-abc12    1/1     Running   0          30s

NAME         TYPE       CLUSTER-IP   EXTERNAL-IP   PORT(S)        AGE
hello-html   NodePort   10.96.x.x    <none>        80:30090/TCP   30s
```

---

## Étape 5 — Accéder via le navigateur

### Test local depuis la VM

```bash
# IP interne du nœud Minikube
minikube ip

# Test curl
curl http://$(minikube ip):30090
```

### Depuis un hôte distant (VMware Workstation)

Le réseau interne Minikube (`192.168.49.x`) n'est **pas routable** depuis
l'hôte Windows. Deux solutions :

---

#### Solution A — Port-forward ✅ (recommandée)

Expose le service sur l'IP VMware de la VM, accessible depuis Windows :

```bash
# Récupérer l'IP VMware de la VM
ip a | grep "inet " | grep -v 127
# → inet 192.168.1.204/24  ←  IP à utiliser depuis Windows

# Lancer le port-forward en arrière-plan
kubectl port-forward svc/hello-html 8888:80 --address='0.0.0.0' &

# Tester depuis la VM
curl http://192.168.1.204:8888
```

Depuis **Firefox Windows** :

```
http://192.168.1.204:8888
```

Arrêter le port-forward :

```bash
kill $(lsof -ti :8888)
```

---

#### Solution B — minikube tunnel

Crée un tunnel réseau et assigne une `EXTERNAL-IP` au service.
Nécessite un terminal dédié (reste en foreground) :

```bash
# Terminal 1 — lancer le tunnel (sudo requis)
sudo minikube tunnel

# Terminal 2 — vérifier l'EXTERNAL-IP assignée
kubectl get svc hello-html
# NAME         TYPE       CLUSTER-IP   EXTERNAL-IP     PORT(S)
# hello-html   NodePort   10.96.x.x    192.168.1.204   80:30090/TCP
```

Depuis **Firefox Windows** :

```
http://192.168.1.204:30090
```

---

## Schéma de l'architecture

```
 Hôte Windows (Firefox)
        │
        │  http://192.168.1.204:8888   (port-forward)
        │  http://192.168.1.204:30090  (minikube tunnel)
        ▼
 VM Debian — IP VMware : 192.168.1.204
        │
        │  kubectl port-forward  →  svc/hello-html:80
        │  minikube tunnel       →  NodePort :30090
        ▼
 Cluster Minikube — IP interne : 192.168.49.2
        │
        │  Service NodePort :30090
        ▼
 Pod hello-html
        │
        └─ nginx:alpine → index.html
           image : hello-html:1.0
```

---

## Mettre à jour la page HTML

```bash
# 1. Modifier index.html
nano /srv/labo/hello-html/index.html

# 2. Reconstruire l'image avec un nouveau tag
#    Cluster 1 nœud :
eval $(minikube docker-env)
docker build -t hello-html:2.0 /srv/labo/hello-html/

#    Cluster multi-nœuds :
docker build -t hello-html:2.0 /srv/labo/hello-html/
minikube image load hello-html:2.0

# 3. Rolling update
kubectl set image deployment/hello-html hello-html=hello-html:2.0

# 4. Suivre le déploiement
kubectl rollout status deployment/hello-html

# 5. Annuler si problème
kubectl rollout undo deployment/hello-html
```

---

## Commandes de diagnostic

```bash
# Entrer dans le pod
kubectl exec -it deployment/hello-html -- sh

# Vérifier le fichier HTML dans le conteneur
kubectl exec deployment/hello-html -- cat /usr/share/nginx/html/index.html

# Vérifier les images disponibles dans Minikube
minikube image ls | grep hello-html

# Redémarrer le pod
kubectl rollout restart deployment/hello-html
```

---

## Nettoyage

```bash
# Supprimer les ressources Kubernetes
kubectl delete -f /srv/labo/k8s/01-kube-manifest.yml

# Supprimer l'image de Minikube
minikube image rm hello-html:1.0

# Arrêter le port-forward si actif
kill $(lsof -ti :8888) 2>/dev/null || true
```
# 02 — Scaling des pods sur cluster multi-nœuds

Ce guide explique comment augmenter le nombre de pods sur un cluster
Minikube multi-nœuds, contrôler leur placement sur chaque nœud,
et appliquer des options de durcissement (hardening).

---

## Prérequis

```bash
# Vérifier que le cluster est multi-nœuds
kubectl get nodes
```

Résultat attendu :

```
NAME          STATUS   ROLES           AGE   VERSION
minikube      Ready    control-plane   10m   v1.35.x
minikube-m02  Ready    <none>          10m   v1.35.x
```

---

## Étape 1 — Structure des fichiers

```bash
# Créer le répertoire si ce n'est pas déjà fait
sudo mkdir -p /srv/labo/{k8s,hello-html,scripts}
sudo chown -R $USER:$USER /srv/labo
```

Arborescence finale de cette étape :

```
/srv/labo/
└── k8s/
    ├── 01-kube-manifest.yml       # pod hello-html (étape précédente)
    ├── 02-namespace.yml           # namespace dédié
    ├── 02-resourcequota.yml       # limites du namespace
    ├── 02-deployment-node1.yml    # déploiement ciblant le nœud 1
    ├── 02-deployment-node2.yml    # déploiement ciblant le nœud 2
    └── 02-hpa.yml                 # autoscaler horizontal
```

---

## Étape 2 — Namespace dédié

Bonne pratique : isoler les ressources de labo dans un namespace
séparé plutôt que d'utiliser `default`.

```bash
vi /srv/labo/k8s/02-namespace.yml
apiVersion: v1
kind: Namespace
metadata:
  name: labo
  labels:
    env: labo
    equipe: devops
```

**Mise en place du namespace**
```
kubectl apply -f /srv/labo/k8s/02-namespace.yml
```

---

## Étape 3 — ResourceQuota (bonne pratique)

Limiter les ressources consommables dans le namespace
**Objectif: **éviter qu'une mauvaise configuration ne sature le cluster.

```bash
vi /srv/labo/k8s/02-resourcequota.yml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-labo
  namespace: labo
spec:
  hard:
    pods: "6"                   # max 6 pods dans le namespace
    requests.cpu: "1"           # CPU total demandé
    requests.memory: "1Gi"      # RAM totale demandée
    limits.cpu: "2"             # CPU total maximum
    limits.memory: "2Gi"        # RAM totale maximum
```

**Exemple de calcul**
- Logique de dimensionnement pour nginx:alpine + HTML statique :
| | Valeur| Calcul pour 6 pods| Quota| 
| ----
| `requests.cpu`| `50m`| 6 × 50m = 300m| 1000m ✅| 
| `requests.memory`| `32Mi`| 6 × 32Mi = 192Mi| 1024Mi ✅| 
| `limits.cpu`| `100m`| 6 × 100m = 600m| 2000m ✅| 
| `limits.memory`| `64Mi`| 6 × 64Mi = 384Mi| 2048Mi ✅| 

Les quotas laissent une marge confortable — nginx:alpine en idle consomme environ `1m` CPU et `4Mi` RAM, donc même avec du trafic réel les limits à `100m/64Mi` sont très généreux.


**Mise en place du namespace**
```bash
kubectl apply -f /srv/labo/k8s/02-resourcequota.yml
```

**Vérifier les quotas**
```bash
kubectl describe resourcequota quota-labo -n labo
```

---

## Étape 4 — Labelliser les nœuds

Kubernetes utilise les labels pour diriger les pods vers les bons nœuds
via `nodeSelector` ou `nodeAffinity`.

```bash
# Labelliser le nœud 1 (control-plane)
kubectl label node minikube     role=node1 zone=primaire

# Labelliser le nœud 2 (worker)
kubectl label node minikube-m02 role=node2 zone=secondaire

# Vérifier les labels
kubectl get nodes --show-labels
```

---

## Étape 5 — Déploiement sur le nœud 1

### Avec `nodeSelector` (simple)

```bash
vi /srv/labo/k8s/02-deployment-node1.yml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-node1
  namespace: labo
  labels:
    app: hello-node1
    version: "1.0"
spec:
  replicas: 2                         # 2 pods sur le nœud 1
  selector:
    matchLabels:
      app: hello-node1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                     # max 1 pod supplémentaire pendant le update
      maxUnavailable: 0               # aucun pod indisponible pendant le update
  template:
    metadata:
      labels:
        app: hello-node1
        version: "1.0"
    spec:
      # ── Placement : nœud 1 uniquement ──────────────────────────────────────
      nodeSelector:
        role: node1                   # uniquement les nœuds avec ce label

      # ── Hardening : contexte de sécurité du pod ───────────────────────────
      securityContext:
        runAsNonRoot: true            # interdit de tourner en root
        runAsUser: 101                # UID nginx
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault        # profil seccomp par défaut du runtime

      # ── Anti-affinité : éviter 2 pods sur le même nœud ───────────────────
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: hello-node1
                topologyKey: kubernetes.io/hostname

      containers:
        - name: hello-node1
          image: hello-html:1.0
          imagePullPolicy: Never

          # ── Hardening : droits du conteneur ──────────────────────────────
          securityContext:
            allowPrivilegeEscalation: false   # interdit l'escalade de privilèges
            readOnlyRootFilesystem: true       # système de fichiers en lecture seule
            capabilities:
              drop:
                - ALL                          # supprime toutes les capabilities Linux
              add:
                - NET_BIND_SERVICE             # autorise nginx à binder le port 80

          ports:
            - containerPort: 80
              name: http

          # ── Ressources : requests et limits obligatoires ──────────────────
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"

          # ── Santé du pod ─────────────────────────────────────────────────
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 15
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10

          # ── Volume temporaire pour nginx (filesystem read-only) ───────────
          volumeMounts:
            - name: tmp-dir
              mountPath: /tmp
            - name: cache-dir
              mountPath: /var/cache/nginx
            - name: run-dir
              mountPath: /var/run

      volumes:
        - name: tmp-dir
          emptyDir: {}
        - name: cache-dir
          emptyDir: {}
        - name: run-dir
          emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: hello-node1
  namespace: labo
spec:
  selector:
    app: hello-node1
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30091
```

**Appliquer la configuration**
```bash
kubectl apply -f /srv/labo/k8s/02-deployment-node1.yml
```

---

## Étape 6 — Déploiement sur le nœud 2

```bash
vi /srv/labo/k8s/02-deployment-node2.yml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-node2
  namespace: labo
  labels:
    app: hello-node2
    version: "1.0"
spec:
  replicas: 2                         # 2 pods sur le nœud 2
  selector:
    matchLabels:
      app: hello-node2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: hello-node2
        version: "1.0"
    spec:
      # ── Placement : nœud 2 uniquement ──────────────────────────────────────
      nodeSelector:
        role: node2

      # ── Hardening identique au nœud 1 ─────────────────────────────────────
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault

      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: hello-node2
                topologyKey: kubernetes.io/hostname

      containers:
        - name: hello-node2
          image: hello-html:1.0
          imagePullPolicy: Never

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
              add:
                - NET_BIND_SERVICE

          ports:
            - containerPort: 80
              name: http

          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"

          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 15
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10

          volumeMounts:
            - name: tmp-dir
              mountPath: /tmp
            - name: cache-dir
              mountPath: /var/cache/nginx
            - name: run-dir
              mountPath: /var/run

      volumes:
        - name: tmp-dir
          emptyDir: {}
        - name: cache-dir
          emptyDir: {}
        - name: run-dir
          emptyDir: {}

---
apiVersion: v1
kind: Service
metadata:
  name: hello-node2
  namespace: labo
spec:
  selector:
    app: hello-node2
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30092
```

**Appliquer la configuration**
```bash
kubectl apply -f /srv/labo/k8s/02-deployment-node2.yml
```

---

## Étape 7 — HPA (Horizontal Pod Autoscaler)

```bash
vi /srv/labo/k8s/02-hpa.yml <<'YAML'
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-node1
  namespace: labo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello-node1
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-node2
  namespace: labo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello-node2
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

**Appliquer la configuration**
```bash
kubectl apply -f /srv/labo/k8s/02-hpa.yml
```

---

## Étape 8 — Vérifications

### Placement des pods sur les nœuds

```bash
# Voir sur quel nœud tourne chaque pod
kubectl get pods -n labo -o wide

# Résultat attendu :
# hello-node1-xxx   Running   minikube       ← nœud 1
# hello-node1-yyy   Running   minikube       ← nœud 1
# hello-node2-xxx   Running   minikube-m02   ← nœud 2
# hello-node2-yyy   Running   minikube-m02   ← nœud 2
```

### Ressources consommées

```bash
# CPU/RAM par pod
kubectl top pods -n labo

# CPU/RAM par nœud
kubectl top nodes
```

### État des HPA

```bash
kubectl get hpa -n labo
kubectl describe hpa hpa-node1 -n labo
```

### Quotas utilisés

```bash
kubectl describe resourcequota quota-labo -n labo
```

---

## Étape 9 — Tester le scaling manuellement

```bash
# Augmenter à 4 pods sur le nœud 1
kubectl scale deployment hello-node1 --replicas=4 -n labo

# Vérifier le placement
kubectl get pods -n labo -o wide

# Réduire à 2
kubectl scale deployment hello-node1 --replicas=2 -n labo
```

---

## Étape 10 — Tester l'accès via port-forward

```bash
# Accès nœud 1
kubectl port-forward svc/hello-node1 8891:80 -n labo --address='0.0.0.0' &

# Accès nœud 2
kubectl port-forward svc/hello-node2 8892:80 -n labo --address='0.0.0.0' &

# Test local
curl http://localhost:8891
curl http://localhost:8892
```

Depuis **Firefox Windows** (remplacer par l'IP de votre VM) :

```
http://192.168.1.204:8891    ← pods du nœud 1
http://192.168.1.204:8892    ← pods du nœud 2
```

---

## Récapitulatif des options de hardening

| Option | Directive YAML | Effet |
|---|---|---|
| Pas de root | `runAsNonRoot: true` | Interdit l'exécution en root |
| UID fixe | `runAsUser: 101` | Force l'UID du processus |
| Filesystem RO | `readOnlyRootFilesystem: true` | Empêche toute écriture dans le conteneur |
| Pas d'escalade | `allowPrivilegeEscalation: false` | Bloque `sudo` et `setuid` |
| Capabilities | `capabilities.drop: [ALL]` | Retire tous les droits kernel Linux |
| Seccomp | `seccompProfile: RuntimeDefault` | Filtre les appels système dangereux |
| Anti-affinité | `podAntiAffinity` | Évite 2 pods identiques sur le même nœud |
| Quotas | `ResourceQuota` | Limite les ressources du namespace |
| Probes | `livenessProbe` / `readinessProbe` | Détecte et remplace les pods défaillants |
| Requests/Limits | `resources.requests/limits` | Garanti CPU/RAM, évite la saturation |

---

## Nettoyage

```bash
# Supprimer toutes les ressources de l'étape
kubectl delete -f /srv/labo/k8s/02-hpa.yml
kubectl delete -f /srv/labo/k8s/02-deployment-node1.yml
kubectl delete -f /srv/labo/k8s/02-deployment-node2.yml
kubectl delete -f /srv/labo/k8s/02-resourcequota.yml
kubectl delete -f /srv/labo/k8s/02-namespace.yml

# Supprimer les labels des nœuds
kubectl label node minikube     role- zone-
kubectl label node minikube-m02 role- zone-

# Arrêter les port-forwards
kill $(lsof -ti :8891) 2>/dev/null || true
kill $(lsof -ti :8892) 2>/dev/null || true
```
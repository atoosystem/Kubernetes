# 03 — Forwarding automatique, scaling automatique et simulation de charge

---

## Partie 1 — Port-forward automatique (persistant)

Le `kubectl port-forward` natif s'arrête dès qu'il perd la connexion.
Pour le rendre persistant, deux approches.

### Avec Service systemd (persistant au reboot)

```bash
vi /srv/labo/scripts/kube-formward.sh
sudo tee /etc/systemd/system/kube-forward@.service > /dev/null <<'EOF'
[Unit]
Description=kubectl port-forward %i
After=network-online.target minikube.service
Wants=network-online.target

[Service]
# Format du paramètre : SERVICE:LOCAL_PORT:REMOTE_PORT:NAMESPACE
# Ex : systemctl start kube-forward@svc-hello-node1:8891:80:labo
Type=simple
Restart=always
RestartSec=3
ExecStart=/bin/bash -c '\
  PARAMS="%i"; \
  SVC=$(echo $PARAMS | cut -d: -f1 | tr - /); \
  LP=$(echo $PARAMS  | cut -d: -f2); \
  RP=$(echo $PARAMS  | cut -d: -f3); \
  NS=$(echo $PARAMS  | cut -d: -f4); \
  exec kubectl port-forward $SVC ${LP}:${RP} -n $NS --address=0.0.0.0'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# Activer pour hello-node1 (port 8891) et hello-node2 (port 8892)
sudo systemctl enable --now kube-forward@svc-hello-node1:8891:80:labo
sudo systemctl enable --now kube-forward@svc-hello-node2:8892:80:labo

# Vérifier
sudo systemctl status "kube-forward@*"
```
```bash
chmod +x /srv/labo/scripts/kube-formward.sh
#~: /srv/labo/scripts/kube-formward.sh
```

## Partie 2 — Scaling automatique (HPA)

Le HPA est déjà défini dans `02-hpa.yml`. Voici comment le surveiller
en temps réel et comprendre ses décisions.

```bash
# État du HPA (mise à jour toutes les 2s)
watch -n 2 kubectl get hpa -n labo

# Détail des décisions de scaling
kubectl describe hpa hpa-node1 -n labo

# Voir les événements de scaling
kubectl get events -n labo --field-selector reason=SuccessfulRescale

# Surveiller pods + HPA simultanément
watch -n 2 'kubectl get pods,hpa -n labo -o wide'
```

---

### LimitRange — bonne pratique complémentaire au HPA

Sans `LimitRange`, un pod sans `resources` définis n'est pas pris en compte
par le HPA. Ce manifeste définit des valeurs par défaut pour tous les pods
du namespace.

```bash
vi /srv/labo/k8s/03-limitrange.yml
apiVersion: v1
kind: LimitRange
metadata:
  name: limitrange-labo
  namespace: labo
spec:
  limits:
    - type: Container
      default:             # limits appliquées si non définies
        cpu: "100m"
        memory: "64Mi"
      defaultRequest:      # requests appliquées si non définies
        cpu: "50m"
        memory: "32Mi"
      max:                 # plafond absolu par conteneur
        cpu: "500m"
        memory: "256Mi"
      min:                 # plancher par conteneur
        cpu: "10m"
        memory: "8Mi"
````

```bash
kubectl apply -f /srv/labo/k8s/03-limitrange.yml
kubectl describe limitrange limitrange-labo -n labo
```

---

## Partie 3 — Simulation de charge

### Outil 1 — Générateur busybox intégré (sans installation)

Utilise une image déjà présente dans Minikube — aucun paquet à installer.

```bash
# Lancer un générateur de charge ciblant hello-node1
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n labo \
  -- sh -c "while true; do wget -q -O- http://hello-node1.labo.svc.cluster.local/; done"

# Surveiller le scaling en temps réel
watch -n 2 kubectl get hpa,pods -n labo
```

Arrêter le générateur :

```bash
kubectl delete pod load-generator -n labo
```

---

### Outil 2 — `hey` (HTTP load generator, léger)

```bash
# Installation sur la VM Debian
sudo apt-get install -y hey 2>/dev/null \
  || go install github.com/rakyll/hey@latest 2>/dev/null \
  || wget -qO /usr/local/bin/hey \
       https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64 \
     && chmod +x /usr/local/bin/hey

# Test simple — 200 requêtes, 10 en parallèle
hey -n 200 -c 10 http://192.168.1.204:8891/

# Charge soutenue pendant 60s — 20 workers
hey -z 60s -c 20 http://192.168.1.204:8891/

# Résultat affiché : latence p50/p99, req/s, erreurs
```

---

### Outil 3 — `k6` (simulation de scénarios réalistes)

```bash
# Installation
sudo apt-get install -y k6 2>/dev/null || {
  curl -fsSL https://dl.k6.io/key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] \
    https://dl.k6.io/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/k6.list
  sudo apt-get update -y && sudo apt-get install -y k6
}
```

Créer un scénario de charge progressif :

```bash
cat > /srv/labo/scripts/load-test.js <<'EOF'
import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 5  },   // montée progressive à 5 users
    { duration: '1m',  target: 20 },   // charge soutenue à 20 users
    { duration: '30s', target: 50 },   // pic à 50 users
    { duration: '30s', target: 0  },   // descente
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],   // 95% des requêtes < 500ms
    http_req_failed:   ['rate<0.01'],   // moins de 1% d'erreurs
  },
};

export default function () {
  const res = http.get('http://192.168.1.204:8891/');
  check(res, {
    'status 200':          (r) => r.status === 200,
    'temps < 200ms':       (r) => r.timings.duration < 200,
    'contient Hello':      (r) => r.body.includes('Hello'),
  });
  sleep(1);
}
EOF

# Lancer le test
k6 run /srv/labo/scripts/load-test.js

# Avec résultats en temps réel dans un second terminal
watch -n 2 kubectl get hpa,pods -n labo
```

---

## Partie 4 — Observer le scaling en action

Ouvrir **3 terminaux** simultanément :

```bash
# Terminal 1 — pods en temps réel
watch -n 2 kubectl get pods -n labo -o wide

# Terminal 2 — HPA en temps réel
watch -n 2 kubectl get hpa -n labo

# Terminal 3 — lancer la charge (choisir un outil)
hey -z 120s -c 30 http://192.168.1.204:8891/
```

Séquence observée :

```
t=0s   → HPA : 2/2 pods   CPU: 5%
t=30s  → Charge démarrée
t=60s  → HPA : 4/6 pods   CPU: 68%  ← scale up déclenché
t=90s  → HPA : 6/6 pods   CPU: 45%  ← maximum atteint
t=120s → Charge stoppée
t=180s → HPA : 2/6 pods   CPU: 3%   ← scale down (délai ~5min par défaut)
```

> Le scale down est intentionnellement lent (5 min par défaut) pour éviter
> les oscillations. Réduire pour les tests :

```bash
kubectl patch hpa hpa-node1 -n labo \
  -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":30}}}}'
```

---

## Récapitulatif des outils

| Outil | Usage | Installation |
|---|---|---|
| `busybox` | Générateur basique dans le cluster | Aucune (image Minikube) |
| `hey` | Test HTTP simple, statistiques claires | `wget` binaire |
| `k6` | Scénarios réalistes, seuils, rapports | APT |
| `ab` | Benchmark rapide | `apache2-utils` |

---

## Nettoyage

```bash
# Arrêter les forwards automatiques
sudo systemctl stop  "kube-forward@*"
sudo systemctl disable "kube-forward@*"

# Supprimer le pod générateur si actif
kubectl delete pod load-generator -n labo 2>/dev/null || true

# Supprimer le LimitRange
kubectl delete -f /srv/labo/k8s/03-limitrange.yml
```
#!/usr/bin/env bash
# =============================================================================
# install_minikube_docker.sh
# Installation complète de Minikube avec driver Docker
# OS cible : Debian
# =============================================================================
set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
RESET="\033[0m"; BOLD="\033[1m"
G="\033[1;32m"; C="\033[1;36m"; Y="\033[1;33m"; R="\033[1;31m"
ok()    { echo -e "${G}✓  $*${RESET}"; }
titre() { echo -e "\n${C}${BOLD}━━━  $*  ━━━${RESET}"; }
warn()  { echo -e "${Y}⚠  $*${RESET}"; }
erreur(){ echo -e "${R}✗  $*${RESET}"; }

# ── Configuration ─────────────────────────────────────────────────────────────
NODES="${MINIKUBE_NODES:-1}"          # nombre de nœuds (ex: MINIKUBE_NODES=2 ./script.sh)
PROXY_PORT="${PROXY_PORT:-8001}"      # port du kubectl proxy

# Arguments CLI
for arg in "$@"; do
  case $arg in
    --nodes=*) NODES="${arg#*=}" ;;
    --port=*)  PROXY_PORT="${arg#*=}" ;;
  esac
done

echo ""
echo "========================================"
echo " Installation Minikube — Driver Docker"
echo " Nœuds  : $NODES"
echo " Proxy  : 0.0.0.0:$PROXY_PORT"
echo "========================================"

# ═════════════════════════════════════════════════════════════════════════════
# 0. VÉRIFICATION DE LA VIRTUALISATION
# ═════════════════════════════════════════════════════════════════════════════
titre "0/10 — Vérification de la virtualisation"

VIRT=$(grep -cE '(vmx|svm)' /proc/cpuinfo || true)
if [ "$VIRT" -eq 0 ]; then
  warn "Virtualisation non détectée (vmx/svm absent)"
  warn "Le driver Docker peut tout de même fonctionner"
else
  ok "Virtualisation activée ($VIRT CPU(s) compatibles)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 1. MISE À JOUR DES PAQUETS
# ═════════════════════════════════════════════════════════════════════════════
titre "1/10 — Mise à jour des paquets"

sudo apt-get update -y
sudo apt-get upgrade -y
ok "Système à jour"

# ═════════════════════════════════════════════════════════════════════════════
# 2. PAQUETS INDISPENSABLES
# ═════════════════════════════════════════════════════════════════════════════
titre "2/10 — Installation des paquets indispensables"

sudo apt-get install -y \
  curl wget \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release
ok "Paquets de base installés"

# ═════════════════════════════════════════════════════════════════════════════
# 3. DOCKER
# ═════════════════════════════════════════════════════════════════════════════
titre "3/10 — Installation de Docker"

if command -v docker &>/dev/null; then
  ok "Docker déjà installé : $(docker --version)"
else
  sudo apt-get install -y docker.io
  ok "Docker installé"
fi

sudo systemctl start docker
sudo systemctl enable docker
ok "Docker démarré et activé au boot"

# Ajout de l'utilisateur courant au groupe docker
CURRENT_USER="${SUDO_USER:-$USER}"
if ! groups "$CURRENT_USER" | grep -q docker; then
  sudo usermod -aG docker "$CURRENT_USER"
  warn "Utilisateur '$CURRENT_USER' ajouté au groupe docker"
  warn "Une déconnexion/reconnexion sera nécessaire pour Docker sans sudo"
else
  ok "Utilisateur '$CURRENT_USER' déjà dans le groupe docker"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. KUBECTL
# ═════════════════════════════════════════════════════════════════════════════
titre "4/10 — Installation de kubectl"

if command -v kubectl &>/dev/null; then
  ok "kubectl déjà installé : $(kubectl version --client --short 2>/dev/null | head -1)"
else
  echo "  → Téléchargement de la dernière version stable..."
  KUBECTL_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)
  echo "  → Version : $KUBECTL_VERSION"

  curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

  # Vérification du checksum
  curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
  if echo "$(cat kubectl.sha256) kubectl" | sha256sum --check --quiet; then
    ok "Checksum kubectl vérifié"
  else
    erreur "Checksum kubectl invalide — abandon"
    rm -f kubectl kubectl.sha256
    exit 1
  fi
  rm -f kubectl.sha256

  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
  ok "kubectl installé dans /usr/local/bin/"
fi

kubectl version --client
ok "kubectl opérationnel"

# ═════════════════════════════════════════════════════════════════════════════
# 5. MINIKUBE
# ═════════════════════════════════════════════════════════════════════════════
titre "5/10 — Installation de Minikube"

if command -v minikube &>/dev/null; then
  ok "Minikube déjà installé : $(minikube version --short)"
else
  echo "  → Téléchargement de la dernière version..."
  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo install minikube-linux-amd64 /usr/local/bin/minikube
  rm -f minikube-linux-amd64
  ok "Minikube installé dans /usr/local/bin/"
fi

minikube version
ok "Minikube opérationnel"

# ═════════════════════════════════════════════════════════════════════════════
# 6. DÉMARRAGE DU CLUSTER
# ═════════════════════════════════════════════════════════════════════════════
titre "6/10 — Démarrage du cluster Minikube"

MINIKUBE_STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")

if [[ "$MINIKUBE_STATUS" == "Running" ]]; then
  ok "Cluster déjà en cours d'exécution"
else
  echo "  → Démarrage avec $NODES nœud(s)..."
  minikube start --driver=docker --nodes="$NODES" --force || \
    minikube start --driver=docker --nodes="$NODES"
  ok "Cluster démarré avec $NODES nœud(s)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 7. VÉRIFICATION DU CLUSTER
# ═════════════════════════════════════════════════════════════════════════════
titre "7/10 — Vérification du cluster"

minikube status
echo ""
kubectl cluster-info
echo ""
kubectl get nodes
ok "Cluster opérationnel"

# ═════════════════════════════════════════════════════════════════════════════
# 8. PROXY KUBECTL
# ═════════════════════════════════════════════════════════════════════════════
titre "8/10 — Démarrage du proxy kubectl"

# Libérer le port s'il est déjà occupé
if lsof -ti :"$PROXY_PORT" &>/dev/null; then
  warn "Port $PROXY_PORT occupé — arrêt du processus existant..."
  kill "$(lsof -ti :"$PROXY_PORT")" 2>/dev/null || true
  sleep 1
fi

kubectl proxy \
  --port="$PROXY_PORT" \
  --address='0.0.0.0' \
  --accept-hosts='.*' \
  > /tmp/kubectl-proxy.log 2>&1 &

PROXY_PID=$!
sleep 2

if kill -0 "$PROXY_PID" 2>/dev/null; then
  echo "$PROXY_PID" > /tmp/kubectl-proxy.pid
  ok "Proxy démarré (PID $PROXY_PID) sur le port $PROXY_PORT"
else
  erreur "Le proxy n'a pas démarré"
  cat /tmp/kubectl-proxy.log
  exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
# 9. ADDONS
# ═════════════════════════════════════════════════════════════════════════════
titre "9/10 — Activation des addons"

# Désactiver storage et ingress explicitement (évite les résidus de config)
minikube config set default-storageclass false
minikube config set storage-provisioner false

# Activer uniquement les addons nécessaires
# registry ajouté automatiquement si cluster multi-nœuds
ADDONS="default-storageclass ingress storage-provisioner metrics-server dashboard"    # addons à activer
# registry ajouté si cluster multi-nœuds (docker-env incompatible avec multi-nœuds)
if [[ "$NODES" -gt 1 ]]; then
  ADDONS="$ADDONS registry"
fi

for addon in $ADDONS; do
  info "Activation de $addon..."
  # On tente toujours l'activation — minikube ignore silencieusement
  # si l'addon est déjà actif (pas d'erreur, pas de parsing fragile)
  if minikube addons enable "$addon" 2>/dev/null; then
    ok "addon $addon activé"
  else
    warn "addon $addon : échec d'activation (non bloquant, on continue)"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# 10. ACCÈS AU DASHBOARD
# ═════════════════════════════════════════════════════════════════════════════
titre "10/10 — Accès au Dashboard"

# Récupérer l'IP de la machine pour l'accès distant
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Démarrer le dashboard en arrière-plan (mode URL uniquement)
minikube dashboard --url > /tmp/minikube-dashboard.log 2>&1 &
sleep 3

echo ""
echo "========================================"
echo " Installation terminée ✓"
echo "========================================"
echo ""
echo "  Nœuds   : $(kubectl get nodes --no-headers | wc -l)"
echo "  Proxy   : PID $(cat /tmp/kubectl-proxy.pid 2>/dev/null)"
echo ""
echo "  ── Dashboard ───────────────────────────────────────────────"
echo "  Depuis la VM    :"
echo "  http://localhost:${PROXY_PORT}/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/"
echo ""
echo "  Depuis l'hôte   (remplacer par votre IP) :"
echo "  http://${LOCAL_IP}:${PROXY_PORT}/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/"
echo ""
echo "  ── Commandes utiles ────────────────────────────────────────"
echo "  \$ kubectl get pods -A"
echo "  \$ kubectl get nodes"
echo "  \$ minikube status"
echo "  \$ minikube addons list"
echo ""
echo "  ── Arrêt propre ────────────────────────────────────────────"
echo "  \$ kill \$(cat /tmp/kubectl-proxy.pid) && minikube stop"
echo ""
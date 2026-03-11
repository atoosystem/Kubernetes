#!/usr/bin/env bash
# =============================================================================
# start-minikube.sh — Démarrage propre du cluster Minikube
# Usage : ./start-minikube.sh [--driver=docker|none] [--nodes=N]
# Exemple:./start-minikube.sh --nodes=3 # 3 nœuds avec docker
# =============================================================================
set -euo pipefail

# ── Configuration (modifiable) ────────────────────────────────────────────────
DRIVER="${MINIKUBE_DRIVER:-docker}"   # docker | none
NODES="${MINIKUBE_NODES:-1}"          # nombre de nœuds
PROXY_PORT="${PROXY_PORT:-8001}"      # port du kubectl proxy
PROXY_ADDRESS="${PROXY_ADDRESS:-0.0.0.0}"  # 0.0.0.0 = accessible depuis l'hôte
ADDONS="default-storageclass ingress storage-provisioner metrics-server dashboard"    # addons à activer
# registry ajouté si cluster multi-nœuds (docker-env incompatible avec multi-nœuds)
if [[ "$NODES" -gt 1 ]]; then
  ADDONS="$ADDONS registry"
fi


# ── Couleurs ──────────────────────────────────────────────────────────────────
RESET="\033[0m"; BOLD="\033[1m"
G="\033[1;32m"; C="\033[1;36m"; Y="\033[1;33m"; B="\033[1;34m"
ok()    { echo -e "${G}✓  $*${RESET}"; }
titre() { echo -e "\n${C}${BOLD}━━━  $*  ━━━${RESET}"; }
warn()  { echo -e "${Y}⚠  $*${RESET}"; }
info()  { echo -e "${B}ℹ  $*${RESET}"; }

# ── Arguments CLI ─────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --driver=*) DRIVER="${arg#*=}" ;;
    --nodes=*)  NODES="${arg#*=}"  ;;
    --port=*)   PROXY_PORT="${arg#*=}" ;;
  esac
done

echo ""
echo "========================================"
echo " Démarrage Minikube"
echo " Driver  : $DRIVER"
echo " Nœuds   : $NODES"
echo " Proxy   : $PROXY_ADDRESS:$PROXY_PORT"
echo "========================================"

# ═════════════════════════════════════════════════════════════════════════════
# 1. VÉRIFICATIONS PRÉALABLES
# ═════════════════════════════════════════════════════════════════════════════
titre "1/5 — Vérifications"

for cmd in minikube kubectl; do
  command -v "$cmd" &>/dev/null \
    && ok "$cmd trouvé : $(command -v $cmd)" \
    || { echo "$cmd introuvable — installez-le avant de continuer."; exit 1; }
done

if [[ "$DRIVER" == "docker" ]]; then
  command -v docker &>/dev/null || { echo "docker introuvable."; exit 1; }
  sudo systemctl is-active docker &>/dev/null \
    && ok "Docker actif" \
    || { warn "Docker arrêté — tentative de démarrage..."; sudo systemctl start docker; }
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. ARRÊT PROPRE DE L'ÉVENTUEL PROXY EN COURS
# ═════════════════════════════════════════════════════════════════════════════
titre "2/5 — Nettoyage du proxy existant"

if lsof -ti :"$PROXY_PORT" &>/dev/null; then
  warn "Port $PROXY_PORT occupé — arrêt du processus existant..."
  kill "$(lsof -ti :"$PROXY_PORT")" 2>/dev/null || true
  sleep 1
  ok "Port $PROXY_PORT libéré"
else
  ok "Port $PROXY_PORT disponible"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. DÉMARRAGE DE MINIKUBE
# ═════════════════════════════════════════════════════════════════════════════
titre "3/5 — Démarrage du cluster"

MINIKUBE_STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")

if [[ "$MINIKUBE_STATUS" == "Running" ]]; then
  ok "Cluster déjà en cours d'exécution"
else
  info "Démarrage du cluster ($DRIVER, $NODES nœud(s))..."

  if [[ "$DRIVER" == "none" ]]; then
    # Driver none — bare metal, nécessite iptables legacy
    if command -v iptables-legacy &>/dev/null; then
      sudo update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
      sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
      info "iptables basculé en mode legacy"
    fi
    sudo minikube start \
      --driver=none \
      --extra-config=apiserver.authorization-mode=Node,RBAC
  else
    minikube start \
      --driver="$DRIVER" \
      --nodes="$NODES"
  fi

  ok "Cluster démarré"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. ACTIVATION DES ADDONS
# ═════════════════════════════════════════════════════════════════════════════
titre "4/5 — Activation des addons"

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
# 5. DÉMARRAGE DU PROXY
# ═════════════════════════════════════════════════════════════════════════════
titre "5/5 — Démarrage du proxy kubectl"

info "Lancement sur $PROXY_ADDRESS:$PROXY_PORT en arrière-plan..."
kubectl proxy \
  --port="$PROXY_PORT" \
  --address="$PROXY_ADDRESS" \
  --accept-hosts='.*' \
  > /tmp/kubectl-proxy.log 2>&1 &

PROXY_PID=$!
sleep 2

# Vérifier que le proxy a bien démarré
if kill -0 "$PROXY_PID" 2>/dev/null; then
  ok "Proxy démarré (PID $PROXY_PID)"
  echo "$PROXY_PID" > /tmp/kubectl-proxy.pid
else
  echo "Le proxy n'a pas démarré — voir /tmp/kubectl-proxy.log"
  cat /tmp/kubectl-proxy.log
  exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ═════════════════════════════════════════════════════════════════════════════
titre "État du cluster"

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -n kubernetes-dashboard 2>/dev/null || true

# Récupérer l'IP locale pour afficher l'URL complète
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "========================================"
echo " Cluster prêt ✓"
echo "========================================"
echo ""
echo "  Nœuds    : $(kubectl get nodes --no-headers | wc -l)"
echo "  Proxy PID: $PROXY_PID  (log: /tmp/kubectl-proxy.log)"
echo ""
echo "  ── Accès au Dashboard ──────────────────────────────────────"
echo "  Depuis la VM    :"
echo "  http://localhost:${PROXY_PORT}/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/"
echo ""
echo "  Depuis l'hôte   :"
echo "  http://${LOCAL_IP}:${PROXY_PORT}/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/"
echo ""
echo "  ── Commandes utiles ────────────────────────────────────────"
echo "  \$ kubectl get pods -A"
echo "  \$ kubectl get nodes"
echo "  \$ minikube status"
echo "  \$ minikube dashboard --url"
echo ""
echo "  ── Arrêter proprement ──────────────────────────────────────"
echo "  \$ ./stop-minikube.sh"
echo "     ou manuellement :"
echo "  \$ kill \$(cat /tmp/kubectl-proxy.pid) && minikube stop"
echo ""

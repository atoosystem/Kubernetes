#!/usr/bin/env bash
# =============================================================================
# stop-minikube.sh — Arrêt propre du cluster Minikube
# =============================================================================
set -euo pipefail

PROXY_PORT="${PROXY_PORT:-8001}"

RESET="\033[0m"; BOLD="\033[1m"
G="\033[1;32m"; C="\033[1;36m"; Y="\033[1;33m"
ok()    { echo -e "${G}✓  $*${RESET}"; }
titre() { echo -e "\n${C}${BOLD}━━━  $*  ━━━${RESET}"; }
warn()  { echo -e "${Y}⚠  $*${RESET}"; }

echo ""
echo "========================================"
echo " Arrêt Minikube"
echo "========================================"

# ── 1. Arrêt du proxy ─────────────────────────────────────────────────────────
titre "1/2 — Arrêt du proxy kubectl"

if [ -f /tmp/kubectl-proxy.pid ]; then
  PID=$(cat /tmp/kubectl-proxy.pid)
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    ok "Proxy (PID $PID) arrêté"
  else
    warn "PID $PID introuvable (déjà arrêté ?)"
  fi
  rm -f /tmp/kubectl-proxy.pid
elif lsof -ti :"$PROXY_PORT" &>/dev/null; then
  kill "$(lsof -ti :"$PROXY_PORT")"
  ok "Proxy sur port $PROXY_PORT arrêté"
else
  ok "Aucun proxy en cours"
fi

# ── 2. Arrêt du cluster ───────────────────────────────────────────────────────
titre "2/2 — Arrêt du cluster Minikube"

if minikube status &>/dev/null; then
  minikube stop
  ok "Cluster arrêté"
else
  ok "Cluster déjà arrêté"
fi

echo ""
echo "========================================"
echo " Arrêt terminé ✓"
echo "========================================"
echo ""
echo "  Redémarrer : \$ ./start-minikube.sh"
echo ""
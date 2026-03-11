#!/usr/bin/env bash
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
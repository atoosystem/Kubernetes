#!/usr/bin/env bash
# Installer k6
sudo apt-get install -y k6 2>/dev/null || {
  echo "deb [trusted=yes] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
  sudo apt-get update -y && sudo apt-get install -y k6
}

# Création du scenario
cat > /srv/labo/scripts/load-test.js <<'EOF'
import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 5  },   // montée progressive à 5 users
    { duration: '1m',  target: 20 },   // charge soutenue à 20 users
    { duration: '2m', target: 50 },   // pic à 50 users
    { duration: '1m', target: 0  },   // descente
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

echo ""
echo "========================================"
echo " # Lancer le test"
echo " k6 run /srv/labo/scripts/load-test.js"
echo ""
echo " # Avec résultats en temps réel dans un second terminal"
echo " watch -n 2 kubectl get hpa,pods -n labo"
echo "========================================"

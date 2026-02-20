#!/bin/bash

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

CLUSTER_NAME="security-demo"
NAMESPACE="vulnerable-app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"



# ── [1] Prerequisites ────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/9] Checking prerequisites...${NC}"
for tool in k3d kubectl docker; do
  command -v $tool &>/dev/null \
    && echo -e "  ${GREEN}✓${NC} $tool" \
    || { echo -e "  ${RED}✗${NC} $tool not found"; exit 1; }
done

# ── [2] Required files ───────────────────────────────────────────────────────
echo -e "\n${YELLOW}[2/9] Checking required files...${NC}"
for f in app.py Dockerfile vulnerable-deployment.yaml attacker-pod.yaml sniffer-pod.yaml; do
  [ -f "$SCRIPT_DIR/$f" ] \
    && echo -e "  ${GREEN}✓${NC} $f" \
    || { echo -e "  ${RED}✗${NC} $f missing from $SCRIPT_DIR"; exit 1; }
done

# ── [3] Docker credential helper fix (macOS Docker Desktop) ─────────────────
echo -e "\n${YELLOW}[3/9] Checking Docker credential config...${NC}"
DOCKER_CONFIG="$HOME/.docker/config.json"
if [ -f "$DOCKER_CONFIG" ] && grep -q '"credsStore"' "$DOCKER_CONFIG"; then
  CREDS=$(python3 -c "import json; print(json.load(open('$DOCKER_CONFIG')).get('credsStore',''))" 2>/dev/null)
  if [ -n "$CREDS" ] && ! command -v "docker-credential-$CREDS" &>/dev/null; then
    cp "$DOCKER_CONFIG" "${DOCKER_CONFIG}.bak"
    python3 -c "
import json
with open('$DOCKER_CONFIG') as f: d = json.load(f)
d.pop('credsStore', None)
with open('$DOCKER_CONFIG', 'w') as f: json.dump(d, f, indent=2)
"
    echo -e "  ${GREEN}✓${NC} Patched broken credsStore (backup saved)"
  else
    echo -e "  ${GREEN}✓${NC} OK"
  fi
else
  echo -e "  ${GREEN}✓${NC} OK"
fi

# ── [4] k3d cluster ──────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[4/9] Checking k3d cluster '${CLUSTER_NAME}'...${NC}"
if k3d cluster list 2>/dev/null | grep -q $CLUSTER_NAME; then
  echo -e "  ${GREEN}✓${NC} Cluster already exists"
else
  k3d cluster create $CLUSTER_NAME --agents 1 --wait
  echo -e "  ${GREEN}✓${NC} Cluster created"
fi

# ── [5] Label agent node (pins all demo pods to same node — critical for sniffing) ──
echo -e "\n${YELLOW}[5/9] Labelling agent node...${NC}"
AGENT_NODE=$(kubectl get nodes --no-headers | grep -v 'control-plane\|master' | awk 'NR==1{print $1}')
[ -z "$AGENT_NODE" ] && AGENT_NODE=$(kubectl get nodes --no-headers | awk 'NR==2{print $1}')
kubectl label node "$AGENT_NODE" node-role=demo --overwrite > /dev/null
echo -e "  ${GREEN}✓${NC} Node labelled: $AGENT_NODE"

# ── [6] Build image ──────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[6/9] Building vulnerable Docker image...${NC}"
cd "$SCRIPT_DIR"
docker build -t vulnerable-demo-app:latest -f Dockerfile . -q
echo -e "  ${GREEN}✓${NC} Image built"

# ── [7] Import images ────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[7/9] Importing images into k3d...${NC}"
k3d image import vulnerable-demo-app:latest -c $CLUSTER_NAME
echo -e "  ${GREEN}✓${NC} vulnerable-demo-app imported"
docker pull nicolaka/netshoot:latest -q
k3d image import nicolaka/netshoot:latest -c $CLUSTER_NAME
echo -e "  ${GREEN}✓${NC} nicolaka/netshoot imported"

# ── [8] Deploy manifests ─────────────────────────────────────────────────────
echo -e "\n${YELLOW}[8/9] Deploying manifests...${NC}"
kubectl apply -f "$SCRIPT_DIR/vulnerable-deployment.yaml" > /dev/null
kubectl apply -f "$SCRIPT_DIR/attacker-pod.yaml" > /dev/null
kubectl apply -f "$SCRIPT_DIR/sniffer-pod.yaml" > /dev/null

# Demo secrets (k3s 1.24+ no longer auto-creates SA token secrets)
kubectl create secret generic db-credentials \
  --from-literal=db-password=hunter2 \
  --from-literal=db-host=postgres.internal \
  -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f - > /dev/null
kubectl create secret generic api-keys \
  --from-literal=stripe-key=sk_live_FAKEKEYFORDEMO123 \
  --from-literal=github-token=ghp_FAKEGITHUBTOKENDEMO \
  -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo -e "  ${GREEN}✓${NC} Manifests and demo secrets applied"

# ── [9] Wait for pods ────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[9/9] Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=vulnerable-app \
  -n $NAMESPACE --timeout=180s \
  && echo -e "  ${GREEN}✓${NC} vulnerable-app ready" \
  || echo -e "  ${RED}✗${NC} vulnerable-app timed out"

kubectl wait --for=condition=ready pod -l app=backend-api \
  -n $NAMESPACE --timeout=180s \
  && echo -e "  ${GREEN}✓${NC} backend-api ready" \
  || echo -e "  ${YELLOW}⚠${NC}  backend-api still starting (flask installs at boot, wait ~60s more)"

kubectl wait --for=condition=ready pod attacker-pod \
  -n $NAMESPACE --timeout=60s \
  && echo -e "  ${GREEN}✓${NC} attacker-pod ready" \
  || echo -e "  ${YELLOW}⚠${NC}  attacker-pod not ready"

kubectl wait --for=condition=ready pod sniffer-pod \
  -n $NAMESPACE --timeout=60s \
  && echo -e "  ${GREEN}✓${NC} sniffer-pod ready" \
  || echo -e "  ${YELLOW}⚠${NC}  sniffer-pod not ready"

# ── Final status ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}Pod placement (all must be on same node):${NC}"
kubectl get pods -n $NAMESPACE -o wide \
  | grep -E 'NAME|vulnerable-app|backend-api|attacker-pod|sniffer-pod'

echo ""
NODES_USED=$(kubectl get pods -n $NAMESPACE -o wide --no-headers \
  | grep -E 'vulnerable-app|backend-api|attacker-pod|sniffer-pod' \
  | awk '{print $7}' | sort -u | wc -l | tr -d ' ')
[ "$NODES_USED" = "1" ] \
  && echo -e "${GREEN}✓ All pods on same node — tcpdump demo will work${NC}" \
  || echo -e "${RED}✗ Pods on different nodes — re-run setup.sh${NC}"

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo -e "Run ${BOLD}./check.sh${NC} to verify all demos are ready."
echo -e "${RED}⚠  After the talk: k3d cluster delete $CLUSTER_NAME${NC}"

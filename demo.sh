#!/bin/bash
# =============================================================================
# CNI Phantom Nodes Demo
# Reproduces the "paying for nodes that can't serve pods" failure mode
#
# Prerequisites: kind, kubectl, helm, jq
# Usage: ./demo.sh [scenario]
#   scenarios: setup | exhaust-ips | slow-cni | kill-kube-proxy | cost | heal | cleanup
# =============================================================================

set -euo pipefail
CLUSTER_NAME="cni-phantom-demo"
NAMESPACE="phantom-demo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEMO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

# --- SETUP ---
setup() {
    log "Creating kind cluster (4 nodes, no default CNI)..."
    kind create cluster --config kind-config.yaml --wait 60s

    log "Nodes are NotReady (no CNI yet):"
    kubectl get nodes
    echo ""

    log "Installing Cilium with constrained IPAM (10.244.0.0/24 = 254 IPs)..."
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update cilium 2>/dev/null

    helm install cilium cilium/cilium --version 1.16.0 \
        --namespace kube-system \
        --set image.pullPolicy=IfNotPresent \
        --set ipam.mode=cluster-pool \
        --set ipam.operator.clusterPoolIPv4PodCIDRList="{10.244.0.0/24}" \
        --set ipam.operator.clusterPoolIPv4MaskSize=26 \
        --set tunnel=vxlan \
        --set operator.replicas=1 \
        --wait --timeout 120s

    log "Waiting for nodes to become Ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    log "Creating demo namespace..."
    kubectl create namespace $NAMESPACE

    log ""
    log "Cluster ready. Cilium installed with /24 pod CIDR (254 total IPs)."
    log "Each node gets a /26 (62 usable IPs)."
    log ""
    log "Current IP allocation:"
    check_ips
    log ""
    log "Next: run './demo.sh exhaust-ips' to fill the IP pool"
}

# --- CHECK IP ALLOCATION ---
check_ips() {
    echo "  Cilium IPAM status:"
    kubectl get ciliumnode -o custom-columns=\
'NODE:.metadata.name,ALLOCATED:.status.ipam.used | length(@),AVAILABLE:.spec.ipam.pool | length(@)' 2>/dev/null || \
    kubectl get pods -A --no-headers | wc -l | xargs -I{} echo "  Total pods running: {}"

    local total_pods
    total_pods=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    echo "  Total pods across cluster: $total_pods"
    echo "  Max pod IPs available: ~248 (254 minus node/service IPs)"
}

# --- SCENARIO 1: IP Exhaustion ---
exhaust_ips() {
    log "=== SCENARIO: IP Exhaustion Mid-Scale ==="
    log "Deploying pods until the /24 CIDR is exhausted..."
    log "This simulates what happens when your subnet runs out of IPs during scale-up"
    log ""

    # Deploy in batches
    kubectl create deployment ip-eater --image=busybox \
        --namespace=$NAMESPACE -- sleep 3600 2>/dev/null || true

    log "Scaling to 200 replicas (will exceed available IPs)..."
    kubectl scale deployment ip-eater --replicas=200 -n $NAMESPACE

    log "Waiting 30s for scheduling to attempt..."
    sleep 30

    log ""
    log "=== Results ==="
    local running pending
    running=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    pending=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)

    info "Pods Running: $running"
    err  "Pods Pending (no IP available): $pending"
    echo ""

    log "Pods stuck in ContainerCreating (have a node, but no IP):"
    kubectl get pods -n $NAMESPACE | grep -c "ContainerCreating" | xargs -I{} echo "  {} pods in ContainerCreating"
    echo ""

    warn "These pods are SCHEDULED to nodes. The nodes are BILLING."
    warn "But the pods will never start because there are no IPs left."
    warn "The autoscaler sees 'capacity available' and won't provision more nodes."
    echo ""

    log "Check events for the failure reason:"
    kubectl get events -n $NAMESPACE --field-selector reason=FailedCreatePodSandBox --sort-by='.lastTimestamp' 2>/dev/null | tail -5
}

# --- SCENARIO 2: Slow CNI Init ---
slow_cni() {
    log "=== SCENARIO: Slow CNI Initialization ==="
    log "Simulating what happens when CNI takes 60s+ to initialize on a new node"
    log "(In production: ENI attachment throttling, slow API calls, etc.)"
    log ""

    # We'll simulate this by adding a node with a taint, then showing the gap
    # between node Ready and pod schedulable

    log "Adding a new worker node to the cluster..."
    # kind doesn't support dynamic node add, so we simulate with a taint/untaint
    # that represents the CNI init window

    local node
    node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | tail -1)

    log "Cordoning $node to simulate 'node exists but CNI not ready'..."
    kubectl cordon $node

    log "Deploying 10 pods that want to schedule on this node..."
    kubectl create deployment slow-cni-victim --image=busybox \
        --namespace=$NAMESPACE -- sleep 3600 2>/dev/null || true
    kubectl scale deployment slow-cni-victim --replicas=10 -n $NAMESPACE

    sleep 5
    log ""
    info "Node $node is cordoned (simulating CNI init delay)."
    info "Pods are Pending - they see the node but can't schedule."
    kubectl get pods -n $NAMESPACE -l app=slow-cni-victim --no-headers | head -5
    echo ""

    warn "In production, this node is RUNNING and BILLING."
    warn "The scheduler sees it as 'Ready' but pods can't start."
    warn "Duration depends on: ENI attach time, IP allocation, kube-proxy startup."
    echo ""

    log "Simulating CNI becoming ready after 60s..."
    log "(In real life: ENI finally attaches, IPs allocated, kube-proxy starts)"
    sleep 5
    kubectl uncordon $node
    log "Node uncordoned. Pods will now schedule."
    sleep 10
    kubectl get pods -n $NAMESPACE -l app=slow-cni-victim --no-headers | head -5
}

# --- SCENARIO 3: kube-proxy Crash ---
kill_kube_proxy() {
    log "=== SCENARIO: kube-proxy Failure Cascade ==="
    log "kube-proxy is a hidden dependency for most CNI plugins."
    log "If it crashes, the CNI DaemonSet can't reach Ready."
    log ""

    local node
    node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | head -1 | cut -d/ -f2)

    log "Target node: $node"
    log "Current kube-proxy status on this node:"
    kubectl get pods -n kube-system -l k8s-app=kube-proxy --field-selector spec.nodeName=$node
    echo ""

    log "Killing kube-proxy on $node..."
    local proxy_pod
    proxy_pod=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy \
        --field-selector spec.nodeName=$node -o name | head -1)
    kubectl delete $proxy_pod -n kube-system --grace-period=0 --force 2>/dev/null

    log "Waiting for cascade effect..."
    sleep 10

    log ""
    log "Node conditions after kube-proxy death:"
    kubectl get node $node -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}){"\n"}{end}'
    echo ""

    warn "In production with certain CNI configurations:"
    warn "  1. kube-proxy dies → iptables rules stale"
    warn "  2. CNI health check fails (can't reach API server via service IP)"
    warn "  3. CNI DaemonSet pod goes NotReady"
    warn "  4. Node condition: NetworkPluginNotReady"
    warn "  5. Existing pods keep running but NEW pods can't get network"
    echo ""

    log "kube-proxy will restart (DaemonSet), but the gap is the problem."
    log "On slow nodes or during API server pressure, this gap can be minutes."
}

# --- COST CALCULATOR ---
cost() {
    log "=== Phantom Node Cost Calculator ==="
    log ""

    # Gather node data
    local nodes_total nodes_ready nodes_notready
    nodes_total=$(kubectl get nodes --no-headers | wc -l)
    nodes_ready=$(kubectl get nodes --no-headers | grep -c " Ready" || echo 0)
    nodes_notready=$((nodes_total - nodes_ready))

    info "Total nodes: $nodes_total"
    info "Ready nodes: $nodes_ready"
    if [ "$nodes_notready" -gt 0 ]; then
        err "NotReady nodes: $nodes_notready"
    else
        log "NotReady nodes: 0"
    fi
    echo ""

    # Check for pods stuck in ContainerCreating
    local stuck_pods
    stuck_pods=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "ContainerCreating" || echo 0)

    if [ "$stuck_pods" -gt 0 ]; then
        err "Pods stuck in ContainerCreating: $stuck_pods"
        echo ""
        warn "Cost formula:"
        warn "  phantom_cost = node_hourly_rate × notready_duration_hours × scale_events_per_day"
        warn ""
        warn "Example (GPU nodes):"
        warn "  \$32/hr × 0.08hr (5 min) × 10 scale events/day = \$25.60/day wasted"
        warn "  \$32/hr × 0.08hr × 10 × 30 days = \$768/month invisible waste"
    else
        log "No stuck pods currently. Run './demo.sh exhaust-ips' first."
    fi
}

# --- SELF-HEALING ---
heal() {
    log "=== Self-Healing Patterns ==="
    log ""

    log "1. Readiness Gate - don't schedule until networking is verified"
    cat manifests/readiness-gate.yaml
    echo ""

    log "2. IP Capacity Alert - warn before exhaustion"
    cat manifests/ip-capacity-alert.yaml
    echo ""

    log "3. Node Readiness Deadline - replace stalled nodes"
    info "With Karpenter: set spec.disruption.consolidateAfter to replace"
    info "nodes that haven't become fully ready within 3 minutes."
    echo ""

    log "Applying readiness gate..."
    kubectl apply -f manifests/readiness-gate.yaml 2>/dev/null || \
        warn "Apply manually - see manifests/readiness-gate.yaml"
}

# --- CLEANUP ---
cleanup() {
    log "Deleting kind cluster..."
    kind delete cluster --name $CLUSTER_NAME
    log "Done."
}

# --- MAIN ---
case "${1:-help}" in
    setup)          setup ;;
    exhaust-ips)    exhaust_ips ;;
    slow-cni)       slow_cni ;;
    kill-kube-proxy) kill_kube_proxy ;;
    cost)           cost ;;
    heal)           heal ;;
    cleanup)        cleanup ;;
    ips)            check_ips ;;
    *)
        echo "Usage: ./demo.sh <scenario>"
        echo ""
        echo "Scenarios (run in order):"
        echo "  setup           - Create kind cluster with Cilium (constrained /24 CIDR)"
        echo "  exhaust-ips     - Scale past available IPs - pods stuck in ContainerCreating"
        echo "  slow-cni        - Simulate slow CNI init (node billing, pods can't start)"
        echo "  kill-kube-proxy - Show kube-proxy crash cascade on CNI readiness"
        echo "  cost            - Calculate phantom node cost"
        echo "  heal            - Deploy self-healing patterns"
        echo "  cleanup         - Delete the cluster"
        echo "  ips             - Check current IP allocation"
        ;;
esac

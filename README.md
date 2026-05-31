# Paying for Phantom Nodes: CNI Readiness Failure Demo

Companion repo for KubeCon 2026 talk.

## The Problem

When a Kubernetes node launches, there is a gap between "instance running" and "network actually works." During this gap, the node is billing but can not serve pods. The scheduler sees the node as Ready and places pods on it. Those pods sit in ContainerCreating until someone notices. The autoscaler sees "capacity available" and does not provision replacements.

This repo reproduces three failure modes that create phantom nodes on a laptop using open source tools.

## What You Need

- [kind](https://kind.sigs.k8s.io/) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/) v3+
- Docker

**Minimum resources:** 4 vCPU, 16GB RAM (4-node kind cluster with Cilium + kwok)

## Quick Start

```bash
./demo.sh setup          # 4-node kind cluster with Cilium (/24 pod CIDR)
./demo.sh exhaust-ips    # Scale past available IPs
./demo.sh phantom-nodes  # Add 20 fake nodes with kwok, show scheduler placing pods that never run
./demo.sh cost           # Calculate what this costs in production
./demo.sh heal           # Deploy self-healing patterns
./demo.sh cleanup        # Delete everything
```

## Scenarios

### 1. IP Exhaustion Mid-Scale

Cilium is configured with a /24 pod CIDR (254 usable IPs). We scale a deployment to 200 replicas. The first ~64 pods get IPs and run. The rest sit in ContainerCreating forever.

**Validated output:**
```
Pods Running: 64
Pods Pending: 135
Pods stuck in ContainerCreating: 135

Events:
  Warning  FailedCreatePodSandBox  plugin type="cilium-cni" failed (add):
    unable to allocate IP via local cilium agent: [POST /ipam][502]
    postIpamFailure  range is full
```

All 4 nodes show Ready. The scheduler sees capacity. But pods can not start because there are no IPs left. In production, these nodes are billing at full rate while serving nothing.

### 2. Phantom Nodes with kwok

[kwok](https://kwok.sigs.k8s.io/) (Kubernetes WithOut Kubelet) simulates fake nodes that appear in the API server without real compute behind them. We use it to show what happens when nodes exist but CNI never initializes.

**What happens:**
1. 20 fake nodes are created. They briefly show Ready.
2. The scheduler immediately places pods on them (100 pods across 20 nodes).
3. Those pods will never start. There is no kubelet, no CNI, no container runtime.
4. In production, those 20 nodes are billing. Zero workload served.

**Validated output:**
```
Real nodes (have CNI, can run pods):
  worker-1: 66 scheduled, 57 running
  worker-2: 67 scheduled, 60 running
  worker-3: 67 scheduled, 60 running

Phantom nodes (kwok, no CNI, pods never start):
  phantom-node-1: 5 scheduled, 0 running
  phantom-node-2: 5 scheduled, 0 running
  phantom-node-3: 5 scheduled, 0 running
  phantom-node-4: 5 scheduled, 0 running
  phantom-node-5: 5 scheduled, 0 running
  ... (20 phantom nodes total)

Total pods scheduled to phantom nodes: 100
All of these pods will NEVER run.
```

### 3. kube-proxy Crash Cascade

kube-proxy is a hidden dependency for most CNI plugins. If it crashes, the CNI DaemonSet can not reach the API server via service IP. This means:

1. kube-proxy dies on a node
2. iptables rules go stale
3. CNI health check fails (can not reach API server)
4. CNI DaemonSet pod goes NotReady
5. New pods on that node can not get network

Existing pods keep running (established connections survive), but new pods are stuck.

## The Dependency Chain

```
Instance Launch
    > Kubelet starts
        > Kubelet registers with API server
            > Node marked "Ready"              <-- BILLING STARTS
                > kube-proxy DaemonSet scheduled
                    > kube-proxy programs iptables
                        > CNI DaemonSet scheduled
                            > CNI initializes (IP allocation)
                                > Node can ACTUALLY run pods  <-- USEFUL
```

The gap between BILLING STARTS and USEFUL is the phantom node window.

## Cost Formula

```
phantom_cost_per_month = hourly_rate x avg_notready_minutes/60 x scale_events_per_day x 30

Examples:
  General purpose (mid-size):  $0.19/hr x 5min x 10/day x 30 = $4.75/month
  GPU (large):                $32.00/hr x 5min x 10/day x 30 = $800/month
  GPU at scale:               $16.00/hr x 5min x 50/day x 30 = $2,000/month
```

This cost is invisible in standard billing. You have to correlate node launch timestamps with first-pod-scheduled timestamps to see it.

## How to Fix This

To break out of this bind, you can apply immediate tactical fixes and architectural changes to prevent it from happening again.

### 1. Tactical Fixes (stop the bleeding)

**Taint Nodes Until Ready**

Ensure your kubelet registers with `registerWithTaints` so it starts with `node.kubernetes.io/not-ready` or a custom taint. The scheduler will ignore the node until the CNI finishes initialization and the taint is removed.

```yaml
# kubelet configuration
registerWithTaints:
- key: node.kubernetes.io/not-ready
  effect: NoSchedule
```

**Aggressive Eviction**

Adjust `node-monitor-grace-period` and `node-monitor-period` in your kube-controller-manager so the control plane detects CNI failures faster. This lets it mark the node NotReady and evict pending pods sooner instead of waiting the default 40 seconds.

```yaml
# kube-controller-manager flags
--node-monitor-period=5s          # default: 5s (check frequency)
--node-monitor-grace-period=20s   # default: 40s (how long before marking Unknown)
```

**IP Capacity Alerts**

Alert before you run out, not after. See `manifests/ip-capacity-alert.yaml` for Prometheus rules that fire when available IPs drop below 20% of your pool.

### 2. Architectural Redesign (prevent it permanently)

**Switch to Node-Local CNI**

Consider transitioning to node-local architectures like Cilium or Calico running in eBPF mode. They compile the networking logic into the kernel, bypassing heavy external plugin initialization that often fails during late-stage node bootstrapping.

**Strict Readiness Gates**

Implement Pod Readiness Gates. This forces the scheduler to wait for custom external conditions (like CNI initialization success) to report True before binding pods. See `manifests/readiness-gate.yaml` for a working example that validates:
- Default route present (CNI initialized)
- DNS resolution working (kube-proxy + CoreDNS path)
- API server reachable via service IP

**Pre-flight DaemonSets**

Run a CNI verification DaemonSet. If the DaemonSet pod fails its initialization on a new node, it can apply a localized taint or label that instantly blocks the default scheduler from using the node. This is defense-in-depth on top of readiness gates.

**IPAM Warm Pool Tuning**

Pre-allocate IPs ahead of demand so new pods do not wait for allocation:

```yaml
# Cilium: larger pool per node
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: ["10.244.0.0/16"]
    clusterPoolIPv4MaskSize: 24  # 254 IPs per node
```

Trade-off: idle IPs cost nothing in overlay networks, but in cloud-provider IPAM (like VPC CNI), each pre-allocated IP holds a real ENI slot.

**Karpenter Disruption Policy**

Replace nodes that have not become fully ready within a deadline:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
spec:
  disruption:
    consolidationPolicy: WhenEmpty
    # Nodes NotReady for >3min get replaced automatically
```

## Key Metrics

```promql
# Available IPs per node (Cilium)
cilium_ip_addresses_available

# Nodes in NotReady state
kube_node_status_condition{condition="Ready", status="false"}

# Pods stuck waiting for network
kube_pod_container_status_waiting_reason{reason="ContainerCreating"}
```

## What This Demo Does NOT Show

Being transparent about limitations:

- **Real cloud billing correlation.** We simulate with kwok, not actual instances. The cost formula is math, not a live billing feed.
- **Real autoscaler interaction.** kind does not have cluster-autoscaler or Karpenter. We show the scheduling behavior, not the autoscaler's response.
- **Real ENI attachment delays.** Cloud-specific IPAM (VPC CNI, Azure CNI) has throttling that does not exist in Cilium overlay mode. The failure pattern is the same but the trigger is different.

## Open Source Projects Used

- [Cilium](https://cilium.io/) (CNCF Graduated) for CNI with constrained IPAM
- [kwok](https://kwok.sigs.k8s.io/) (CNCF project under kubernetes-sigs) for simulating nodes at scale
- [Karpenter](https://karpenter.sh/) (CNCF Sandbox) referenced for self-healing patterns
- [kind](https://kind.sigs.k8s.io/) for local Kubernetes clusters
- [Prometheus](https://prometheus.io/) (CNCF Graduated) for alerting rules

## References

- [Cilium IPAM documentation](https://docs.cilium.io/en/stable/network/concepts/ipam/)
- [kwok documentation](https://kwok.sigs.k8s.io/)
- [Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/)
- [Kubernetes node conditions](https://kubernetes.io/docs/concepts/architecture/nodes/#condition)

## License

MIT

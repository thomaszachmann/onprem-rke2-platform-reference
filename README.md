# Enterprise RKE2 HA Cluster - Ansible Deployment

Production-grade Ansible repository for deploying RKE2 Kubernetes in HA mode (embedded etcd) on Ubuntu 24.04 with kube-vip for API server high availability, Longhorn distributed storage, Kyverno policy engine, cert-manager TLS automation, and Prometheus/Grafana observability.

## Architecture

### Network Diagram

```
                      ┌──────────────────────────────────────────────────────────┐
                      │                    External Network                      │
                      │  DNS: longhorn.procilon.duckdns.org → 172.16.0.240      │
                      └────────────────────────┬─────────────────────────────────┘
                                               │
                                               │  Port 80/443 (Ingress)
                                               │  Port 6443 (K8s API)
                                               ▼
                      ┌──────────────────────────────────────────────────────────┐
                      │              VIP: 172.16.0.240 (kube-vip)               │
                      │              HA floating IP via gratuitous ARP           │
                      └────────────────────────┬─────────────────────────────────┘
                                               │
              ┌────────────────────────────────┼────────────────────────────────┐
              │                                │                                │
              ▼                                ▼                                ▼
     ┌─────────────────┐             ┌─────────────────┐             ┌─────────────────┐
     │ rke2-master-01  │◄───────────►│ rke2-master-02  │◄───────────►│ rke2-master-03  │
     │ 172.16.0.230    │  etcd peer  │ 172.16.0.45     │  etcd peer  │ 172.16.0.90     │
     │                 │  :2379-2380 │                 │  :2379-2380 │                 │
     │ ● RKE2 Server   │             │ ● RKE2 Server   │             │ ● RKE2 Server   │
     │ ● etcd member   │             │ ● etcd member   │             │ ● etcd member   │
     │ ● kube-vip      │             │ ● kube-vip      │             │ ● kube-vip      │
     │ ● Ingress Nginx │             │ ● Ingress Nginx │             │ ● Ingress Nginx │
     └────────┬────────┘             └────────┬────────┘             └────────┬────────┘
              │          Canal VXLAN :8472     │                                │
              └────────────────────────────────┼────────────────────────────────┘
                                               │
              ┌────────────────────────────────┼────────────────────────────────┐
              │                                │                                │
              ▼                                ▼                                ▼
     ┌─────────────────┐             ┌─────────────────┐             ┌─────────────────┐
     │ rke2-worker-01  │◄───────────►│ rke2-worker-02  │◄───────────►│ rke2-worker-03  │
     │ 172.16.0.12     │  Longhorn   │ 172.16.0.75     │  Longhorn   │ 172.16.0.83     │
     │                 │  replication │                 │  replication │                 │
     │ ● RKE2 Agent    │             │ ● RKE2 Agent    │             │ ● RKE2 Agent    │
     │ ● Longhorn Mgr  │             │ ● Longhorn Mgr  │             │ ● Longhorn Mgr  │
     │ ● Longhorn CSI  │             │ ● Longhorn CSI  │             │ ● Longhorn CSI  │
     │ ● Ingress Nginx │             │ ● Ingress Nginx │             │ ● Ingress Nginx │
     │ ● Prometheus    │             │ ● Alertmanager  │             │ ● Grafana       │
     │ ● node-exporter │             │ ● node-exporter │             │ ● node-exporter │
     └─────────────────┘             └─────────────────┘             └─────────────────┘
```

### Control Plane

The control plane runs on 3 server nodes in HA configuration:

| Component | Instances | HA Mechanism |
|-----------|-----------|-------------|
| kube-apiserver | 3 | Load balanced via kube-vip VIP |
| etcd | 3 | Raft consensus (quorum = 2) |
| kube-scheduler | 3 | Leader election |
| kube-controller-manager | 3 | Leader election |
| kube-vip | 3 | ARP-based VIP failover |

**Failure tolerance:** The cluster survives the loss of 1 server node. With 3 etcd members, quorum requires 2 nodes. API requests are routed through the VIP which automatically migrates to a healthy node.

### Storage Layer

Longhorn provides distributed block storage across the 3 worker nodes:

```
     ┌─────────────────────────────────────────────────────────────┐
     │                    Longhorn Storage Pool                    │
     │                                                             │
     │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
     │  │   Worker-01   │  │   Worker-02   │  │   Worker-03   │     │
     │  │ /var/lib/     │  │ /var/lib/     │  │ /var/lib/     │     │
     │  │   longhorn/   │  │   longhorn/   │  │   longhorn/   │     │
     │  │              │  │              │  │              │     │
     │  │  Replica A1  │  │  Replica A2  │  │  Replica A3  │     │
     │  │  Replica B1  │  │  Replica B2  │  │  Replica B3  │     │
     │  │  Replica C1  │  │  Replica C2  │  │  Replica C3  │     │
     │  └──────────────┘  └──────────────┘  └──────────────┘     │
     │                                                             │
     │  Default replica count: 3 (data on all workers)             │
     │  Default StorageClass: longhorn                             │
     │  Access mode: ReadWriteOnce                                 │
     └─────────────────────────────────────────────────────────────┘
```

| Property | Value |
|----------|-------|
| StorageClass | `longhorn` (default) |
| Replica count | 3 (across all workers) |
| Data path | `/var/lib/longhorn/` per worker |
| CSI Driver | `driver.longhorn.io` (worker nodes only) |
| Scheduling | Worker nodes only (`node-role.kubernetes.io/worker=true`) |

**Failure tolerance:** Any single worker node can fail without data loss. Longhorn automatically rebuilds replicas on remaining nodes.

### Backup Strategy

```
     ┌───────────────────────────────────────────────────────────────┐
     │                       Backup Layers                          │
     │                                                               │
     │  Layer 1: etcd Snapshots (Cluster State)                      │
     │  ├── Schedule: Every 6 hours (0 */6 * * *)                   │
     │  ├── Retention: 56 snapshots (14 days)                        │
     │  ├── Location: /var/lib/rancher/rke2/server/db/snapshots/     │
     │  ├── Scope: All K8s resources, RBAC, secrets, configmaps      │
     │  └── Restore: rke2 server --cluster-reset                     │
     │                                                               │
     │  Layer 2: Longhorn Volumes (Persistent Data)                  │
     │  ├── 3x replicas across worker nodes                          │
     │  ├── Survives single node failure                             │
     │  └── Optional: Longhorn backup to S3/NFS (not yet configured) │
     │                                                               │
     │  Layer 3: Infrastructure as Code (this repository)            │
     │  ├── All cluster config in Git                                │
     │  ├── Ansible playbooks for full rebuild                       │
     │  └── Secrets encrypted via ansible-vault                      │
     └───────────────────────────────────────────────────────────────┘
```

| What | Backed Up By | RPO | RTO |
|------|-------------|-----|-----|
| Cluster state (resources, RBAC, secrets) | etcd snapshots | 6 hours | ~15 min (restore + restart) |
| Persistent volume data | Longhorn 3x replication | 0 (synchronous) | Automatic (node failure) |
| Cluster configuration | Git repository | Last commit | Full rebuild via `make all` |
| Vault secrets | Ansible Vault (encrypted in Git) | Last commit | Decrypt + deploy |

### Security Architecture

```
     ┌────────────────────────────────────────────────────────────────┐
     │                    Security Layers                             │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 1: Admission Control (Kyverno)                    │ │
     │  │  ├── disallow-privileged-containers      [PSS Baseline]  │ │
     │  │  ├── disallow-host-namespaces            [PSS Baseline]  │ │
     │  │  ├── disallow-host-ports                 [PSS Baseline]  │ │
     │  │  ├── disallow-capability-escalation      [PSS Baseline]  │ │
     │  │  ├── require-run-as-nonroot              [PSS Restricted]│ │
     │  │  ├── require-resource-limits             [Best Practice] │ │
     │  │  └── disallow-default-namespace          [Best Practice] │ │
     │  │  Mode: Audit (switch to Enforce when ready)              │ │
     │  └──────────────────────────────────────────────────────────┘ │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 2: TLS / Certificate Management (cert-manager)    │ │
     │  │  ├── Self-signed CA for homelab (no internet required)   │ │
     │  │  ├── ClusterIssuer: homelab-ca (RSA 4096, 10yr validity) │ │
     │  │  ├── Optional: Let's Encrypt for public domains          │ │
     │  │  └── Ingress TLS via annotation                          │ │
     │  └──────────────────────────────────────────────────────────┘ │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 3: Network                                        │ │
     │  │  ├── CNI: Canal (Calico policy + Flannel VXLAN overlay)  │ │
     │  │  ├── Ingress: rke2-ingress-nginx (HostPort 80/443)       │ │
     │  │  └── API: TLS on port 6443, VIP-fronted                  │ │
     │  └──────────────────────────────────────────────────────────┘ │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 4: Infrastructure                                 │ │
     │  │  ├── Secrets: Ansible Vault (encrypted at rest in Git)   │ │
     │  │  ├── SSH: Key-based only, ubuntu user with sudo          │ │
     │  │  ├── RKE2: CIS 1.23 hardened by default                 │ │
     │  │  └── etcd: mTLS between peers, encrypted traffic         │ │
     │  └──────────────────────────────────────────────────────────┘ │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 5: Audit Logging                                  │ │
     │  │  ├── K8s API audit log on all server nodes               │ │
     │  │  ├── Tiered policy: None → Metadata → RequestResponse   │ │
     │  │  ├── Secret access logged (metadata only, no body)       │ │
     │  │  ├── All mutations logged with full request/response     │ │
     │  │  └── Log rotation: 100MB/file, 10 backups, 30 days      │ │
     │  └──────────────────────────────────────────────────────────┘ │
     │                                                                │
     │  ┌──────────────────────────────────────────────────────────┐ │
     │  │  Layer 6: Observability                                  │ │
     │  │  ├── Prometheus: Metrics collection (14d retention)      │ │
     │  │  ├── Alertmanager: Alert routing (2 replicas HA)         │ │
     │  │  ├── Grafana: Dashboards and visualization               │ │
     │  │  ├── node-exporter: Host-level metrics (all 6 nodes)     │ │
     │  │  ├── kube-state-metrics: Kubernetes object metrics       │ │
     │  │  ├── Promtail: Log shipping to external Loki             │ │
     │  │  └── Audit logs forwarded via Promtail                   │ │
     │  └──────────────────────────────────────────────────────────┘ │
     └────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Control machine**: Ansible >= 2.15, Python 3
- **Target nodes**: Ubuntu 24.04 with SSH access
- **SSH user**: `ubuntu` with passwordless sudo
- **Network**: All nodes reachable from the control machine; nodes can reach each other
- **DNS/hosts**: `rke2-api.intra.local` must resolve to the VIP (`172.16.0.240`) on all nodes and clients

### Install Ansible Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

## Configuration

### VIP and FQDN

Edit `inventory/group_vars/all.yml`:

```yaml
rke2_api_vip: "172.16.0.240"      # Unused IP on the same L2 segment as masters
rke2_api_fqdn: "rke2-api.intra.local"  # DNS A record pointing to the VIP
```

Ensure the VIP is **not** assigned to any host. kube-vip manages it via ARP.

If your control-plane NIC is not `eth0`, update `inventory/group_vars/rke2_servers.yml`:

```yaml
kube_vip_interface: "ens18"  # or bond0, etc.
```

### Longhorn Storage

Longhorn is deployed exclusively on the 3 worker nodes using the RKE2 Helm Controller (`HelmChart` CRD). No `helm` binary is needed on the control machine.

Default settings in `inventory/group_vars/all.yml`:

```yaml
longhorn_version: "v1.7.2"
```

Additional overrides can be set in `inventory/group_vars/all.yml` or host vars:

```yaml
longhorn_default_replica_count: 3       # Number of volume replicas (default: 3)
longhorn_default_storageclass: true      # Set as default StorageClass (default: true)
longhorn_node_selector_key: "node-role.kubernetes.io/worker"
longhorn_node_selector_value: "true"
```

All Longhorn components (manager, UI, driver, CSI, instance-manager) are constrained to worker nodes via `nodeSelector` and `systemManagedComponentsNodeSelector`.

### Longhorn UI Access

The Longhorn dashboard is exposed via an Ingress resource using the built-in `rke2-ingress-nginx` controller (HostPort on ports 80/443 across all nodes).

Configure the hostname in `inventory/group_vars/all.yml`:

```yaml
longhorn_ingress_host: "longhorn.procilon.duckdns.org"
```

**DNS setup:** Point your DNS A record to the kube-vip VIP (`172.16.0.240`). This is the recommended option since the VIP is highly available and remains stable if a node goes down. Any node IP also works since the ingress controller runs on all nodes.

Once deployed and DNS is configured, access the UI at: `http://longhorn.procilon.duckdns.org`

To enable TLS via cert-manager (deploy cert-manager first):

```yaml
longhorn_ingress_tls_enabled: true
longhorn_ingress_tls_issuer: "homelab-ca"  # default, uses self-signed CA
```

With TLS enabled, access the UI at: `https://longhorn.procilon.duckdns.org`

> **Note:** The self-signed CA certificate must be imported into your browser/OS trust store to avoid security warnings. See the cert-manager section for instructions.

To disable the ingress entirely, set `longhorn_ingress_enabled: false` in your inventory or role defaults.

### etcd Backup

Automated etcd snapshots are configured on all server nodes via the RKE2 config. Defaults in `inventory/group_vars/all.yml`:

```yaml
rke2_etcd_snapshot_schedule: "0 */6 * * *"   # Every 6 hours
rke2_etcd_snapshot_retention: 56               # Keep 14 days (56 snapshots at 6h intervals)
rke2_etcd_snapshot_dir: "/var/lib/rancher/rke2/server/db/snapshots"
```

Snapshots are stored locally on each server node. To apply changes, re-run the servers playbook:

```bash
make servers
```

Verify snapshots:

```bash
# List snapshots on a server node
sudo /var/lib/rancher/rke2/bin/etcdctl \
  --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  snapshot status /var/lib/rancher/rke2/server/db/snapshots/<snapshot-file>

# Or via RKE2 CLI
sudo rke2 etcd-snapshot list
```

To restore from a snapshot, see the [RKE2 etcd backup/restore documentation](https://docs.rke2.io/backup_restore).

### cert-manager

[cert-manager](https://cert-manager.io/) automates TLS certificate management. Deployed in HA mode via the RKE2 Helm Controller.

Default settings in `inventory/group_vars/all.yml`:

```yaml
cert_manager_version: "v1.17.1"
cert_manager_ca_enabled: true        # Deploy self-signed CA ClusterIssuer
cert_manager_ca_cn: "Homelab CA"     # CA certificate common name
```

#### Self-Signed CA (Homelab / Internal)

For homelab and air-gapped environments, cert-manager deploys a **self-signed CA** chain:

1. **`selfsigned-bootstrap`** — Bootstrap ClusterIssuer (self-signed)
2. **`homelab-ca` Certificate** — RSA 4096-bit CA certificate (10-year validity, auto-renew at 1 year)
3. **`homelab-ca` ClusterIssuer** — Issues certificates signed by the CA

This is enabled by default (`cert_manager_ca_enabled: true`). No external DNS or internet access required.

To enable TLS on any Ingress, add the annotation:

```yaml
annotations:
  cert-manager.io/cluster-issuer: "homelab-ca"
spec:
  tls:
    - hosts:
        - your.domain.example
      secretName: your-tls-secret
```

> **Browser trust:** Since the CA is self-signed, browsers will show a security warning on first visit. You can trust the CA by exporting the CA certificate and importing it into your browser/OS trust store:
>
> ```bash
> kubectl -n cert-manager get secret homelab-ca-key-pair -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
> # Import homelab-ca.crt into your browser or OS certificate store
> ```

#### Let's Encrypt (Optional, Public Domains)

For publicly reachable domains, you can additionally enable Let's Encrypt:

```yaml
cert_manager_letsencrypt_email: "you@example.com"
```

This creates a `letsencrypt-prod` ClusterIssuer using HTTP-01 challenge validation (port 80 must be reachable from the internet).

### Kyverno Policy Engine

[Kyverno](https://kyverno.io/) is deployed as the cluster policy engine for admission control, validation, mutation, and generation of Kubernetes resources. It runs in HA mode with multiple replicas across control-plane nodes.

Default settings in `inventory/group_vars/all.yml`:

```yaml
kyverno_version: "3.3.4"
```

Additional overrides can be set in `inventory/group_vars/all.yml` or role defaults:

```yaml
kyverno_replica_count: 3   # Admission controller replicas (default: 3)
```

Kyverno deploys the following controllers:

| Controller | Replicas | Purpose |
|-----------|----------|---------|
| Admission Controller | 3 | Validates and mutates resources on admission |
| Background Controller | 2 | Processes policies on existing resources |
| Cleanup Controller | 2 | Handles resource cleanup based on policies |
| Reports Controller | 2 | Generates policy reports |

### Kyverno Baseline Policies

A set of baseline security policies is deployed in **Audit** mode by default. This means violations are logged and reported but not blocked, allowing you to assess impact before enforcing.

```yaml
kyverno_policies_mode: "Audit"     # Set to "Enforce" when ready to block violations
```

| Policy | Category | Severity | Description |
|--------|----------|----------|-------------|
| `disallow-privileged-containers` | PSS Baseline | High | Prevents privileged containers |
| `disallow-host-namespaces` | PSS Baseline | High | Blocks hostPID, hostIPC, hostNetwork |
| `disallow-host-ports` | PSS Baseline | High | Blocks hostPort usage |
| `disallow-capability-escalation` | PSS Baseline | High | Prevents allowPrivilegeEscalation |
| `require-run-as-nonroot` | PSS Restricted | Medium | Requires runAsNonRoot: true |
| `require-resource-limits` | Best Practices | Medium | Requires CPU/memory requests and limits |
| `disallow-default-namespace` | Best Practices | Medium | Prevents deployments to default namespace |

System namespaces (kube-system, longhorn-system, monitoring, kyverno, cert-manager) are excluded from all policies.

To switch from Audit to Enforce:

```yaml
# inventory/group_vars/all.yml
kyverno_policies_mode: "Enforce"
```

Then re-run:

```bash
make kyverno-policies
```

Check policy violations:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

### NetworkPolicies

Network segmentation via Kubernetes [NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) enforced by the Canal CNI. Each protected namespace gets a default-deny-ingress rule, with explicit allow rules for required traffic flows.

Protected namespaces: `longhorn-system`, `cert-manager`, `kyverno`, `monitoring`

| Policy | Namespaces | Purpose |
|--------|-----------|---------|
| `default-deny-ingress` | All protected | Block all ingress by default |
| `allow-intra-namespace` | All protected | Allow pods within same namespace to communicate |
| `allow-from-ingress-nginx` | longhorn-system, monitoring | Allow rke2-ingress-nginx (kube-system) to reach services with Ingress |
| `allow-prometheus-scraping` | All protected | Allow Prometheus to scrape metrics endpoints |
| `allow-apiserver-webhook` | cert-manager, kyverno | Allow kube-apiserver to reach admission webhooks |
| `allow-kubelet-to-longhorn` | longhorn-system | Allow kubelet/node traffic to Longhorn CSI and instance-manager |

Deploy or update:

```bash
make network-policies
```

Verify:

```bash
kubectl get networkpolicies -A
```

### Monitoring (Prometheus + Grafana)

Full observability stack based on [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack), deployed in HA mode via the RKE2 Helm Controller.

Default settings in `inventory/group_vars/all.yml`:

```yaml
monitoring_version: "72.6.2"
```

Additional overrides can be set in `inventory/group_vars/all.yml` or role defaults:

```yaml
monitoring_grafana_admin_password: "admin"     # Change for production!
monitoring_retention: "14d"                     # Prometheus retention period
monitoring_retention_size: "10GB"               # Prometheus retention size limit
monitoring_storage_class: "longhorn"            # StorageClass for persistent volumes
monitoring_storage_size: "5Gi"                  # Prometheus PV size
monitoring_alertmanager_storage_size: "5Gi"     # Alertmanager PV size
```

Components deployed:

| Component | Type | Storage |
|-----------|------|---------|
| Prometheus | StatefulSet | 5Gi (Longhorn) |
| Alertmanager | StatefulSet (2 replicas) | 5Gi (Longhorn) |
| Grafana | Deployment | 5Gi (Longhorn) |
| Prometheus Operator | Deployment | - |
| node-exporter | DaemonSet | - |
| kube-state-metrics | Deployment | - |

To expose Grafana via Ingress:

```yaml
monitoring_grafana_ingress_enabled: true
monitoring_grafana_ingress_host: "grafana.example.com"
monitoring_grafana_ingress_tls_enabled: true   # requires cert-manager
```

Access Grafana via port-forward (without Ingress):

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# Open http://localhost:3000 (admin / <password>)
```

#### Remote Write to External Prometheus

To push all cluster metrics to an external Prometheus:

```yaml
monitoring_remote_write_url: "https://prometheus.example.com/api/v1/write"
monitoring_cluster_name: "rke2-prod"   # added as label to all metrics
```

The external Prometheus must have `--web.enable-remote-write-receiver` enabled. All metrics get a `cluster` label for filtering in Grafana.

### Audit Logging

Kubernetes API audit logging is enabled on all server nodes. Every API request is logged with configurable verbosity levels.

Default settings in `inventory/group_vars/all.yml`:

```yaml
rke2_audit_enabled: true
rke2_audit_log_maxage: 30      # Days to retain audit logs
rke2_audit_log_maxbackup: 10   # Number of old log files to keep
rke2_audit_log_maxsize: 100    # Max size in MB before rotation
```

Log location: `/var/lib/rancher/rke2/server/logs/audit.log` on each server node.

The audit policy follows a tiered approach:

| Category | Audit Level | Details |
|----------|------------|---------|
| Secret/ConfigMap access | Metadata | Logs who accessed, not the content |
| Auth/AuthZ requests | Metadata | Token reviews, RBAC checks |
| Resource mutations (create/update/delete) | RequestResponse | Full request and response body |
| Health checks, events, node watches | None | Filtered out to reduce noise |
| Everything else | Metadata | API path, user, verb, status code |

To apply changes, re-run `make servers` (rolling restart, one at a time).

### Centralized Logging (Promtail)

[Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) is deployed as a DaemonSet on all nodes to ship container logs and audit logs to an external Loki instance.

```yaml
promtail_loki_url: "https://loki.example.com/loki/api/v1/push"
promtail_cluster_name: "rke2-prod"
```

Promtail collects:

| Source | Path | Label |
|--------|------|-------|
| Container logs | `/var/log/pods/` | `job=kubernetes-pods` |
| Audit logs | `/var/lib/rancher/rke2/server/logs/audit.log` | `job=rke2-audit` |

All log entries are tagged with `cluster=<cluster_name>` for multi-cluster filtering.

Promtail is **skipped** when `promtail_loki_url` is empty. Set the URL and run:

```bash
make logging
```

### Inventory

Edit `inventory/hosts.ini` with your actual IPs. Ensure hostnames resolve or are set via `ansible_host`.

### Vault (Cluster Token)

1. Generate a strong token:
   ```bash
   openssl rand -hex 32
   ```

2. Edit `vault/secrets.yml` and replace `CHANGE_ME_BEFORE_DEPLOYING`:
   ```yaml
   rke2_cluster_token: "<your-generated-token>"
   ```

3. Create a vault password file:
   ```bash
   echo 'your-vault-password' > .vault_pass
   chmod 600 .vault_pass
   ```

4. Encrypt the secrets file:
   ```bash
   ansible-vault encrypt vault/secrets.yml
   ```

## Deployment

### Full Deployment (Recommended)

```bash
make all
```

This runs all playbooks in order: bootstrap, servers, agents, post, longhorn, cert-manager, kyverno, kyverno-policies, network-policies, monitoring, logging.

### RKE2 Only (No Storage)

```bash
make install-rke2
```

This runs bootstrap, servers, agents, and post (without Longhorn).

### Step-by-Step Deployment

```bash
# 1. Prepare all nodes (packages, kernel modules, sysctls, swap off)
make bootstrap

# 2. Deploy RKE2 servers one at a time (serial: 1)
make servers

# 3. Deploy RKE2 agents (all in parallel)
make agents

# 4. Fetch kubeconfig to ./artifacts/kubeconfig.yaml
make post

# 5. Deploy Longhorn storage on worker nodes
make longhorn

# 6. Deploy cert-manager for TLS certificate management
make cert-manager

# 7. Deploy Kyverno policy engine
make kyverno

# 8. Deploy Kyverno baseline policies (Enforce mode)
make kyverno-policies

# 9. Deploy NetworkPolicies for namespace isolation
make network-policies

# 10. Deploy monitoring stack (Prometheus + Grafana)
make monitoring

# 11. Deploy centralized logging (Promtail → Loki)
make logging
```

### Install Longhorn Separately

If the cluster is already running, install Longhorn on its own:

```bash
make install-longhorn
```

### Using the Cluster

```bash
export KUBECONFIG=./artifacts/kubeconfig.yaml
kubectl get nodes -o wide
```

## Firewall Ports

Ensure the following ports are open between nodes:

| Port | Protocol | Source | Destination | Purpose |
|------|----------|--------|-------------|---------|
| 6443 | TCP | All | Servers | Kubernetes API |
| 9345 | TCP | Servers | Servers | RKE2 supervisor API |
| 2379-2380 | TCP | Servers | Servers | etcd |
| 10250 | TCP | All | All | kubelet |
| 8472 | UDP | All | All | Canal/Flannel VXLAN |
| 51820-51821 | UDP | All | All | Canal/Flannel WireGuard |

## Troubleshooting

### RKE2 Server Logs

```bash
# Server service status
sudo systemctl status rke2-server

# Server logs (follow)
sudo journalctl -u rke2-server -f

# Last 100 lines
sudo journalctl -u rke2-server -n 100 --no-pager
```

### RKE2 Agent Logs

```bash
sudo systemctl status rke2-agent
sudo journalctl -u rke2-agent -f
```

### etcd Health

```bash
sudo /var/lib/rancher/rke2/bin/etcdctl \
  --cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  endpoint status --cluster -w table
```

### kube-vip

```bash
# Check VIP is responding
ping 172.16.0.240

# Check which node holds the VIP
ip addr show | grep 172.16.0.240

# kube-vip pod logs
kubectl -n kube-system logs -l app.kubernetes.io/name=kube-vip
```

### Longhorn

```bash
# Check HelmChart CR status
kubectl get helmchart longhorn -n default

# Longhorn pods (all should be on worker nodes)
kubectl get pods -n longhorn-system -o wide

# StorageClass (longhorn should be default)
kubectl get storageclass

# Test PVC creation
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc longhorn-test-pvc   # should be Bound
kubectl delete pvc longhorn-test-pvc

# Longhorn manager logs
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=50
```

### Common Issues

- **Server fails to start on master-02/03**: Ensure master-01 API is reachable on port 9345. Check DNS resolution of `rke2_api_fqdn`.
- **Agents can't join**: Verify the cluster token matches across all nodes. Check that port 9345 is open on servers.
- **VIP not responding**: Confirm `kube_vip_interface` matches the actual NIC name on control-plane nodes. Check kube-vip pod logs.
- **Longhorn pods on masters**: Verify worker nodes are labeled: `kubectl get nodes --show-labels | grep worker`. Re-run `make longhorn` to re-apply labels.
- **PVC stuck in Pending**: Check `kubectl -n longhorn-system logs -l app=longhorn-manager` and ensure `iscsid` is running on all workers (`systemctl status iscsid`).
- **cert-manager not issuing certificates**: Check `kubectl -n cert-manager logs -l app.kubernetes.io/component=controller --tail=50`. Verify the ClusterIssuer is ready: `kubectl get clusterissuer`. For Let's Encrypt HTTP-01, port 80 must be reachable from the internet.
- **etcd snapshots not created**: Check `sudo rke2 etcd-snapshot list` on a server node. Verify the cron schedule in `/etc/rancher/rke2/config.yaml`. Check server logs: `journalctl -u rke2-server | grep snapshot`.
- **Kyverno webhook errors**: Check `kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller --tail=50`. If the admission controller is down, resource creation may be blocked — scale or restart the deployment.
- **Kyverno policy violations**: Run `kubectl get policyreport -A` to see per-namespace violations. Use `kubectl describe clusterpolicy <name>` to check policy status.
- **Prometheus not scraping targets**: Check `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` and visit Status > Targets. Verify ServiceMonitor selectors match.
- **Grafana not accessible**: Check `kubectl -n monitoring logs -l app.kubernetes.io/name=grafana --tail=50`. Verify PVC is bound: `kubectl -n monitoring get pvc`.
- **Audit logs not written**: Verify `/var/lib/rancher/rke2/server/logs/audit.log` exists on server nodes. Check `rke2_audit_enabled: true` in config. Run `journalctl -u rke2-server | grep audit` for errors.
- **Promtail not shipping logs**: Check `kubectl -n logging logs -l app.kubernetes.io/name=promtail --tail=50`. Verify Loki URL is reachable from cluster. Check `kubectl -n logging get ds promtail`.

## Upgrade Strategy

1. **Pin the new version** in `inventory/group_vars/all.yml`:
   ```yaml
   rke2_version: "v1.32.0+rke2r1"
   ```

2. **Upgrade servers first** (one at a time):
   ```bash
   ansible-playbook playbooks/10-rke2-servers.yml
   ```
   The `serial: 1` ensures rolling upgrade with zero API downtime.

3. **Upgrade agents**:
   ```bash
   ansible-playbook playbooks/20-rke2-agents.yml
   ```

4. **Verify**:
   ```bash
   kubectl get nodes -o wide
   ```

> **Note**: Always review the [RKE2 release notes](https://github.com/rancher/rke2/releases) before upgrading. Skip no more than one minor version at a time.

### Longhorn Upgrade

1. **Pin the new version** in `inventory/group_vars/all.yml`:
   ```yaml
   longhorn_version: "v1.8.0"
   ```

2. **Re-run the playbook**:
   ```bash
   make longhorn
   ```
   The HelmChart CR is updated, and the RKE2 Helm Controller handles the in-place upgrade.

3. **Verify**:
   ```bash
   kubectl -n longhorn-system get pods -o wide
   kubectl get helmchart longhorn -n default
   ```

> **Note**: Always review the [Longhorn release notes](https://github.com/longhorn/longhorn/releases) before upgrading. Ensure all volumes are healthy before starting.

### Kyverno Upgrade

1. **Pin the new version** in `inventory/group_vars/all.yml`:
   ```yaml
   kyverno_version: "3.4.0"
   ```

2. **Re-run the playbook**:
   ```bash
   make kyverno
   ```

3. **Verify**:
   ```bash
   kubectl -n kyverno get pods -o wide
   kubectl get helmchart kyverno -n default
   ```

> **Note**: Always review the [Kyverno release notes](https://github.com/kyverno/kyverno/releases) before upgrading.

### cert-manager Upgrade

1. **Pin the new version** in `inventory/group_vars/all.yml`:
   ```yaml
   cert_manager_version: "v1.18.0"
   ```

2. **Re-run the playbook**:
   ```bash
   make cert-manager
   ```

3. **Verify**:
   ```bash
   kubectl -n cert-manager get pods -o wide
   kubectl get clusterissuer
   ```

> **Note**: Always review the [cert-manager release notes](https://cert-manager.io/docs/release-notes/) before upgrading.

### Monitoring Upgrade

1. **Pin the new version** in `inventory/group_vars/all.yml`:
   ```yaml
   monitoring_version: "73.0.0"
   ```

2. **Re-run the playbook**:
   ```bash
   make monitoring
   ```

3. **Verify**:
   ```bash
   kubectl -n monitoring get pods -o wide
   kubectl get helmchart monitoring -n default
   ```

> **Note**: Always review the [kube-prometheus-stack release notes](https://github.com/prometheus-community/helm-charts/releases) before upgrading. CRD updates may require manual steps.

## Linting

```bash
make lint
```

## Repository Structure

```
.
├── ansible.cfg
├── requirements.yml
├── Makefile
├── inventory/
│   ├── hosts.ini
│   └── group_vars/
│       ├── all.yml
│       ├── rke2_servers.yml
│       └── rke2_agents.yml
├── vault/
│   └── secrets.yml
├── playbooks/
│   ├── 00-bootstrap.yml
│   ├── 10-rke2-servers.yml
│   ├── 20-rke2-agents.yml
│   ├── 30-post.yml
│   ├── 40-longhorn.yml
│   ├── 45-cert-manager.yml
│   ├── 50-kyverno.yml
│   ├── 51-kyverno-policies.yml
│   ├── 52-network-policies.yml
│   ├── 55-monitoring.yml
│   └── 56-logging.yml
└── roles/
    ├── bootstrap_linux/
    │   └── tasks/main.yml
    ├── rke2_common/
    │   ├── tasks/main.yml
    │   └── templates/rke2-config.yaml.j2
    ├── rke2_server/
    │   ├── tasks/main.yml
    │   └── handlers/main.yml
    ├── rke2_agent/
    │   ├── tasks/main.yml
    │   └── handlers/main.yml
    ├── kube_vip/
    │   ├── tasks/main.yml
    │   └── templates/kube-vip.yaml.j2
    ├── longhorn/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── longhorn-helmchart.yaml.j2
    │       └── longhorn-ingress.yaml.j2
    ├── cert_manager/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── cert-manager-helmchart.yaml.j2
    │       ├── clusterissuer-selfsigned-ca.yaml.j2
    │       └── clusterissuer-letsencrypt.yaml.j2
    ├── kyverno/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/kyverno-helmchart.yaml.j2
    ├── kyverno_policies/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── disallow-privileged.yaml.j2
    │       ├── disallow-host-namespaces.yaml.j2
    │       ├── disallow-host-ports.yaml.j2
    │       ├── disallow-capability-escalation.yaml.j2
    │       ├── disallow-default-namespace.yaml.j2
    │       ├── require-resource-limits.yaml.j2
    │       └── require-run-as-nonroot.yaml.j2
    ├── network_policies/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── default-deny-ingress.yaml.j2
    │       ├── allow-intra-namespace.yaml.j2
    │       ├── allow-ingress-nginx.yaml.j2
    │       ├── allow-prometheus-scraping.yaml.j2
    │       ├── allow-cert-manager-webhooks.yaml.j2
    │       └── allow-longhorn-internal.yaml.j2
    ├── monitoring/
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/monitoring-helmchart.yaml.j2
    └── logging/
        ├── defaults/main.yml
        ├── tasks/main.yml
        └── templates/promtail-helmchart.yaml.j2
```

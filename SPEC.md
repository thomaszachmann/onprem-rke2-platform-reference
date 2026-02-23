# Claude Code Prompt: Enterprise-ready RKE2 (HA) on Ubuntu 24.04 with Ansible (3 Masters + 3 Workers)

You are Claude Code acting as a senior DevOps / Kubernetes platform engineer.  
Your task: generate a production-grade, enterprise-ready **Ansible repository** that deploys **RKE2** in **HA mode (embedded etcd)** on **Ubuntu 24.04**.

## Hard requirements
- Target OS: **Ubuntu 24.04**
- SSH user: **ubuntu** (sudo available, passwordless sudo assumed; if not, make it configurable)
- Cluster layout:
  - Masters (control-plane / servers): `172.16.0.230`, `172.16.0.45`, `172.16.0.90`
  - Workers (agents): `172.16.0.12`, `172.16.0.75`, `172.16.0.83`
- Use **best practices**: version pinning, idempotency, Ansible Vault for secrets, clear documentation, smoke tests, structured repo layout.
- Output must be a **complete set of files** ready to commit to Git.
- Every YAML must be valid and pass `ansible-lint` basic expectations (where reasonable).
- Prefer **systemd** services managed by Ansible, and RKE2 installed via official install script with pinned version.
- Do not assume external Internet proxy, but keep steps standard (curl to get.rke2.io).
- No Kubernetes manifests applied via kubectl from the operator machine unless necessary; prefer RKE2 auto-deploy manifests under `/var/lib/rancher/rke2/server/manifests/` where appropriate.

## Architecture & best practices
- RKE2 HA control plane with embedded etcd
- Stable API endpoint via **kube-vip** (L2 ARP mode) on control-plane nodes
  - Use a configurable VIP IP and FQDN:
    - `rke2_api_vip: 172.16.0.240` (placeholder; clearly document how to change)
    - `rke2_api_fqdn: rke2-api.intra.local` (placeholder; clearly document DNS/hosts requirements)
  - kube-vip should be deployed using RKE2 manifests directory so it applies automatically
- Store `rke2_cluster_token` in Ansible Vault (`vault/secrets.yml`)
- Provide a safe default for CNI and configurable options:
  - `rke2_cni: canal` by default; allow `cilium` as alternative
- Provide a configurable list:
  - `rke2_disable: []` (example: disable rke2-ingress-nginx)
- Provide optional `rke2_node_ip` if multi-NIC

## Deliverables: repository structure
Create this structure (exact paths):
- `ansible.cfg`
- `requirements.yml` (if you use collections; otherwise keep minimal)
- `inventory/hosts.ini`
- `inventory/group_vars/all.yml`
- `inventory/group_vars/rke2_servers.yml`
- `inventory/group_vars/rke2_agents.yml`
- `vault/secrets.yml` (UNENCRYPTED placeholder content + instructions to encrypt; do NOT include real secrets)
- `playbooks/00-bootstrap.yml`
- `playbooks/10-rke2-servers.yml`
- `playbooks/20-rke2-agents.yml`
- `playbooks/30-post.yml`
- Roles:
  - `roles/bootstrap_linux/tasks/main.yml`
  - `roles/rke2_common/tasks/main.yml`
  - `roles/rke2_common/templates/rke2-config.yaml.j2`
  - `roles/rke2_server/tasks/main.yml`
  - `roles/rke2_server/handlers/main.yml`
  - `roles/rke2_agent/tasks/main.yml`
  - `roles/rke2_agent/handlers/main.yml`
  - `roles/kube_vip/tasks/main.yml`
  - `roles/kube_vip/templates/kube-vip.yaml.j2`
- `README.md` with:
  - Overview and architecture diagram (ASCII is fine)
  - Prereqs, SSH access, sudo expectations
  - How to set VIP/FQDN
  - How to create and encrypt vault secrets
  - Execution order and commands
  - Troubleshooting section (journalctl commands, common failure modes)
  - Upgrade strategy (how to bump rke2_version, rolling upgrade steps)
- `Makefile` with helpful targets:
  - `lint` (ansible-lint if available)
  - `bootstrap`, `servers`, `agents`, `post`
  - `all`

## Implementation details you must follow

### Inventory & vars
- Inventory must use the SSH user `ubuntu`.
- Use groups:
  - `[rke2_servers]` with hostnames `rke2-master-01..03`
  - `[rke2_agents]` with hostnames `rke2-worker-01..03`
  - `[k8s:children]` for both
- group_vars:
  - `all.yml` includes `ansible_user: ubuntu`, `rke2_version`, `rke2_api_vip`, `rke2_api_fqdn`, `rke2_cni`, `rke2_disable`, `kubeconfig_local_path`
  - `rke2_servers.yml` includes `kube_vip_enabled: true`, `kube_vip_interface` default `eth0` but document change
  - `rke2_agents.yml` minimal

### Bootstrap role
- Must install packages needed for Kubernetes/RKE2 on Ubuntu 24.04:
  - `curl`, `ca-certificates`, `open-iscsi`, `nfs-common`, `ipvsadm`, `jq`
- Must load kernel modules: `br_netfilter`, `overlay` and persist them
- Must set sysctls:
  - `net.bridge.bridge-nf-call-iptables=1`
  - `net.bridge.bridge-nf-call-ip6tables=1`
  - `net.ipv4.ip_forward=1`
- Must disable swap and remove swap entries from `/etc/fstab`
- Must enable and start `iscsid` (ignore errors if not applicable)
- Must be idempotent (use `creates`, templates, file modules, etc.)

### RKE2 installation & config
- `rke2_common` role:
  - create `/etc/rancher/rke2/config.yaml` from template
  - install RKE2 pinned: `curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=... sh -`
  - ensure config file has:
    - `token: {{ rke2_cluster_token }}`
    - `server: https://{{ rke2_api_fqdn }}:9345`
    - `tls-san` includes VIP and FQDN
    - `cni` from var
    - `disable` from list if set

- `rke2_server` role:
  - enable and start `rke2-server`
  - wait for API on localhost 6443
  - optionally ensure kubectl symlink exists to `/usr/local/bin/kubectl` pointing to `/var/lib/rancher/rke2/bin/kubectl` (ignore if missing)

- `rke2_agent` role:
  - enable and start `rke2-agent`
  - wait for kubelet port 10250 locally (ignore errors if too strict)

### kube-vip
- Deploy kube-vip as a manifest placed at:
  - `/var/lib/rancher/rke2/server/manifests/kube-vip.yaml`
- Use hostNetwork and privileged
- Configure env:
  - VIP address = `rke2_api_vip`
  - interface = `kube_vip_interface`
  - ARP enabled
  - port 6443
- Use a configurable image:
  - `kube_vip_image: ghcr.io/kube-vip/kube-vip:v0.8.2`

### Post playbook
- Fetch kubeconfig from `rke2-master-01`:
  - `/etc/rancher/rke2/rke2.yaml`
  - save to `./artifacts/kubeconfig.yaml`
- Replace server endpoint from `127.0.0.1:6443` to `https://{{ rke2_api_fqdn }}:6443`
- Print a short hint how to use it: `export KUBECONFIG=...` and `kubectl get nodes -o wide`

## Output format
- Create the entire repository content as a file tree with each file’s full content.
- Use code blocks per file, like:

```text
path/to/file
<content>

Do not omit files.

Do not add extra commentary outside of the repository files except a short final checklist.

Start now

Generate the full repository exactly as specified.

```

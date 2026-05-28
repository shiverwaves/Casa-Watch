Yes! `kubectl get nodes` returning Ready is the moment. Recap below — and the honest answer to your prod question is **mostly yes, with caveats**.

## What just happened, in plain English

1. **`curl -sfL https://get.rke2.io | sudo sh -`** downloaded a shell script and ran it as root. That script:
   - Detected Fedora + SELinux enforcing
   - Added the Rancher rpm repo, installed the `rke2-selinux` package (the SELinux policy that says "these containerd/kubelet operations are legitimate")
   - Downloaded the RKE2 binary to `/usr/local/bin/rke2`
   - Created systemd units at `/usr/local/lib/systemd/system/rke2-server.service`
   - Did **not** start anything

2. **`systemctl enable --now rke2-server`** kicked off the actual cluster bootstrap. On first boot, `rke2 server` does an enormous amount of work:
   - Extracts the bundled images tarball into containerd's image store
   - Generates a complete PKI from scratch — root CA, intermediate CAs, certs for every control-plane component, kubelet certs, service-account signing keys
   - Initializes etcd (a fresh, single-node cluster)
   - Starts kube-apiserver, kube-scheduler, kube-controller-manager, kube-cloud-controller-manager as **static pods** (containers managed directly by kubelet, not the scheduler — chicken-and-egg)
   - Brings up containerd, kubelet, kube-proxy
   - Deploys the addon manifests: CoreDNS, Canal CNI, ingress-nginx, metrics-server, snapshot-controller
   - Writes the admin kubeconfig to `/etc/rancher/rke2/rke2.yaml`

3. **kubeconfig copy + chown** gave your user read access to the cluster-admin credentials. That YAML file contains:
   - The cluster's CA certificate (so kubectl can verify the apiserver)
   - The apiserver URL (defaults to `127.0.0.1:6443`)
   - An admin client cert + key (which authenticates as a cluster-admin role)

4. **Symlinking kubectl** put RKE2's bundled kubectl (extracted to `/var/lib/rancher/rke2/bin/`) on your PATH. RKE2 ships its own kubectl that's version-matched to the cluster — avoids client/server skew bugs.

That's it. Five commands and you have a fully functional single-node Kubernetes control plane.

## Is this what prod looks like?

**The installation mechanism: yes, this is genuinely the same.** Rancher uses this exact install script in production deployments. It's not a "lab toy" path — RKE2 is positioned as the production/government-compliant sibling of k3s for a reason. The script is well-engineered, idempotent, supports a ton of customization via env vars, and you'd run the same `curl | sh` on a prod node.

**What changes in prod:**

1. **Topology.** Single node is the dev/lab shape. Prod is **3 or 5 control-plane nodes** (for etcd quorum) plus N worker nodes. The install script handles this: subsequent nodes join via `INSTALL_RKE2_TYPE=server` with a shared token, and they form a quorum automatically.

2. **Automation wrapper.** You don't `curl | sh` by hand in prod. You wrap it in Ansible / Terraform / cloud-init / Pulumi / whatever your IaC tool is. The actions are the same — they just run from CI. Rancher even ships an `rke2-ansible` playbook for this.

3. **Config file is real.** Instead of taking all defaults, you write `/etc/rancher/rke2/config.yaml` with intentional choices: `token:`, `server:` (for joining), `tls-san:` (extra cert names), `disable:` (skip bundled components you're replacing), `cni:`, `node-label:`, `node-taint:`, etc. Templated by your IaC tool, never hand-edited.

4. **Firewall not disabled.** Proper port rules — RKE2 needs 6443 (apiserver), 9345 (RKE2 supervisor), 2379-2380 (etcd between control planes), 10250 (kubelet), etc. We disabled firewalld for lab simplicity; in prod you open exactly those ports between the right hosts.

5. **Storage isn't local-path.** Prod uses a real CSI driver — Longhorn for on-prem, EBS/GCE-PD/Azure-Disk for cloud, NetApp/Pure for serious storage, Rook-Ceph if you're brave. Local-path-provisioner is "data is pinned to one node and lost if that node dies" — fine for a lab, not for anything important.

6. **Kubeconfig isn't admin.** No one human uses `/etc/rancher/rke2/rke2.yaml` directly. That file is treated as a break-glass secret. Real users authenticate via OIDC (your company's SSO) hitting kube-apiserver's `--oidc-issuer-url`. RBAC roles map SSO groups → cluster permissions. The admin kubeconfig lives in a vault for emergencies only.

7. **Backups.** etcd snapshot to S3 on a cron. RKE2 has this built in (`etcd-s3-*` config options). In prod you also test the restore procedure regularly.

8. **Observability.** kube-prometheus-stack, Loki, Tempo or similar. Cluster-level dashboards, alerts for "control plane down," "etcd lagging," "node OOM," etc.

9. **Network policy.** Default-deny `NetworkPolicy` so pods can only talk to what they're explicitly allowed to. Canal CNI supports this; the policies are written and managed alongside workloads.

10. **Cert rotation, audit logging, admission controllers, pod security standards** — all configured intentionally rather than defaulted.

## The mental model

Think of it as: **the install mechanism is the same; the configuration, topology, automation, and surrounding ecosystem are what scale up.** What you just did is the literal core that everything else is layered on top of. A prod cluster admin would look at our session and say "yeah, that's day 1 of standing up a node — you just have 30 more days of automation and policy work ahead of you."

Which is exactly the point of where we're heading with ArgoCD next — automation of the *cluster contents* via Git is one of those layers. The other layers (automating the *cluster itself* via Terraform/Ansible, secrets management, SSO, observability) come later.

Ready to keep moving? Next up is your first **manual** `kubectl apply` — the local-path-provisioner — to feel the "apply by hand" half of the kubectl-then-Argo loop.


## Resolved: NodePort over Tailscale (asymmetric routing)

**Symptom:** SSH to the laptop's tailnet IP worked; ArgoCD NodePort (and `nc` on any
other port) did not. `Test-NetConnection` from the desktop reported `TcpTestSucceeded:
False`. Local `curl https://127.0.0.1:<nodeport>` on the laptop returned 200 OK.

**Root cause:** Asymmetric routing of pod-originated replies. The inbound SYN arrived
on `tailscale0` and was DNATed to the pod, but the pod's SYN-ACK went back out
`wlp2s0f0` (the WiFi default route) instead of `tailscale0`. Tailscale installs
policy-routing rules that steer any packet carrying fwmark `0x80000` into the main
table (default → WiFi). Forwarded/NATed replies were being marked, so they bypassed
the tailnet route in table 52 entirely. Host-originated traffic (e.g. `nc` listening on
the host) wasn't marked, which is why SSH and a host-bound `nc` worked fine.

**Diagnosis path:**
- `tcpdump -ni any 'tcp port <nodeport>'` showed `In tailscale0` for the SYN and
  `Out wlp2s0f0` for the SYN-ACK — smoking gun.
- `ip rule list` showed rules 5210/5230/5250 intercepting `fwmark 0x80000` and
  routing to main/default/unreachable, ahead of rule 5270 (`lookup 52`).
- `ip route show table 52` had the tailnet host route via `tailscale0`, but the
  marked packets never reached it.

**Fix:**
```bash
sudo tailscale set --netfilter-mode=off
```
Persists across `tailscaled` restarts. Leaves Tailscale's routes intact; removes its
netfilter rules including the mark-based steering.

**Tradeoff carried forward:** loses Tailscale's anti-spoof `DROP` in `ts-input` for
`100.64.0.0/10` arriving on non-tailscale interfaces. Acceptable on this single-node
lab box (firewalld off, trusted LAN). Revisit when hardening — likely by putting
explicit nft anti-spoof rules back, or moving to the Tailscale Kubernetes Operator
which sidesteps NodePort entirely.

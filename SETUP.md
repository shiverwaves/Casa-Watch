cd ~
git clone git@github.com:<yourusername>/ANewIdealista.git casa-watch
# or whatever the repo is named on GitHub - you can also rename in the GH UI
cd casa-watch
# create the scaffold.sh I gave you earlier, then:
chmod +x scaffold.sh && ./scaffold.sh
git add -A
git commit -m "scaffold repo structure"
git push

# disable swap
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab
# disable firewalld for the lab (cluster is on tailnet, no exposure)
sudo systemctl disable --now firewalld
# tell NetworkManager to keep its hands off CNI interfaces
sudo tee /etc/NetworkManager/conf.d/rke2-canal.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
EOF
sudo systemctl reload NetworkManager

# Pull RKE2 package and install script. start service
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable --now rke2-server
# in another terminal (or tab) - follow the journal
sudo journalctl -u rke2-server -f

# wire up kubectl
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
sudo ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl
# verify
ls -la ~/.kube/config
# should show your user as owner
kubectl get nodes

# Apply the local-path-provisioner directly from upstream:
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
# This creates a Namespace, ServiceAccount, ClusterRole, ClusterRoleBinding, ConfigMap, Deployment, and StorageClass — all in one go. Watch them appear:

kubectl get all -n local-path-storage
kubectl get storageclass
# Mark it as the default storage class (so PVCs that don't name a class get it automatically):

kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass
# should now show "local-path (default)"
Smoke test with a tiny PVC — save this as /tmp/test-pvc.yaml:

apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-claim
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
kubectl apply -f /tmp/test-pvc.yaml
# wait a moment, then:
kubectl get pvc
# expect: status "Bound", volume name allocated
If it shows Bound, you've just proven the storage class works. Clean up:

# Better smoke test — actually run a pod that uses it:

# /tmp/test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
    - name: writer
      image: busybox
      command: ['sh', '-c', 'echo "hello from $(date)" > /data/hello.txt && sleep 60']
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-claim
kubectl apply -f /tmp/test-pod.yaml
kubectl get pvc       # should now go to Bound
kubectl get pv        # a PV should now exist
kubectl logs test-pod
kubectl exec test-pod -- cat /data/hello.txt

# cleanup
kubectl delete -f /tmp/test-pod.yaml
kubectl delete -f /tmp/test-pvc.yaml

# ArgoCD install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# wait for it to come up (~30-60s)
kubectl get pods -n argocd -w
# Ctrl+C when all pods are Running and Ready (you'll see argocd-server, argocd-repo-server, argocd-redis, argocd-application-controller, argocd-applicationset-controller, argocd-notifications-controller, argocd-dex-server all green)

# Access ArgoCD the UI from your desktop browser 
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
kubectl get svc argocd-server -n argocd
# note the port mapped to 443 (e.g. 31234)

┌────────────────────────────────────────────────────────────────┐
│  Fedora laptop = your ONE node                                  │
│                                                                  │
│  Linux + systemd                                                 │
│     │                                                            │
│     └─ rke2-server (systemd unit)                                │
│          │                                                       │
│          ├─ containerd  ← actually runs containers               │
│          ├─ kubelet     ← node agent; talks to apiserver         │
│          ├─ kube-proxy  ← sets up service networking (iptables)  │
│          │                                                       │
│          └─ launches "static pods" for the control plane:        │
│              ┌──────────────────────────────────────────┐        │
│              │  kube-apiserver                          │        │
│              │  etcd                                    │        │
│              │  kube-scheduler                          │        │
│              │  kube-controller-manager                 │        │
│              │  kube-cloud-controller-manager           │        │
│              └──────────────────────────────────────────┘        │
│                                                                  │
│          And after bootstrap, kubelet also runs:                 │
│              CoreDNS, ingress-nginx, ArgoCD, local-path-         │
│              provisioner, plus eventually your workloads         │
└────────────────────────────────────────────────────────────────┘
Pod          ──► one instance, no self-healing, no replicas
ReplicaSet   ──► N identical pods, replaces dead ones
Deployment   ──► ReplicaSet + rolling updates + rollback
StatefulSet  ──► like Deployment, but pods have stable identity + stable storage
DaemonSet    ──► one pod per node (per-node agents)

# log into ArgoCD

5. Login with `admin` + the password from `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
rQ7FmrzF7J93ZyHo

cd ~/path/to/Casa-Watch    # wherever your repo is locally

# pull down the manifest you applied manually earlier
curl -sLo infrastructure/local-path-provisioner/storage.yaml \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# verify
ls infrastructure/local-path-provisioner/
# should show storage.yaml

# commit
git add infrastructure/local-path-provisioner/
git commit -m "infrastructure: local-path-provisioner manifest under GitOps control"
git push
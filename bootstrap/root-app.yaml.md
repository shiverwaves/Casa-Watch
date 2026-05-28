apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  # Prevents accidental deletion of the root from cascading and nuking everything
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    # !!! EDIT THIS to your repo URL !!!
    repoURL: https://github.com/shiverwaves/casa-watch.git
    targetRevision: HEAD
    path: infrastructure
    directory:
      recurse: true

  destination:
    server: https://kubernetes.default.svc
    # Each manifest under infrastructure/ specifies its own namespace;
    # this is just the fallback if one doesn't.
    namespace: default

  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual changes back to Git state
    syncOptions:
      - CreateNamespace=true   # auto-create namespaces declared in manifests
      - ServerSideApply=true   # use SSA instead of client-side apply (better conflict handling)
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
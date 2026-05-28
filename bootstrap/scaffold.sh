#!/usr/bin/env bash
set -euo pipefail

mkdir -p \
  bootstrap \
  infrastructure/local-path-provisioner \
  infrastructure/cnpg \
  infrastructure/strimzi \
  infrastructure/redis \
  infrastructure/minio \
  infrastructure/grafana \
  apps/producers \
  apps/consumers \
  src/common \
  src/adapters \
  src/producer \
  src/consumers \
  tests

# .gitkeep so empty dirs survive git
find bootstrap infrastructure apps src tests -type d -empty -exec touch {}/.gitkeep \;

# stub top-level files
cat > .gitignore <<'EOF'
# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# IDE / OS
.idea/
.vscode/
.DS_Store
*.swp

# Local secrets / kubeconfig (NEVER commit)
kubeconfig
*.pem
*.key
.env
.env.local
EOF

cat > README.md <<'EOF'
# casa-watch

Real-estate listings platform — GitOps-driven event pipeline ingesting Spanish/Portuguese
listings, diffing for changes, fanning out to independent consumers.

See `DESIGN.md` for architecture and rationale.
EOF

touch requirements.txt
touch Dockerfile

echo "Done. Structure:"
find . -maxdepth 3 -not -path './.git*' -not -name '.gitkeep'
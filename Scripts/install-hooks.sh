#!/bin/bash
# Makes git run Scripts/check.sh before every commit, so a broken build or a failing test cannot be committed.
# Run once after cloning:   Scripts/install-hooks.sh
set -euo pipefail
cd "$(dirname "$0")/.."
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
exec "$(git rev-parse --show-toplevel)/Scripts/check.sh"
HOOK
chmod +x .git/hooks/pre-commit
echo "Installed .git/hooks/pre-commit"

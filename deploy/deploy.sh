#!/usr/bin/env bash
set -euo pipefail

expected_sha=${1:?Usage: deploy.sh COMMIT_SHA}
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid commit SHA' >&2; exit 1; }

cd "$HOME/cheotsalim-backend"
exec 9> "$HOME/.cheotsalim-deploy.lock"
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
test -f .env || { echo 'Create the server .env first' >&2; exit 1; }
test "$(git branch --show-current)" = develop
test -z "$(git status --porcelain)"
git fetch --no-tags origin develop

if [[ "$(git rev-parse origin/develop)" != "$expected_sha" ]]; then
    echo 'Skipping superseded commit; deploy the latest develop workflow instead'
    exit 0
fi

git merge --ff-only "$expected_sha"
test "$(git rev-parse HEAD)" = "$expected_sha"
# shortcut: deployment briefly interrupts service and has no automatic rollback; add image releases when availability requires it.
sudo -n /usr/bin/docker compose \
    -f /home/deploy/cheotsalim-backend/compose.yaml \
    --project-directory /home/deploy/cheotsalim-backend \
    up -d --build --wait --wait-timeout 180
curl --fail --silent --show-error --max-time 15 http://127.0.0.1/api/health
printf '\nDeployed %s\n' "$expected_sha"

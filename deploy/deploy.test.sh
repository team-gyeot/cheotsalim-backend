#!/usr/bin/env bash
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/deploy.sh
bash -n "$script"
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd)
work=$(mktemp -d "$temp_root/cheotsalim-deploy-test.XXXXXX")
[[ "$work" == "$temp_root"/cheotsalim-deploy-test.* ]]
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME/cheotsalim-backend" "$work/bin"
export PATH="$work/bin:$PATH"
export CALL_LOG="$work/calls"

# Use a local Git remote; Docker and HTTP are the only external effects mocked.
git init --bare --initial-branch=develop "$work/origin.git" > /dev/null
git clone "$work/origin.git" "$HOME/cheotsalim-backend" 2> /dev/null
cd "$HOME/cheotsalim-backend"
git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m initial > /dev/null
git push origin develop 2> /dev/null
sha=$(git rev-parse HEAD)
touch .env
printf '.env\n' > .git/info/exclude

for command in sudo curl flock; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$CALL_LOG"\nexit "${MOCK_%s_EXIT:-0}"\n' \
        "$command" "$command" > "$work/bin/$command"
    chmod +x "$work/bin/$command"
done

bash "$script" "$sha" > /dev/null
grep -q '^sudo$' "$CALL_LOG"
grep -q '^curl$' "$CALL_LOG"

# A failed Compose deployment must not be reported as healthy.
: > "$CALL_LOG"
if MOCK_sudo_EXIT=1 bash "$script" "$sha" > /dev/null 2>&1; then exit 1; fi
! grep -q '^curl$' "$CALL_LOG"
if MOCK_curl_EXIT=1 bash "$script" "$sha" > /dev/null 2>&1; then exit 1; fi

# Deploy only the selected development branch.
: > "$CALL_LOG"
git switch -c main 2> /dev/null
if bash "$script" "$sha" > /dev/null 2>&1; then exit 1; fi
! grep -q '^sudo$' "$CALL_LOG"
git switch develop 2> /dev/null

# A stale SHA and local edits must never restart the application.
: > "$CALL_LOG"
code=0
bash "$script" 0000000000000000000000000000000000000000 > /dev/null || code=$?
test "$code" = 0
! grep -q '^sudo$' "$CALL_LOG"
git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m next > /dev/null
git push origin develop 2> /dev/null
code=0
bash "$script" "$sha" > /dev/null || code=$?
test "$code" = 0
! grep -q '^sudo$' "$CALL_LOG"
remote_sha=$(git rev-parse HEAD)
git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -m local-only > /dev/null
if bash "$script" "$remote_sha" > /dev/null 2>&1; then exit 1; fi
! grep -q '^sudo$' "$CALL_LOG"
printf 'tracked\n' > tracked
git add tracked
if bash "$script" "$remote_sha" > /dev/null 2>&1; then exit 1; fi
! grep -q '^sudo$' "$CALL_LOG"

if bash "$script" invalid > /dev/null 2>&1; then exit 1; fi
echo 'Deployment checks passed'

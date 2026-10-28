#!/usr/bin/env bash
set -euo pipefail

# Trigger tunnel traffic; check WireGuard itself rather than requiring SSH authentication.
timeout 1 bash -c 'exec 3<>/dev/tcp/10.203.0.1/22' > /dev/null 2>&1 || true
for attempt in {1..15}; do
    if sudo wg show wg-ci latest-handshakes | awk '$2 ~ /^[0-9]+$/ && $2 > 0 {up=1} END {exit !up}'; then
        echo 'WireGuard handshake confirmed'
        exit 0
    fi
    sleep 2
done

echo '::error::No WireGuard handshake. Check DEPLOY_HOST, UDP 51820 ACG/NACL rules and WireGuard key pairs.'
ip -4 route get 10.203.0.1
sudo wg show wg-ci endpoints
sudo wg show wg-ci latest-handshakes
sudo wg show wg-ci transfer
exit 1

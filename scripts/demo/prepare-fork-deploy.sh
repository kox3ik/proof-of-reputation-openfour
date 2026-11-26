#!/usr/bin/env bash
# Makes a patched scratch copy of OpenFour's developer/fork-deploy next to it (not committed here).
# Why: ethers' default 250 ms RPC cache returns a stale nonce on anvil (instant mining) -> "nonce has already been used".
# The patch only disables that cache (cacheTimeout:-1) and batching; it changes nothing else.
set -euo pipefail
: "${OPENFOUR_DEV:?set OPENFOUR_DEV to <openfour-docs>/developer}"
[ -d "$OPENFOUR_DEV/node_modules/ethers" ] || (cd "$OPENFOUR_DEV" && npm install --no-audit --no-fund)
rm -rf "$OPENFOUR_DEV/fork-deploy-local"
cp -r "$OPENFOUR_DEV/fork-deploy" "$OPENFOUR_DEV/fork-deploy-local"
rm -rf "$OPENFOUR_DEV/fork-deploy-local/out"
sed -i 's|new ethers.JsonRpcProvider(rpc)|new ethers.JsonRpcProvider(rpc, undefined, { batchMaxCount: 1, cacheTimeout: -1 })|' "$OPENFOUR_DEV/fork-deploy-local/fork-from-chain.js"
grep -q cacheTimeout "$OPENFOUR_DEV/fork-deploy-local/fork-from-chain.js"
echo "patched copy: $OPENFOUR_DEV/fork-deploy-local"

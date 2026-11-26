#!/usr/bin/env bash
# Re-clones pinned dependencies into lib/ (lib/ is git-ignored to keep the repo small).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p lib
[ -d lib/forge-std ] || git clone --depth 1 --branch v1.9.4 https://github.com/foundry-rs/forge-std lib/forge-std
[ -d lib/openzeppelin-contracts ] || git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts

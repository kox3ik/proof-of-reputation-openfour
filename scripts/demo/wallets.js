#!/usr/bin/env node
"use strict";
/**
 * Demo wallet helper for scripts/deploy-testnet.sh. Keys only come from files / the environment, never from argv, and
 * are never printed.
 *   node wallets.js gen <file>                 create 6 fresh demo wallets (mode 600), skipped if the file exists
 *   node wallets.js keys <file>                print the 6 keys comma-separated, for WALLET_KEYS (stdout is captured by the caller)
 *   node wallets.js fund <file> <ether>        top every demo wallet up to <ether> x its role weight (trusted 2, others 1 or 0.6)
 *   node wallets.js fund-address <addr> <ether>  top one address up to <ether>
 *   node wallets.js refund <file>              send the leftovers of the demo wallets back to the deployer
 *   node wallets.js set-updater <registry> <addr>  registry.setUpdater(addr) from DEPLOYER_PRIVATE_KEY (registry owner)
 * Env: OPENFOUR_DEV (provides ethers), RPC_URL, DEPLOYER_PRIVATE_KEY, GAS_PRICE (wei, default 100000000)
 */
const fs = require("fs");
const path = require("path");
const { ethers } = require(path.join(process.env.OPENFOUR_DEV, "node_modules", "ethers"));
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL, undefined, { cacheTimeout: -1, batchMaxCount: 1 });
const GAS = { gasPrice: BigInt(process.env.GAS_PRICE || "100000000") };
// share of the base amount each role needs (trusted trades and migrates the most; the others only buy a few times)
const WEIGHT = { trusted: 2, regular: 1, fresh: 1, flagged: 0.6, babholder: 0.6, agentholder: 0.6 };
const ROLES = ["trusted", "regular", "fresh", "flagged", "babholder", "agentholder"];

const load = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const deployer = () => new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);

async function main() {
  const [cmd, a, b] = process.argv.slice(2);
  if (cmd === "gen") {
    if (fs.existsSync(a)) return console.log("demo wallets exist, reused");
    const w = ROLES.map((r) => { const x = ethers.Wallet.createRandom(); return { role: r, address: x.address, private_key: x.privateKey }; });
    fs.writeFileSync(a, JSON.stringify(w, null, 2), { mode: 0o600 });
    return console.log("demo wallets created");
  }
  if (cmd === "keys") return console.log(load(a).map((w) => w.private_key).join(","));
  if (cmd === "fund" || cmd === "fund-address") {
    const rows = cmd === "fund" ? load(a) : [{ address: a, role: null }];
    const addrs = rows.map((w) => w.address);
    const targets = rows.map((w) => ethers.parseEther(String(Number(b) * (WEIGHT[w.role] ?? 1))));
    // addresses for fund-address come as argv (public); amount b is the target balance
    const d = deployer();
    let nonce = await provider.getTransactionCount(d.address, "pending");
    for (let i = 0; i < addrs.length; ++i) {
      const addr = addrs[i], target = targets[i];
      const bal = await provider.getBalance(addr);
      if (bal >= target) continue;
      const tx = await d.sendTransaction({ to: addr, value: target - bal, nonce: nonce++, ...GAS });
      await tx.wait();
    }
    return console.log("funded", addrs.length, "address(es) up to", b);
  }
  if (cmd === "refund") {
    const d = deployer();
    let back = 0n;
    for (const w of load(a)) {
      const s = new ethers.Wallet(w.private_key, provider);
      const bal = await provider.getBalance(s.address);
      const fee = 21000n * GAS.gasPrice;
      if (bal <= fee) continue;
      await (await s.sendTransaction({ to: d.address, value: bal - fee, gasLimit: 21000n, ...GAS })).wait();
      back += bal - fee;
    }
    return console.log("refunded to deployer (wei):", back.toString());
  }
  if (cmd === "set-updater") {
    const reg = new ethers.Contract(a, ["function setUpdater(address)", "function updater() view returns (address)"], deployer());
    await (await reg.setUpdater(b, GAS)).wait();
    return console.log("updater set:", (await reg.updater()) === ethers.getAddress(b));
  }
  throw new Error("usage: see header");
}
main().catch((e) => { console.error(e.shortMessage || e.message); process.exit(1); });

#!/usr/bin/env node
"use strict";
/**
 * Bot wallet helper. Keys live in a file (mode 600) under testnet-keys/sim/, never printed.
 *   node bots.js gen      create the bot wallets (skipped when the file exists)
 *   node bots.js fund     top every bot up from the deployer to its target (env FUND_<ROLE> overrides, in BNB)
 *   node bots.js refund   send the leftovers of all bots back to the deployer
 */
const lib = require("./lib");
const { ethers, provider, GAS } = lib;
const TARGET = { honestA: "0.036", honestB: "0.02", newbie: "0.006", bundle: "0.013", bundle1: "0.018" };
const target = (role) => ethers.parseEther(process.env[`FUND_${role.toUpperCase()}`] || TARGET[role] || TARGET[role.replace(/\d+$/, "")]);

async function main() {
  const cmd = process.argv[2];
  if (cmd === "plan") return console.log(lib.ROLES.reduce((a, r) => a + Number(ethers.formatEther(target(r))), 0).toFixed(4)); // total funding, no chain access
  if (cmd === "need") {  // what the deployer still has to send to fund the bots (balances read from chain; full plan when no bot file yet)
    if (!require("fs").existsSync(lib.botsFile())) return console.log(lib.ROLES.reduce((a, r) => a + Number(ethers.formatEther(target(r))), 0).toFixed(4));
    await lib.chainGuard();
    let need = 0n;
    for (const [role, w] of Object.entries(lib.loadBots())) { const d = target(role) - (await provider.getBalance(w.address)); if (d > 0n) need += d; }
    return console.log(Number(ethers.formatEther(need)).toFixed(4));
  }
  await lib.chainGuard();
  if (cmd === "gen") return lib.genBots();
  const bots = lib.loadBots(), dep = lib.deployer();
  if (cmd === "fund") {
    let nonce = await provider.getTransactionCount(dep.address, "pending"), sent = 0n;
    for (const [role, w] of Object.entries(bots)) {
      const need = target(role) - (await provider.getBalance(w.address));
      if (need <= 0n) continue;
      await (await dep.sendTransaction({ to: w.address, value: need, nonce: nonce++, ...GAS })).wait();
      sent += need;
    }
    return console.log("funded bots, total BNB:", ethers.formatEther(sent));
  }
  if (cmd === "liquidate") { // sell whatever the bots still hold of the tokens listed in LIVE_JSON (recover tBNB after an aborted run)
    const { Sim } = require("./trades");
    const S = new Sim(); await S.init();
    const toks = Object.values(lib.readJson(process.env.LIVE_JSON).tokens).map((t) => t.token);
    for (const role of lib.ROLES) for (const tk of toks) {
      const bal = await new ethers.Contract(tk, lib.ERC20, provider).balanceOf(S.addr(role));
      if (bal === 0n) continue;
      try { await S.approve(role, tk); await S.sell(role, tk, 100, `liquidate ${role}`); } catch (e) { console.log("skip", role, e.shortMessage || e.message); }
    }
    return;
  }
  if (cmd === "refund") {
    let back = 0n;
    for (const w of Object.values(bots)) {
      const bal = await provider.getBalance(w.address), fee = 21000n * GAS.gasPrice;
      if (bal <= fee) continue;
      await (await w.sendTransaction({ to: dep.address, value: bal - fee, gasLimit: 21000n, ...GAS })).wait();
      back += bal - fee;
    }
    return console.log("refunded to deployer, BNB:", ethers.formatEther(back));
  }
  throw new Error("usage: bots.js gen|fund|refund");
}
main().catch((e) => { console.error(e.shortMessage || e.message); process.exit(1); });

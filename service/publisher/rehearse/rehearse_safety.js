#!/usr/bin/env node
"use strict";
/**
 * Safety rehearsal on the LOCAL anvil fork: (A) the publish tx of a bundle dump is refused twice (injected), (B) the daemon is
 * stopped, a second bundle dumps while it is down, it is restarted, (C) a reorg (anvil evm_snapshot / evm_revert) removes a
 * block range the daemon already processed and published from. A sampler reads (coveredUntil, flags) at ONE block every 250 ms
 * and records a violation whenever coveredUntil >= a dump's time while one of its wallets is not flagged at that block.
 */
const fs = require("fs");
const R = require("./rehearse.js");
const { ethers, provider, reg, A, GAS, sleep, waitUntil, blockInfo, createToken, buy, sellAll, ERC20, deployer } = R;
const { execFileSync } = require("child_process");
const here = __dirname;
const fresh = async (n) => {
  const ws = Array.from({ length: n }, () => ethers.Wallet.createRandom().connect(provider));
  for (const w of ws) await provider.send("anvil_setBalance", [w.address, "0x56BC75E2D63100000"]);
  return ws;
};
let lastBuyTs = 0;
const watches = [], violations = [], covPath = [];
let stopSampler = false, lastCov = -1;
async function sampler() {
  while (!stopSampler) {
    try {
      const bn = await provider.getBlockNumber();
      const cov = Number(await reg.coveredUntil({ blockTag: bn }));
      if (cov !== lastCov) { covPath.push({ block: bn, cov }); lastCov = cov; }
      for (const w of watches) {
        if (cov < w.ts) continue;
        for (const a of w.wallets) if (!(await reg.isFlagged(a, { blockTag: bn }))) violations.push({ label: w.label, wallet: a, block: bn, cov, dumpTs: w.ts });
      }
    } catch (e) { /* node busy during revert */ }
    await sleep(250);
  }
}
const daemon = (cmd) => execFileSync(`${here}/daemon.sh`, [cmd], { env: process.env, stdio: "inherit" });
const log = () => fs.readFileSync(`${process.env.OUT_JSON.replace(/[^/]*$/, "")}publisher.jsonl`, "utf8").split("\n").filter(Boolean).map(JSON.parse);
const flaggedAll = async (ws) => (await Promise.all(ws.map((w) => reg.isFlagged(w.address)))).every(Boolean);
async function bundle(token, createTs, label, ws) {
  let lastBuy = 0;
  for (const w of ws) lastBuy = (await provider.getBlock((await (await buy(w, token, "0.05")).wait()).blockNumber)).timestamp;
  lastBuyTs = lastBuy;
  for (const w of ws) await (await new ethers.Contract(token, ERC20, w).approve(A.core, ethers.MaxUint256, GAS)).wait();
  return async () => {  // dump in one block, once the 60 s skip of the detector has passed
    const wait = createTs + 68 - (await provider.getBlock("latest")).timestamp;
    if (wait > 0) await sleep(wait * 1000);
    const nonces = await Promise.all(ws.map((w) => provider.getTransactionCount(w.address)));
    const recs = await Promise.all((await Promise.all(ws.map((w, i) => sellAll(w, token, nonces[i])))).map((t) => t.wait()));
    const d = await blockInfo(recs[0].blockNumber);
    watches.push({ label, ts: d.ts, wallets: ws.map((w) => w.address) });
    return { dump: d, sameBlock: recs.every((r) => r.blockNumber === recs[0].blockNumber) };
  };
}
async function main() {
  const out = { started: new Date().toISOString() };
  const sam = sampler();
  // ---------- A: the flag batch is refused twice ----------
  const t1 = await createToken(); const A_ws = await fresh(3);
  const dumpA = await bundle(t1.token, t1.ts, "A", A_ws);
  fs.writeFileSync(process.env.FAULT_FILE, "2");
  const a = await dumpA();
  await waitUntil(() => flaggedAll(A_ws), "A flagged", 120000);
  const fa = await firstFlag(A_ws[2], a.dump.block);
  out.A_sendFailure = { ...a, injectedFailuresLeft: fs.readFileSync(process.env.FAULT_FILE, "utf8"), flaggedAtBlock: fa, blocksAfterDump: fa - a.dump.block };
  console.log("A", JSON.stringify(out.A_sendFailure));
  // ---------- B: restart, trades while the daemon is down ----------
  const t2 = await createToken(); const B_ws = await fresh(3), late = (await fresh(1))[0];
  const dumpB = await bundle(t2.token, t2.ts, "B", B_ws);
  await sleep(3000);
  const covBefore = Number(await reg.coveredUntil()); const stopBlock = await provider.getBlockNumber();
  daemon("stop");
  await (await buy(late, t2.token, "0.02")).wait();
  const b = await dumpB();
  await sleep(6000);
  const covDown = Number(await reg.coveredUntil());
  const startedAt = Date.now(); daemon("start");
  await waitUntil(() => flaggedAll(B_ws), "B flagged after restart", 120000);
  const fb = await firstFlag(B_ws[2], b.dump.block);
  out.B_restart = { ...b, stoppedAtBlock: stopBlock, covBeforeStop: covBefore, covWhileDown: covDown, covChangedWhileDown: covDown !== covBefore,
    flaggedAtBlock: fb, secondsFromRestartToFlag: (Date.now() - startedAt) / 1000, lateWalletScored: (await R.comp(late.address, "latest")).some((x) => x > 0) };
  console.log("B", JSON.stringify(out.B_restart));
  // ---------- E: the answer to a send is lost and the daemon dies at once ----------
  const [lw] = await fresh(1);
  const lostFile = `${process.env.OUT}/lost`; fs.writeFileSync(lostFile, "1");
  await (await buy(lw, t2.token, "0.05")).wait();
  await waitUntil(() => fs.readFileSync(lostFile, "utf8").trim() === "0", "the lost answer happened", 60000);
  daemon("stop"); daemon("start");
  await waitUntil(async () => (await R.comp(lw.address, "latest")).some((x) => x > 0), "scored after the restart", 90000);
  await sleep(4000);
  const Le = log();
  out.E_lostAnswer = { adopted: Le.filter((r) => r.event === "pending_adopted").length, sendUnknown: Le.filter((r) => r.event === "send_unknown").length,
    failedPublishes: Le.filter((r) => r.event === "publish" && !r.ok).length, walletScored: (await R.comp(lw.address, "latest")).join(",") };
  console.log("E", JSON.stringify(out.E_lostAnswer));
  // ---------- C: reorg ----------
  const [r1, r2] = await fresh(2);
  await waitUntil(async () => Number(await reg.coveredUntil()) > b.dump.ts, "coverage after B");
  const snap = await provider.send("evm_snapshot", []); const snapBlock = await provider.getBlockNumber();
  await (await buy(r1, t2.token, "0.05")).wait();
  await waitUntil(async () => (await R.comp(r1.address, "latest")).some((x) => x > 0), "r1 scored on the branch to be dropped");
  const sc = (await R.comp(r1.address, "latest")).join(",");
  const headBefore = await provider.getBlockNumber();
  await provider.send("evm_revert", [snap]);
  console.log("reverted", headBefore, "->", await provider.getBlockNumber());
  await waitUntil(() => log().some((r) => r.event === "reorg"), "daemon notices the reorg", 90000);
  await (await buy(r2, t2.token, "0.05")).wait();
  await waitUntil(async () => (await R.comp(r2.address, "latest")).some((x) => x > 0), "r2 scored on the new branch", 90000);
  await sleep(8000);
  out.C_reorg = { snapshotBlock: snapBlock, headWhenReverted: headBefore, orphanScoredAs: sc, orphanAfter: (await R.comp(r1.address, "latest")).join(","),
    newBranchWallet: (await R.comp(r2.address, "latest")).join(","), reorgEvents: log().filter((r) => r.event === "reorg") };
  console.log("C", JSON.stringify(out.C_reorg));
  // ---------- D: positions that were opened before the daemon (re)started ----------
  const t3 = await createToken(); const D_ws = await fresh(3);
  const dumpD = await bundle(t3.token, t3.ts, "D", D_ws);
  const buysTs = lastBuyTs;
  await waitUntil(async () => Number(await reg.coveredUntil()) >= buysTs, "coverage past the buys", 90000);
  daemon("stop"); fs.rmSync(`${process.env.OUT}/state`, { recursive: true, force: true }); daemon("start");  // empty state: history is replayed
  const d = await dumpD();
  await waitUntil(() => flaggedAll(D_ws), "D flagged", 120000);
  const LD = log();
  out.D_positionsBeforeStart = { ...d, flaggedAtBlock: await firstFlag(D_ws[2], d.dump.block), warmup: LD.filter((r) => r.event === "warmup_done").slice(-1),
    coverageDisabled: LD.filter((r) => r.event === "coverage_disabled").length };
  console.log("D", JSON.stringify(out.D_positionsBeforeStart));
  stopSampler = true; await sam;
  const L = log();
  out.violations = violations; out.covPath = covPath;
  out.log = { sendFailed: L.filter((r) => r.event === "send_failed").length, publishFailed: L.filter((r) => r.event === "publish" && !r.ok).length,
    publishOk: L.filter((r) => r.event === "publish" && r.ok).length, restored: L.filter((r) => r.event === "restored"), starts: L.filter((r) => r.event === "start").length,
    bumped: L.filter((r) => r.event === "tx_bumped").length, errors: L.filter((r) => r.event === "error").map((r) => r.error).slice(0, 5) };
  fs.writeFileSync(process.env.OUT_JSON, JSON.stringify(out, null, 2));
  console.log("violations:", violations.length, "written", process.env.OUT_JSON);
}
async function firstFlag(w, from) { return R.firstBlock(from, async (b) => await reg.isFlagged(w.address, { blockTag: b })); }
main().catch((e) => { console.error(e); stopSampler = true; process.exit(1); });

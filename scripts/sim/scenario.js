#!/usr/bin/env node
"use strict";
/**
 * Live rating simulation: honest traders whose score grows, newbies paying the refundable deposit, a 4-wallet bundle that buys
 * together and dumps within one block (flagged by the publisher), post-flag trades that pay the penalty on chain, forfeiture of
 * the bundle's deposit, and the honest wallets' deposit refund / cashback. The publisher must already be running.
 * Env: SIM_SECONDS (nominal length, default 1500 = 25 min; the dry run uses ~300), SIM_RAISE (curve raise, default 0.2),
 *      BUNDLE_BUDGET (0.01), HONEST_BUDGET (0.006), NEWBIE_BUDGET (0.004), LIVE_JSON (written for the page), RUN_LOG (output).
 */
const fs = require("fs");
const lib = require("./lib");
const { Sim } = require("./trades");
const { provider, sleep } = lib;

const TOTAL = Number(process.env.SIM_SECONDS || 1500) * 1000;
const RAISE = process.env.SIM_RAISE || "0.2";
const BUNDLE = process.env.BUNDLE_BUDGET || "0.01", HONEST = process.env.HONEST_BUDGET || "0.006", NEWBIE = process.env.NEWBIE_BUDGET || "0.004";
const BUNDLE_ROLES = ["bundle1", "bundle2", "bundle3", "bundle4"];

async function main() {
  const S = new Sim();
  await S.init();
  const t0 = Date.now();
  const pace = async (frac) => { const d = t0 + frac * TOTAL - Date.now(); if (d > 0) await sleep(d); };
  const stamp = (m) => console.log(`[+${Math.round((Date.now() - t0) / 1000)}s] ${m}`);
  const waitScored = (role) => S.waitFor(async () => (await S.snapshot(role)).comps.some((x) => x > 0), `${role} scored`);
  const log = { startedAt: new Date().toISOString(), onPublicChain: !String(process.env.RPC_URL).includes("127.0.0.1"), chainId: S.chainId, explorer: lib.EXPLORER,
    registry: S.por.registry, pool: S.por.pool, core: S.fork.addresses.core, presetId: S.presetId.toString(), rates: {
      freshDepositBps: process.env.FRESH_DEPOSIT_BPS, penaltyBps: process.env.PENALTY_BPS, zeroBps: process.env.ZERO_BPS },
    wallets: Object.fromEntries(lib.ROLES.map((r) => [r, S.addr(r)])), tokens: {}, steps: [] };
  const compact = (t) => ({ role: t.role, side: t.side, label: t.label, hash: t.hash, link: t.link, block: t.block, score: t.before.score, flagged: t.before.flagged,
    reg: t.before.bps.regular, dep: t.before.bps.deposit, pen: t.before.bps.penalty, chargedBps: t.fees?.extraFeeBps, extraFeeBnb: t.fees?.extraFeeBnb });
  let finished = false;
  const flush = () => fs.writeFileSync(process.env.LIVE_JSON, lib.J({ startedAt: log.startedAt, totalSeconds: TOTAL / 1000, roster: log.wallets, tokens: log.tokens, rates: log.rates,
    explorer: lib.EXPLORER, onPublicChain: log.onPublicChain, trades: S.trades.map(compact), feeBeforeAfter: log.feeBeforeAfter && { wallet: log.feeBeforeAfter.wallet, summary: log.feeBeforeAfter.summary }, finished }));
  S.onChange = flush;
  const step = (name, extra = {}) => { log.steps.push({ name, t: Math.round((Date.now() - t0) / 1000), ...extra }); stamp(name); flush(); };

  // ---- tokens (created by the deployer = Core.signer); T1 is the bundle's token
  const tokens = {};
  for (const [k, nm] of [["T1", "ALPHA"], ["T2", "BETA"], ["T3", "GAMMA"]]) {
    const t = await lib.createToken(S.dep, S.fork, S.presetId, `${nm}${String(Date.now()).slice(-4)}`, RAISE);
    tokens[k] = t; log.tokens[k] = t; S.track(`create token ${k}`, "keeper", { hash: t.tx, blockNumber: t.block, status: 1 });
  }
  S.startSampler(lib.ROLES, Number(process.env.SAMPLE_MS || 4000), t0);
  step("tokens created");

  // ---- A: newbies and the first honest buy (all fresh wallets: they pay the refundable deposit)
  await pace(0.03);
  await S.buy("newbie1", tokens.T1.token, NEWBIE, "newbie1 first buy T1 (fresh: deposit applies)");
  await S.buy("newbie2", tokens.T1.token, NEWBIE, "newbie2 first buy T1 (fresh: deposit applies)");
  const a1 = await S.buy("honestA", tokens.T1.token, HONEST, "honestA first buy T1 (fresh: deposit applies)");
  await S.approve("honestA", tokens.T1.token);
  await S.approve("newbie1", tokens.T1.token);
  step("fresh wallets bought", { tx: a1.hash });

  // ---- B: the honest wallet keeps trading other tokens, its score is published after each round and grows
  await pace(0.08);
  await waitScored("honestA");
  step("honestA scored", { snapshot: await S.snapshot("honestA") });
  await S.buy("honestA", tokens.T2.token, HONEST, "honestA buys T2 (has a record now)");
  await S.buy("honestB", tokens.T2.token, HONEST, "honestB first buy T2 (fresh)");
  await S.buy("newbie3", tokens.T2.token, NEWBIE, "newbie3 first buy T2 (fresh)");
  await pace(0.16);
  await S.buy("honestA", tokens.T3.token, HONEST, "honestA buys T3");
  await S.buy("newbie4", tokens.T3.token, NEWBIE, "newbie4 first buy T3 (fresh)");
  await S.approve("honestA", tokens.T2.token); await S.approve("honestB", tokens.T2.token); await S.approve("honestA", tokens.T3.token);
  step("honest rounds", { honestA: await S.snapshot("honestA") });

  // ---- C: the bundle buys T1 together (fresh wallets, normal fees: nothing is known about them yet)
  await pace(0.30);
  const bundleBuys = [];
  for (const r of BUNDLE_ROLES) bundleBuys.push(await S.buy(r, tokens.T1.token, BUNDLE, `${r} buys T1 together with the bundle (fee BEFORE any flag)`));
  for (const r of BUNDLE_ROLES) await S.approve(r, tokens.T1.token);
  step("bundle bought", { blocks: bundleBuys.map((b) => b.block) });
  await S.buy("honestB", tokens.T3.token, HONEST, "honestB buys T3");
  // bundle1 is no longer fresh once its first trade is published: this buy shows its normal fee before any flag
  await waitScored("bundle1");
  await S.approve("bundle1", tokens.T2.token);
  const preFlagBuy = await S.buy("bundle1", tokens.T2.token, NEWBIE, "bundle1 buys T2 BEFORE the flag (normal fee, no deposit: no longer fresh)");

  // ---- D: the bundle dumps T1 inside one block (after the detector's 60 s blind window)
  await pace(0.42);
  const wait = tokens.T1.ts + 70 - (await provider.getBlock("latest")).timestamp;
  if (wait > 0) { stamp(`waiting ${wait}s: the detector ignores sells in the first 60 s of a token`); await sleep(wait * 1000); }
  const pre = Object.fromEntries(await Promise.all(BUNDLE_ROLES.map(async (r) => [r, await S.snapshot(r, false)])));
  const nonces = await Promise.all(BUNDLE_ROLES.map((r) => provider.getTransactionCount(S.addr(r), "pending")));
  const pend = [];
  for (const [i, r] of BUNDLE_ROLES.entries()) pend.push(await S.sell(r, tokens.T1.token, 100, `${r} dumps T1 (with the bundle, fee before flag)`, { nonce: nonces[i], presign: true, pre: pre[r] }));
  const sentTx = await Promise.all(pend.map((p) => p.send()));  // one instant: all four sells reach the node together
  const dumps = [];
  for (const [i, p] of pend.entries()) dumps.push(await p.finish(sentTx[i]));
  const dumpBlock = Math.min(...dumps.map((d) => d.block));
  const dumpInfo = await S.blockOf(dumpBlock);
  step("bundle dumped", { blocks: dumps.map((d) => d.block) });
  const flagged = await S.waitFor(async () => (await Promise.all(BUNDLE_ROLES.map((r) => S.reg.isFlagged(S.addr(r))))).every(Boolean) && (await provider.getBlockNumber()), "bundle flagged");
  // first block where all four are flagged (historical reads)
  let flagBlock = flagged;
  for (let b = dumpBlock; b <= flagged; b++) {
    const all = await Promise.all(BUNDLE_ROLES.map((r) => S.reg.isFlagged(S.addr(r), { blockTag: b })));
    if (all.every(Boolean)) { flagBlock = b; break; }
  }
  log.flag = { dumpBlock, flaggedBlock: flagBlock, blocksAfterDump: flagBlock - dumpBlock, secondsAfterDump: (await S.blockOf(flagBlock)).ts - dumpInfo.ts,
    honestFlagged: await S.reg.isFlagged(S.addr("honestA")), flaggedFrom: Number(await S.reg.flaggedFrom(S.addr("bundle1"))) };
  step("bundle flagged on chain", log.flag);

  // ---- E: after the flag the same wallet trades again and pays the penalty on chain
  await pace(0.55);
  const after = await S.buy("bundle1", tokens.T2.token, NEWBIE, "bundle1 buys T2 AFTER the flag (regular + penalty on chain)");
  const afterSell = await S.sell("bundle1", tokens.T2.token, 100, "bundle1 sells T2 AFTER the flag (penalty, no sell cap)");
  log.feeBeforeAfter = { wallet: S.addr("bundle1"), buy: { before: preFlagBuy, after }, sell: { before: dumps[0], after: afterSell },
    summary: { buyBeforeBps: preFlagBuy.fees.extraFeeBps, buyAfterBps: after.fees.extraFeeBps, sellBeforeBps: dumps[0].fees.extraFeeBps, sellAfterBps: afterSell.fees.extraFeeBps,
      penaltyBpsAfter: after.before.bps.penalty } };
  step("post-flag trades", log.feeBeforeAfter.summary);

  // ---- F: coverage passes the sales -> the keeper settles the bundle's buckets (deposit and cashback forfeited), honest wallets claim
  await pace(0.66);
  const lastBundleSale = Math.max(dumpInfo.ts, (await S.blockOf(afterSell.block)).ts);
  await S.waitCovered(lastBundleSale, "bundle sales");
  for (const r of BUNDLE_ROLES) await S.claim("keeper", r, tokens.T1.token, `keeper settles ${r}: flagged wallet forfeits deposit and cashback`);
  await S.claim("keeper", "bundle1", tokens.T2.token, "keeper settles bundle1's post-flag T2 sale").catch((e) => { const d = e.data ? S.pool.interface.parseError(e.data) : null; console.log("bundle1 T2 bucket claim reverted:", d ? d.name : e.shortMessage || e.message); log.bundle1T2Claim = { reverted: d ? d.name : e.shortMessage || e.message, bucket: null }; });
  step("bundle forfeited", { fund: (await S.pool.fund(S.asset)).toString() });

  await pace(0.74);
  const honestSales = [await S.sell("honestA", tokens.T1.token, 100, "honestA sells T1 (closes its position)"),
    await S.sell("newbie1", tokens.T1.token, 100, "newbie1 sells T1 (closes its position)"), await S.sell("honestB", tokens.T2.token, 100, "honestB sells T2")];
  const lastSale = Math.max(...(await Promise.all(honestSales.map((x) => S.blockOf(x.block)))).map((b) => b.ts));  // coverage must pass the sales, not the chain head
  await S.waitCovered(lastSale, "honest sales");
  for (const [r, tk] of [["honestA", tokens.T1], ["honestB", tokens.T2], ["newbie1", tokens.T1]]) await S.claim(r, r, tk.token, `${r} claims its deposit refund and cashback`);
  step("honest claims done");

  // ---- G: the honest wallet trades on: its score keeps rising
  await pace(0.88);
  await S.buy("honestA", tokens.T3.token, HONEST, "honestA buys T3 again");
  await S.buy("honestA", tokens.T2.token, HONEST, "honestA buys T2 again");
  await pace(0.96);
  S.stopSampler();
  log.final = Object.fromEntries(await Promise.all(lib.ROLES.map(async (r) => [r, { ...(await S.snapshot(r, true)), balanceBnb: Number(lib.ethers.formatEther(await provider.getBalance(S.addr(r)))) }])));
  Object.assign(log, { finishedAt: new Date().toISOString(), txs: S.txs, trades: S.trades, claims: S.claims, timeline: S.timeline,
    poolState: { fund: (await S.pool.fund(S.asset)).toString(), deposits: (await S.pool.depositPool(S.asset)).toString(), budget: (await S.pool.budgetPool(S.asset)).toString() } });
  fs.writeFileSync(process.env.RUN_LOG, lib.J(log));
  finished = true; flush();
  stamp("done, run log written");
}
main().catch((e) => { console.error(e); process.exit(1); });

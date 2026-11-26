"use strict";
/** Trading / reading primitives of the simulation: every tx is recorded with its explorer link and fee breakdown. */
const lib = require("./lib");
const { ethers, provider, GAS, sleep } = lib;

const unit = (x) => Number((Number(x) / 1000).toFixed(3));
const bnb = (v) => Number(ethers.formatEther(v));

class Sim {
  constructor() { this.txs = []; this.trades = []; this.claims = []; this.timeline = []; }

  async init() {
    this.chainId = await lib.chainGuard();
    this.fork = lib.readJson(process.env.FORK_JSON);
    this.por = lib.readJson(process.env.POR_JSON);
    this.presetId = BigInt(lib.readJson(process.env.STATE_JSON).presetId);
    this.dep = lib.deployer();
    this.bots = lib.loadBots();
    this.W = { ...this.bots };
    this.asset = this.fork.addresses.wbnb;
    this.core = new ethers.Contract(this.fork.addresses.core, lib.CORE_ABI, provider);
    this.reg = new ethers.Contract(this.por.registry, lib.abiOf("ReputationRegistry"), provider);
    this.pool = new ethers.Contract(this.por.pool, lib.abiOf("CashbackPool"), provider);
    this.wbnb = new ethers.Contract(this.asset, lib.ERC20, provider);
  }

  addr(role) { return role === "keeper" ? this.dep.address : this.W[role].address; }
  signer(role) { return role === "keeper" ? this.dep : this.W[role]; }
  link(hash) { return `${lib.EXPLORER}/tx/${hash}`; }

  track(label, role, rcpt) {
    const t = { label, role, wallet: this.addr(role), hash: rcpt.hash, link: this.link(rcpt.hash), block: rcpt.blockNumber, status: rcpt.status };
    this.txs.push(t);
    return t;
  }

  /** Extra fee the wallet would pay now (bps parts) and its record. */
  async snapshot(role, isBuy = true) {
    const a = this.addr(role);
    const [q, score, flagged, fresh, comps] = await Promise.all([
      this.reg.quoteDetailed(a, isBuy), this.reg.scoreOf(a), this.reg.isFlagged(a), this.reg.isFresh(a), this.reg.componentsOf(a)]);
    return { score: unit(score), flagged, fresh, comps: Array.from(comps).map(Number),
      bps: { regular: Number(q.regularBps), deposit: Number(q.depositBps), penalty: Number(q.penaltyBps), total: Number(q.regularBps + q.depositBps + q.penaltyBps) } };
  }

  async withMargin(method, args, ov) { return { ...ov, gasLimit: ((await method.estimateGas(...args, ov)) * 3n) / 2n }; }

  decode(rcpt) {
    for (const l of rcpt.logs) {
      try { const p = this.core.interface.parseLog(l); if (p?.name === "TradeExecuted") return p.args; } catch { /* other log */ }
    }
    return null;
  }

  /** Fee breakdown in bps and BNB from the quote taken just before the trade and the TradeExecuted event. */
  breakdown(pre, ev) {
    if (!ev) return null;
    const cq = ev.curveQuoteAmount, part = (b) => bnb((cq * BigInt(b)) / 10000n);
    return { curveQuoteBnb: bnb(cq), tokens: ev.tokenAmount.toString(), protocolFeeBnb: bnb(ev.protocolFee), extraFeeBnb: bnb(ev.taxFee),
      extraFeeBps: this.shownBps(ev, pre), measuredFeeBps: cq === 0n ? 0 : Number(((Number(ev.taxFee) / Number(cq)) * 1e4).toFixed(4)),
      quoted: { ...pre.bps, regularBnb: part(pre.bps.regular), depositBnb: part(pre.bps.deposit), penaltyBnb: part(pre.bps.penalty) } };
  }

  /** Fee in bps as shown: the contract's integer quote when the paid fee matches it (the contract rounds down in wei), else the measured value. */
  shownBps(ev, pre) {
    const cq = ev.curveQuoteAmount;
    if (cq === 0n) return 0;
    const measured = (Number(ev.taxFee) / Number(cq)) * 1e4;
    return Math.abs(measured - pre.bps.total) < 0.05 ? pre.bps.total : Number(measured.toFixed(2));
  }

  async buy(role, token, budget, label, extra = {}) {
    const w = this.signer(role), c = this.core.connect(w), amt = ethers.parseEther(String(budget));
    const pre = await this.snapshot(role, true);
    const ov = await this.withMargin(c.buyByBudget, [token, amt, 0, 0, "0x"], { value: amt, ...GAS });
    const rcpt = await (await c.buyByBudget(token, amt, 0, 0, "0x", ov)).wait();
    return this.record({ side: "buy", role, token, label, pre, rcpt, ...extra });
  }

  async approve(role, token) {
    const t = new ethers.Contract(token, lib.ERC20, this.signer(role));
    if ((await t.allowance?.(this.addr(role), this.core.target)) > 0n) return;
    const rcpt = await (await t.approve(this.core.target, ethers.MaxUint256, GAS)).wait();
    this.track(`approve ${role}`, role, rcpt);
  }

  /** Sell `pct` percent of the wallet's balance. opts.nonce + opts.noWait: send now, resolve later (returns {pending}). */
  async sell(role, token, pct, label, opts = {}) {
    const w = this.signer(role), c = this.core.connect(w), t = new ethers.Contract(token, lib.ERC20, provider);
    const amount = ((await t.balanceOf(w.address)) * BigInt(pct)) / 100n;
    const pre = opts.pre || (await this.snapshot(role, false));
    const ov = opts.nonce !== undefined ? { ...GAS, nonce: opts.nonce, gasLimit: 1_500_000n } : await this.withMargin(c.sell, [token, amount, 0, 0, "0x"], GAS);
    if (opts.presign) {  // sign now, broadcast later together with the other wallets of the bundle (all in the same instant)
      const tx = await c.sell.populateTransaction(token, amount, 0, 0, "0x", ov);
      const raw = await w.signTransaction({ ...tx, from: undefined, chainId: this.chainId, type: 0, nonce: ov.nonce, gasLimit: ov.gasLimit, gasPrice: ov.gasPrice });
      return { send: async () => { const r = await provider.broadcastTransaction(raw); return r; },
        finish: async (sent) => this.record({ side: "sell", role, token, label, pre, rcpt: await (await sent).wait() }) };
    }
    const tx = await c.sell(token, amount, 0, 0, "0x", ov);
    if (opts.noWait) return { tx, finish: async () => this.record({ side: "sell", role, token, label, pre, rcpt: await tx.wait() }) };
    return this.record({ side: "sell", role, token, label, pre, rcpt: await tx.wait() });
  }

  record({ side, role, token, label, pre, rcpt, ...extra }) {
    const ev = this.decode(rcpt);
    const tr = { ...this.track(label, role, rcpt), side, token, before: pre, fees: this.breakdown(pre, ev), ...extra };
    this.trades.push(tr);
    if (this.onChange) this.onChange();
    console.log(`${side.padEnd(4)} ${role.padEnd(8)} score=${pre.score} flagged=${pre.flagged} quoted=${pre.bps.total}bps (reg ${pre.bps.regular} dep ${pre.bps.deposit} pen ${pre.bps.penalty}) charged=${tr.fees?.extraFeeBps}bps ${label}`);
    return tr;
  }

  async claim(caller, wallet, token, label) {
    const asset = this.asset, u = await this.pool.unlocked(asset, token, this.addr(wallet));
    const before = await this.wbnb.balanceOf(this.addr(wallet));
    const poolBefore = { fund: bnb(await this.pool.fund(asset)), bonusLiability: bnb(await this.pool.bonusLiability(asset)) };
    const rcpt = await (await this.pool.connect(this.signer(caller)).claim(asset, token, this.addr(wallet), GAS)).wait();
    const ev = rcpt.logs.map((l) => { try { return this.pool.interface.parseLog(l); } catch { return null; } }).find((e) => e && (e.name === "Claimed" || e.name === "Forfeited"));
    const paid = (await this.wbnb.balanceOf(this.addr(wallet))) - before;
    const rec = { ...this.track(label, caller, rcpt), wallet: this.addr(wallet), forWallet: wallet, event: ev ? ev.name : null,
      args: ev ? Object.fromEntries(ev.fragment.inputs.map((i, k) => [i.name, ev.args[k].toString()])) : {},
      unlockedBefore: { deposit: bnb(u.deposit), fee: bnb(u.fee), bonus: bnb(u.bonus), ts: Number(u.ts) }, paidToWalletBnbBalanceDiff: bnb(paid), poolBefore,
      poolAfter: { fund: bnb(await this.pool.fund(asset)), bonusLiability: bnb(await this.pool.bonusLiability(asset)) } };
    const A = rec.args; // the event is the truth; balance reads on a load-balanced RPC can lag
    if (rec.event === "Claimed") rec.paidByEventBnb = (Number(A.deposit) + Number(A.cashback) + Number(A.bonus)) / 1e18;
    if (rec.event === "Forfeited") rec.forfeitedByEventBnb = (Number(A.deposit) + Number(A.fee)) / 1e18;
    this.claims.push(rec);
    console.log(`claim for ${wallet}: ${rec.event} ${rec.paidByEventBnb ?? rec.forfeitedByEventBnb} BNB (${label})`);
    return rec;
  }

  async covered() { return Number(await this.reg.coveredUntil()); }
  async waitFor(fn, label, timeoutMs = 240_000) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) { const r = await fn(); if (r) return r; await sleep(Number(process.env.WAIT_MS || 400)); }
    throw new Error(`timeout waiting for ${label}`);
  }
  async waitCovered(ts, label) { return this.waitFor(async () => (await this.covered()) >= ts, `coverage ${label}`); }
  async blockOf(n) { const b = await provider.getBlock(n); return { block: n, ts: b.timestamp }; }

  /** Background sampler: roster state every `everyMs` into the timeline (also used for "score over time"). */
  startSampler(roles, everyMs, t0) {
    this.sampling = true;
    (async () => {
      while (this.sampling) {
        try {
          const head = await provider.getBlockNumber();
          const row = { t: Math.round((Date.now() - t0) / 1000), block: head, wallets: {} };
          for (const r of roles) { const s = await this.snapshot(r, true); row.wallets[r] = { score: s.score, flagged: s.flagged, fresh: s.fresh, buyBps: s.bps.total, penaltyBps: s.bps.penalty }; }
          this.timeline.push(row);
        } catch (e) { /* keep sampling */ }
        await sleep(everyMs);
      }
    })();
  }
  stopSampler() { this.sampling = false; }
}
module.exports = { Sim, unit, bnb };

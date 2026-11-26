"use strict";
/* Live simulation panel: shown only when sim-live.json exists next to the page (scripts/sim/run-sim.sh writes it).
   Everything in the roster table is read from the Registry / CashbackPool every ~1.5 s; the trade list and the
   "before / after flag" box come from the simulation log (every row has a tx hash). */
(async function () {
  const { ethers } = window;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const short = (a) => (a ? a.slice(0, 6) + "..." + a.slice(-4) : "-");
  const get = async (f) => { try { const r = await fetch(f, { cache: "no-store" }); return r.ok ? await r.json() : null; } catch { return null; } };
  const cfg = await get("config.json"), live = await get("sim-live.json");
  if (!cfg || !live) return;
  const net = cfg.networks[new URLSearchParams(location.search).get("net") || cfg.default];
  if (!net || !net.registry) return;
  $("live").hidden = false;
  const provider = new ethers.JsonRpcProvider(net.rpc, net.chainId, { staticNetwork: true, batchMaxCount: 1 });
  const R = new ethers.Contract(net.registry, [
    "function scoreOf(address) view returns (uint256)", "function isFlagged(address) view returns (bool)", "function isFresh(address) view returns (bool)",
    "function quoteDetailed(address,bool) view returns (tuple(uint256 regularBps,uint256 depositBps,uint256 penaltyBps,uint256 treasuryBps,uint256 poolBps,address treasury,address pool))",
    "function coveredUntil() view returns (uint64)", "function currentEpoch() view returns (uint64)"], provider);
  const logsProvider = net.logsRpc ? new ethers.JsonRpcProvider(net.logsRpc, net.chainId, { staticNetwork: true, batchMaxCount: 1 }) : provider; // getLogs needs a node that allows it
  const P = net.pool ? new ethers.Contract(net.pool, [
    "function fund(address) view returns (uint256)", "function depositPool(address) view returns (uint256)", "function bonusLiability(address) view returns (uint256)",
    "function unlocked(address asset,address token,address wallet) view returns (uint256 deposit,uint256 fee,uint256 bonus,uint64 ts)",
    "event Claimed(address indexed asset,address indexed wallet,address indexed caller,uint256 deposit,uint256 cashback,uint256 bonus)",
    "event Forfeited(address indexed asset,address indexed wallet,uint256 deposit,uint256 fee,uint256 bonusWrittenOff)"], provider) : null;
  const tc = async (f) => { try { return await f(); } catch { return null; } };
  const unit = (x) => (Number(x) / 1000).toFixed(3);
  const bnb = (v, d = 6) => (v == null ? "-" : Number(ethers.formatEther(v)).toFixed(d).replace(/0+$/, "").replace(/\.$/, "") || "0");
  const group = (r) => (r.startsWith("honest") ? "honest" : r.startsWith("newbie") ? "newbie" : "bundle");
  const prev = {}, feed = [], seen = new Set();
  let fromBlock = null, lastFeedAt = 0;
  const say = (cls, text) => { feed.unshift({ cls, text, t: new Date().toISOString().slice(11, 19) }); feed.length = Math.min(feed.length, 14); };

  async function poll() {
    const roster = Object.entries(live.roster);
    const [head, epoch, cov, fund, dep, liab] = await Promise.all([tc(() => provider.getBlockNumber()), tc(() => R.currentEpoch()), tc(() => R.coveredUntil()),
      P ? tc(() => P.fund(net.quoteAsset)) : null, P ? tc(() => P.depositPool(net.quoteAsset)) : null, P ? tc(() => P.bonusLiability(net.quoteAsset)) : null]);
    if (fromBlock === null && head !== null) fromBlock = Math.max(0, head - 300);
    const rows = await Promise.all(roster.map(async ([role, a]) => {
      const [score, flagged, fresh, q, u] = await Promise.all([tc(() => R.scoreOf(a)), tc(() => R.isFlagged(a)), tc(() => R.isFresh(a)), tc(() => R.quoteDetailed(a, true)),
        P ? tc(async () => { const sum = { deposit: 0n, fee: 0n }; for (const t of window.PORLiveTokens || []) { const b = await P.unlocked(net.quoteAsset, t, a); sum.deposit += b.deposit; sum.fee += b.fee; } return sum; }) : null]);
      return { role, a, score: score === null ? null : unit(score), flagged, fresh, q, u };
    }));
    for (const r of rows) {
      const p = prev[r.role];
      if (p && r.score !== null) {
        if (p.score !== r.score) say(Number(r.score) > Number(p.score) ? "up" : "down", `${r.role}: score ${p.score} -> ${r.score}${r.fresh === false && p.fresh ? " (no longer fresh: deposit stops)" : ""}`);
        if (!p.flagged && r.flagged) say("bad", `${r.role}: FLAGGED as a rug participant (penalty ${r.q ? r.q.penaltyBps : "?"} bps now applies)`);
      }
      prev[r.role] = r; r.changed = !p || p.score !== r.score || p.flagged !== r.flagged;
    }
    if (P && fromBlock !== null) {
      const PL = P.connect(logsProvider);
      const evs = await tc(async () => [...(await PL.queryFilter(PL.filters.Forfeited(), fromBlock, "latest")), ...(await PL.queryFilter(PL.filters.Claimed(), fromBlock, "latest"))]);
      for (const e of evs || []) {
        const k = e.transactionHash + e.index; if (seen.has(k)) continue; seen.add(k);
        const who = rows.find((r) => r.a.toLowerCase() === e.args.wallet.toLowerCase());
        if (e.fragment.name === "Forfeited") say("bad", `${who ? who.role : short(e.args.wallet)}: deposit ${bnb(e.args.deposit)} + cashback ${bnb(e.args.fee)} BNB forfeited to the scam fund`);
        else say("up", `${who ? who.role : short(e.args.wallet)}: claimed deposit refund ${bnb(e.args.deposit)} + cashback ${bnb(e.args.cashback)} + bonus ${bnb(e.args.bonus)} BNB`);
      }
    }
    render(rows, { head, epoch, cov, fund, dep, liab });
  }

  function render(rows, s) {
    $("liveStats").innerHTML = [[s.head ?? "-", "block"], [s.epoch ?? "-", "publication epoch"], [s.fund === null ? "-" : bnb(s.fund, 6), "scam fund (BNB): confiscated deposits"],
      [s.liab == null ? "-" : bnb(s.liab, 6), "honest bonus owed (BNB)"], [s.dep === null ? "-" : bnb(s.dep, 6), "deposits held (BNB)"], [`${live.rates.freshDepositBps} / ${live.rates.penaltyBps}`, "fresh deposit / flag penalty (bps)"]]
      .map(([v, l]) => `<div class="stat"><b>${esc(v)}</b><span>${esc(l)}</span></div>`).join("");
    let h = `<tr><th>Wallet</th><th>Address</th><th>Score 0..1</th><th></th><th class="num">Buy fee bps: regular + deposit + penalty</th><th class="num">Deposit / cashback held (BNB)</th></tr>`;
    for (const r of rows) {
      const pills = (r.flagged ? `<span class="pill bad">flagged</span> ` : "") + (r.fresh ? `<span class="pill warn">fresh</span>` : "");
      const q = r.q ? `${r.q.regularBps} + ${r.q.depositBps} + ${r.q.penaltyBps} = <b>${Number(r.q.regularBps + r.q.depositBps + r.q.penaltyBps)}</b>` : "-";
      const u = r.u ? `${bnb(r.u.deposit, 7)} / ${bnb(r.u.fee, 7)}` : "-";
      const w = r.score === null ? 0 : Math.round(Number(r.score) * 100);
      h += `<tr class="${group(r.role)} ${r.changed ? "flash" : ""}"><td>${esc(r.role)}</td><td><a href="#" data-a="${esc(r.a)}">${esc(short(r.a))}</a></td>` +
        `<td><div class="track mini"><div class="fill ${r.flagged ? "neg" : ""}" style="width:${w}%"></div></div></td><td><b>${r.score ?? "-"}</b> ${pills}</td><td class="num">${q}</td><td class="num">${u}</td></tr>`;
    }
    $("liveTable").innerHTML = h;
    $("liveTable").querySelectorAll("a[data-a]").forEach((el) => el.addEventListener("click", (e) => { e.preventDefault(); $("addr").value = el.dataset.a; $("go").click(); }));
    $("liveFeed").innerHTML = feed.map((f) => `<li class="${f.cls}"><span class="muted">${f.t}</span> ${esc(f.text)}</li>`).join("") || `<li class="muted">waiting for activity...</li>`;
  }

  async function renderLog() {
    const L = await get("sim-live.json");
    if (!L) return;
    window.PORLiveTokens = Object.values(L.tokens || {}).map((t) => t.token);
    const link = (t) => (L.onPublicChain ? `<a href="${esc(t.link)}" target="_blank" rel="noopener">${esc(short(t.hash))}</a>` : `<code>${esc(short(t.hash))}</code>`);
    const fba = L.feeBeforeAfter;
    $("liveFba").innerHTML = fba ? `<div class="note"><b>Same wallet, before and after the flag</b> (${esc(short(fba.wallet))}): buy fee <b>${fba.summary.buyBeforeBps} bps</b> -> <b>${fba.summary.buyAfterBps} bps</b>, ` +
      `sell fee <b>${fba.summary.sellBeforeBps} bps</b> -> <b>${fba.summary.sellAfterBps} bps</b> (flag penalty ${fba.summary.penaltyBpsAfter} bps; the sell cap no longer applies). Its deposit and cashback are forfeited.</div>` : "";
    let h = `<tr><th>Wallet</th><th>Side</th><th class="num">Score</th><th class="num">Quoted bps (reg+dep+pen)</th><th class="num">Charged bps</th><th class="num">Extra fee BNB</th><th>Tx</th><th>What</th></tr>`;
    for (const t of (L.trades || []).slice(-14).reverse()) {
      h += `<tr class="${group(t.role)}"><td>${esc(t.role)}</td><td>${esc(t.side)}</td><td class="num">${t.score}${t.flagged ? " flagged" : ""}</td><td class="num">${t.reg}+${t.dep}+${t.pen}</td><td class="num">${t.chargedBps}</td><td class="num">${t.extraFeeBnb}</td><td>${link(t)}</td><td>${esc(t.label)}</td></tr>`;
    }
    $("liveTrades").innerHTML = h;
    $("liveNote").textContent = `${L.onPublicChain ? "BSC testnet" : "local fork"}; tokens ${Object.values(L.tokens).map((t) => short(t.token)).join(", ")}`;
  }
  const loop = async () => { try { await poll(); if (Date.now() - lastFeedAt > 3000) { lastFeedAt = Date.now(); await renderLog(); } } catch (e) { /* retry */ } setTimeout(loop, net.pollMs || 1500); };
  loop();
})();

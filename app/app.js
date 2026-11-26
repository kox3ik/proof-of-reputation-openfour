"use strict";
const { ethers } = window;
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const short = (a) => (a ? a.slice(0, 6) + "..." + a.slice(-4) : "-");

const REGISTRY_ABI = [
  "function scoreOf(address) view returns (uint256)",
  "function componentsOf(address) view returns (tuple(uint16 volume,uint16 activity,uint16 holding,uint16 identity,uint16 penalty))",
  "function effectiveIdentity(address) view returns (uint16)",
  "function isFlagged(address) view returns (bool)",
  "function isFresh(address) view returns (bool)",
  "function quoteFeeBps(address,bool) view returns (uint256)",
  "function quoteDetailed(address,bool) view returns (tuple(uint256 regularBps,uint256 depositBps,uint256 penaltyBps,uint256 treasuryBps,uint256 poolBps,address treasury,address pool))",
  "function config() view returns (tuple(uint16 wVolume,uint16 wActivity,uint16 wHolding,uint16 wIdentity,uint16 penaltyWeight,uint16 flagThreshold,uint16 neutralScore,uint16 zeroBps,uint16 neutralBps,uint16 minBps,uint16 sellCapBps,uint16 treasuryShareBps,address treasury,address rewardsPool,uint32 configDelay,address babToken,address agentIdToken,uint16 babIdentity,uint16 agentIdentity,uint16 freshDepositBps,uint16 penaltyBps))",
  "function currentEpoch() view returns (uint64)",
  "function coveredUntil() view returns (uint64)",
];
const POOL_ABI = [
  "function budgetPool(address) view returns (uint256)",
  "function depositPool(address) view returns (uint256)",
  "function unlocked(address asset,address token,address wallet) view returns (uint256 deposit,uint256 fee,uint256 bonus,uint64 ts)",
  "function claim(address asset,address token,address wallet) returns (uint256,uint256)",
  "function fund(address) view returns (uint256)",
  "function bonusLiability(address) view returns (uint256)",
  "event Claimed(address indexed asset,address indexed wallet,address indexed caller,uint256 deposit,uint256 cashback,uint256 bonus)",
];
const MINT_ABI = ["function mint(address to)"];

const state = { cfg: null, net: null, provider: null, run: null, looked: null, claimable: 0n, account: null, signer: null };

const bnb = (v, d = 6) => {
  const s = Number(ethers.formatEther(v));
  return s === 0 ? "0" : s < 1e-6 ? s.toExponential(2) : s.toFixed(d).replace(/0+$/, "").replace(/\.$/, "");
};
function tok(v) {
  const n = Number(ethers.formatUnits(v, 18));
  if (n >= 1e9) return (n / 1e9).toFixed(3) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(3) + "M";
  return n.toFixed(2);
}
async function tryCall(fn) {
  try { return { ok: true, v: await fn() }; } catch (e) { return { ok: false, err: e }; }
}
// buckets are per (asset, token, wallet): sum over the tokens this network lists (n.tokens, else n.token)
const tokensOf = (n) => (n.tokens && n.tokens.length ? n.tokens : n.token ? [n.token] : window.PORLiveTokens || []);
async function unlockedAll(asset, wallet) {
  const toks = tokensOf(state.net), sum = { deposit: 0n, fee: 0n, bonus: 0n, ts: 0n }, open = [];
  if (!toks.length) return { ok: false, err: new Error("no token listed for this network") };
  for (const t of toks) {
    const r = await tryCall(() => state.pool.unlocked(asset, t, wallet));
    if (!r.ok) return r;
    sum.deposit += r.v.deposit; sum.fee += r.v.fee; sum.bonus += r.v.bonus;
    if (r.v.ts > sum.ts) sum.ts = r.v.ts;
    if (r.v.deposit + r.v.fee + r.v.bonus > 0n) open.push(t);
  }
  state.claimToken = open[0] || null;
  return { ok: true, v: sum };
}
function contractAt(addr, abi) {
  return addr ? new ethers.Contract(addr, abi, state.provider) : null;
}

// ---------- network ----------
function setNet(key) {
  const n = state.cfg.networks[key];
  state.net = n;
  state.provider = new ethers.JsonRpcProvider(n.rpc, n.chainId, { staticNetwork: true, batchMaxCount: 1 });
  state.registry = contractAt(n.registry, REGISTRY_ABI);
  state.pool = contractAt(n.pool, POOL_ABI);
  $("chips").innerHTML = Object.entries(n.wallets).map(([r, a]) => `<button class="chip" data-a="${esc(a)}">${esc(r)}</button>`).join("") +
    (n.router ? `<button class="chip" data-a="${esc(n.router)}">terminal router</button>` : "");
  $("chips").querySelectorAll("button").forEach((b) => b.addEventListener("click", () => { $("addr").value = b.dataset.a; lookup(); }));
  $("snippet").textContent = snippet(n);
  $("mint").title = n.mockBabt ? "Mints the stand-in BABT (open mint) to the connected wallet" : "No mock BABT on this network";
  checkNet();
  renderTable();
  renderCashback();
  if ($("addr").value) lookup();
}
async function checkNet() {
  const el = $("netstat");
  el.className = "pill"; el.textContent = "connecting...";
  const r = await tryCall(() => state.provider.getBlockNumber());
  if (r.ok) { el.textContent = `connected, block ${r.v}`; }
  else { el.className = "pill bad"; el.textContent = state.net.key === "local" ? "local node not running" : "RPC unreachable"; }
}

// ---------- wallet lookup ----------
async function lookup() {
  const out = $("walletOut");
  const a = $("addr").value.trim();
  if (!ethers.isAddress(a)) { out.innerHTML = `<span class="note">Not a valid address.</span>`; return; }
  const n = state.net;
  if (!state.registry) { out.innerHTML = `<span class="note">Registry not deployed on this network yet.</span>`; return; }
  out.textContent = "reading chain...";
  const R = state.registry;
  const [score, comps, flagged, fresh, buy, sell, det, conf, ident] = await Promise.all([
    tryCall(() => R.scoreOf(a)), tryCall(() => R.componentsOf(a)), tryCall(() => R.isFlagged(a)), tryCall(() => R.isFresh(a)),
    tryCall(() => R.quoteFeeBps(a, true)), tryCall(() => R.quoteFeeBps(a, false)), tryCall(() => R.quoteDetailed(a, true)),
    tryCall(() => R.config()), tryCall(() => R.effectiveIdentity(a)),
  ]);
  state.looked = a;
  if (!score.ok && !buy.ok) { out.innerHTML = `<span class="note">Registry at ${esc(short(n.registry))} did not answer (${esc(state.net.label)}).</span>`; return; }
  const pills = [];
  if (flagged.ok) pills.push(flagged.v ? `<span class="pill bad">flagged (rug penalty)</span>` : `<span class="pill">not flagged</span>`);
  if (fresh.ok) pills.push(fresh.v ? `<span class="pill warn">fresh wallet (deposit applies)</span>` : `<span class="pill">has history</span>`);
  const stat = (v, l) => `<div class="stat"><b>${v}</b><span>${l}</span></div>`;
  const bps = (r) => (r.ok ? `${r.v} bps` : "n/a");
  let html = `<div class="row"><code>${esc(a)}</code> ${pills.join(" ")}</div><div class="grid">` +
    stat(score.ok ? unit(score.v) : "n/a", "reputation score (0..1)") + stat(bps(buy), "buy fee (extra, on top of OpenFour 50)") +
    stat(bps(sell), "sell fee (extra)") + stat(bps(sell), "pre-migration transfer fee = sell rate") + `</div>`;
  if (det.ok) {
    const q = det.v;
    html += `<p class="muted small">Buy fee breakdown: curve ${q.regularBps} bps, fresh deposit ${q.depositBps} bps (refundable), flag penalty ${q.penaltyBps} bps; treasury tier ${q.treasuryBps}, cashback pool tier ${q.poolBps}.</p>`;
  }
  html += componentBars(comps, conf, ident);
  out.innerHTML = html;
  await renderCashback();
}
// On chain scores and components are integers 0..1000; people see them as 0..1.
const unit = (x) => (Number(x) / 1000).toFixed(3);
function componentBars(comps, conf, ident) {
  if (!comps.ok) return `<p class="muted">Score components not available from this deployment.</p>`;
  const c = comps.v, w = conf.ok ? conf.v : null;
  const rows = [["volume", c.volume, w && w.wVolume], ["activity", c.activity, w && w.wActivity], ["holding", c.holding, w && w.wHolding], ["identity", c.identity, w && w.wIdentity]];
  const sumW = w ? Number(w.wVolume + w.wActivity + w.wHolding + w.wIdentity) : 0;
  let h = `<h3>Score components</h3><div class="bars">`;
  for (const [name, val, wt] of rows) {
    const v = name === "identity" && ident.ok ? Number(ident.v) : Number(val);
    const part = sumW ? ` -> +${unit((v * Number(wt)) / sumW)}` : "";
    h += bar(name, v, false, `${unit(v)}${part}`);
  }
  const pen = Number(c.penalty);
  const penPts = w ? ` -> -${unit((pen * Number(w.penaltyWeight)) / 1000)}` : "";
  h += bar("penalty", pen, true, `${unit(pen)}${penPts}`) + `</div>`;
  if (ident.ok && Number(ident.v) !== Number(c.identity)) h += `<p class="muted small">Identity is raised from stored ${unit(c.identity)} to ${unit(ident.v)} by an on-chain BABT / Agent ID balance.</p>`;
  if (w) h += `<p class="muted small">Weights volume/activity/holding/identity = ${w.wVolume}/${w.wActivity}/${w.wHolding}/${w.wIdentity}; score = weighted average - penalty x ${w.penaltyWeight}/1000; flagged at penalty >= ${unit(w.flagThreshold)}.</p>`;
  return h;
}
function bar(name, v, neg, label) {
  return `<div class="bar"><span>${esc(name)}</span><div class="track"><div class="fill ${neg ? "neg" : ""}" style="width:${Math.min(100, v / 10)}%"></div></div><span>${esc(label)}</span></div>`;
}

// ---------- run table ----------
async function loadRun() {
  const r = await tryCall(async () => (await fetch("run.json", { cache: "no-store" })).json());
  state.run = r.ok ? r.v : null;
  renderTable();
}
function renderTable() {
  const t = $("runTable"), note = $("runNote");
  if (!state.run) { t.innerHTML = ""; note.textContent = "run.json not found. Run make_config.py."; return; }
  const run = state.run, trades = run.trades || [];
  const link = state.cfg.runOnTestnet && state.cfg.networks.testnet.explorer;
  note.innerHTML = `Source: <code>${esc(state.cfg.runSource)}</code>, token <code>${esc(short(run.token || ""))}</code>. ` +
    (link ? "Hashes link to the testnet explorer." : "This is the local-fork run: hashes are not on the public testnet (the testnet run is regenerated later).") +
    ` Fee = PoR extra fee on top of OpenFour's own ${trades.find((x) => x.protocolBps)?.protocolBps ? Math.round(trades.find((x) => x.protocolBps).protocolBps) : 50} bps. "vs trusted" compares tokens received for the same budget.`;
  const ref = trades.find((x) => x.label && x.label.startsWith("same buy: trusted"));
  const refTok = ref && ref.event ? BigInt(ref.event.tokenAmount) : null;
  let h = `<tr><th>Wallet role</th><th>Wallet</th><th>Side</th><th class="num">In</th><th class="num">Received</th><th class="num">Fee paid</th><th class="num">Fee bps</th><th class="num">vs trusted</th><th>Tx</th></tr>`;
  for (const x of trades) {
    const e = x.event || {};
    let inn = "-", got = "-", fee = "-";
    if (x.side === "buy") { inn = x.budget ? bnb(x.budget) + " BNB" : "-"; got = e.tokenAmount ? tok(e.tokenAmount) + " tok" : "-"; fee = e.taxFee ? bnb(e.taxFee, 8) + " BNB" : "-"; }
    else if (x.side === "sell") { inn = tok(x.tokenAmount || e.tokenAmount || 0) + " tok"; got = e.traderQuote ? bnb(e.traderQuote) + " BNB" : "-"; fee = e.taxFee ? bnb(e.taxFee, 8) + " BNB" : "-"; }
    else if (x.side === "transfer") { inn = tok(x.amountSent || 0) + " tok"; got = tok(x.amountReceived || 0) + " tok"; fee = tok(x.feeToTreasury || 0) + " tok"; }
    const b = x.chargedExtraBps != null ? Math.round(x.chargedExtraBps) : x.expectedExtraBps;
    let vs = "";
    const isSame = x.side === "buy" && refTok && x.budget === ref.budget && !x.viaRouter && x.label.startsWith("same buy");
    if (isSame && e.tokenAmount) vs = (Number((BigInt(e.tokenAmount) * 10000n) / refTok) / 100).toFixed(1) + "%";
    const label = x.viaRouter ? `${x.role} via terminal router` : x.label && x.label.startsWith("setup") ? `${x.role} (setup)` : x.role;
    const txl = x.tx ? (link ? `<a href="${esc(state.cfg.networks.testnet.explorer)}/tx/${esc(x.tx)}" target="_blank" rel="noopener">${esc(short(x.tx))}</a>` : `<code>${esc(short(x.tx))}</code>`) : "-";
    h += `<tr title="${esc(x.label || "")}"><td>${esc(label)}</td><td><code>${esc(short(x.wallet))}</code></td><td>${esc(x.side)}</td><td class="num">${inn}</td><td class="num">${got}</td><td class="num">${fee}</td><td class="num">${b ?? "-"}</td><td class="num">${vs}</td><td>${txl}</td></tr>`;
  }
  t.innerHTML = h;
}

// ---------- cashback ----------
async function renderCashback() {
  const n = state.net, el = $("cbOut");
  const parts = [];
  const R = state.registry;
  if (R) {
    const [ep, cov] = await Promise.all([tryCall(() => R.currentEpoch()), tryCall(() => R.coveredUntil())]);
    if (ep.ok) parts.push(`<div class="stat"><b>${ep.v}</b><span>current epoch</span></div>`);
    if (cov.ok) parts.push(`<div class="stat"><b>${Number(cov.v) ? new Date(Number(cov.v) * 1000).toISOString().replace("T", " ").slice(0, 16) : "0"}</b><span>coveredUntil (UTC): claims open for sales up to here</span></div>`);
  }
  state.claimable = 0n;
  if (!state.pool) {
    el.innerHTML = `<div class="grid">${parts.join("")}</div><p class="note">CashbackPool / ReputationLedger: not deployed on this network yet.</p>`;
  } else {
    const asset = n.quoteAsset;
    const [bud, dep, fnd, liab] = await Promise.all([tryCall(() => state.pool.budgetPool(asset)), tryCall(() => state.pool.depositPool(asset)), tryCall(() => state.pool.fund(asset)), tryCall(() => state.pool.bonusLiability(asset))]);
    if (bud.ok) parts.push(`<div class="stat"><b>${bnb(bud.v, 8)}</b><span>cashback budget (WBNB)</span></div>`);
    if (dep.ok) parts.push(`<div class="stat"><b>${bnb(dep.v, 8)}</b><span>refundable deposits held (WBNB)</span></div>`);
    if (fnd.ok) parts.push(`<div class="stat"><b>${bnb(fnd.v, 8)}</b><span>scam fund (WBNB): pays honest bonuses</span></div>`);
    let who = "";
    if (state.looked) {
      const [u, flagged, covered, claimed] = await Promise.all([
        unlockedAll(asset, state.looked),
        tryCall(() => R.isFlagged(state.looked)), tryCall(() => R.coveredUntil()),
        tryCall(() => state.pool.queryFilter(state.pool.filters.Claimed(asset, state.looked), state.net.fromBlock ?? 0, "latest")),
      ]);
      if (u.ok) {
        const open = covered.ok && Number(covered.v) >= Number(u.v.ts) && !(flagged.ok && flagged.v);
        const cash = bud.ok && u.v.fee > bud.v ? bud.v : u.v.fee;
        const bonus = fnd.ok && liab.ok && liab.v > 0n ? (fnd.v >= liab.v ? u.v.bonus : (fnd.v * u.v.bonus) / liab.v) : 0n;
        state.claimable = open ? u.v.deposit + cash + bonus : 0n;
        who = `<h3>Wallet <code>${esc(short(state.looked))}</code></h3><div class="grid">` +
          `<div class="stat"><b>${bnb(state.claimable, 8)}</b><span>claimable now (deposit refund + cashback + bonus)</span></div>` +
          `<div class="stat"><b>${bnb(u.v.deposit, 8)} / ${bnb(u.v.fee, 8)}</b><span>unlocked deposit / unlocked fees (waiting)</span></div>` +
          (claimed.ok ? `<div class="stat"><b>${bnb(claimed.v.reduce((s, ev) => s + ev.args.cashback, 0n), 8)}</b><span>cashback paid so far (${claimed.v.length} claims)</span></div>` : "") + `</div>` +
          (!open && u.v.ts > 0n ? `<p class="muted small">Not claimable yet: ${flagged.ok && flagged.v ? "wallet is flagged (deposit forfeited)" : "waiting for the next published epoch to cover the sale"}.</p>` : "");
      }
    }
    el.innerHTML = `<div class="grid">${parts.join("")}</div>${who}`;
  }
  if (!state.pool) el.innerHTML += "";
  updateButtons();
}
function updateButtons() {
  const me = state.account;
  $("claim").disabled = !(me && state.pool && state.looked && state.claimToken && state.claimable > 0n); // anyone may claim for any wallet; funds go only to it
  $("mint").disabled = !(me && state.net.mockBabt);
}

// ---------- wallet (MetaMask) ----------
async function connect() {
  const m = $("walletMsg");
  if (!window.ethereum) { m.textContent = "No browser wallet found (install MetaMask)."; return; }
  try {
    const bp = new ethers.BrowserProvider(window.ethereum);
    await bp.send("eth_requestAccounts", []);
    try { await bp.send("wallet_switchEthereumChain", [{ chainId: ethers.toQuantity(state.net.chainId) }]); } catch (e) { m.textContent = `Switch the wallet to chain ${state.net.chainId} (${state.net.label}) manually.`; }
    state.signer = await new ethers.BrowserProvider(window.ethereum).getSigner();
    state.account = await state.signer.getAddress();
    m.textContent = `Connected ${short(state.account)}`;
    $("addr").value = state.account;
    await lookup();
  } catch (e) { m.textContent = "Connection refused: " + (e.shortMessage || e.message); }
  updateButtons();
}
async function sendTx(label, fn) {
  const m = $("walletMsg");
  try {
    m.textContent = `${label}: confirm in your wallet...`;
    const tx = await fn();
    m.textContent = `${label}: sent ${short(tx.hash)}, waiting...`;
    await tx.wait();
    m.textContent = `${label}: confirmed.`;
    await lookup();
  } catch (e) { m.textContent = `${label} failed: ` + (e.shortMessage || e.message); }
}
const claim = () => sendTx("Claim", () => new ethers.Contract(state.net.pool, POOL_ABI, state.signer).claim(state.net.quoteAsset, state.claimToken, state.looked));
const mint = () => sendTx("Get test BABT", () => new ethers.Contract(state.net.mockBabt, MINT_ABI, state.signer).mint(state.account));

function snippet(n) {
  return `// ethers v6, read-only. Registry: ${n.registry || "<registry address>"}
const reg = new ethers.Contract(REGISTRY, [
  "function scoreOf(address) view returns (uint256)",
  "function quoteFeeBps(address,bool) view returns (uint256)",
], provider);

const score  = await reg.scoreOf(trader);          // integer 0..1000 on chain; divide by 1000 for the 0..1 shown to people
const buyBps = await reg.quoteFeeBps(trader, true);  // extra fee bps for a buy
// price = OpenFour protocol fee (50 bps) + buyBps; sell: quoteFeeBps(trader, false)
// pre-migration transfer fee = quoteFeeBps(sender, false)`;
}

(async function init() {
  const r = await tryCall(async () => (await fetch("config.json", { cache: "no-store" })).json());
  if (!r.ok) { $("walletOut").innerHTML = `<span class="note">config.json missing. Run make_config.py.</span>`; return; }
  state.cfg = r.v;
  $("net").innerHTML = Object.entries(r.v.networks).map(([k, n]) => `<option value="${esc(k)}">${esc(n.label)}</option>`).join("");
  const q = new URLSearchParams(location.search);
  const k = q.get("net") && r.v.networks[q.get("net")] ? q.get("net") : r.v.default;
  $("net").value = k;
  $("net").addEventListener("change", () => setNet($("net").value));
  $("go").addEventListener("click", lookup);
  $("addr").addEventListener("keydown", (e) => { if (e.key === "Enter") lookup(); });
  $("connect").addEventListener("click", connect);
  $("claim").addEventListener("click", claim);
  $("mint").addEventListener("click", mint);
  await loadRun();
  setNet(k);
  if (q.get("addr")) { $("addr").value = q.get("addr"); lookup(); }
})();

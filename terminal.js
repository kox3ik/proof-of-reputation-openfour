"use strict";
/* Proof of Reputation terminal: charts drawn in SVG, ratings re-read live from the testnet registry (read-only eth_call). */
(function () {
  var CFG = { rpc: "https://bsc-testnet-rpc.publicnode.com", chainId: 97, registry: "0x7231682cdfed6d9d401efb8a2002b026bcbbc105", explorer: "https://testnet.bscscan.com" };
  var ABI = [
    "function scoreOf(address) view returns (uint256)", "function isFlagged(address) view returns (bool)", "function isFresh(address) view returns (bool)",
    "function quoteFeeBps(address,bool) view returns (uint256)",
    "function quoteDetailed(address,bool) view returns (tuple(uint256 regularBps,uint256 depositBps,uint256 penaltyBps,uint256 treasuryBps,uint256 poolBps,address treasury,address pool))"
  ];
  var COL = { honest: "#7fe07f", "new": "#f2c75c", bundle: "#ff9f5c", flagged: "#ff5d5d", other: "#a8a8a2" };
  var NAME = { honest: "honest", "new": "new wallet", bundle: "bundle", flagged: "flagged", other: "other" };
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); };
  var short = function (a) { return a.slice(0, 6) + "…" + a.slice(-4); };
  var S = { sets: [], set: null, tokens: [], tok: null, live: {}, liveOk: null };

  // pixel wallet icon, same as the landing page
  var MAP = ["....########....", "..##........##..", ".#..###.####..#.", ".#.#...#....#.#.", "################", "#..............#", "#..............#", "#..........###.#", "#.........#...#.", "#.........#.#.#.", "#..........##.#.", "#..............#", "#..............#", "################"];
  document.querySelectorAll("[data-pxwallet]").forEach(function (el) {
    var r = ""; MAP.forEach(function (row, y) { for (var x = 0; x < row.length; x++) if (row[x] === "#") r += '<rect x="' + x + '" y="' + y + '" width="1" height="1"/>'; });
    el.innerHTML = '<svg viewBox="0 0 16 14" shape-rendering="crispEdges" fill="#141414" aria-hidden="true">' + r + "</svg>";
  });

  // ---- number formats ----
  function fp(p) { // price per 1M tokens (BNB), up to 4 significant digits, no exponent
    p = p * 1e6;
    if (!isFinite(p) || p === 0) return "0";
    var e = Math.floor(Math.log10(Math.abs(p))), dec = Math.max(0, Math.min(12, 3 - e));
    return p.toFixed(dec).replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, "");
  }
  var fb = function (x) { return x >= 0.01 ? x.toFixed(4) : x.toFixed(5); };
  function ft(t) { var d = new Date(t * 1000); return d.toISOString().slice(11, 19); }
  function base(t) { return t.network === "bsc-testnet" ? CFG.explorer : "https://bscscan.com"; }
  function txUrl(t, x) { // tx page, or the wallet's transfers of this token when the hash is missing
    if (x.tx) return base(t) + "/tx/" + x.tx;
    if (x.wallet && t.address) return base(t) + "/token/" + t.address + "?a=" + x.wallet;
    return t.address ? base(t) + "/token/" + t.address : base(t);
  }
  var cls = function (r) { return COL[r] ? r : "other"; };

  // ---- load data ----
  function getJSON(u) { return fetch(u, { cache: "no-store" }).then(function (r) { if (!r.ok) throw new Error(u + " " + r.status); return r.json(); }); }
  function loadSet(set) {
    S.set = set;
    document.querySelectorAll("#sets button").forEach(function (b) { b.classList.toggle("on", b.dataset.id === set.id); });
    var isT = /testnet/.test(set.id);
    $("setnote").innerHTML = '<b>' + (isT ? "BSC testnet" : "Mainnet replay") + '</b>' + esc(set.note || (isT ? "BSC testnet" : "Mainnet replay: scores computed by our open rule, fees = what the module would charge"));
    return Promise.all(set.tokens.map(function (f) { return getJSON("data/terminal/" + f).catch(function () { return null; }); })).then(function (arr) {
      S.tokens = arr.filter(Boolean);
      S.tokens.forEach(function (t) { t.trades = t.trades.filter(function (x) { return x.t > 1e9 && x.price > 0; }); t.trades.sort(function (a, b) { return a.t - b.t; }); });
      $("tcount").textContent = S.tokens.length;
      renderTokens();
      selectToken(S.tokens[0] || null);
      if (isT) liveRefresh();
    });
  }
  function boot() {
    getJSON("data/terminal/index.json").then(function (idx) {
      S.sets = idx.sets || [];
      $("sets").innerHTML = S.sets.map(function (s) { return '<button type="button" data-id="' + esc(s.id) + '">' + esc(s.title) + "</button>"; }).join("");
      $("sets").addEventListener("click", function (e) { var b = e.target.closest("button"); if (!b) return; loadSet(S.sets.filter(function (s) { return s.id === b.dataset.id; })[0]); });
      if (S.sets.length) loadSet(S.sets[0]);
    }).catch(function (e) { $("setnote").textContent = "Could not load data: " + e.message; });
  }

  // ---- tokens list ----
  function renderTokens() {
    $("tlist").innerHTML = S.tokens.map(function (t, i) {
      var tr = t.trades, last = tr.length ? tr[tr.length - 1].price : 0, first = tr.length ? tr[0].price : 0;
      var ch = first ? (last / first - 1) * 100 : 0;
      var rug = (t.events || []).some(function (e) { return e.kind === "flag"; });
      return '<button class="titem" data-i="' + i + '"><span class="nm">' + esc(t.name) + '<small>' + esc(t.symbol) + "</small>" + (rug ? '<span class="badge">rug flagged</span>' : "") + '</span><span class="px">' + fp(last) + '</span><span class="sub">' + tr.length + ' trades</span><span class="ch ' + (ch >= 0 ? "up" : "dn") + '">' + (ch >= 0 ? "+" : "") + ch.toFixed(1) + " %</span></button>";
    }).join("");
    $("tlist").onclick = function (e) { var b = e.target.closest(".titem"); if (b) selectToken(S.tokens[+b.dataset.i]); };
  }
  function selectToken(t) {
    S.tok = t; S.showAll = false;
    document.querySelectorAll(".titem").forEach(function (b, i) { b.classList.toggle("on", S.tokens[i] === t); });
    if (!t) return;
    var tr = t.trades, last = tr.length ? tr[tr.length - 1].price : 0, vol = tr.reduce(function (a, x) { return a + x.bnb; }, 0), hi = 0, lo = Infinity;
    tr.forEach(function (x) { hi = Math.max(hi, x.price); lo = Math.min(lo, x.price); });
    $("ctitle").textContent = t.name + " / BNB (per 1M tokens)";
    $("cstats").innerHTML = [["Last", fp(last)], ["High", fp(hi)], ["Low", fp(lo === Infinity ? 0 : lo)], ["Volume", fb(vol) + " BNB"], ["Trades", tr.length]].map(function (x) { return "<div>" + x[0] + "<b>" + x[1] + "</b></div>"; }).join("");
    $("ctoken").innerHTML = (t.network === "bsc-testnet" ? "BSC testnet" : "Mainnet replay") + " &middot; token " + (t.address ? '<a href="' + base(t) + '/token/' + esc(t.address) + '" target="_blank" rel="noopener">' + esc(t.address) + "</a>" : "") + (t.note ? " &middot; " + esc(t.note) : "") + ' &middot; <a href="https://www.tradingview.com/" target="_blank" rel="noopener">Charts by TradingView Lightweight Charts</a>';
    $("legend").innerHTML = Object.keys(COL).filter(function (k) { return k !== "other" || tr.some(function (x) { return cls(x.role) === "other"; }); }).map(function (k) { return '<span><i style="background:' + COL[k] + '"></i>' + NAME[k] + "</span>"; }).join("") + '<span class="vleg">volume: <i style="background:' + VC.bad + '"></i>bundle <i style="background:' + VC["new"] + '"></i>new <i style="background:' + VC.ok + '"></i>honest</span><button type="button" class="more" id="tgl">' + (S.showTrades ? "Hide trades" : "Show trades") + "</button>";
    drawChart(); renderTraders(); renderTape();
  }

  // ---- chart: TradingView Lightweight Charts (candles from trades + volume + trade markers) ----
  var VC = { bad: "rgba(255,110,80,.8)", "new": "rgba(242,199,92,.75)", ok: "rgba(127,224,127,.5)" };
  var LW = null, T0 = 1700000000, STEP = 60;
  function buildBuckets(tr) {
    var n = tr.length, k = Math.max(1, Math.ceil(n / 100)), out = [];
    for (var i = 0; i < n; i += k) {
      var seg = tr.slice(i, i + k), pr = seg.map(function (x) { return x.price * 1e6; });
      var o = out.length ? out[out.length - 1].close : pr[0], c = pr[pr.length - 1];
      out.push({ time: T0 + out.length * STEP, open: o, high: Math.max.apply(null, pr.concat([o])), low: Math.min.apply(null, pr.concat([o])), close: c, first: i, last: i + seg.length - 1, vol: seg.reduce(function (a, x) { return a + x.bnb; }, 0), cv: seg.reduce(function (a, x) { var r = cls(x.role), g = (r === "bundle" || r === "flagged") ? "bad" : r === "new" ? "new" : "ok"; a[g] += x.bnb; return a; }, { bad: 0, "new": 0, ok: 0 }) });
    }
    return out;
  }
  function eventIndex(t, e) {
    var tr = t.trades, n = tr.length;
    if (e.tx) for (var q = 0; q < n; q++) if (tr[q].tx === e.tx) return q;
    var lo = 0, hi = n; while (lo < hi) { var mid = (lo + hi) >> 1; if (tr[mid].t < e.t) lo = mid + 1; else hi = mid; }
    return Math.min(lo, n - 1);
  }
  function drawChart() {
    var t = S.tok, el = $("lw"), tip = $("tip"), tr = t.trades;
    if (LW) { LW.remove(); LW = null; }
    el.innerHTML = ""; tip.hidden = true;
    if (!tr.length) { el.innerHTML = '<p class="muted" style="padding:20px">no trades</p>'; return; }
    if (!window.LightweightCharts) { el.innerHTML = '<p class="muted" style="padding:20px">chart library failed to load</p>'; return; }
    var B = buildBuckets(tr), idxBucket = []; B.forEach(function (b, bi) { for (var i = b.first; i <= b.last; i++) idxBucket[i] = bi; });
    var longSpan = tr[tr.length - 1].t - tr[0].t > 10800;
    var lab = function (time) { var b = B[Math.max(0, Math.min(B.length - 1, Math.round((time - T0) / STEP)))]; var tv = tr[b.first].t; return longSpan ? new Date(tv * 1000).toISOString().slice(5, 16).replace("T", " ") : ft(tv); };
    var fmt = function (v) { return fp(v / 1e6); };
    LW = LightweightCharts.createChart(el, {
      autoSize: true,
      layout: { background: { type: "solid", color: "#1c1c1b" }, textColor: "#a8a8a2", fontFamily: "JetBrains Mono, monospace", fontSize: 11 },
      grid: { vertLines: { color: "#2a2a29" }, horzLines: { color: "#2a2a29" } },
      rightPriceScale: { borderColor: "#444443", scaleMargins: { top: 0, bottom: 0 } },
      timeScale: { borderColor: "#444443", rightOffset: 6, tickMarkFormatter: lab, timeVisible: true, secondsVisible: false },
      localization: { timeFormatter: lab, priceFormatter: fmt },
      crosshair: { mode: 0 }
    });
    var cs = LW.addCandlestickSeries({ upColor: "#7fe07f", downColor: "#ff7a5c", borderUpColor: "#7fe07f", borderDownColor: "#ff7a5c", wickUpColor: "#7fe07f", wickDownColor: "#ff7a5c", priceFormat: { type: "custom", formatter: fmt, minMove: 1e-9 },
      autoscaleInfoProvider: function () { // fixed range: never below 0, leaves the bottom fifth to the volume bars
        var lo = Math.min.apply(null, B.map(function (b) { return b.low; })), hi = Math.max.apply(null, B.map(function (b) { return b.high; })), r = (hi - lo) || hi * 0.2 || 1;
        return { priceRange: { minValue: Math.max(0, lo - r * 0.38), maxValue: hi + r * 0.2 } };
      } });
    cs.setData(B.map(function (b) { return { time: b.time, open: b.open, high: b.high, low: b.low, close: b.close }; }));
    var vs = LW.addHistogramSeries({ priceScaleId: "vol", priceFormat: { type: "custom", formatter: function (v) { return fb(v) + " BNB"; }, minMove: 1e-9 }, lastValueVisible: false, priceLineVisible: false });
    LW.priceScale("vol").applyOptions({ scaleMargins: { top: 0.8, bottom: 0 } });
    vs.setData(B.map(function (b) { return { time: b.time, value: b.vol, color: VC[b.cv.bad >= b.cv["new"] && b.cv.bad >= b.cv.ok && b.cv.bad > 0 ? "bad" : b.cv["new"] >= b.cv.ok && b.cv["new"] > 0 ? "new" : "ok"] }; }));
    var firstBuy = {}, mk = [];
    if (S.showTrades) tr.forEach(function (x, i) {
      var w = x.wallet.toLowerCase(), r = cls(x.role), show = r === "bundle" || r === "flagged" || (r === "new" && x.side === "buy" && !firstBuy[w]);
      if (x.side === "buy") firstBuy[w] = 1;
      mk.push({ time: B[idxBucket[i]].time, position: x.side === "buy" ? "belowBar" : "aboveBar", shape: x.side === "buy" ? "arrowUp" : "arrowDown", color: COL[r], size: 1 });
    });
    var firstDump = -1; tr.forEach(function (x, i) { if (firstDump < 0 && x.side === "sell" && (x.role === "bundle" || x.role === "flagged")) firstDump = i; });
    var late = function (tm) { return (tm - T0) / STEP > B.length * 0.9; };
    var seen = {};
    (t.events || []).forEach(function (e) {
      var tm = B[idxBucket[eventIndex(t, e)]].time;
      if (e.kind === "dump" && !seen.dump) { seen.dump = 1; mk.push({ time: tm, position: late(tm) ? "belowBar" : "aboveBar", shape: "square", color: "#ff9f5c", text: "DUMP", size: 1 }); }
      else if (e.kind === "flag" && !seen.flag) { seen.flag = 1; mk.push({ time: tm, position: late(tm) ? "belowBar" : "aboveBar", shape: "circle", color: "#ff5d5d", text: "FLAGGED", size: 1 }); }
      else if (e.kind === "claim") mk.push({ time: tm, position: "belowBar", shape: "circle", color: "#4cc9b0", size: 1 });
    });
    if (!seen.dump) { // no dump event in the data: take the candle with the largest bundle sell volume
      var best = -1, bv = 0;
      B.forEach(function (bk, bi) { var v = 0; for (var i = bk.first; i <= bk.last; i++) if (tr[i].side === "sell" && (tr[i].role === "bundle" || tr[i].role === "flagged")) v += tr[i].bnb; if (v > bv) { bv = v; best = bi; } });
      if (best >= 0) mk.push({ time: B[best].time, position: late(B[best].time) ? "belowBar" : "aboveBar", shape: "square", color: "#ff9f5c", text: "DUMP", size: 1 });
    }
    mk.sort(function (a, b) { return a.time - b.time; });
    cs.setMarkers(mk);
    LW.timeScale().fitContent();
    function nearest(param) {
      if (!param || param.time === undefined || !param.point) return null;
      var b = B[Math.round((param.time - T0) / STEP)]; if (!b) return null;
      var best = b.first, bd = 1e18;
      for (var i = b.first; i <= b.last; i++) { var y = cs.priceToCoordinate(tr[i].price * 1e6); var d = y === null ? 1e9 : Math.abs(y - param.point.y); if (d < bd) { bd = d; best = i; } }
      return best;
    }
    LW.subscribeCrosshairMove(function (param) {
      var i = nearest(param); el.style.cursor = i === null ? "default" : "pointer";
      if (i === null) { tip.hidden = true; return; }
      var x = tr[i], f = x.feeBps || {};
      tip.hidden = false;
      tip.innerHTML = '<b>' + (x.side === "buy" ? "BUY" : "SELL") + "</b> &middot; " + NAME[cls(x.role)] + "<br>" + short(x.wallet) + "<br>" + fb(x.bnb) + " BNB @ " + fp(x.price) + " /1M<br>fee " + f.total + " bps (reg " + f.regular + " + dep " + f.deposit + " + pen " + f.penalty + ")<br>" + ft(x.t) + " UTC";
      tip.style.left = Math.min(param.point.x + 16, el.clientWidth - 215) + "px"; tip.style.top = Math.max(4, param.point.y - 80) + "px";
    });
    LW.subscribeClick(function (param) { var i = nearest(param); if (i !== null) window.open(txUrl(t, tr[i]), "_blank", "noopener"); });
  }


  // ---- traders table ----
  function traderRows() {
    var t = S.tok, rows = [];
    Object.keys(t.wallets || {}).forEach(function (a) {
      var w = Object.assign({}, t.wallets[a]), L = S.live[a.toLowerCase()];
      if (L) { w = Object.assign(w, L, { live: true }); }
      w.addr = a; rows.push(w);
    });
    rows.sort(function (a, b) { return b.score - a.score; });
    return rows;
  }
  function status(w) { return w.flagged ? "flagged" : (w.fresh || w.depositBps > 0) ? "fresh" : w.buyBps < 50 ? "trusted" : "regular"; }
  function renderTraders() {
    var rows = traderRows(), t = S.tok, total = rows.length, CAP = 40;
    if (!S.showAll && total > CAP) {
      var fl = rows.filter(function (w) { return w.flagged; }).slice(0, 15), keep = {};
      fl.forEach(function (w) { keep[w.addr] = 1; });
      rows.filter(function (w) { return !keep[w.addr]; }).slice(0, CAP - fl.length).forEach(function (w) { keep[w.addr] = 1; });
      rows = rows.filter(function (w) { return keep[w.addr]; });
    }
    var roleOf = {}; t.trades.forEach(function (x) { roleOf[x.wallet.toLowerCase()] = x.role; });
    document.querySelector("#ttab tbody").innerHTML = rows.map(function (w) {
      var st = status(w), exp = (t.network === "bsc-testnet" ? CFG.explorer : "https://bscscan.com") + "/address/" + w.addr;
      return '<tr><td><span class="dot" style="background:' + COL[cls(roleOf[w.addr.toLowerCase()])] + '"></span><a href="' + esc(exp) + '" target="_blank" rel="noopener" title="' + esc(w.addr) + '">' + short(w.addr) + "</a>" + (w.label ? ' <span class="muted">' + esc(w.label) + "</span>" : "") + "</td>" +
        '<td><span class="sbar' + (w.flagged ? " bad" : "") + '"><i style="width:' + Math.round(w.score * 100) + '%"></i></span>' + Number(w.score).toFixed(3) + "</td>" +
        '<td class="r">' + w.buyBps + '</td><td class="r">' + w.sellBps + '</td><td class="r">' + w.depositBps + '</td><td><span class="chip ' + st + '">' + st + "</span>" + (w.live ? ' <span class="up" title="read live from the registry">&#9679;</span>' : "") + "</td></tr>";
    }).join("") || '<tr><td colspan="6" class="muted">no traders</td></tr>';
    if (rows.length < total) document.querySelector("#ttab tbody").insertAdjacentHTML("beforeend", '<tr><td colspan="6"><button type="button" class="more" id="showall">Show all ' + total + ' traders (showing flagged + top by score)</button></td></tr>');
    var ls = $("livestate");
    if (/testnet/.test(S.set.id)) { ls.className = "livestate " + (S.liveOk ? "on" : "off"); ls.textContent = S.liveOk === null ? "reading registry…" : S.liveOk ? "● live from registry" : "stored values (RPC unavailable)"; }
    else { ls.className = "livestate"; ls.textContent = "replay values"; }
  }

  // ---- tape ----
  function renderTape() {
    var t = S.tok, tx = t.network === "bsc-testnet" ? CFG.explorer : "https://bscscan.com";
    document.querySelector("#tape tbody").innerHTML = t.trades.slice().reverse().map(function (x) {
      var f = x.feeBps || {}, c = cls(x.role);
      return '<tr class="rowlink" data-href="' + esc(txUrl(t, x)) + '"><td>' + ft(x.t) + '</td><td class="' + (x.side === "buy" ? "up" : "dn") + '">' + x.side.toUpperCase() + "</td><td>" + short(x.wallet) + "</td><td class=\"r\">" + fb(x.bnb) + '</td><td class="r"><b>' + f.total + '</b></td><td class="split">' + f.regular + " + " + f.deposit + " + " + f.penalty + '</td><td><span class="dot" style="background:' + COL[c] + '"></span>' + NAME[c] + '</td><td><a href="' + esc(txUrl(t, x)) + '" target="_blank" rel="noopener">' + (x.tx ? esc(x.tx.slice(0, 10)) + "\u2026" : "transfers") + "</a></td></tr>";
    }).join("");
  }

  $("legend").addEventListener("click", function (e) { if (e.target.id === "tgl") { S.showTrades = !S.showTrades; e.target.textContent = S.showTrades ? "Hide trades" : "Show trades"; drawChart(); } });
  $("ttab").addEventListener("click", function (e) { if (e.target.id === "showall") { S.showAll = true; renderTraders(); } });
  $("tape").addEventListener("click", function (e) { if (e.target.closest("a")) return; var r = e.target.closest("tr.rowlink"); if (r) window.open(r.dataset.href, "_blank", "noopener"); });

  // ---- live registry reads ----
  var reg = null;
  function registry() {
    if (reg) return reg;
    if (!window.ethers) return null;
    var p = new ethers.JsonRpcProvider(CFG.rpc, CFG.chainId, { staticNetwork: true });
    reg = new ethers.Contract(CFG.registry, ABI, p); return reg;
  }
  function read(a) {
    var R = registry(); if (!R) return Promise.reject(new Error("ethers not loaded"));
    return Promise.all([R.scoreOf(a), R.isFlagged(a), R.isFresh(a), R.quoteFeeBps(a, true), R.quoteFeeBps(a, false), R.quoteDetailed(a, true)]).then(function (v) {
      return { score: Number(v[0]) / 1000, flagged: v[1], fresh: v[2], buyBps: Number(v[3]), sellBps: Number(v[4]), depositBps: Number(v[5].depositBps), penaltyBps: Number(v[5].penaltyBps) };
    });
  }
  function liveRefresh() {
    S.liveOk = null; var set = S.set;
    var addrs = {}; S.tokens.forEach(function (t) { Object.keys(t.wallets || {}).forEach(function (a) { addrs[a.toLowerCase()] = 1; }); });
    var list = Object.keys(addrs), ok = 0;
    if (S.tok) renderTraders();
    Promise.all(list.map(function (a) { return read(a).then(function (r) { S.live[a] = r; ok++; }).catch(function () { }); })).then(function () {
      if (S.set !== set) return;
      S.liveOk = ok > 0; if (S.tok) renderTraders();
    });
  }

  // ---- "Your fee" box ----
  $("yform").addEventListener("submit", function (e) {
    e.preventDefault(); var a = $("yaddr").value.trim(), o = $("yout");
    o.hidden = false;
    if (!window.ethers || !ethers.isAddress(a)) { o.textContent = "Enter a valid 0x address."; return; }
    o.textContent = "Reading BSC testnet registry…";
    read(a).then(function (r) {
      var pc = function (b) { return (b / 100).toFixed(2) + " %"; };
      o.innerHTML = '<span><b>' + r.score.toFixed(3) + "</b>score 0&ndash;1</span><span><b>" + r.buyBps + "</b>buy bps (" + pc(r.buyBps) + ")</span><span><b>" + r.sellBps + "</b>sell bps (" + pc(r.sellBps) + ")</span><span><b>" + r.depositBps + "</b>deposit bps, refundable</span><span class=\"chip " + (r.flagged ? "flagged" : (r.fresh || r.depositBps > 0) ? "fresh" : r.buyBps < 50 ? "trusted" : "regular") + '">' + (r.flagged ? "flagged" : (r.fresh || r.depositBps > 0) ? "fresh" : r.buyBps < 50 ? "trusted" : "regular") + '</span><span class="muted">BSC testnet registry, eth_call</span>';
    }).catch(function (err) { o.textContent = "Could not read the testnet RPC (" + (err && (err.shortMessage || err.message) || err) + ")."; });
  });
  boot();
})();

"use strict";
/* Proof of Reputation site: pixel art + live testnet lookup (read-only eth_call, no wallet, no tracking). */
(function () {
  // ---- pixel wallet icon (16 x 14 grid), dark pixels on gradient tile ----
  var MAP = [
    "....########....",
    "..##........##..",
    ".#..###.####..#.",
    ".#.#...#....#.#.",
    "################",
    "#..............#",
    "#..............#",
    "#..........###.#",
    "#.........#...#.",
    "#.........#.#.#.",
    "#..........##.#.",
    "#..............#",
    "#..............#",
    "################"
  ];
  function pixelWallet(color) {
    var r = "";
    MAP.forEach(function (row, y) {
      for (var x = 0; x < row.length; x++) if (row[x] === "#") r += '<rect x="' + x + '" y="' + y + '" width="1" height="1"/>';
    });
    return '<svg viewBox="0 0 16 14" shape-rendering="crispEdges" fill="' + (color || "#141414") + '" aria-hidden="true" focusable="false">' + r + "</svg>";
  }
  document.querySelectorAll("[data-pxwallet]").forEach(function (el) { el.innerHTML = pixelWallet(el.getAttribute("data-pxwallet") || undefined); });

  // ---- pixel histogram (decorative) ----
  var H = [1, 1, 2, 3, 4, 5, 7, 9, 8, 6, 4, 3, 2, 1];
  var hist = document.getElementById("hist");
  if (hist) {
    var cells = "";
    H.forEach(function (h, i) {
      var t = i / (H.length - 1);
      // lime -> green -> teal
      var c = t < .5 ? mix([215, 242, 92], [127, 224, 127], t * 2) : mix([127, 224, 127], [76, 201, 176], (t - .5) * 2);
      cells += '<div style="--bc:rgb(' + c.join(",") + ');height:' + h * 10 + '%"></div>';
    });
    hist.innerHTML = cells;
  }
  function mix(a, b, t) { return a.map(function (v, i) { return Math.round(v + (b[i] - v) * t); }); }

  // ---- live lookup ----
  var CFG = {
    rpc: "https://bsc-testnet-rpc.publicnode.com",
    chainId: 97,
    registry: "0x7231682cdfed6d9d401efb8a2002b026bcbbc105",
    explorer: "https://testnet.bscscan.com"
  };
  var ABI = [
    "function scoreOf(address) view returns (uint256)",
    "function isFlagged(address) view returns (bool)",
    "function isFresh(address) view returns (bool)",
    "function quoteFeeBps(address,bool) view returns (uint256)",
    "function quoteDetailed(address,bool) view returns (tuple(uint256 regularBps,uint256 depositBps,uint256 penaltyBps,uint256 treasuryBps,uint256 poolBps,address treasury,address pool))"
  ];
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); };
  var reg = null, provider = null;
  function registry() {
    if (reg) return reg;
    if (!window.ethers) return null;
    provider = new ethers.JsonRpcProvider(CFG.rpc, CFG.chainId, { staticNetwork: true, batchMaxCount: 1 });
    reg = new ethers.Contract(CFG.registry, ABI, provider);
    return reg;
  }
  var unit = function (x) { return (Number(x) / 1000).toFixed(3); }; // chain stores 0..1000, people see 0..1
  var pct = function (bps) { return (Number(bps) / 100).toFixed(2) + " %"; };
  function read(a) {
    var R = registry();
    if (!R) return Promise.reject(new Error("ethers not loaded"));
    return Promise.all([R.scoreOf(a), R.isFlagged(a), R.isFresh(a), R.quoteFeeBps(a, true), R.quoteFeeBps(a, false), R.quoteDetailed(a, true)])
      .then(function (v) { return { score: unit(v[0]), flagged: v[1], fresh: v[2], buy: v[3], sell: v[4], det: v[5] }; });
  }
  var out = document.getElementById("walletOut"), addr = document.getElementById("addr");
  function show(a) {
    if (!out) return;
    if (!window.ethers || !ethers.isAddress(a)) { out.innerHTML = '<p class="muted">Enter a valid 0x address.</p>'; return; }
    out.innerHTML = '<p class="muted">Reading BSC testnet...</p>';
    read(a).then(function (r) {
      var pills = [r.flagged ? '<span class="pl bad">flagged: rug penalty applies</span>' : '<span class="pl ok">not flagged</span>',
        r.fresh ? '<span class="pl warn">new wallet: refundable deposit applies</span>' : '<span class="pl ok">has history</span>'];
      var dep = Number(r.det.depositBps);
      out.innerHTML = '<div class="pills">' + pills.join("") + '</div>' +
        '<div class="res">' +
        '<div><b>' + r.score + '</b><span>Score 0 to 1</span></div>' +
        '<div><b>' + pct(r.buy) + '</b><span>Buy fee (' + r.buy + ' bps)</span></div>' +
        '<div><b>' + pct(r.sell) + '</b><span>Sell fee (' + r.sell + ' bps)</span></div>' +
        '<div><b>' + pct(dep) + '</b><span>Deposit on buy (' + dep + ' bps, refundable)</span></div></div>' +
        '<p class="small muted">Read from the registry <a href="' + CFG.explorer + '/address/' + CFG.registry + '">' + CFG.registry.slice(0, 8) + '...' + CFG.registry.slice(-4) + '</a> with eth_call. Penalty part of the buy fee: ' + Number(r.det.penaltyBps) + ' bps.</p>';
    }).catch(function (e) {
      out.innerHTML = '<p class="muted">Could not read the testnet RPC (' + esc(e && e.shortMessage || e && e.message || e) + '). Try again in a moment.</p>';
    });
  }
  document.querySelectorAll(".chip").forEach(function (b) {
    b.addEventListener("click", function () { addr.value = b.dataset.a; show(b.dataset.a); });
  });
  var form = document.getElementById("lkform");
  if (form) form.addEventListener("submit", function (e) { e.preventDefault(); show(addr.value.trim()); });

  // ---- cards: replace the snapshot with live values when the RPC answers ----
  document.querySelectorAll(".wcard[data-live]").forEach(function (card) {
    read(card.dataset.live).then(function (r) {
      card.querySelector(".sc").innerHTML = r.score + " <small>/ 1</small>";
      card.querySelector(".pill").textContent = (r.flagged ? "flagged, " : "") + "buy " + pct(r.buy) + " / sell " + pct(r.sell);
      card.classList.toggle("bad", !!r.flagged);
      card.setAttribute("data-source", "live");
    }).catch(function () { /* keep the static snapshot */ });
  });
})();

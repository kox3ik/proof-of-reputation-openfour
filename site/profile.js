"use strict";
(function () {
  var P = POR, $ = function (id) { return document.getElementById(id); }, NEUTRAL = 400, NAMES = ["Volume", "Activity", "Holding", "Identity", "Penalty"], WT = ["30", "25", "25", "20", "−"];
  var lb = null;
  var EX = [
    { l: "low-score newcomer", a: "0x1a6024151faf44ba7a51caa8792f97ac43e32b8b" },
    { l: "median wallet", a: "0xc366f55d3ea6e6da886343b374582a35801dcb7a" },
    { l: "top wallet", a: "0x896d37ee4a1022d722304d2fd2f9594b26d16c8c" },
    { l: "flagged (rug history)", a: "0x6b042bc47cb517315480e1d85834185d802224b3" }
  ];
  EX.forEach(function (e) { var b = document.createElement("button"); b.className = "btn"; b.type = "button"; b.textContent = e.l; b.onclick = function () { $("w").value = e.a; show(e.a); }; $("ex").appendChild(b); });
  function stored(a) {
    return (lb ? Promise.resolve(lb) : fetch("data/leaderboard.json").then(function (r) { return r.json(); }).then(function (d) { lb = d; return d; }).catch(function () { lb = { rows: [] }; return lb; }))
      .then(function (d) { var r = d.rows.find(function (x) { return x.a === a; }); return r ? { c: r.c, flagged: r.f } : null; });
  }
  function show(a) {
    a = a.trim().toLowerCase();
    if (!/^0x[0-9a-f]{40}$/.test(a)) { alert("Enter a valid 0x wallet address."); return; }
    history.replaceState(null, "", "?w=" + a);
    P.liveRead(a).then(function (v) { v.src = "live testnet registry"; return v; }).catch(function () { return stored(a).then(function (v) { if (v) v.src = "stored snapshot of the registry (RPC unavailable)"; return v; }); })
      .then(function (v) { if (!v) { v = { c: [0, 0, 0, 0, 0], flagged: false, src: "unknown wallet: not in the registry" }; } render(a, v); });
  }
  function render(a, v) {
    var c = v.c, s = P.score(c); if (v.flagged) s = 0;
    var b = P.quote(s, c[4], true), sl = P.quote(s, c[4], false), gap = Math.max(0, NEUTRAL - s);
    $("out").hidden = false;
    $("head").innerHTML = "Score " + s + " points <span style=\"color:var(--muted)\">· " + (s / 1000).toFixed(3) + " of 1</span> <span class=\"chip " + (P.status(s, v.flagged, c[4]) === "trusted" ? "trusted" : P.status(s, v.flagged, c[4]) === "regular" ? "regular" : P.status(s, v.flagged, c[4]) === "flagged" ? "flagged" : "fresh") + "\">" + P.status(s, v.flagged, c[4]) + "</span>";
    $("addr").innerHTML = '<a href="https://testnet.bscscan.com/address/' + a + '" target="_blank" rel="noopener">' + a + "</a>";
    $("bar").firstElementChild.style.width = Math.min(100, s / 10) + "%"; $("bar").lastElementChild.style.left = "40%";
    $("msg").innerHTML = v.flagged ? "This wallet is <b>flagged</b> for rug participation: score 0, penalty applies, deposit is not refunded while flagged."
      : gap > 0 ? "You are <b>" + gap + " points</b> away from the newcomer threshold. Your buy deposit now: <b>" + P.pct(b.deposit) + "</b> (refundable). At 400 points it is <b>0</b>."
        : "You are <b>" + (s - NEUTRAL) + " points above</b> the newcomer threshold. Your buy deposit is <b>0</b>; the regular fee is " + P.pct(b.regular) + " and keeps falling to 0 at 1000 points.";
    var h = ""; c.forEach(function (x, i) {
      h += '<div style="display:grid;grid-template-columns:110px 1fr 70px 70px;gap:10px;align-items:center;margin:6px 0" class="mono"><span>' + NAMES[i] + '</span><div class="bar" style="margin:0;height:12px"><i style="width:' + x / 10 + "%" + (i === 4 ? ";background:var(--bad)" : "") + '"></i></div><span class="r">' + x + "</span><span style=\"color:var(--muted)\">weight " + WT[i] + "</span></div>";
    });
    $("comps").innerHTML = h; $("src").textContent = "source: " + v.src;
    $("fees").innerHTML = [["Buy fee", b.total + " bps (" + P.pct(b.total) + ")"], ["Sell fee", sl.total + " bps (" + P.pct(sl.total) + ")"], ["Regular", b.regular + " bps"], ["Deposit (refundable)", b.deposit + " bps (" + P.pct(b.deposit) + ")"], ["Penalty", b.penalty + " bps"]]
      .map(function (x) { return "<div>" + x[0] + "<b>" + x[1] + "</b></div>"; }).join("");
    $("livefees").textContent = v.buy !== undefined ? "Live testnet registry quotes today: buy " + v.buy + " bps, sell " + v.sell + " bps (the deployed registry predates the current deposit formula; values above are the current contracts)." : "";
  }
  $("f").addEventListener("submit", function (e) { e.preventDefault(); show($("w").value); });
  var q = /[?&]w=(0x[0-9a-fA-F]{40})/.exec(location.search); if (q) { $("w").value = q[1]; show(q[1]); }
})();

"use strict";
(function () {
  var P = POR, $ = function (id) { return document.getElementById(id); }, EXP = "https://testnet.bscscan.com";
  var rows = [], liveMap = {};
  function fmt(r) { return r.a.slice(0, 6) + "…" + r.a.slice(-4); }
  function render(list, shown) {
    var h = "";
    list.forEach(function (r, i) {
      var b = P.quote(r.s, r.c[4], true), s = P.quote(r.s, r.c[4], false), st = P.status(r.s, r.f, r.c[4]), lv = liveMap[r.a];
      var cls = st === "trusted" ? "trusted" : st === "regular" ? "regular" : st === "flagged" ? "flagged" : "fresh";
      h += "<tr><td>" + (r.rank) + '</td><td><a href="' + EXP + "/address/" + r.a + '" target="_blank" rel="noopener" title="' + r.a + '">' + fmt(r) + '</a> <a href="profile.html?w=' + r.a + '" title="profile">&rarr;</a></td>' +
        '<td class="r">' + r.s + "</td><td>" + (r.s / 1000).toFixed(3) + '</td><td class="r">' + b.total + '</td><td class="r">' + P.pct(b.total) + '</td><td class="r">' + s.total + '</td><td class="r">' + P.pct(s.total) + '</td><td class="r">' + b.deposit +
        '</td><td><span class="chip ' + cls + '">' + st + "</span></td><td class=\"r\">" + (lv ? lv.buy + " / " + lv.sell + ' <span class="up" title="read live from the testnet registry">&#9679;</span>' : "&mdash;") + "</td></tr>";
    });
    document.querySelector("#t tbody").innerHTML = h || '<tr><td colspan="11">No match.</td></tr>';
    $("cnt").textContent = shown;
  }
  function go() {
    var q = $("q").value.trim().toLowerCase();
    if (!q) { render(rows.slice(0, 100), "top 100 of " + rows.length); return; }
    var m = rows.filter(function (r) { return r.a.indexOf(q) >= 0; });
    render(m.slice(0, 100), m.length + " match" + (m.length === 1 ? "" : "es") + (m.length > 100 ? " (first 100)" : ""));
  }
  fetch("data/leaderboard.json").then(function (r) { return r.json(); }).then(function (d) {
    rows = d.rows.map(function (r, i) { r.rank = i + 1; return r; });
    $("q").addEventListener("input", go); go(); live();
  }).catch(function (e) { $("cnt").textContent = "data load failed: " + e.message; });
  function live() {
    var ls = $("live"); ls.className = "livestate off"; ls.textContent = "reading registry…"; var ok = 0;
    Promise.all(rows.slice(0, 100).map(function (r) { return P.liveRead(r.a).then(function (v) { liveMap[r.a] = v; ok++; }).catch(function () { }); })).then(function () {
      ls.className = "livestate " + (ok ? "on" : "off"); ls.textContent = ok ? "● live testnet registry: " + ok + "/100 rows" : "stored values (RPC unavailable)"; go();
    });
  }
})();

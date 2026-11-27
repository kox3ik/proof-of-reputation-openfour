"use strict";
/* Shared helpers for leaderboard/profile: config is read from terminal.js (single source), fee formula = current contracts. */
window.POR = (function () {
  var FALLBACK = { rpc: "https://bsc-testnet-rpc.publicnode.com", chainId: 97, registry: "0x7231682cdfed6d9d401efb8a2002b026bcbbc105", explorer: "https://testnet.bscscan.com" };
  var ABI = ["function scoreOf(address) view returns (uint256)", "function isFlagged(address) view returns (bool)", "function quoteFeeBps(address,bool) view returns (uint256)",
    "function componentsOf(address) view returns (tuple(uint16 volume,uint16 activity,uint16 holding,uint16 identity,uint16 penalty))"];
  function config() {
    return fetch("terminal.js").then(function (r) { return r.text(); }).then(function (t) {
      var m = /var CFG = (\{[^}]*\})/.exec(t); if (!m) return FALLBACK;
      return (new Function("return " + m[1]))();
    }).catch(function () { return FALLBACK; });
  }
  var regP = null;
  function registry() {
    if (!regP) regP = config().then(function (c) {
      if (!window.ethers) throw new Error("ethers not loaded");
      var p = new ethers.JsonRpcProvider(c.rpc, c.chainId, { staticNetwork: true });
      return { cfg: c, R: new ethers.Contract(c.registry, ABI, p) };
    });
    return regP;
  }
  function liveRead(a) {
    return registry().then(function (x) {
      return Promise.all([x.R.componentsOf(a), x.R.isFlagged(a), x.R.quoteFeeBps(a, true), x.R.quoteFeeBps(a, false)]).then(function (v) {
        var c = [Number(v[0][0]), Number(v[0][1]), Number(v[0][2]), Number(v[0][3]), Number(v[0][4])];
        return { c: c, flagged: v[1], buy: Number(v[2]), sell: Number(v[3]) };
      });
    });
  }
  // ---- fee formula of the current contracts (ports build_mainnet_replay.py) ----
  var W = [30, 25, 25, 20];
  function score(c) { var pos = Math.floor((c[0] * 30 + c[1] * 25 + c[2] * 25 + c[3] * 20) / 100), pen = c[4]; return pos > pen ? pos - pen : 0; }
  function regular(s) { s = Math.min(s, 1000); return s <= 400 ? 50 : Math.floor(50 - Math.floor(50 * (s - 400) / 600)) ; }
  function quote(s, p, buy) {
    var reg = regular(s); if (!buy && p === 0 && reg > 100) reg = 100; reg = Math.min(reg, 950);
    var room = 950 - reg, pen = Math.min(Math.floor(640 * p / 1000), room), dep = Math.min(buy && s < 400 ? Math.floor(640 * (400 - s) / 400) : 0, room - pen);
    return { regular: reg, deposit: dep, penalty: pen, total: reg + dep + pen };
  }
  function status(s, flagged, p) { return flagged ? "flagged" : p > 0 ? "flagged" : s >= 600 ? "trusted" : s >= 400 ? "regular" : "low score"; }
  var pct = function (b) { return (b / 100).toFixed(2) + " %"; };
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); };
  return { config: config, liveRead: liveRead, score: score, quote: quote, status: status, pct: pct, esc: esc, W: W };
})();

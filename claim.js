"use strict";
/* Claim your cashback: read-only view of the testnet CashbackPool + optional wallet claim (chainId 97). */
(function () {
  var CFG = {
    chainId: 97, rpc: "https://bsc-testnet-rpc.publicnode.com", explorer: "https://testnet.bscscan.com",
    pool: "0x26c3fF93169be2049aaD92F732F013d015E70e75", asset: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd", fromBlock: 145034000
  };
  var TOKENS = [
    { name: "ALPHA5252", addr: "0xbda42CeC66986F8FD47Fa2f28a9f23e6CDc79518" },
    { name: "BETA7893", addr: "0xBb9076Dc35AA9B34474cdA341c3eeB84a9179957" },
    { name: "GAMMA0100", addr: "0xB9F2fF25C51f2f88789ACD78C08AEc3ca8E4C1d6" }
  ];
  var EXAMPLES = [
    { label: "honestA (claimed)", addr: "0xb016De44fcB18d88Fd9638dbFE3e1358b12CfCc7" },
    { label: "honestB (claimed)", addr: "0x94d0DE9B5507b7df50C23ceC686c1eb3479f3fdb" },
    { label: "newbie1 (claimed)", addr: "0xa8d8Ca5d1c52fde169f57815823A47db5d3649C7" },
    { label: "bundle1 (rug, forfeited)", addr: "0x628303D7831E3f37bC8D166EFF5c950A6dD37C9B" }
  ];
  /* claim transactions of our simulation run, shown even if the log query is rate-limited */
  var KNOWN = {
    "0xb016de44fcb18d88fd9638dbfe3e1358b12cfcc7": [{ tx: "0x9d8ab38f1d", d: "357541721325683", c: "27932946978569", b: "27932946978568" }],
    "0x94d0de9b5507b7df50c23cec686c1eb3479f3fdb": [{ tx: "0xa2d4bd080d", d: "357541535114283", c: "29213728025088", b: "29213728025088" }],
    "0xa8d8ca5d1c52fde169f57815823a47db5d3649c7": [{ tx: "0x18612b8749", d: "238361050698694", c: "19579777992185", b: "19579777992184" }]
  };
  var ABI = [
    "function fund(address) view returns (uint256)", "function depositPool(address) view returns (uint256)",
    "function budgetPool(address) view returns (uint256)", "function bonusLiability(address) view returns (uint256)",
    "function unlocked(address asset,address token,address wallet) view returns (uint256 deposit,uint256 fee,uint256 bonus,uint64 ts)",
    "function claim(address asset,address token,address wallet) returns (uint256 depositOut,uint256 cashback)",
    "event Claimed(address indexed asset,address indexed wallet,address indexed caller,uint256 deposit,uint256 cashback,uint256 bonus)"
  ];
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); };
  var bnb = function (x, d) { return Number(ethers.formatEther(x)).toFixed(d || 6); };
  var provider = new ethers.JsonRpcProvider(CFG.rpc, CFG.chainId, { staticNetwork: true });
  var pool = new ethers.Contract(CFG.pool, ABI, provider);
  var cur = null; // { wallet, claimable:[token...] }
  function status(t, c) { var s = $("status"); s.textContent = t || ""; s.className = c || ""; }
  $("poolLink").href = CFG.explorer + "/address/" + CFG.pool; $("poolLink").textContent = CFG.pool;

  EXAMPLES.forEach(function (e) {
    var b = document.createElement("button"); b.type = "button"; b.textContent = e.label;
    b.onclick = function () { $("addr").value = e.addr; lookup(e.addr); }; $("ex").appendChild(b);
  });

  function card(l, v, sub) { return '<div class="card"><div class="l">' + l + '</div><div class="v">' + v + "</div>" + (sub ? '<div class="muted small">' + sub + "</div>" : "") + "</div>"; }

  async function loadFund() {
    var r = await Promise.all([pool.fund(CFG.asset), pool.bonusLiability(CFG.asset), pool.budgetPool(CFG.asset), pool.depositPool(CFG.asset)]);
    $("fund").innerHTML = card("Scam fund (tBNB)", bnb(r[0]), "rug penalties + forfeited deposits") + card("Bonus owed", bnb(r[1]), "rights of honest wallets") +
      card("Cashback budget", bnb(r[2]), "fees returned to honest wallets") + card("Deposits held", bnb(r[3]), "refundable after honest trading");
    return { fund: r[0], liab: r[1], budget: r[2] };
  }

  async function pastClaims(w) {
    var rows = [], ok = true;
    try {
      var head = await provider.getBlockNumber(), step = 40000;
      for (var from = CFG.fromBlock; from <= head; from += step) {
        var ev = await pool.queryFilter(pool.filters.Claimed(CFG.asset, w), from, Math.min(head, from + step - 1));
        ev.forEach(function (e) { rows.push({ block: e.blockNumber, tx: e.transactionHash, d: e.args.deposit, c: e.args.cashback, b: e.args.bonus }); });
      }
    } catch (e) { ok = false; }
    if (!rows.length && !ok && KNOWN[w.toLowerCase()]) rows = KNOWN[w.toLowerCase()].map(function (k) { return { block: "", tx: k.tx, d: BigInt(k.d), c: BigInt(k.c), b: BigInt(k.b), partial: true }; });
    return rows;
  }

  async function lookup(a) {
    var w;
    try { w = ethers.getAddress(a.trim().toLowerCase()); } catch (e) { status("Not a valid 0x address.", "err"); return; }
    status("Reading testnet contracts…");
    try {
      var f = await loadFund();
      var us = await Promise.all(TOKENS.map(function (t) { return pool.unlocked(CFG.asset, t.addr, w); }));
      var tb = "", sd = 0n, sf = 0n, sb = 0n, sc = 0n, claimable = [];
      var fundOk = f.fund >= f.liab, budget = f.budget;
      us.forEach(function (u, i) {
        var cash = u.fee < budget ? u.fee : budget, bonus = fundOk ? u.bonus : 0n;
        var now = u.deposit + cash + bonus;
        if (u.deposit + u.fee + u.bonus > 0n) claimable.push(TOKENS[i].addr);
        sd += u.deposit; sf += u.fee; sb += u.bonus; sc += now;
        tb += "<tr><td><b>" + TOKENS[i].name + '</b> <a class="mono small" target="_blank" rel="noopener" href="' + CFG.explorer + "/token/" + TOKENS[i].addr + '">' + TOKENS[i].addr.slice(0, 8) + "…</a></td>" +
          '<td class="r">' + bnb(u.deposit, 7) + '</td><td class="r">' + bnb(u.fee, 7) + '</td><td class="r">' + bnb(u.bonus, 7) + '</td><td class="r"><b>' + bnb(now, 7) + "</b></td></tr>";
      });
      $("tt").querySelector("tbody").innerHTML = tb;
      $("tot").innerHTML = card("Open deposit", bnb(sd, 7)) + card("Cashback", bnb(sf, 7)) + card("Bonus", bnb(sb, 7)) + card("Claimable now", bnb(sc, 7), sc === 0n ? "nothing waiting" : "tBNB, paid to this wallet");
      var cl = await pastClaims(w);
      $("ct").querySelector("tbody").innerHTML = cl.length ? cl.map(function (r) {
        var link = r.partial ? '<a target="_blank" rel="noopener" href="' + CFG.explorer + "/address/" + w + '">' + esc(r.tx) + "… (wallet page)</a>" :
          '<a class="mono" target="_blank" rel="noopener" href="' + CFG.explorer + "/tx/" + r.tx + '">' + r.tx.slice(0, 12) + "…</a>";
        return "<tr><td>" + r.block + '</td><td class="r">' + bnb(r.d, 7) + '</td><td class="r">' + bnb(r.c, 7) + '</td><td class="r">' + bnb(r.b, 7) + "</td><td>" + link + "</td></tr>";
      }).join("") : '<tr><td colspan="5" class="muted">No claims found for this wallet.</td></tr>';
      cur = { wallet: w, claimable: claimable };
      $("wallet").hidden = false; setBtn();
      status("Loaded " + w, "ok");
    } catch (e) { status("Could not read the testnet RPC: " + (e.shortMessage || e.message), "err"); }
  }

  function setBtn() {
    var b = $("claimBtn");
    if (!window.ethereum) { b.disabled = true; $("wnote").textContent = "No wallet extension detected: view is read-only."; return; }
    b.disabled = false;
    $("wnote").textContent = cur && cur.claimable.length ? "Calls claim() for " + cur.claimable.length + " token(s) of this wallet." : "Nothing is claimable for this wallet right now.";
  }

  $("claimBtn").onclick = async function () {
    try {
      status("Connecting wallet…");
      var bp = new ethers.BrowserProvider(window.ethereum);
      await bp.send("eth_requestAccounts", []);
      var net = await bp.getNetwork();
      if (Number(net.chainId) !== CFG.chainId) {
        try { await bp.send("wallet_switchEthereumChain", [{ chainId: "0x61" }]); }
        catch (e) { await bp.send("wallet_addEthereumChain", [{ chainId: "0x61", chainName: "BSC Testnet", rpcUrls: [CFG.rpc], nativeCurrency: { name: "tBNB", symbol: "tBNB", decimals: 18 }, blockExplorerUrls: [CFG.explorer] }]); }
        bp = new ethers.BrowserProvider(window.ethereum);
      }
      var signer = await bp.getSigner();
      var target = cur ? cur.wallet : await signer.getAddress(); // anyone may trigger; funds always go to `wallet`
      var list = cur && cur.claimable.length ? cur.claimable : [];
      if (!list.length) { status("Nothing to claim for " + target + ".", "err"); return; }
      var wp = pool.connect(signer);
      for (var i = 0; i < list.length; i++) {
        status("Confirm claim " + (i + 1) + "/" + list.length + " in your wallet…");
        var tx = await wp.claim(CFG.asset, list[i], target);
        status("Sent " + tx.hash + " …"); await tx.wait();
      }
      status("Claimed. Refreshing…", "ok"); lookup(target);
    } catch (e) { status("Claim failed: " + (e.shortMessage || e.message), "err"); }
  };

  $("f").onsubmit = function (e) { e.preventDefault(); lookup($("addr").value); };
  loadFund().catch(function (e) { status("Could not read the testnet RPC: " + (e.shortMessage || e.message), "err"); });
  var q = new URLSearchParams(location.search).get("wallet"); if (q) { $("addr").value = q; lookup(q); }
})();

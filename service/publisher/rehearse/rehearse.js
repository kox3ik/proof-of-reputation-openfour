#!/usr/bin/env node
"use strict";
/**
 * Real-time rehearsal on the LOCAL anvil fork (chain 97 fork, interval mining). The publisher daemon runs separately.
 * Scenario (anvil's public dev keys only): newcomer + veteran buy (fee changes), 3-wallet bundle dumps in ONE block
 * (flags), an honest wallet sells alone (claim opens once coveredUntil passes the sale, then it claims the cashback).
 * Every latency is measured on chain: the first block at which registry state changed, read with historical eth_calls.
 * Env: OPENFOUR_DEV RPC_URL FORK_JSON POR_JSON STATE_JSON DEPLOYER_PRIVATE_KEY WALLET_KEYS(6) OUT_JSON [RAISE_AMOUNT]
 */
const fs = require("fs");
const path = require("path");
const { ethers } = require(path.join(process.env.OPENFOUR_DEV, "node_modules", "ethers"));
const RPC = process.env.RPC_URL || "http://127.0.0.1:8549";
const provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1, batchMaxCount: 1, pollingInterval: 200 });
const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const fork = readJson(process.env.FORK_JSON), por = readJson(process.env.POR_JSON), state = readJson(process.env.STATE_JSON);
const A = fork.addresses, GAS = { gasPrice: 100_000_000n };
const deployer = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
const keys = process.env.WALLET_KEYS.split(",");
// roles: honest seller, newcomer, bundle x3, veteran (the rehearsal snapshot carries real-looking history for it)
const [honest, newcomer, b1, b2, b3, veteran] = keys.map((k) => new ethers.Wallet(k, provider));
const coder = ethers.AbiCoder.defaultAbiCoder();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const CORE_ABI = [
  "function createToken(bytes createArgs,bytes signature) payable returns (address)",
  "function buyByBudget(address token,uint256 maxPayAmount,uint256 minAmountOut,uint256 options,bytes proof) payable",
  "function sell(address token,uint256 amount,uint256 minQuoteRecvAmount,uint256 options,bytes proof)",
  "event TokenCreated(uint256 requestId,uint256 indexed presetId,address indexed creator,address indexed token,string name,string symbol,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,uint256 initialPrice,address quoteAsset,address vault,address curveModule,address tradeModule,address migrateModule,address customData,address tokenModule,string tokenMetaUri,uint256 flags,bytes encodedTags)",
];
const PARAM = "tuple(string name,string abiType,uint8 decimals,bool optional,string title,string defaultValue,string hint,string minValue,string maxValue)";
const SCH = `tuple(string kind,uint8 version,${PARAM}[] params)`;
const TOOLS_ABI = [`function getPresetEncodeSchemas(uint256) view returns (${SCH},${SCH},${SCH},${SCH},${SCH},${SCH})`];
const REG_ABI = ["function componentsOf(address) view returns (tuple(uint16 volume,uint16 activity,uint16 holding,uint16 identity,uint16 penalty))",
  "function isFlagged(address) view returns (bool)", "function quoteFeeBps(address,bool) view returns (uint256)",
  "function scoreOf(address) view returns (uint256)", "function flaggedFrom(address) view returns (uint64)", "function coveredUntil() view returns (uint64)", "function currentEpoch() view returns (uint64)"];
const POOL_ABI = ["function claim(address asset,address token,address wallet) returns (uint256,uint256)", "function unlocked(address asset,address token,address wallet) view returns (uint256 deposit,uint256 fee,uint256 bonus,uint64 ts)",
  "function fund(address) view returns (uint256)", "function bonusLiability(address) view returns (uint256)", "function budgetPool(address) view returns (uint256)", "function depositPool(address) view returns (uint256)",
  "event Claimed(address indexed asset,address indexed wallet,address indexed caller,uint256 deposit,uint256 cashback,uint256 bonus)",
  "event Forfeited(address indexed asset,address indexed wallet,uint256 deposit,uint256 fee,uint256 bonusWrittenOff)"];
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const core = new ethers.Contract(A.core, CORE_ABI, deployer), tools = new ethers.Contract(A.tools, TOOLS_ABI, provider);
const reg = new ethers.Contract(por.registry, REG_ABI, provider), pool = new ethers.Contract(por.pool, POOL_ABI, provider);

const mapParam = (p) => ({ name: p.name, abiType: p.abiType, decimals: Number(p.decimals || 0), optional: Boolean(p.optional), defaultValue: p.defaultValue || "" });
function resolveParam(d, form) {
  let raw = form[d.name];
  if (raw == null || String(raw).trim() === "") {
    if (d.defaultValue) raw = d.defaultValue;
    else if (d.optional) return d.abiType === "address" ? ethers.ZeroAddress : d.abiType === "bool" ? false : 0n;
    else throw new Error(`missing ${d.name}`);
  }
  const s = String(raw).trim();
  if (d.abiType === "bool") return s === "true" || s === "1";
  if (["address", "string", "bytes32", "bytes"].includes(d.abiType)) return s;
  return d.decimals > 0 ? ethers.parseUnits(s, d.decimals) : BigInt(s);
}
const encParams = (sch, form) => (sch.params.length ? coder.encode([`(${sch.params.map((p) => p.abiType).join(",")})`], [sch.params.map((p) => resolveParam(p, form))]) : "0x");

async function createToken() {
  const presetId = BigInt(state.presetId), name = `RT${String(Date.now()).slice(-5)}`;
  const form = { name, symbol: name, maxSupply: "10000000000", saleAmount: "8000000000", raiseAmount: process.env.RAISE_AMOUNT || "1" };
  const [token, vault, curve, trade, migrate, custom] = (await tools.getPresetEncodeSchemas(presetId)).map((s) => ({ params: Array.from(s.params).map(mapParam) }));
  const args = coder.encode(
    ["tuple(uint256 requestId,uint256 presetId,uint256 validTimestamp,uint256 createFee,uint256 presaleQuote,bool antiSniperEnabled,address partner,tuple(string name,string symbol,string tokenUri,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,address quoteAsset,bytes32 tokenSalt,bytes tokenParams,bytes vaultParams,bytes curveParams,bytes tradeParams,bytes migrateParams,bytes customDataParams) initParams)"],
    [[BigInt(Date.now()), presetId, BigInt(Math.floor(Date.now() / 1000) + 3600), 0n, 0n, false, ethers.ZeroAddress,
      [form.name, form.symbol, "", ethers.parseUnits(form.maxSupply, 18), ethers.parseUnits(form.saleAmount, 18), ethers.parseUnits(form.raiseAmount, 18), ethers.getAddress(A.wbnb), ethers.ZeroHash,
        encParams(token, form), encParams(vault, form), encParams(curve, form), encParams(trade, form), encParams(migrate, form), encParams(custom, form)]]]);
  const net = await provider.getNetwork();
  const digest = ethers.keccak256(ethers.solidityPacked(["string", "uint256", "address", "bytes32"], ["createOpenFourToken", net.chainId, deployer.address, ethers.keccak256(args)]));
  const sig = await deployer.signMessage(ethers.getBytes(digest));
  const rec = await (await core.createToken(args, sig, GAS)).wait();
  const ts = (await provider.getBlock(rec.blockNumber)).timestamp;
  for (const l of rec.logs) { try { const p = core.interface.parseLog(l); if (p?.name === "TokenCreated") return { token: p.args.token, block: rec.blockNumber, ts }; } catch { /* other log */ } }
  throw new Error("TokenCreated not found");
}

const buy = (w, token, bnb) => core.connect(w).buyByBudget(token, ethers.parseEther(bnb), 0, 0, "0x", { value: ethers.parseEther(bnb), ...GAS });
const sellAll = async (w, token, nonce) => {
  const t = new ethers.Contract(token, ERC20, provider);
  return core.connect(w).sell(token, await t.balanceOf(w.address), 0, 0, "0x", { ...GAS, nonce });
};
async function firstBlock(fromBlock, pred) {
  const head = await provider.getBlockNumber();
  for (let b = fromBlock; b <= head; b++) if (await pred(b)) return b;
  return null;
}
async function waitUntil(fn, label, timeoutMs = 90_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) { const r = await fn(); if (r) return r; await sleep(150); }
  throw new Error(`timeout waiting for ${label}`);
}
const blockInfo = async (n) => { const b = await provider.getBlock(n); return { block: n, ts: b.timestamp }; };
const comp = async (w, tag) => (await reg.componentsOf(w, { blockTag: tag })).toArray().map(Number);

async function main() {
  const out = { rpc: RPC, registry: por.registry, started: new Date().toISOString() };
  for (const w of [deployer, ...[honest, newcomer, b1, b2, b3, veteran]]) await provider.send("anvil_setBalance", [w.address, "0x56BC75E2D63100000"]);
  const { token, ts: createTs, block: createBlock } = await createToken();
  out.token = token; out.createBlock = createBlock; console.log("token", token, "created at block", createBlock);
  await sleep(2500);

  // 1. fee changes within a block or two of a trade (a newcomer with no history, and a veteran with mainnet history)
  out.feeChange = {};
  for (const [label, w] of [["newcomer", newcomer], ["veteran", veteran]]) {
    const before = { fee: Number(await reg.quoteFeeBps(w.address, true)), comps: await comp(w.address, "latest") };
    const rec = await (await buy(w, token, "0.02")).wait();
    const tb = await blockInfo(rec.blockNumber);
    await waitUntil(async () => (await comp(w.address, "latest")).some((x) => x > 0), `${label} scored`);
    const fb = await firstBlock(tb.block, async (b) => (await comp(w.address, b)).some((x) => x > 0));
    const fi = await blockInfo(fb);
    out.feeChange[label] = { wallet: w.address, trade: tb, before, scoredAt: fi, blocksAfterTrade: fb - tb.block, secondsAfterTrade: fi.ts - tb.ts,
      after: { fee: Number(await reg.quoteFeeBps(w.address, true)), score: Number(await reg.scoreOf(w.address)), comps: await comp(w.address, "latest") } };
    console.log(label, JSON.stringify(out.feeChange[label]));
  }

  // 2. honest wallet and the bundle buy, then the bundle dumps in one block
  const honestBuy = await (await buy(honest, token, "0.02")).wait();
  const bundleBuys = [];
  for (const w of [b1, b2, b3]) bundleBuys.push((await buy(w, token, "0.05")));
  await Promise.all(bundleBuys.map((t) => t.wait()));
  for (const w of [b1, b2, b3, honest]) await (await new ethers.Contract(token, ERC20, w).approve(A.core, ethers.MaxUint256, GAS)).wait();
  await waitUntil(async () => (await comp(b3.address, "latest")).some((x) => x > 0), "bundle scored");
  const wait60 = createTs + 70 - (await provider.getBlock("latest")).timestamp;
  if (wait60 > 0) { console.log(`waiting ${wait60}s: the detector ignores sells in the first 60 s of a token`); await sleep(wait60 * 1000); }
  const nonces = await Promise.all([b1, b2, b3].map((w) => provider.getTransactionCount(w.address)));
  const sells = await Promise.all([b1, b2, b3].map((w, i) => sellAll(w, token, nonces[i])));
  const recs = await Promise.all(sells.map((t) => t.wait()));
  const dump = await blockInfo(recs[0].blockNumber);
  out.bundleDump = { wallets: [b1, b2, b3].map((w) => w.address), sameBlock: recs.every((r) => r.blockNumber === recs[0].blockNumber), dump };
  await waitUntil(async () => (await reg.isFlagged(b1.address)) && (await reg.isFlagged(b2.address)) && (await reg.isFlagged(b3.address)), "bundle flagged");
  const flagBlock = await firstBlock(dump.block, async (b) => await reg.isFlagged(b3.address, { blockTag: b }));
  const fl = await blockInfo(flagBlock);
  out.bundleDump.flaggedAt = fl; out.bundleDump.blocksAfterDump = flagBlock - dump.block; out.bundleDump.secondsAfterDump = fl.ts - dump.ts;
  out.bundleDump.flaggedFrom = Number(await reg.flaggedFrom(b1.address));
  out.bundleDump.honestFlagged = await reg.isFlagged(honest.address);
  console.log("dump", JSON.stringify(out.bundleDump));

  // 3. honest wallet sells alone, later; claim opens when coveredUntil passes the sale
  await sleep(6000);
  const hs = await (await sellAll(honest, token)).wait();
  const sale = await blockInfo(hs.blockNumber);
  const bucket = await pool.unlocked(A.wbnb, token, honest.address);
  let blocked = null;
  try { await pool.connect(honest).claim.staticCall(A.wbnb, token, honest.address); } catch (e) { blocked = e.shortMessage || e.reason || String(e.code); }
  await waitUntil(async () => Number(await reg.coveredUntil()) >= sale.ts, "coverage passes the sale");
  const covBlock = await firstBlock(sale.block, async (b) => Number(await reg.coveredUntil({ blockTag: b })) >= sale.ts);
  const ci = await blockInfo(covBlock);
  const evOf = (rec, name) => rec.logs.map((l) => { try { return pool.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === name);
  // the flagged bundle wallet's sale (a rug sale) is confiscated first: deposit and cashback right move to the scam fund,
  // which then pays the honest wallet's bonus
  const fundBefore = await pool.fund(A.wbnb), liabBefore = await pool.bonusLiability(A.wbnb);
  const bb = await pool.unlocked(A.wbnb, token, b1.address);
  await waitUntil(async () => Number(await reg.coveredUntil()) >= Number(bb.ts), "coverage passes the bundle sale");
  const frec = await (await pool.connect(honest).claim(A.wbnb, token, b1.address, GAS)).wait(); // anyone may trigger it
  const fev = evOf(frec, "Forfeited");
  out.forfeit = { wallet: b1.address, bucket: { deposit: bb.deposit.toString(), fee: bb.fee.toString(), bonus: bb.bonus.toString() },
    forfeited: !!fev, event: fev ? { deposit: fev.args.deposit.toString(), fee: fev.args.fee.toString(), bonusWrittenOff: fev.args.bonusWrittenOff.toString() } : null,
    fundBefore: fundBefore.toString(), fundAfter: (await pool.fund(A.wbnb)).toString(), bonusLiabilityBefore: liabBefore.toString(), bonusLiabilityAfter: (await pool.bonusLiability(A.wbnb)).toString() };
  console.log("forfeit", JSON.stringify(out.forfeit));
  const wb = new ethers.Contract(A.wbnb, ERC20, provider);
  const w0 = await wb.balanceOf(honest.address);
  const claimRec = await (await pool.connect(honest).claim(A.wbnb, token, honest.address, GAS)).wait();
  const cev = evOf(claimRec, "Claimed");
  out.claim = { sale, bucket: { deposit: bucket.deposit.toString(), fee: bucket.fee.toString(), bonus: bucket.bonus.toString(), ts: Number(bucket.ts) }, claimBeforeCoverage: blocked,
    coveredAt: ci, blocksAfterSale: covBlock - sale.block, secondsAfterSale: ci.ts - sale.ts, claimTxBlock: claimRec.blockNumber,
    paid: ((await wb.balanceOf(honest.address)) - w0).toString(),
    paidParts: cev ? { deposit: cev.args.deposit.toString(), cashback: cev.args.cashback.toString(), bonus: cev.args.bonus.toString() } : null };
  console.log("claim", JSON.stringify(out.claim));

  out.finished = new Date().toISOString();
  fs.writeFileSync(process.env.OUT_JSON, JSON.stringify(out, null, 2));
  console.log("written", process.env.OUT_JSON);
}
module.exports = { ethers, provider, core, reg, A, por, GAS, sleep, waitUntil, blockInfo, createToken, buy, sellAll, ERC20, comp, firstBlock, deployer };
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });

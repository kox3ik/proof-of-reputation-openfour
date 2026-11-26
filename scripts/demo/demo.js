#!/usr/bin/env node
"use strict";
/**
 * Proof of Reputation x OpenFour end-to-end demo (fork or real BSC Testnet).
 *   node scripts/demo/demo.js register   # register module + preset on YOUR fork Registry, fee override
 *   node scripts/demo/demo.js trade      # create token, publish scores, trade from 4 wallets, write log
 *   node scripts/demo/demo.js migrate    # create -> buy -> sell -> migrate -> settle -> claim on a small curve (MIGRATE_RAISE)
 *
 * Env (no .env files; pass on the command line):
 *   OPENFOUR_DEV         path to OpenFour docs repo `developer/` dir (provides ethers via node_modules)
 *   RPC_URL              rpc endpoint
 *   FORK_JSON            OpenFour fork-deployment.json (from `npm run fork`)
 *   POR_JSON             our deployment json (forge script/Deploy.s.sol), default deployments/por-deployment.json
 *   DEPLOYER_PRIVATE_KEY owner of fork Registry + Core.signer + our updater
 *   WALLET_KEYS          comma list of 4 keys: trusted,regular,fresh,flagged
 *   TREASURY_ADDRESS / REWARDS_ADDRESS   (informational: fee recipients, read from the registry config)
 *   OUT_JSON             demo log path
 *   BUY_BUDGET           quote budget per buy in BNB (default 0.004)
 *   RAISE_AMOUNT         token raise target (default 0.1)
 */
const fs = require("fs");
const path = require("path");
const DEV = process.env.OPENFOUR_DEV;
if (!DEV) throw new Error("set OPENFOUR_DEV=<openfour-docs>/developer");
const { ethers } = require(path.join(DEV, "node_modules", "ethers"));

const ROOT = path.resolve(__dirname, "../..");
const RPC = process.env.RPC_URL || "http://127.0.0.1:8545";
const FORK_JSON = process.env.FORK_JSON;
const POR_JSON = process.env.POR_JSON || path.join(ROOT, "deployments/por-deployment.json");
const STATE_JSON = process.env.STATE_JSON || path.join(ROOT, "deployments/demo-state.json");
const BUY_BUDGET = ethers.parseEther(process.env.BUY_BUDGET || "0.004");
const RAISE = process.env.RAISE_AMOUNT || "0.1";
const MODULE_TAG = "module.trade.reputation";
const DATA_TAG = "module.data.reputation_ledger";
const PRESET_NAME = "Reputation Bonding V1";

const provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1, batchMaxCount: 1 });
const J = (o) => JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const coder = ethers.AbiCoder.defaultAbiCoder();

const REGISTRY_ABI = [
  "function owner() view returns (address)",
  "function getPreset(uint256) view returns (tuple(uint256 id,string name,string description,string version,bool active,bool createEnabled,address validator,bytes32 tokenModuleId,bytes32 vaultModuleId,bytes32 curveModuleId,bytes32 tradeModuleId,bytes32 migrateModuleId,bytes32 tokenImplId,bytes32 customDataId,address author))",
  "function upsertModule(bytes32 moduleKey,address implementation,uint8 kind,tuple(bytes32 moduleId,string version,string name,string description,address author,uint16 feeShareBps) metadata,bool active)",
  "function upsertPreset(tuple(uint256 id,string name,string description,string version,bool active,bool createEnabled,address validator,bytes32 tokenModuleId,bytes32 vaultModuleId,bytes32 curveModuleId,bytes32 tradeModuleId,bytes32 migrateModuleId,bytes32 tokenImplId,bytes32 customDataId,address author) preset)",
  "function getModuleImplementation(bytes32) view returns (address)",
  "function upsertTokenImpl(bytes32 tokenImplId,address implementation,string version)",
  "function getTokenImpl(bytes32) view returns (tuple(address implementation,string version))",
];
const FEE_ROUTER_ABI = [
  "function presetFeeConfig(uint256) view returns (uint16 protocolFeeBps,uint16 developerFeePoolBps,uint16 maxProtocolDevFeeBps,uint16 maxTaxBps,uint8 maxTaxTiers,bool active,uint256 partnerProtocolShareBps)",
  "function setPresetFeeConfig(uint256 presetId,tuple(uint16 protocolFeeBps,uint16 developerFeePoolBps,uint16 maxProtocolDevFeeBps,uint16 maxTaxBps,uint8 maxTaxTiers,bool active,uint256 partnerProtocolShareBps) cfg)",
];
const PARAM = "tuple(string name,string abiType,uint8 decimals,bool optional,string title,string defaultValue,string hint,string minValue,string maxValue)";
const SCH = `tuple(string kind,uint8 version,${PARAM}[] params)`;
const TRADE_EVENT =
  "event TradeExecuted(address indexed token,address indexed trader,uint256 indexed presetId,bool isBuy,address quoteAsset,address vault,uint256 requestedTokenAmount,uint256 tokenAmount,uint256 curveQuoteAmount,uint256 traderQuoteAmount,uint256 lastPrice,uint256 slippageLimit,uint256 protocolFee,uint256 taxFee,uint256 devFee,uint256 antiSniperFee,uint256 totalRaised,uint256 remainingForSale)";
const CORE_ABI = [
  "function createToken(bytes createArgs,bytes signature) payable returns (address)",
  "function buy(address token,uint256 amount,uint256 maxQuotePayAmount,uint256 options,bytes proof) payable",
  "function buyByBudget(address token,uint256 maxPayAmount,uint256 minAmountOut,uint256 options,bytes proof) payable",
  "function sell(address token,uint256 amount,uint256 minQuoteRecvAmount,uint256 options,bytes proof)",
  "function tokens(address) view returns (uint32 version,address creator,uint256 presetId,address token,string name,string symbol,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,address quoteAsset,address vault,address curveModule,address tradeModule,address migrateModule,address tokenModule,address customData,uint256 createBlock,bool exists,bool paused,bool antiSniperEnabled)",
  "function wrappedNative() view returns (address)",
  "event TokenCreated(uint256 requestId,uint256 indexed presetId,address indexed creator,address indexed token,string name,string symbol,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,uint256 initialPrice,address quoteAsset,address vault,address curveModule,address tradeModule,address migrateModule,address customData,address tokenModule,string tokenMetaUri,uint256 flags,bytes encodedTags)",
  TRADE_EVENT,
];
const TOOLS_ABI = [
  `function getPresetEncodeSchemas(uint256) view returns (${SCH},${SCH},${SCH},${SCH},${SCH},${SCH})`,
  "function estimateBuyByBudget(address token,address trader,uint256 maxQuotePayAmount,uint256 options,bytes proof) returns (tuple(uint256 curveQuote,uint256 totalFee,uint256 userPays,uint256 userReceives,uint256 tokenAmount,uint256 executionPrice))",
  "function estimateSell(address token,address trader,uint256 amount,uint256 options,bytes proof) returns (tuple(uint256 curveQuote,uint256 totalFee,uint256 userPays,uint256 userReceives,uint256 tokenAmount,uint256 executionPrice))",
];
const POR_REGISTRY_ABI = [
  "function finalizeEpoch(uint64 epoch,uint64 coveredUntil)",
  "function setScores(uint64 epoch,address[] wallets,tuple(uint16 volume,uint16 activity,uint16 holding,uint16 identity,uint16 penalty)[] comps)",
  "function currentEpoch() view returns (uint64)",
  "function scoreOf(address) view returns (uint256)",
  "function isFlagged(address) view returns (bool)",
  "function quoteFeeBps(address,bool) view returns (uint256)",
  "function proposeRouter(address)",
  "function activateRouter(address)",
  "function isRouter(address) view returns (bool)",
  "function effectiveIdentity(address) view returns (uint16)",
  "function config() view returns (tuple(uint16 wVolume,uint16 wActivity,uint16 wHolding,uint16 wIdentity,uint16 penaltyWeight,uint16 flagThreshold,uint16 neutralScore,uint16 zeroBps,uint16 neutralBps,uint16 minBps,uint16 sellCapBps,uint16 treasuryShareBps,address treasury,address rewardsPool,uint32 configDelay,address babToken,address agentIdToken,uint16 babIdentity,uint16 agentIdentity,uint16 freshDepositBps,uint16 penaltyBps))",
];
const POOL_ABI = [
  "function fund(address) view returns (uint256)",
  "function bonusLiability(address) view returns (uint256)",
  "function budgetPool(address) view returns (uint256)",
  "function depositPool(address) view returns (uint256)",
  "function unlocked(address,address,address) view returns (uint256 deposit,uint256 fee,uint256 bonus,uint64 ts)",
  "function claim(address asset,address token,address wallet) returns (uint256 depositOut,uint256 cashback)",
  "function sweepSurplus(address asset) returns (uint256)",
  "event Claimed(address indexed asset,address indexed wallet,address indexed caller,uint256 deposit,uint256 cashback,uint256 bonus)",
  "event Forfeited(address indexed asset,address indexed wallet,uint256 deposit,uint256 fee,uint256 bonusWrittenOff)",
];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
];
const MOCK_ABI = ["function mint(address)"];
// scores and identity are integers 0..1000 on chain; the log shows them as 0..1
const unit = (x) => Number((Number(x) / 1000).toFixed(3));
const TRADE_ERRORS = new ethers.Interface(["error CoreErrTradeRejected()"]);

async function ctx() {
  const net = await provider.getNetwork();
  const chainId = Number(net.chainId);
  if (chainId === 56 || chainId === 4663) throw new Error(`refusing to run on mainnet chainId ${chainId}`);
  const deployer = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  const fork = readJson(FORK_JSON);
  const por = readJson(POR_JSON);
  // 97 = BSC testnet (also the local fork); legacy gas price keeps costs minimal
  const gas = { gasPrice: chainId === 97 ? 100_000_000n : undefined };
  Object.keys(gas).forEach((k) => gas[k] === undefined && delete gas[k]);
  return { chainId, deployer, fork, por, gas };
}

async function register() {
  const { chainId, deployer, fork, por, gas } = await ctx();
  const A = fork.addresses;
  const registry = new ethers.Contract(A.registry, REGISTRY_ABI, deployer);
  const feeRouter = new ethers.Contract(A.feeRouter, FEE_ROUTER_ABI, deployer);
  if ((await registry.owner()) !== deployer.address) throw new Error("deployer is not the fork Registry owner");

  const moduleKey = ethers.keccak256(ethers.toUtf8Bytes(MODULE_TAG));
  const rec = await (await registry.upsertModule(moduleKey, por.tradeModule, 3, {
    moduleId: moduleKey, version: "1.0.0", name: "ReputationTradeModule",
    description: "Reputation-priced trade module (Proof of Reputation)", author: deployer.address, feeShareBps: 0,
  }, true, gas)).wait();
  console.log("upsertModule", rec.hash);

  // customData module (ReputationLedger, kind 5): Core calls its afterHook after every trade; one BeaconProxy per token
  const dataKey = ethers.keccak256(ethers.toUtf8Bytes(DATA_TAG));
  const drec = await (await registry.upsertModule(dataKey, por.ledger, 5, {
    moduleId: dataKey, version: "1.0.0", name: "ReputationLedger",
    description: "Per-token cashback ledger: tracks curve positions, unlocks deposit and cashback on sells", author: deployer.address, feeShareBps: 0,
  }, true, gas)).wait();
  console.log("upsertModule (customData)", drec.hash);

  // token implementation with the pre-migration transfer fee (ReputationLockedToken), bound to the preset through its own tokenImplId
  const tokenImplId = ethers.keccak256(ethers.toUtf8Bytes("TOKEN_IMPL_REPUTATION_LOCKED"));
  const trec = await (await registry.upsertTokenImpl(tokenImplId, por.lockedToken, "1", gas)).wait();
  console.log("upsertTokenImpl", trec.hash);

  const base = await registry.getPreset(fork.presets.bondingV1);
  const presetId = BigInt(process.env.PRESET_ID || Date.now());
  const preset = {
    id: presetId, name: PRESET_NAME, description: "Bonding V1 with reputation-priced Trade module and pre-migration transfer fee", version: "1.0.0",
    active: true, createEnabled: true, validator: base.validator, tokenModuleId: base.tokenModuleId,
    vaultModuleId: base.vaultModuleId, curveModuleId: base.curveModuleId, tradeModuleId: moduleKey,
    migrateModuleId: base.migrateModuleId, tokenImplId, customDataId: dataKey,
    author: deployer.address,
  };
  const prec = await (await registry.upsertPreset(preset, gas)).wait();
  console.log("upsertPreset", prec.hash, presetId.toString());
  // the pool accepts reports only from ledgers of tokens created with this preset (one-time binding)
  const pool = new ethers.Contract(por.pool, ["function bindPreset(uint256)"], deployer);
  const brec = await (await pool.bindPreset(presetId, gas)).wait();
  console.log("bindPreset", brec.hash);

  const res = { presetId: presetId.toString(), moduleKey, dataKey, upsertDataModuleTx: drec.hash, tokenImplId, lockedTokenImpl: por.lockedToken, upsertTokenImplTx: trec.hash, upsertModuleTx: rec.hash, upsertPresetTx: prec.hash, feeOverride: {} };
  // start from the fork default fee config (the per-preset entry of bondingV1 may be empty), zero the developer pool
  const cur = (await feeRouter.presetFeeConfig(fork.presets.bondingV1)).active ? await feeRouter.presetFeeConfig(fork.presets.bondingV1) : fork.config.feeConfig;
  const cfg = {
    protocolFeeBps: cur.protocolFeeBps, developerFeePoolBps: 0, maxProtocolDevFeeBps: cur.maxProtocolDevFeeBps,
    maxTaxBps: cur.maxTaxBps, maxTaxTiers: cur.maxTaxTiers, active: true, partnerProtocolShareBps: cur.partnerProtocolShareBps || 0,
  };
  try {
    const frec = await (await feeRouter.setPresetFeeConfig(presetId, cfg, gas)).wait();
    const now = await feeRouter.presetFeeConfig(presetId);
    res.feeOverride = { worked: true, tx: frec.hash, protocolFeeBps: Number(now.protocolFeeBps), developerFeePoolBps: Number(now.developerFeePoolBps) };
  } catch (e) {
    res.feeOverride = { worked: false, error: e.shortMessage || e.message };
  }
  console.log("fee override", J(res.feeOverride));
  fs.mkdirSync(path.dirname(STATE_JSON), { recursive: true });
  fs.writeFileSync(STATE_JSON, J({ chainId, ...res }));
}

// ───────── schema encoding (same scheme as OpenFour create-test-preset.js) ─────────
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

async function createToken(c, core, tools, presetId, name, raise = RAISE) {
  const form = { name, symbol: name, maxSupply: "10000000000", saleAmount: "8000000000", raiseAmount: raise };
  const raw = await tools.getPresetEncodeSchemas(presetId);
  const [token, vault, curve, trade, migrate, custom] = raw.map((s) => ({ params: Array.from(s.params).map(mapParam) }));
  const wbnb = ethers.getAddress(c.fork.addresses.wbnb);
  const args = coder.encode(
    ["tuple(uint256 requestId,uint256 presetId,uint256 validTimestamp,uint256 createFee,uint256 presaleQuote,bool antiSniperEnabled,address partner,tuple(string name,string symbol,string tokenUri,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,address quoteAsset,bytes32 tokenSalt,bytes tokenParams,bytes vaultParams,bytes curveParams,bytes tradeParams,bytes migrateParams,bytes customDataParams) initParams)"],
    [[BigInt(Date.now()), presetId, BigInt(Math.floor(Date.now() / 1000) + 3600), 0n, 0n, false, ethers.ZeroAddress,
      [form.name, form.symbol, "", ethers.parseUnits(form.maxSupply, 18), ethers.parseUnits(form.saleAmount, 18), ethers.parseUnits(form.raiseAmount, 18), wbnb, ethers.ZeroHash,
        encParams(token, form), encParams(vault, form), encParams(curve, form), encParams(trade, form), encParams(migrate, form), encParams(custom, form)]]],
  );
  const digest = ethers.keccak256(ethers.solidityPacked(["string", "uint256", "address", "bytes32"], ["createOpenFourToken", c.chainId, c.deployer.address, ethers.keccak256(args)]));
  const sig = await c.deployer.signMessage(ethers.getBytes(digest));
  await core.createToken.staticCall(args, sig, c.gas);
  const rec = await (await core.createToken(args, sig, c.gas)).wait();
  let tokenAddr;
  for (const l of rec.logs) { try { const p = core.interface.parseLog(l); if (p?.name === "TokenCreated") tokenAddr = p.args.token; } catch { /* other log */ } }
  const blk = await provider.getBlock(rec.blockNumber);
  // same fields as OpenFour's workbench/data/tokens.json rows (startup/scripts/create-and-trade.js)
  const record = { tokenAddress: tokenAddr, name: form.name, symbol: form.symbol, presetId: presetId.toString(), presetName: PRESET_NAME, creator: c.deployer.address,
    txHash: rec.hash, chainId: c.chainId, quoteAsset: wbnb, createdAt: new Date(blk.timestamp * 1000).toISOString(), digest };
  return { tokenAddr, tx: rec.hash, record };
}

function decodeTrade(core, rec) {
  for (const l of rec.logs) {
    try {
      const p = core.interface.parseLog(l);
      if (p?.name === "TradeExecuted") {
        const a = p.args;
        return { isBuy: a.isBuy, tokenAmount: a.tokenAmount, curveQuote: a.curveQuoteAmount, traderQuote: a.traderQuoteAmount, protocolFee: a.protocolFee, taxFee: a.taxFee, devFee: a.devFee, antiSniperFee: a.antiSniperFee, trader: a.trader };
      }
    } catch { /* other log */ }
  }
  return null;
}
const TRANSFER_AMOUNT = ethers.parseUnits("100000", 18); // fixed token amount for the pre-migration transfer step
// Core calls the ledger hook inside the trade; estimateGas can land just under what the hook needs (an out-of-gas
// revert seen on fresh keys), so every trade is sent with a 50 % gas margin (unused gas is refunded).
const withMargin = async (method, args, overrides) => ({ ...overrides, gasLimit: ((await method.estimateGas(...args, overrides)) * 3n) / 2n });
const bps = (fee, base) => (base === 0n ? 0 : Math.round(Number((fee * 100_000_000n) / base)) / 10_000);

async function trade() {
  const c = await ctx();
  const state = readJson(STATE_JSON);
  const A = c.fork.addresses;
  const presetId = BigInt(state.presetId);
  const core = new ethers.Contract(A.core, CORE_ABI, c.deployer);
  const tools = new ethers.Contract(A.tools, TOOLS_ABI, c.deployer);
  const preg = new ethers.Contract(c.por.registry, POR_REGISTRY_ABI, c.deployer);
  const keys = (process.env.WALLET_KEYS || "").split(",").filter(Boolean);
  if (keys.length !== 6) throw new Error("WALLET_KEYS must hold 6 comma-separated keys: trusted,regular,fresh,flagged,babholder,agentholder");
  const roles = ["trusted", "regular", "fresh", "flagged", "babholder", "agentholder"];
  const W = Object.fromEntries(roles.map((r, i) => [r, new ethers.Wallet(keys[i], provider)]));
  const cfg = await preg.config();
  const watch = { treasury: cfg.treasury, rewardsPool: cfg.rewardsPool, protocolTreasury: c.deployer.address };
  const wbnb = new ethers.Contract(A.wbnb, ERC20_ABI, provider);
  const snap = async () => Object.fromEntries(await Promise.all(Object.entries(watch).map(async ([k, a]) => [k, await wbnb.balanceOf(a)])));

  const { tokenAddr, tx: createTx, record: tokenRecord } = await createToken(c, core, tools, presetId, `POR${String(Date.now()).slice(-5)}`);
  console.log("token", tokenAddr);
  const rt = await core.tokens(tokenAddr);
  const token = new ethers.Contract(tokenAddr, ERC20_ABI, provider);

  const pub = async (epoch, entries) => {
    const rec = await (await preg.setScores(epoch, entries.map((e) => e[0]), entries.map((e) => e[1]), c.gas)).wait();
    return rec.hash;
  };
  // epoch 1: trusted / regular published; fresh has no record; flagged has a decent record but not yet a penalty
  const epoch0 = BigInt(await preg.currentEpoch());
  const tx1 = await pub(epoch0 + 1n, [
    [W.trusted.address, [900, 900, 900, 900, 0]],
    [W.regular.address, [400, 400, 400, 400, 0]],
    [W.flagged.address, [500, 500, 500, 500, 0]],
  ]);
  const log = { chainId: c.chainId, rpc: RPC.replace(/\/\/[^@/]*@/, "//"), generatedAt: new Date().toISOString(), openfour: { registry: A.registry, core: A.core, feeRouter: A.feeRouter, tools: A.tools, wbnb: A.wbnb }, por: c.por, presetId: state.presetId, feeOverride: state.feeOverride, token: tokenAddr, createTx, tokenRecord, registration: state, config: {
    weights: [cfg.wVolume, cfg.wActivity, cfg.wHolding, cfg.wIdentity].map(Number), penaltyWeight: Number(cfg.penaltyWeight), flagThreshold: unit(cfg.flagThreshold), neutralScore: unit(cfg.neutralScore), zeroBps: Number(cfg.zeroBps), neutralBps: Number(cfg.neutralBps), minBps: Number(cfg.minBps), sellCapBps: Number(cfg.sellCapBps), treasuryShareBps: Number(cfg.treasuryShareBps), babToken: cfg.babToken, agentIdToken: cfg.agentIdToken, babIdentity: unit(cfg.babIdentity), agentIdentity: unit(cfg.agentIdentity), treasury: cfg.treasury, rewardsPool: cfg.rewardsPool },
    publishTxs: { epoch1: tx1 }, wallets: Object.fromEntries(roles.map((r) => [r, W[r].address])), trades: [] };

  const doBuy = async (label, role, viaRouter, router) => {
    const w = W[role];
    const coreW = core.connect(w);
    const [score, flagged, expBps] = [await preg.scoreOf(w.address), await preg.isFlagged(w.address), await preg.quoteFeeBps(w.address, true)];
    const base = { label, role, wallet: w.address, identity: unit(await preg.effectiveIdentity(w.address)), viaRouter: !!viaRouter, score: unit(score), flagged, expectedExtraBps: Number(expBps), side: "buy", budget: BUY_BUDGET.toString() };
    const before = await snap();
    try {
      if (viaRouter) {
        const r = router.connect(w);
        await r.buyFor.staticCall(tokenAddr, BUY_BUDGET, { value: BUY_BUDGET, ...c.gas });
        const rec = await (await r.buyFor(tokenAddr, BUY_BUDGET, { value: BUY_BUDGET, ...c.gas })).wait();
        return finish(base, rec, before);
      }
      await coreW.buyByBudget.staticCall(tokenAddr, BUY_BUDGET, 0, 0, "0x", { value: BUY_BUDGET, ...c.gas });
      const ov = await withMargin(coreW.buyByBudget, [tokenAddr, BUY_BUDGET, 0, 0, "0x"], { value: BUY_BUDGET, ...c.gas });
      const rec = await (await coreW.buyByBudget(tokenAddr, BUY_BUDGET, 0, 0, "0x", ov)).wait();
      return finish(base, rec, before);
    } catch (e) {
      // buyByBudget probes the curve itself and reports its own error; the exact-amount
      // `buy` path reports it as CoreErrTradeRejected (testnet Core does not bubble the module payload).
      const budgetErr = e.data || e.info?.error?.data || "";
      const ref = log.trades.filter((t) => t.event && t.side === "buy").pop();
      const amount = ref ? BigInt(ref.event.tokenAmount) : 0n;
      const maxPay = BUY_BUDGET * 2n;
      let data = "";
      let decoded = null;
      try { await coreW.buy.staticCall(tokenAddr, amount, maxPay, 0, "0x", { value: maxPay, ...c.gas }); } catch (e2) { data = e2.data || e2.info?.error?.data || ""; }
      try { decoded = TRADE_ERRORS.parseError(data); } catch { /* unknown */ }
      // put a reverting tx on chain so the failed buy has a hash
      let failedTx = null;
      try { const t = await coreW.buy(tokenAddr, amount, maxPay, 0, "0x", { value: maxPay, gasLimit: 1_500_000, ...c.gas }); failedTx = t.hash; await t.wait().catch(() => {}); } catch { /* ignore */ }
      return { ...base, reverted: true, revertError: decoded ? `${decoded.name}(${decoded.args.join(",")})` : "unknown", note: "unexpected: the module never blocks trades (buys and sells are only priced); registry.isFlagged(wallet)=" + flagged, revertData: data, buyByBudgetRevertData: budgetErr, failedTx };
    }
  };
  const finish = async (base, rec, before) => {
    const after = await snap();
    const ev = decodeTrade(core, rec);
    const recipients = Object.fromEntries(Object.keys(before).map((k) => [k, (after[k] - before[k]).toString()]));
    return { ...base, tx: rec.hash, status: rec.status, event: ev && Object.fromEntries(Object.entries(ev).map(([k, v]) => [k, typeof v === "bigint" ? v.toString() : v])),
      chargedExtraBps: ev ? bps(ev.taxFee, ev.curveQuote) : null, protocolBps: ev ? bps(ev.protocolFee, ev.curveQuote) : null, devBps: ev ? bps(ev.devFee, ev.curveQuote) : null, recipientsDelta: recipients };
  };

  // setup buy by the soon-to-be-flagged wallet (still clean) so it holds tokens to sell later
  log.trades.push(await doBuy("setup buy of future flagged wallet (good record, no penalty yet)", "flagged"));
  // epoch 2: wallet #4 gets a rug penalty (flagged label, score drops to 0.1); it still trades, at the fee its score gives
  const tx2 = await pub(epoch0 + 2n, [[W.flagged.address, [900, 900, 900, 900, 800]]]);
  log.publishTxs.epoch2 = tx2;
  // same buy, four wallets
  for (const r of roles.slice(0, 4)) log.trades.push(await doBuy(`same buy: ${r}${r === "flagged" ? " (rug penalty, flagged: buys are NOT blocked)" : ""}`, r));
  // on-chain identity: same wallet buys before and after it receives a BABT; another wallet holds an Agent ID
  log.trades.push(await doBuy("babholder, no BABT yet (unknown record, identity 0)", "babholder"));
  const babC = new ethers.Contract(cfg.babToken, MOCK_ABI, c.deployer);
  const agC = new ethers.Contract(cfg.agentIdToken, MOCK_ABI, c.deployer);
  log.identityTxs = {
    babMint: (await (await babC.mint(W.babholder.address, c.gas)).wait()).hash,
    agentMint: (await (await agC.mint(W.agentholder.address, c.gas)).wait()).hash,
  };
  log.trades.push(await doBuy("same babholder after receiving a BABT (identity -> babIdentity)", "babholder"));
  log.trades.push(await doBuy("agentholder holding an Agent ID (identity -> agentIdentity)", "agentholder"));
  // router (contract trader -> tx.origin resolution)
  const rf = await (await import_router(c)).waitForDeployment();
  const router = rf;
  log.router = await router.getAddress();
  // router allowlist for the pull-from-signer exemption: owner proposes, activation after configDelay (0 on test chains)
  const regOwner = preg.connect(c.deployer);
  const routerAddr = await router.getAddress();
  const proposeTx = await (await regOwner.proposeRouter(routerAddr, c.gas)).wait();
  const activateTx = await (await regOwner.activateRouter(routerAddr, c.gas)).wait();
  log.routerAllowlist = { router: routerAddr, proposeTx: proposeTx.hash, activateTx: activateTx.hash, isRouter: await preg.isRouter(routerAddr) };
  if (!log.routerAllowlist.isRouter) throw new Error("router activation failed");
  console.log("router allowlisted", routerAddr);
  const trBefore = await token.balanceOf(W.trusted.address), tsBefore = await token.balanceOf(cfg.treasury);
  const routerBuy = await doBuy("buy through DemoRouter contract by trusted wallet (tx.origin resolution; router hand-off to the signer is free)", "trusted", true, router);
  routerBuy.tokensReceivedByWallet = ((await token.balanceOf(W.trusted.address)) - trBefore).toString();
  routerBuy.transferFeeToTreasury = ((await token.balanceOf(cfg.treasury)) - tsBefore).toString();
  routerBuy.routerTokenBalanceAfter = (await token.balanceOf(routerAddr)).toString();
  routerBuy.handOffFree = routerBuy.transferFeeToTreasury === "0" && routerBuy.routerTokenBalanceAfter === "0" && BigInt(routerBuy.tokensReceivedByWallet) === BigInt(routerBuy.event.tokenAmount);
  console.log(`router buy hand-off: wallet received ${routerBuy.tokensReceivedByWallet}, buy amount ${routerBuy.event.tokenAmount}, transfer fee ${routerBuy.transferFeeToTreasury} ${routerBuy.handOffFree ? "OK (free)" : "MISMATCH"}`);
  if (!routerBuy.handOffFree) throw new Error("router hand-off was not free");
  log.trades.push(routerBuy);

  // pre-migration wallet-to-wallet transfer: the sender pays its own sell rate (quoteFeeBps(sender,false)) in tokens to the registry treasury
  const doTransfer = async (label, from, to) => {
    const bal = await token.balanceOf(W[from].address);
    const amount = TRANSFER_AMOUNT;
    if (bal < amount) throw new Error(`${from} holds less than the fixed transfer amount`);
    const bpsSender = await preg.quoteFeeBps(W[from].address, false);
    const [sBefore, rBefore, tBefore] = [await token.balanceOf(W[from].address), await token.balanceOf(W[to].address), await token.balanceOf(cfg.treasury)];
    const rec = await (await token.connect(W[from]).transfer(W[to].address, amount, c.gas)).wait();
    const [sAfter, rAfter, tAfter] = [await token.balanceOf(W[from].address), await token.balanceOf(W[to].address), await token.balanceOf(cfg.treasury)];
    const received = rAfter - rBefore, fee = tAfter - tBefore, expectedFee = (amount * bpsSender) / 10000n;
    const ok = fee === expectedFee && received === amount - fee && sBefore - sAfter === amount;
    console.log(`transfer ${from}->${to}: sent=${amount} received=${received} fee=${fee} sellRate=${bpsSender}bps expectedFee=${expectedFee} ${ok ? "OK" : "MISMATCH"}`);
    if (!ok) throw new Error(`transfer fee check failed for ${label}`);
    return { label, role: from, wallet: W[from].address, side: "transfer", to: W[to].address, tx: rec.hash, status: rec.status, tokenAmount: amount.toString(), score: unit(await preg.scoreOf(W[from].address)), flagged: await preg.isFlagged(W[from].address), expectedExtraBps: Number(bpsSender), sellRateBps: Number(bpsSender), amountSent: amount.toString(), amountReceived: received.toString(), feeToTreasury: fee.toString(), expectedFee: expectedFee.toString(), feeMatches: ok, treasury: cfg.treasury, chargedExtraBps: Number(bps(fee, amount)) };
  };
  log.trades.push(await doTransfer("trusted (good record) -> regular, plain transfer before migration: pays its sell rate in tokens", "trusted", "regular"));
  log.trades.push(await doTransfer("flagged (rug penalty in the rate) -> regular, plain transfer before migration", "flagged", "regular"));
  log.trades.push(await doTransfer("fresh wallet -> regular, plain transfer before migration (fresh deposit in the rate)", "fresh", "regular"));

  // sells
  const doSell = async (label, role, frac) => {
    const w = W[role];
    const bal = await token.balanceOf(w.address);
    const amount = (bal * frac) / 100n;
    const coreW = core.connect(w);
    const [score, flagged, expBps] = [await preg.scoreOf(w.address), await preg.isFlagged(w.address), await preg.quoteFeeBps(w.address, false)];
    const base = { label, role, wallet: w.address, score: unit(score), flagged, expectedExtraBps: Number(expBps), side: "sell", tokenAmount: amount.toString() };
    await (await token.connect(w).approve(A.core, ethers.MaxUint256, c.gas)).wait();
    const before = await snap();
    const rec = await (await coreW.sell(tokenAddr, amount, 0, 0, "0x", await withMargin(coreW.sell, [tokenAddr, amount, 0, 0, "0x"], c.gas))).wait();
    return finish(base, rec, before);
  };
  // sale through the allowlisted router: pull from the signer is free, only the sell rate applies
  const routerSell = async () => {
    const w = W.trusted, amount = TRANSFER_AMOUNT;
    const sellBps = await preg.quoteFeeBps(w.address, false);
    const base = { label: "sell through allowlisted DemoRouter by trusted wallet (pull from signer free; only the sell rate)", role: "trusted", wallet: w.address, viaRouter: true, side: "sell", tokenAmount: amount.toString(), score: unit(await preg.scoreOf(w.address)), flagged: await preg.isFlagged(w.address), expectedExtraBps: Number(sellBps) };
    await (await token.connect(w).approve(routerAddr, ethers.MaxUint256, c.gas)).wait();
    const tsB = await token.balanceOf(cfg.treasury), before = await snap();
    const rec = await (await router.connect(w).sellFor(tokenAddr, amount, c.gas)).wait();
    const r = await finish(base, rec, before);
    r.transferFeeToTreasury = ((await token.balanceOf(cfg.treasury)) - tsB).toString();
    r.noTransferFee = r.transferFeeToTreasury === "0";
    console.log(`router sell: sellRate=${sellBps}bps charged=${r.chargedExtraBps}bps transferFee=${r.transferFeeToTreasury} ${r.noTransferFee ? "OK (no transfer fee)" : "MISMATCH"}`);
    if (!r.noTransferFee) throw new Error("router sale paid a transfer fee");
    return r;
  };
  log.trades.push(await routerSell());
  // negative: a contract NOT on the allowlist pulling tokens from the signer pays the transfer fee
  const router2 = await (await import_custody(c)).waitForDeployment();
  const router2Addr = await router2.getAddress();
  const negAmount = TRANSFER_AMOUNT, negBps = await preg.quoteFeeBps(W.trusted.address, false);
  await (await token.connect(W.trusted).approve(router2Addr, ethers.MaxUint256, c.gas)).wait();
  const [n2tB, n2rB] = [await token.balanceOf(cfg.treasury), await token.balanceOf(router2Addr)];
  const negRec = await (await router2.connect(W.trusted).pullFrom(tokenAddr, negAmount, c.gas)).wait();
  const negFee = (await token.balanceOf(cfg.treasury)) - n2tB, negGot = (await token.balanceOf(router2Addr)) - n2rB, negExp = (negAmount * negBps) / 10000n;
  const negOk = !(await preg.isRouter(router2Addr)) && negFee === negExp && negGot === negAmount - negFee && negFee > 0n;
  console.log(`non-listed router pull: amount=${negAmount} received=${negGot} fee=${negFee} sellRate=${negBps}bps expectedFee=${negExp} ${negOk ? "OK" : "MISMATCH"}`);
  if (!negOk) throw new Error("non-listed router pull did not pay the expected transfer fee");
  log.trades.push({ label: "pull by a contract NOT on the router allowlist (CustodyMock): pays the transfer fee", role: "trusted", wallet: W.trusted.address, side: "transfer", to: router2Addr, viaRouter: true, routerListed: false, tx: negRec.hash, status: negRec.status, tokenAmount: negAmount.toString(), score: unit(await preg.scoreOf(W.trusted.address)), flagged: false, expectedExtraBps: Number(negBps), sellRateBps: Number(negBps), amountSent: negAmount.toString(), amountReceived: negGot.toString(), feeToTreasury: negFee.toString(), expectedFee: negExp.toString(), feeMatches: negOk, treasury: cfg.treasury, chargedExtraBps: Number(bps(negFee, negAmount)) });

  log.trades.push(await doSell("sell by flagged wallet (penalty in the sell rate)", "flagged", 100n));
  log.trades.push(await doSell("sell by trusted wallet", "trusted", 50n));

  log.scamFundCircle = await scamFundCircle(c, preg, pub, epoch0 + 3n, W, A.wbnb, cfg.treasury, wbnb, tokenAddr);

  const out = process.env.OUT_JSON || path.join(ROOT, "demo-out/demo-run.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, J(log));
  for (const t of log.trades) {
    console.log(`${t.side.padEnd(8)} ${t.role.padEnd(11)} score=${String(t.score).padStart(5)} expected=${t.expectedExtraBps}bps ` + (t.reverted ? `REVERT ${t.revertError}` : (t.side === "transfer" ? `fee=${t.chargedExtraBps}bps in tokens (sent ${t.amountSent}, received ${t.amountReceived}, to treasury ${t.feeToTreasury}) ${t.label}` : `charged=${t.chargedExtraBps}bps protocol=${t.protocolBps}bps dev=${t.devBps}bps ${t.label}`)));
  }
  console.log("written", out);
}

/// Scam-fund circle: the flagged wallet's pool shares went to the fund and its sale is a rug sale (deposit and cashback
/// right confiscated); the honest wallet claims cashback + bonus from the fund; the surplus is swept to the treasury.
async function scamFundCircle(c, preg, pub, epoch, W, asset, treasury, wbnb, tokenAddr) {
  const pool = new ethers.Contract(c.por.pool, POOL_ABI, c.deployer);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const state = async () => ({ fund: await pool.fund(asset), bonusLiability: await pool.bonusLiability(asset), budget: await pool.budgetPool(asset), deposits: await pool.depositPool(asset), poolBalance: await wbnb.balanceOf(c.por.pool), treasury: await wbnb.balanceOf(treasury) });
  const str = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, v.toString()]));
  const out = { before: str(await state()) };
  // a complete publication covering every sale so far opens the claims
  await pub(epoch, [[W.regular.address, [400, 400, 400, 400, 0]]]);
  await sleep(2500);
  const cov = (await provider.getBlock("latest")).timestamp;
  await sleep(1500);
  await (await preg.finalizeEpoch(epoch, cov, c.gas)).wait();
  out.coveredUntil = cov;
  const claimOf = async (role) => {
    const u = await pool.unlocked(asset, tokenAddr, W[role].address);
    if (u.deposit + u.fee + u.bonus === 0n) return { role, wallet: W[role].address, event: null, note: "nothing unlocked for this wallet", args: [], paidToWallet: "0" };
    const before = await wbnb.balanceOf(W[role].address);
    const rec = await (await pool.claim(asset, tokenAddr, W[role].address, c.gas)).wait();
    const paid = (await wbnb.balanceOf(W[role].address)) - before;
    const ev = rec.logs.map((l) => { try { return pool.interface.parseLog(l); } catch { return null; } }).find((e) => e && (e.name === "Claimed" || e.name === "Forfeited"));
    return { role, wallet: W[role].address, unlockedDeposit: u.deposit.toString(), unlockedFee: u.fee.toString(), unlockedBonus: u.bonus.toString(), event: ev ? ev.name : null, args: ev ? ev.args.slice(ev.name === "Claimed" ? 3 : 2).map(String) : [], paidToWallet: paid.toString(), tx: rec.hash };
  };
  out.flaggedClaim = await claimOf("flagged"); // rug sale: nothing paid, confiscated into the fund
  out.afterConfiscation = str(await state());
  out.trustedClaim = await claimOf("trusted"); // deposit (none: not fresh) + cashback + bonus from the fund
  out.afterHonestClaim = str(await state());
  const rec = await (await pool.sweepSurplus(asset, c.gas)).wait();
  out.sweepTx = rec.hash;
  out.afterSweep = str(await state());
  console.log("scam-fund circle: fund", out.before.fund, "->", out.afterConfiscation.fund, "-> honest bonus", out.trustedClaim.args.join("/"), "-> swept; treasury +", (BigInt(out.afterSweep.treasury) - BigInt(out.afterHonestClaim.treasury)).toString());
  return out;
}

async function import_router(c) {
  const art = readJson(path.join(ROOT, "out/DemoRouter.sol/DemoRouter.json"));
  const f = new ethers.ContractFactory(art.abi, art.bytecode.object, c.deployer);
  return f.deploy(c.fork.addresses.core, c.gas);
}

async function import_custody(c) {
  const art = readJson(path.join(ROOT, "out/CustodyMock.sol/CustodyMock.json"));
  const f = new ethers.ContractFactory(art.abi, art.bytecode.object, c.deployer);
  return f.deploy(c.gas);
}

/// create -> buy -> sell -> migrate -> settle -> claim on a small curve (MIGRATE_RAISE, default 0.02 BNB), step log in OUT_JSON
async function migrate() {
  const c = await ctx();
  const state = readJson(STATE_JSON);
  const A = c.fork.addresses;
  const core = new ethers.Contract(A.core, CORE_ABI, c.deployer);
  const tools = new ethers.Contract(A.tools, TOOLS_ABI, c.deployer);
  const preg = new ethers.Contract(c.por.registry, POR_REGISTRY_ABI, c.deployer);
  const keys = (process.env.WALLET_KEYS || "").split(",").filter(Boolean);
  if (keys.length !== 6) throw new Error("WALLET_KEYS must hold 6 comma-separated keys");
  const roles = ["trusted", "regular", "fresh", "flagged", "babholder", "agentholder"];
  const W = Object.fromEntries(roles.map((r, i) => [r, new ethers.Wallet(keys[i], provider)]));
  const wbnb = new ethers.Contract(A.wbnb, ERC20_ABI, provider);
  const pub = async (epoch, entries) => (await (await preg.setScores(epoch, entries.map((e) => e[0]), entries.map((e) => e[1]), c.gas)).wait()).hash;
  const nextEpoch = async () => BigInt(await preg.currentEpoch()) + 1n;
  const out = process.env.OUT_JSON || path.join(ROOT, "demo-out/demo-migrate.json");
  const raise = process.env.MIGRATE_RAISE || "0.02";
  await require("./migrate_flow").run({ withMargin, ethers, c, core, preg, pub, W, wbnb, createToken, tools, state, provider, poolAbi: POOL_ABI, out, raise, buyBudget: BUY_BUDGET, nextEpoch });
}

const cmd = process.argv[2];
({ register, trade, migrate }[cmd] || (() => { throw new Error("usage: demo.js register|trade|migrate"); }))().catch((e) => { console.error(e); process.exit(1); });

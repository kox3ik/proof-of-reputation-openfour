"use strict";
/**
 * Shared helpers of the simulation scripts (scripts/sim/*). Keys only come from files (never argv / stdout).
 * Env (set by run-sim.sh from $WORK/sim-env.sh): OPENFOUR_DEV RPC_URL FORK_JSON POR_JSON STATE_JSON WORK; KEYS_DIR (testnet-keys);
 * BOTS_FILE (bot keys, default $KEYS_DIR/sim/bots.json); ABI_DIR (forge out dir, default $WORK/forge-out: ABIs are read from the build).
 */
const fs = require("fs");
const path = require("path");
const DEV = process.env.OPENFOUR_DEV;
if (!DEV) throw new Error("set OPENFOUR_DEV (run via scripts/sim/run-sim.sh)");
const { ethers } = require(path.join(DEV, "node_modules", "ethers"));

const RPC = process.env.RPC_URL;
const KEYS_DIR = process.env.KEYS_DIR;
const provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1, batchMaxCount: 1, pollingInterval: Number(process.env.POLL_MS || 250) });
const GAS = { gasPrice: BigInt(process.env.GAS_PRICE || "100000000") };
const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const J = (o) => JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
const ROLES = ["honestA", "honestB", "newbie1", "newbie2", "newbie3", "newbie4", "newbie5", "bundle1", "bundle2", "bundle3", "bundle4"];
const EXPLORER = "https://testnet.bscscan.com";

async function chainGuard() {
  const id = Number((await provider.getNetwork()).chainId);
  if (id !== 97) throw new Error(`refusing to run on chain ${id} (only 97 = BSC testnet or a local fork of it)`);
  return id;
}
const deployer = () => new ethers.Wallet(readJson(path.join(KEYS_DIR, "deployer.json"))[0].private_key.replace(/^(?!0x)/, "0x"), provider);
const botsFile = () => process.env.BOTS_FILE || path.join(KEYS_DIR, "sim", "bots.json");
function loadBots() {
  return Object.fromEntries(readJson(botsFile()).map((b) => [b.role, new ethers.Wallet(b.private_key, provider)]));
}
function genBots() {
  const f = botsFile();
  if (fs.existsSync(f)) return console.log("bot wallets exist, reused");
  fs.mkdirSync(path.dirname(f), { recursive: true, mode: 0o700 });
  const rows = ROLES.map((r) => { const x = ethers.Wallet.createRandom(); return { role: r, address: x.address, private_key: x.privateKey }; });
  fs.writeFileSync(f, JSON.stringify(rows, null, 2), { mode: 0o600 });
  console.log("bot wallets created:", rows.length);
}
function abiOf(name) {
  const dir = process.env.ABI_DIR || path.join(process.env.WORK || "", "forge-out");
  return readJson(path.join(dir, `${name}.sol`, `${name}.json`)).abi;
}

const CORE_ABI = [
  "function createToken(bytes createArgs,bytes signature) payable returns (address)",
  "function buyByBudget(address token,uint256 maxPayAmount,uint256 minAmountOut,uint256 options,bytes proof) payable",
  "function sell(address token,uint256 amount,uint256 minQuoteRecvAmount,uint256 options,bytes proof)",
  "event TokenCreated(uint256 requestId,uint256 indexed presetId,address indexed creator,address indexed token,string name,string symbol,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,uint256 initialPrice,address quoteAsset,address vault,address curveModule,address tradeModule,address migrateModule,address customData,address tokenModule,string tokenMetaUri,uint256 flags,bytes encodedTags)",
  "event TradeExecuted(address indexed token,address indexed trader,uint256 indexed presetId,bool isBuy,address quoteAsset,address vault,uint256 requestedTokenAmount,uint256 tokenAmount,uint256 curveQuoteAmount,uint256 traderQuoteAmount,uint256 lastPrice,uint256 slippageLimit,uint256 protocolFee,uint256 taxFee,uint256 devFee,uint256 antiSniperFee,uint256 totalRaised,uint256 remainingForSale)",
];
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const PARAM = "tuple(string name,string abiType,uint8 decimals,bool optional,string title,string defaultValue,string hint,string minValue,string maxValue)";
const SCH = `tuple(string kind,uint8 version,${PARAM}[] params)`;
const TOOLS_ABI = [`function getPresetEncodeSchemas(uint256) view returns (${SCH},${SCH},${SCH},${SCH},${SCH},${SCH})`];
const coder = ethers.AbiCoder.defaultAbiCoder();
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

/** Create a token of the Proof of Reputation preset (signed by the deployer = Core.signer). Returns {token, tx, block, ts, raise}. */
async function createToken(dep, fork, presetId, name, raise) {
  const core = new ethers.Contract(fork.addresses.core, CORE_ABI, dep);
  const tools = new ethers.Contract(fork.addresses.tools, TOOLS_ABI, provider);
  const form = { name, symbol: name, maxSupply: "10000000000", saleAmount: "8000000000", raiseAmount: String(raise) };
  const [token, vault, curve, trade, migrate, custom] = (await tools.getPresetEncodeSchemas(presetId)).map((s) => ({ params: Array.from(s.params).map(mapParam) }));
  const args = coder.encode(
    ["tuple(uint256 requestId,uint256 presetId,uint256 validTimestamp,uint256 createFee,uint256 presaleQuote,bool antiSniperEnabled,address partner,tuple(string name,string symbol,string tokenUri,uint256 maxSupply,uint256 saleAmount,uint256 raiseAmount,address quoteAsset,bytes32 tokenSalt,bytes tokenParams,bytes vaultParams,bytes curveParams,bytes tradeParams,bytes migrateParams,bytes customDataParams) initParams)"],
    [[BigInt(Date.now()), presetId, BigInt(Math.floor(Date.now() / 1000) + 3600), 0n, 0n, false, ethers.ZeroAddress,
      [form.name, form.symbol, "", ethers.parseUnits(form.maxSupply, 18), ethers.parseUnits(form.saleAmount, 18), ethers.parseUnits(form.raiseAmount, 18), ethers.getAddress(fork.addresses.wbnb), ethers.ZeroHash,
        encParams(token, form), encParams(vault, form), encParams(curve, form), encParams(trade, form), encParams(migrate, form), encParams(custom, form)]]]);
  const net = await provider.getNetwork();
  const digest = ethers.keccak256(ethers.solidityPacked(["string", "uint256", "address", "bytes32"], ["createOpenFourToken", net.chainId, dep.address, ethers.keccak256(args)]));
  const sig = await dep.signMessage(ethers.getBytes(digest));
  const rec = await (await core.createToken(args, sig, GAS)).wait();
  const ts = (await provider.getBlock(rec.blockNumber)).timestamp;
  for (const l of rec.logs) { try { const p = core.interface.parseLog(l); if (p?.name === "TokenCreated") return { token: p.args.token, name, tx: rec.hash, block: rec.blockNumber, ts, raise: String(raise) }; } catch { /* other log */ } }
  throw new Error("TokenCreated not found");
}
module.exports = { ethers, provider, GAS, readJson, sleep, J, ROLES, EXPLORER, chainGuard, deployer, loadBots, genBots, botsFile, abiOf, CORE_ABI, ERC20, createToken, KEYS_DIR };

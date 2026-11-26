"use strict";
/**
 * Full lifecycle on a small curve: create -> buy -> sell -> migrate -> settle -> claim, one JSON record per step
 * (tx hash, block, token). Called by `demo.js migrate` with the helpers of demo.js (no chain logic is duplicated here).
 * The raise target is small (MIGRATE_RAISE, default 0.02), so graduation costs little on a real testnet.
 */
const LEDGER_ABI = ["function settle(address wallet)", "function migratedAt() view returns (uint64)", "function positions(address) view returns (uint256 pos,uint256 depositOpen,uint256 feeOpen,uint256 bonusOpen)"];
const MIGRATE_EVENT = "event MigrateExecuted(uint256 indexed presetId,address indexed caller,address indexed token,address vault,address migrateModule,bytes8 migrateTagId,uint256 totalRaised,uint256 remainingForSale,bytes32 hookDataHash,uint8 migratedDataVersion,bytes encodedMigratedData)";

async function run(env) {
  const { withMargin, ethers, c, core, preg, pub, W, wbnb, createToken, tools, state, provider, poolAbi, out, raise, buyBudget, nextEpoch } = env;
  const steps = [];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const rec = async (name, tx, extra = {}) => {
    const r = await tx.wait();
    const row = { step: name, tx: r.hash, block: r.blockNumber, ...extra };
    steps.push(row);
    console.log("migrate-flow", name, r.hash, "block", r.blockNumber);
    return r;
  };
  const migIface = new ethers.Interface([MIGRATE_EVENT]);
  const migrated = (r) => r.logs.map((l) => { try { return migIface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "MigrateExecuted");

  // known wallets: trusted and regular have a record, fresh pays the deposit
  let epoch = await nextEpoch();
  const pubTx = await pub(epoch, [[W.trusted.address, [900, 900, 900, 900, 0]], [W.regular.address, [400, 400, 400, 400, 0]]]);
  steps.push({ step: "publish scores", tx: pubTx, epoch: epoch.toString() });

  const { tokenAddr, tx: createTx, record: tokenRecord } = await createToken(c, core, tools, BigInt(state.presetId), `MIG${String(Date.now()).slice(-5)}`, raise);
  const createRec = await provider.getTransactionReceipt(createTx);
  steps.push({ step: "create", tx: createTx, block: createRec.blockNumber, token: tokenAddr, raiseBNB: raise, tokenRecord });
  const rt = await core.tokens(tokenAddr);
  const ledger = new ethers.Contract(rt.customData, LEDGER_ABI, provider);
  const token = new ethers.Contract(tokenAddr, ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"], provider);
  const pool = new ethers.Contract(c.por.pool, poolAbi, c.deployer);

  const buy = async (role, budget) => { const cw = core.connect(W[role]); return cw.buyByBudget(tokenAddr, budget, 0, 0, "0x", await withMargin(cw.buyByBudget, [tokenAddr, budget, 0, 0, "0x"], { value: budget, ...c.gas })); };
  for (const role of ["fresh", "regular", "trusted"]) await rec(`buy ${role}`, await buy(role, buyBudget), { role, wallet: W[role].address, token: tokenAddr });
  // sells before migration: a partial sale by the fresh wallet and a full sale by regular
  for (const [role, pct] of [["fresh", 50n], ["regular", 100n]]) {
    const bal = await token.balanceOf(W[role].address);
    await (await token.connect(W[role]).approve(c.fork.addresses.core, ethers.MaxUint256, c.gas)).wait();
    await rec(`sell ${pct}% ${role}`, await (async () => { const cw = core.connect(W[role]), amt = (bal * pct) / 100n; return cw.sell(tokenAddr, amt, 0, 0, "0x", await withMargin(cw.sell, [tokenAddr, amt, 0, 0, "0x"], c.gas)); })(), { role, wallet: W[role].address, token: tokenAddr });
  }
  // buys of the trusted wallet until the raise target is reached and Core migrates the token
  let mig = null;
  for (let i = 0; i < 12 && !mig; ++i) {
    const r = await rec(`buy trusted #${i + 1} (towards the raise target)`, await buy("trusted", buyBudget * 2n), { role: "trusted", token: tokenAddr });
    mig = migrated(r);
    if (mig) steps.push({ step: "migrate", tx: r.hash, block: r.blockNumber, token: tokenAddr, totalRaised: mig.args.totalRaised.toString(), remainingForSale: mig.args.remainingForSale.toString(), migrateModule: mig.args.migrateModule, note: "executed by Core inside the buy that reached the raise target; Core then called ReputationLedger.onMigrate" });
  }
  if (!mig) throw new Error("token did not migrate: raise target not reached (increase MIGRATE_RAISE steps or lower the raise)");
  const at = await ledger.migratedAt();
  steps.push({ step: "ledger migratedAt", migratedAt: Number(at) });
  if (at === 0n) throw new Error("ReputationLedger.onMigrate was not called");

  // after migration open positions release lazily: anyone calls settle(wallet)
  for (const role of ["fresh", "trusted"]) {
    const before = await ledger.positions(W[role].address);
    await rec(`settle ${role}`, await new ethers.Contract(rt.customData, LEDGER_ABI, c.deployer).settle(W[role].address, c.gas), { role, wallet: W[role].address, token: tokenAddr, openBefore: { pos: before.pos.toString(), deposit: before.depositOpen.toString(), fee: before.feeOpen.toString(), bonus: before.bonusOpen.toString() } });
  }
  // a complete publication covering the migration time opens the claims
  epoch = await nextEpoch();
  await pub(epoch, [[W.regular.address, [400, 400, 400, 400, 0]]]);
  await sleep(2500);
  const cov = (await provider.getBlock("latest")).timestamp;
  await sleep(1500);
  await rec("finalizeEpoch (coveredUntil passes the migration)", await env.preg.finalizeEpoch(epoch, cov, c.gas), { coveredUntil: cov });

  const asset = c.fork.addresses.wbnb;
  for (const role of ["fresh", "regular", "trusted"]) {
    const u = await pool.unlocked(asset, tokenAddr, W[role].address);
    if (u.deposit + u.fee + u.bonus === 0n) { steps.push({ step: `claim ${role}`, note: "nothing unlocked" }); continue; }
    const w0 = await wbnb.balanceOf(W[role].address);
    const r = await rec(`claim ${role}`, await pool.claim(asset, tokenAddr, W[role].address, c.gas), { role, wallet: W[role].address, token: tokenAddr });
    const ev = r.logs.map((l) => { try { return pool.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "Claimed");
    steps[steps.length - 1].unlocked = { deposit: u.deposit.toString(), fee: u.fee.toString(), bonus: u.bonus.toString() };
    steps[steps.length - 1].paid = { deposit: ev ? ev.args.deposit.toString() : "0", cashback: ev ? ev.args.cashback.toString() : "0", bonus: ev ? ev.args.bonus.toString() : "0", total: ((await wbnb.balanceOf(W[role].address)) - w0).toString() };
  }
  const result = { generatedAt: new Date().toISOString(), chainId: c.chainId, presetId: state.presetId, token: tokenAddr, raiseBNB: raise, steps };
  require("fs").mkdirSync(require("path").dirname(out), { recursive: true });
  require("fs").writeFileSync(out, JSON.stringify(result, null, 2) + "\n");
  console.log("written", out);
  return result;
}
module.exports = { run };

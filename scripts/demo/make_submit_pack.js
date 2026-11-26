#!/usr/bin/env node
"use strict";
/**
 * Writes OpenFour's own submission files for our preset from the demo results (no chain access, no new data):
 *   <out>/tokens.json                          same rows as workbench/data/tokens.json ({ tokens: [...] })
 *   <out>/reputation-bonding-registration.json same fields as startup/out/<slug>-registration.json (register.js)
 *   <out>/reputation-bonding-submit-pack.json  same shape as startup/scripts/pack-submit.js writes
 * Field names are copied from developer/startup/scripts/{pack-submit.js,register.js,create-and-trade.js}. Nothing is
 * written into OpenFour's directories.
 *
 *   node scripts/demo/make_submit_pack.js --run demo-out/demo-run-local.json [--migrate demo-out/demo-migrate-local.json] [--out submit-pack]
 */
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const ROOT = path.resolve(__dirname, "../..");
const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
const runFile = path.resolve(arg("run", path.join(ROOT, "demo-out/demo-run-local.json")));
const migFile = arg("migrate", path.join(ROOT, "demo-out/demo-migrate-local.json"));
const outDir = path.resolve(arg("out", path.join(ROOT, "demo-out/submit-pack")));
const SLUG = "reputation-bonding";
const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const write = (p, v) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`); return p; };
const gitRev = () => { try { return execSync("git rev-parse HEAD", { cwd: ROOT, encoding: "utf8" }).trim(); } catch { return ""; } };

const run = readJson(runFile);
const reg = run.registration;
if (!run.tokenRecord || !reg) throw new Error("run json lacks tokenRecord / registration: rerun `demo.js trade` with the current demo.js");
const por = run.por, of = run.openfour;

// token rows: the trade token and the token that went all the way to migration (same presetId)
const tokens = [run.tokenRecord, ...(run.extraTokens || [])];
if (migFile && fs.existsSync(migFile)) {
  const mig = readJson(migFile);
  const create = (mig.steps || []).find((s) => s.step === "create" && s.tokenRecord);
  if (create) tokens.unshift(create.tokenRecord);
}
const tokensFile = write(path.join(outDir, "tokens.json"), { tokens });

const TRADE_KEY = "module.trade.reputation", DATA_KEY = "module.data.reputation_ledger", IMPL_KEY = "TOKEN_IMPL_REPUTATION_LOCKED";
const moduleKeys = {
  ReputationTradeModule: { keySource: TRADE_KEY, moduleKey: reg.moduleKey },
  ReputationLedger: { keySource: DATA_KEY, moduleKey: reg.dataKey },
};
const implementations = {
  ReputationTradeModule: por.tradeModule, ReputationLedger: por.ledger, ReputationLockedToken: por.lockedToken,
  CashbackPool: por.pool, ReputationRegistry: por.registry,
};
const developerModules = [
  { keySource: TRADE_KEY, moduleKey: reg.moduleKey, implementation: por.tradeModule, kind: 3, name: "ReputationTradeModule", txHash: reg.upsertModuleTx },
  { keySource: DATA_KEY, moduleKey: reg.dataKey, implementation: por.ledger, kind: 5, name: "ReputationLedger", txHash: reg.upsertDataModuleTx },
];
const registrationFile = path.join(outDir, `${SLUG}-registration.json`);
const registration = {
  slug: SLUG, presetPath: "presets/reputation-bonding.json", network: run.onPublicChain ? "bsctestnet" : "fork of bsctestnet", chainId: run.chainId,
  registeredAt: run.generatedAt,
  registry: of.registry, core: of.core, presetId: reg.presetId, tokenImplId: reg.tokenImplId, tokenImpl: por.lockedToken,
  implementations, moduleKeys, developerModules, presetTx: reg.upsertPresetTx,
};
write(registrationFile, registration);

// preset in the startup/presets/*.json shape; slots not replaced by us reuse the fork's Bonding V1 modules
const preset = {
  id: SLUG, name: "Reputation Bonding V1",
  description: "Bonding V1 with reputation-priced Trade module and pre-migration transfer fee",
  modules: {
    token: { keySource: "module.token.standard", reuse: true },
    vault: { keySource: "module.vault.standard", reuse: true },
    curve: { keySource: "module.curve.bonding", reuse: true },
    trade: { contract: "ReputationTradeModule", keySource: TRADE_KEY },
    migrate: { keySource: "module.migrate.bonding", reuse: true },
    customData: { contract: "ReputationLedger", keySource: DATA_KEY },
  },
  validator: { reuse: "fork", note: "the validator of the fork's Bonding V1 preset (the Preset copies it unchanged)" },
  tokenImpl: { contract: "ReputationLockedToken", keySource: IMPL_KEY },
};
const sources = [
  "src/ReputationTradeModule.sol", "src/ReputationLedger.sol", "src/ReputationLockedToken.sol",
  "src/ReputationRegistry.sol", "src/CashbackPool.sol", "src/ReputationMath.sol", "src/ReputationTypes.sol",
].filter((f) => fs.existsSync(path.join(ROOT, f)));

const pack = {
  kind: "openfour-submit-pack", version: "1", createdAt: new Date().toISOString(), gitRev: gitRev(),
  preset: { id: SLUG, name: preset.name, description: preset.description, path: registration.presetPath, modules: preset.modules, validator: preset.validator, tokenImpl: preset.tokenImpl },
  sources,
  registration: { path: path.relative(ROOT, registrationFile), registry: registration.registry, core: registration.core, presetId: registration.presetId, tokenImplId: registration.tokenImplId, moduleKeys },
  forkRegistry: registration.registry,
  tokens,
  notes: [
    "Do not upsert production Registries yourself.",
    "Include this file, module source, tests, and the fork Registry address on four.meme.",
    "Sources are paths relative to the Proof of Reputation repository root (Foundry project), not to developer/startup.",
    run.onPublicChain
      ? "Registry and Core addresses are those of our own OpenFour fork deployed on the real BSC Testnet (chain id 97); tx hashes are in the simulation run log."
      : "Registry and Core addresses are those of a local anvil fork of BSC Testnet (chain id 97), see the demo logs under demo-out/.",
  ],
  frontendStyle: "developer/frontend-style/",
};
const packFile = write(path.join(outDir, `${SLUG}-submit-pack.json`), pack);
console.log(JSON.stringify({ tokens: tokensFile, registration: registrationFile, pack: packFile, forkRegistry: pack.forkRegistry, presetId: registration.presetId, tokenRows: tokens.length }, null, 2));

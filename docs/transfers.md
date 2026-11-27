# Transfers (before and after migration)

> Moving tokens before migration costs exactly what selling from the sender would cost, so a clean or warmed wallet gives
> no discount; the fee goes to the protocol treasury.

`ReputationLockedToken._update` (before and after migration; after migration trades against the migrated DEX pair are priced like curve trades, see the last section):
- Wallet-to-wallet transfer: fee in tokens = `amount * quoteFeeBps(sender, false) / 10000` (the SENDER's sell rate from the
  registry, flag penalty included; no fresh deposit: that is charged on curve buys only). The receiver gets the rest; the fee goes to
  the registry's treasury. Nothing is burned.
- Phases: the fee applies in Created, Trading, SoldOut and Terminal (no DEX pool is tradeable there; SoldOut and
  Terminal are not DEX states per the OpenFour integration guide), and from MigratePending on as well (wallet-to-wallet only; moves touching the migrated pair are priced as trades, protocol moves are free).
- Free: mint / burn; anything involving the vault or Core (buys, sells); a contract handing the signer tokens it received
  from the vault or Core earlier in the same transaction (transient credit, capped at the amount received: a purchase
  through any router); a router on the registry allowlist (`isRouter`) pulling tokens from the signer for a sale
  (`from == tx.origin`, `msg.sender == to`).
- Everything else pays the fee at the sender's rate: a custody contract or an unlisted router pulling from the signer, and
  any later withdrawal from a contract (no same-transaction credit). The allowlist is owner-managed in the registry:
  `proposeRouter` (activatable after `configDelay`), `activateRouter` (anyone), `removeRouter` (immediate).
  `tx.origin` is used only for this exemption.
- Relayers / ERC-4337: `tx.origin` is the relayer, so hand-offs to the real user are charged like transfers.

## After migration: same pricing against the DEX pair
`_update` also sees every transfer after migration. A transfer FROM a migrated pool pair (`migratedPools`, set by the
migrate module) is a **buy** of the receiver (`quoteDetailed(wallet, true)`: regular fee by score, refundable deposit by
score, penalty if flagged); a transfer TO the pair is a **sale** of the sender (`quoteDetailed(wallet, false)`). A contract
on the trader side is priced at `tx.origin`. The fee is taken **in tokens**: on a buy from the receiver after the pair
has paid out in full (the pair's own accounting is untouched), on a sale from the amount (the pair receives
`amount - fee`). It goes to the treasury and to the cashback pool, which records it under asset = this token (the token
itself reports; only tokens created with our preset are accepted). A sale into the pair unlocks the wallet's deposit and
cashback right for the sold fraction (token-asset position kept in the token, curve position in the ledger via
`onPoolSale`); a sale at or after `flaggedFrom` is forfeited. Free: moves involving the vault, Core, migrate module,
ledger, treasury or pool (liquidity at migration, claims, sweeps). A plain wallet-to-wallet transfer after migration still
costs the sender's sell rate in tokens (same rules, exemptions and split as before migration), so a flagged wallet cannot
hand tokens to a clean wallet for free.

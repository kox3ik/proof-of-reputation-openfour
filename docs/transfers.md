# Transfers before migration

> Moving tokens before migration costs exactly what selling from the sender would cost, so a clean or warmed wallet gives
> no discount; the fee goes to the protocol treasury.

`ReputationLockedToken._update` (pre-migration only; after migration the token is a normal token without any fee):
- Wallet-to-wallet transfer: fee in tokens = `amount * quoteFeeBps(sender, false) / 10000` (the SENDER's sell rate from the
  registry, flag penalty included; no fresh deposit: that is charged on curve buys only). The receiver gets the rest; the fee goes to
  the registry's treasury. Nothing is burned.
- Phases: the fee applies in Created, Trading, SoldOut and Terminal (no DEX pool is tradeable there; SoldOut and
  Terminal are not DEX states per the OpenFour integration guide). From MigratePending on: no fee.
- Free: mint / burn; anything involving the vault or Core (buys, sells); a contract handing the signer tokens it received
  from the vault or Core earlier in the same transaction (transient credit, capped at the amount received: a purchase
  through any router); a router on the registry allowlist (`isRouter`) pulling tokens from the signer for a sale
  (`from == tx.origin`, `msg.sender == to`).
- Everything else pays the fee at the sender's rate: a custody contract or an unlisted router pulling from the signer, and
  any later withdrawal from a contract (no same-transaction credit). The allowlist is owner-managed in the registry:
  `proposeRouter` (activatable after `configDelay`), `activateRouter` (anyone), `removeRouter` (immediate).
  `tx.origin` is used only for this exemption.
- Relayers / ERC-4337: `tx.origin` is the relayer, so hand-offs to the real user are charged like transfers.

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OpenFourTypes} from "./vendor/openfour/OpenFourTypes.sol";
import {IOpenFourToken} from "./vendor/openfour/IOpenFourToken.sol";
import {ReputationRegistry} from "./ReputationRegistry.sol";
import {FeeQuote} from "./ReputationTypes.sol";

interface IVaultCore {
    function fourCore() external view returns (address);
}

/// @title ReputationLockedToken
/// @notice OpenFour token implementation for the Proof of Reputation preset: same surface and storage semantics as
///         OpenFour's `OpenFourToken` (so Core / Vault / Migrate modules treat it identically), plus a transfer fee
///         before migration: a wallet-to-wallet transfer costs the SENDER's sell rate from the registry
///         (`quoteFeeBps(sender, false)`, penalty included if flagged), paid in tokens to the registry's treasury (no
///         burn); the receiver gets the rest. After migration the token is a normal token without any fee.
/// @dev Fee applies in every phase where no DEX pool is tradeable: Created, Trading, SoldOut, Terminal (OpenFour
///      integration guide section 4: SoldOut = "internal buy/sell unavailable ... not an external DEX state";
///      Terminal = reserved / trade-terminated token, never a DEX token). From MigratePending on the token is a normal
///      token (OpenFour itself lifts its pool-transfer block there) and no fee is charged.
///      Free (no fee) before migration: mint / burn; any transfer involving the vault or Core (buys, sells); a
///      contract handing the signer tokens it received from the vault or Core EARLIER IN THE SAME TRANSACTION
///      (transient credit per contract, consumed by the hand-off: a purchase through a router); a contract on the
///      registry's router allowlist pulling tokens from the signer (`from == tx.origin`, `msg.sender == to`) for a sale.
///      Any other contract (own custody contract, unlisted router) pays the normal fee at the sender's rate, so tokens
///      cannot be parked in or pooled through a contract for free. `tx.origin` is used only for this fee exemption,
///      never for authorization.
///      Why: the owner defines a rug as "collect tokens by plain transfers onto one wallet, then sell in one trade";
///      with the fee a clean or warmed wallet gets no discount for moving tokens, it pays what selling would cost.
/// @dev OpenFour's guide asks custom tokens to inherit `OpenFourToken`. The vendored reference is written for OpenZeppelin 4
///      (`_beforeTokenTransfer` / `_afterTokenTransfer`) while this repo uses OpenZeppelin 5 (`_update`), so inheriting it
///      would mean porting the hooks and the whole OZ stack; this contract instead mirrors its storage layout, getters,
///      `descriptor()`, phase semantics and `TokenTransferred` events one to one. Submitting it officially needs that port.
///      Listing a router in the registry means trusting it to sell what it pulls in the same transaction: the free pull is
///      recorded as "owed to a sale" (cleared by any transfer to the vault or Core); a listed router moving owed tokens
///      anywhere else pays the transfer fee at `tx.origin`'s rate. A listed router that simply keeps the tokens until
///      the end of the transaction cannot be caught on-chain; its later withdrawal pays at the router's own rate.
contract ReputationLockedToken is Initializable, ERC20, IOpenFourToken {
    struct InitArgs {
        uint256 requestId;
        string name;
        string symbol;
        address vault;
        uint256 maxSupply;
        string tokenUri;
        address curveModule;
        address tradeModule;
        address migrateModule;
        address tokenModule;
        address customDataModule;
        address creator;
        address quoteAsset;
        bytes tokenParams;
        string tokenImplVersion;
    }

    error InvalidCore();
    error ZeroFeeRecipient();

    ReputationRegistry public immutable REGISTRY;

    string private _tokenName;
    string private _tokenSymbol;
    string private _tokenMetadataUri;

    uint256 public maxSupply;
    address public vault;
    address public curveModule;
    address public tradeModule;
    address public migrateModule;
    address public tokenModule;
    uint256 public requestId;
    address public customData;
    mapping(address => bool) public migratedPools;
    OpenFourTypes.Phase public tokenPhase;
    string internal _descriptorVersion;
    /// @dev Cached OpenFour Core (read lazily from the vault: the vault may learn its Core after this token is set up).
    ///      Appended AFTER every field of OpenFour's `OpenFourToken` so the layout stays a superset of it.
    address private _core;

    event MigratedPoolUpdated(address indexed pool, bool enabled);
    event MigratedPoolsUpdated(address[] pools, bool enabled);
    event TokenPhaseUpdated(OpenFourTypes.Phase indexed phase);
    event TokenTransferred(address indexed from, address indexed to, uint256 indexed requestId, uint256 amount);
    event TransferFee(address indexed from, address indexed treasury, uint256 amount);

    constructor(ReputationRegistry registry_) ERC20("", "") {
        require(address(registry_) != address(0), "Token: zero registry");
        REGISTRY = registry_;
        _disableInitializers();
    }

    function initialize(InitArgs calldata c) external initializer {
        require(bytes(c.name).length != 0, "Token: empty name");
        require(bytes(c.symbol).length != 0, "Token: empty symbol");
        require(c.vault != address(0), "Token: vault is zero");
        require(
            c.curveModule != address(0) && c.tradeModule != address(0) && c.migrateModule != address(0)
                && c.tokenModule != address(0),
            "Token: zero module"
        );
        _tokenName = c.name;
        _tokenSymbol = c.symbol;
        vault = c.vault;
        maxSupply = c.maxSupply;
        _tokenMetadataUri = c.tokenUri;
        curveModule = c.curveModule;
        tradeModule = c.tradeModule;
        migrateModule = c.migrateModule;
        tokenModule = c.tokenModule;
        customData = c.customDataModule;
        requestId = c.requestId;
        _descriptorVersion = c.tokenImplVersion;
        if (c.maxSupply > 0) _mint(c.vault, c.maxSupply);
    }

    function descriptor() external view returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "token.reputation_locked";
        return (bytes8(keccak256(bytes(tag))), tag, _descriptorVersion);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function tokenURI() external view returns (string memory) {
        return _tokenMetadataUri;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Token: only vault");
        _;
    }

    modifier onlyMigrate() {
        require(msg.sender == migrateModule, "Token: only migrate");
        _;
    }

    function setMigratedPool(address pool, bool enabled) external onlyMigrate {
        require(pool != address(0), "Token: zero pool");
        migratedPools[pool] = enabled;
        emit MigratedPoolUpdated(pool, enabled);
    }

    function setMigratedPools(address[] calldata pools, bool enabled) external onlyMigrate {
        uint256 n = pools.length;
        for (uint256 i; i < n; ++i) {
            require(pools[i] != address(0), "Token: zero pool");
            migratedPools[pools[i]] = enabled;
        }
        if (n > 0) emit MigratedPoolsUpdated(pools, enabled);
    }

    function setPhase(OpenFourTypes.Phase newPhase) external onlyVault {
        require(tokenPhase != OpenFourTypes.Phase.Migrated, "Token: already migrated");
        tokenPhase = newPhase;
        emit TokenPhaseUpdated(newPhase);
    }

    /// @dev True once ordinary transfers are allowed (migration started or done).
    function transfersUnlocked() public view returns (bool) {
        OpenFourTypes.Phase p = tokenPhase;
        return p == OpenFourTypes.Phase.MigratePending || p == OpenFourTypes.Phase.Migrated;
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee;
        FeeQuote memory q;
        if (from != address(0) && to != address(0) && !transfersUnlocked()) {
            uint256 bal = balanceOf(from);
            if (bal < amount) revert ERC20InsufficientBalance(from, bal, amount); // before splitting off a fee
            (bool free, address payer) = _isFree(from, to, amount);
            if (!free) {
                q = REGISTRY.quoteDetailed(payer, false);
                if (q.treasury == address(0)) revert ZeroFeeRecipient();
                fee = Math.mulDiv(amount, q.regularBps + q.depositBps + q.penaltyBps, 10_000);
            }
        }
        if (fee != 0) {
            super._update(from, q.treasury, fee);
            emit TokenTransferred(from, q.treasury, requestId, fee);
            emit TransferFee(from, q.treasury, fee);
        }
        super._update(from, to, amount - fee);
        // Same as OpenFour's own token: one event per transfer, also for zero amounts and mint / burn.
        emit TokenTransferred(from, to, requestId, amount - fee);
    }

    /// @dev Pre-migration transfer exemptions (see contract notes). Returns whether the transfer is free and whose sell
    ///      rate applies otherwise. Maintains two per-contract transient counters: `credit` (received from the vault /
    ///      Core in this tx) and `owed` (pulled for a sale by a listed router, not yet handed to the vault / Core).
    function _isFree(address from, address to, uint256 amount) private returns (bool, address) {
        address v = vault;
        // Every outgoing transfer spends the sender's credit, so an old balance can never ride on fresh credit.
        bool covered = _spend(from, amount);
        uint256 owed = _tget(_owedKey(from));
        if (from == v || to == v) {
            if (from == v) _addCredit(to, amount);
            else _spendOwed(from, owed, amount);
            return (true, from);
        }
        address core = _core;
        if (core == address(0)) {
            core = IVaultCore(v).fourCore();
            if (core == address(0)) revert InvalidCore();
            _core = core;
        }
        if (from == core || to == core) {
            if (from == core) _addCredit(to, amount);
            else _spendOwed(from, owed, amount);
            return (true, from);
        }
        if (from.code.length > 0 && to == tx.origin && covered) return (true, from); // purchase hand-off
        if (from == tx.origin && msg.sender == to && REGISTRY.isRouter(to)) {
            _tset(_owedKey(to), _tget(_owedKey(to)) + amount); // free pull, must be sold in this tx
            return (true, from);
        }
        if (owed != 0) {
            // a listed router moving tokens it pulled for a sale anywhere but to the vault / Core: the signer pays
            _spendOwed(from, owed, amount);
            return (false, tx.origin);
        }
        return (false, from);
    }

    function _spendOwed(address who, uint256 owed, uint256 amount) private {
        if (owed != 0) _tset(_owedKey(who), owed > amount ? owed - amount : 0);
    }

    function _addCredit(address who, uint256 amount) private {
        _tset(_creditKey(who), _tget(_creditKey(who)) + amount);
    }

    /// @dev Reduces the credit of `who` by up to `amount`; true if the credit covered all of it.
    function _spend(address who, uint256 amount) private returns (bool ok) {
        uint256 c = _tget(_creditKey(who));
        ok = c >= amount;
        if (c != 0) _tset(_creditKey(who), ok ? c - amount : 0);
    }

    function _creditKey(address a) private pure returns (uint256) {
        return uint256(uint160(a));
    }

    function _owedKey(address a) private pure returns (uint256) {
        return uint256(uint160(a)) | (1 << 160);
    }

    function _tget(uint256 k) private view returns (uint256 v) {
        assembly {
            v := tload(k)
        }
    }

    function _tset(uint256 k, uint256 v) private {
        assembly {
            tstore(k, v)
        }
    }
}

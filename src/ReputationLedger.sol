// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOpenFourCustomDataModule} from "./vendor/openfour/interfaces/IOpenFourCustomDataModule.sol";
import {IOpenFourModuleSchema} from "./vendor/openfour/interfaces/IOpenFourModuleSchema.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "./vendor/openfour/libraries/OpenFourTypes.sol";
import {ReputationRegistry} from "./ReputationRegistry.sol";
import {FeeQuote} from "./ReputationTypes.sol";
import {CashbackPool} from "./CashbackPool.sol";

/// @title ReputationLedger
/// @notice OpenFour customData module (one BeaconProxy per token). Core calls `afterHook` after every buy/sell; the
///         ledger recomputes what the trade module charged this wallet, reports the amounts paid to the pool and tracks
///         the wallet's curve position. A sale unlocks the sold fraction of the deposit and fees paid while the position
///         was open; `onMigrate` unlocks everything still open. Transfers are invisible here and unlock nothing.
/// @dev Registry and pool are `immutable`s of the implementation (carried over to every proxy). The fee amounts mirror
///      Core's tier arithmetic: amount = curveQuote * bps / 10_000, rounded down per tier. The payer is resolved exactly
///      as in `ReputationTradeModule.resolveWallet`. `tx.origin` is used only for accounting, never for authorization.
///      On a sell, its own fee (a sell pays no deposit, see `quoteDetailed`) is added to the open amounts first, so a full sale unlocks everything.
///      A sell with no tracked position (tokens that arrived by transfer) unlocks only what that sale itself paid.
contract ReputationLedger is Initializable, IOpenFourCustomDataModule, IOpenFourModuleSchema {
    uint256 private constant BPS = 10_000;

    struct Position {
        uint256 pos; // tokens bought on the curve and not yet sold on it
        uint256 depositOpen; // deposits paid while the position was open
        uint256 feeOpen; // POOL PART of the regular module fees (no treasury part, no deposit, no penalty) paid while open
        uint256 bonusOpen; // TREASURY PART of the regular fees paid while open (bonus right, owed from the scam fund)
    }

    ReputationRegistry public immutable REGISTRY;
    CashbackPool public immutable POOL;

    address public token;
    address public fourCore;
    uint64 public migratedAt;
    string private _moduleVersion;
    mapping(address => Position) public positions;

    event Settled(address indexed wallet, uint256 deposit, uint256 fee, uint64 at);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ReputationRegistry registry_, CashbackPool pool_) {
        require(address(registry_) != address(0) && address(pool_) != address(0), "Ledger: zero address");
        REGISTRY = registry_;
        POOL = pool_;
        _disableInitializers();
    }

    modifier onlyCore() {
        require(msg.sender == fourCore, "Ledger: only core");
        _;
    }

    function init(address token_, address fourCore_, bytes calldata params, string calldata moduleVersion_)
        external
        override
        initializer
    {
        require(token_ != address(0) && fourCore_ != address(0), "Ledger: zero address");
        require(params.length == 0, "Ledger: params not empty");
        token = token_;
        fourCore = fourCore_;
        _moduleVersion = moduleVersion_;
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.data.reputation_ledger";
        return (bytes8(keccak256(bytes(tag))), tag, _moduleVersion);
    }

    /// @notice Wallet charged for a trade by `trader`: the trader itself, or tx.origin for contracts (as the trade module).
    function resolveWallet(address trader) public view returns (address) {
        return trader.code.length > 0 ? tx.origin : trader;
    }

    function afterHook(OpenFourTypes.TradeHookContext calldata ctx) external override onlyCore {
        require(ctx.token == token, "Ledger: wrong token");
        address wallet = resolveWallet(ctx.trader);
        FeeQuote memory q = REGISTRY.quoteDetailed(wallet, ctx.isBuy);
        (uint256 poolAmt, uint256 deposit, uint256 fee, uint256 fundIn, uint256 bonus) = _amounts(wallet, q, ctx.curveQuote);

        Position storage ps = positions[wallet];
        ps.depositOpen += deposit;
        ps.feeOpen += fee;
        ps.bonusOpen += bonus;
        uint256 unlockDeposit;
        uint256 unlockFee;
        uint256 unlockBonus;
        if (ctx.isBuy) {
            ps.pos += ctx.executedAmount;
        } else {
            uint256 p = ps.pos;
            if (p == 0) {
                (unlockDeposit, unlockFee, unlockBonus) = (ps.depositOpen, ps.feeOpen, ps.bonusOpen);
            } else {
                uint256 sold = ctx.executedAmount < p ? ctx.executedAmount : p;
                unlockDeposit = Math.mulDiv(ps.depositOpen, sold, p);
                unlockFee = Math.mulDiv(ps.feeOpen, sold, p);
                unlockBonus = Math.mulDiv(ps.bonusOpen, sold, p);
                ps.pos = p - sold;
            }
            ps.depositOpen -= unlockDeposit;
            ps.feeOpen -= unlockFee;
            ps.bonusOpen -= unlockBonus;
        }
        if (poolAmt == 0 && bonus == 0 && unlockDeposit == 0 && unlockFee == 0 && unlockBonus == 0) return;
        POOL.report(
            ctx.token, wallet, poolAmt - deposit - fundIn, deposit, fundIn, bonus, unlockDeposit, unlockFee, unlockBonus,
            uint64(block.timestamp)
        );
    }

    /// @dev Splits what this trade really paid into the pool. Amounts that really arrived mirror the module's tiers
    ///      (each rounded down); if the pool is not the rewards recipient nothing arrived and nothing is recorded.
    ///      A wallet flagged at trade time pays its whole pool share into the fund: no cashback right, no bonus.
    ///      An honest wallet gets the pool part of its regular fee as cashback right and, when the treasury tier is a
    ///      separate recipient, the treasury part as bonus right (owed from the fund). With one collapsed tier (treasury = pool) there is no bonus right and that treasury part goes to the fund, as the treasury would have received it.
    function _amounts(address wallet, FeeQuote memory q, uint256 cq)
        private
        view
        returns (uint256 poolAmt, uint256 deposit, uint256 fee, uint256 fundIn, uint256 bonus)
    {
        if (q.pool != address(POOL)) return (0, 0, 0, 0, 0);
        bool collapsed = q.treasury == q.pool;
        poolAmt = collapsed ? cq * (q.treasuryBps + q.poolBps) / BPS : cq * q.poolBps / BPS;
        if (REGISTRY.isFlagged(wallet)) return (poolAmt, 0, 0, poolAmt, 0);
        // honest: no penalty; the pool tier before the deposit is the only cashback basis
        uint256 poolTier = cq * q.poolBps / BPS; // the treasury part of a collapsed tier is never cashback basis
        deposit = cq * q.depositBps / BPS;
        if (deposit > poolAmt) deposit = poolAmt;
        fee = poolTier > deposit ? poolTier - deposit : 0;
        if (collapsed) fundIn = poolAmt - poolTier; // the treasury part of the one tier: ownerless otherwise, so it joins the fund
        else bonus = cq * q.treasuryBps / BPS;
    }

    /// @dev Remembers the migration time; open positions are released lazily through `settle`.
    function onMigrate(OpenFourTypes.MigrateHookContext calldata ctx) external override onlyCore {
        require(ctx.token == token, "Ledger: wrong token");
        if (migratedAt == 0) migratedAt = uint64(block.timestamp);
    }

    /// @notice After migration, release a wallet's still-open deposit and fees (timestamp = migration time). Anyone may call.
    function settle(address wallet) external {
        uint64 at = migratedAt;
        require(at != 0, "Ledger: not migrated");
        Position memory ps = positions[wallet];
        if (ps.depositOpen == 0 && ps.feeOpen == 0 && ps.bonusOpen == 0 && ps.pos == 0) return;
        delete positions[wallet];
        emit Settled(wallet, ps.depositOpen, ps.feeOpen, at);
        if (ps.depositOpen != 0 || ps.feeOpen != 0 || ps.bonusOpen != 0) {
            POOL.report(token, wallet, 0, 0, 0, 0, ps.depositOpen, ps.feeOpen, ps.bonusOpen, at);
        }
    }

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("customData", 1, new ParamDescriptor[](0));
    }
}

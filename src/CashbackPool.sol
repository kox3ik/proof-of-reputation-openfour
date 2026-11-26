// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Config} from "./ReputationTypes.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Slice of OpenFourCore's public `tokens(address)` getter (compiler-generated, full tuple).
interface IOpenFourCoreTokens {
    function tokens(address token)
        external
        view
        returns (
            uint32 version,
            address creator,
            uint256 presetId,
            address token_,
            string memory name,
            string memory symbol,
            uint256 maxSupply,
            uint256 saleAmount,
            uint256 raiseAmount,
            address quoteAsset,
            address vault,
            address curveModule,
            address tradeModule,
            address migrateModule,
            address tokenModule,
            address customData,
            uint256 createBlock,
            bool exists,
            bool paused,
            bool antiSniperEnabled
        );
}

interface IReputationFlags {
    function coveredUntil() external view returns (uint64);
    function isFlagged(address wallet) external view returns (bool);
    function flaggedFrom(address wallet) external view returns (uint64);
    function config() external view returns (Config memory);
}

/// @title CashbackPool
/// @notice Global cashback pool: it IS the `rewardsPool` recipient of the trade module. Per-token `ReputationLedger`
///         instances (OpenFour customData, called by Core after every trade) track each wallet's curve position and
///         report what the wallet paid; when the wallet SELLS, the matching fraction of its fresh-wallet deposit (paid on buys only) and of
///         the module fees it paid becomes claimable. All amounts come from OpenFour's own post-trade hook; the only
///         trusted input is the rating registry's flags.
/// @dev Accounting per quote asset (WBNB etc., exact ERC-20 transfers; tokens with a transfer tax are unsupported):
///      `depositPool` = deposits received and not yet refunded or forfeited (always reserved, refunded in full);
///      `budgetPool`  = the honest wallets' own pool shares (cashback budget) not yet paid out;
///      `fund`        = the "scam fund": the whole pool share of every trade of a flagged wallet, plus deposits and
///                      cashback rights confiscated from rug sales. It pays the honest wallets' bonus (see below);
///      `bonusLiability` = bonus rights granted to honest wallets (open and unlocked) and not yet paid (written off only by a rug forfeit or the wallet's own partial claim).
///      Claim order for a wallet's unlocked bucket of one token: (1) rug sale -> nothing, its deposit and cashback right move to
///      `fund`, its bonus right is written off; (2) else deposit refunded in full, then cashback = min(unlocked own
///      fees, budgetPool), then bonus = the wallet's bonus right, paid in full from `fund` when fund >= bonusLiability; when the fund is short
///      `claim` pays no bonus and leaves the right owed (claimable in full after a refill), and only the wallet itself may
///      take a pro rata share through `claimBonusPartial` (fund / bonusLiability of the right, the rest written off).
///      `sweepSurplus` sends only `fund - bonusLiability` to the treasury; it never touches deposits or the budget.
///      Authenticity: `report` is accepted only from the `customData` instance that OpenFour Core itself bound to the
///      reported token, and only for tokens created with OUR preset (`bindPreset`, once). No owner withdrawal exists.
contract CashbackPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Unlocked (sold) amounts waiting for a claim, one bucket per (asset, token, wallet) = per position, so a sale of
    ///      one token never touches the refund of another token's closed position; `ts` is the latest sale/migration time folded in (conservative).
    struct Unlocked {
        uint256 deposit;
        uint256 fee;
        uint256 bonus;
        uint64 ts;
    }

    struct Ledger {
        address token;
        address quoteAsset;
    }

    IOpenFourCoreTokens public immutable CORE;
    IReputationFlags public immutable REGISTRY;

    uint256 public presetId;
    bool public presetBound;

    mapping(address => bool) public allowedAsset; // quote assets accepted at deploy (exact-transfer ERC-20s)
    mapping(address => Ledger) public ledgerOf; // verified customData instance => token + quote asset
    mapping(address => uint256) public depositPool; // asset => refundable deposits held
    mapping(address => uint256) public budgetPool; // asset => cashback budget
    mapping(address => uint256) public fund; // asset => scam fund (flagged wallets' pool shares + confiscations)
    mapping(address => uint256) public bonusLiability; // asset => bonus rights granted and not yet paid / written off
    mapping(address => mapping(address => mapping(address => Unlocked))) public unlocked; // asset => token => wallet => bucket (one per position)

    event PresetBound(uint256 presetId);
    event LedgerVerified(address indexed ledger, address indexed token, address indexed quoteAsset);
    event Inflow(address indexed asset, address indexed wallet, uint256 budget, uint256 deposit, uint256 fund, uint256 bonus);
    event Unlock(address indexed asset, address indexed wallet, uint256 deposit, uint256 fee, uint256 bonus, uint64 ts);
    event Claimed(address indexed asset, address indexed wallet, address indexed caller, uint256 deposit, uint256 cashback, uint256 bonus);
    event Forfeited(address indexed asset, address indexed wallet, uint256 deposit, uint256 fee, uint256 bonusWrittenOff);
    event Swept(address indexed asset, address indexed treasury, uint256 amount);

    error ZeroAddress();
    error PresetAlreadyBound();
    error PresetNotBound();
    error NotOurLedger();
    error FlagsNotPublished();
    error NotFlagged();
    error AssetNotAllowed();
    error NothingToClaim();
    error NothingToSweep();
    error Underfunded();
    error RenounceDisabled();

    constructor(address initialOwner, address core, address registry, address[] memory quoteAssets) Ownable(initialOwner) {
        if (core == address(0) || registry == address(0)) revert ZeroAddress();
        for (uint256 i; i < quoteAssets.length; ++i) {
            if (quoteAssets[i] == address(0)) revert ZeroAddress();
            allowedAsset[quoteAssets[i]] = true;
        }
        CORE = IOpenFourCoreTokens(core);
        REGISTRY = IReputationFlags(registry);
    }

    /// @notice Disabled: renouncing would leave the preset unbound forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice One-time: the OpenFour preset id whose tokens may report here. Nothing else is ever configurable.
    function bindPreset(uint256 presetId_) external onlyOwner {
        if (presetBound) revert PresetAlreadyBound();
        presetBound = true;
        presetId = presetId_;
        emit PresetBound(presetId_);
    }

    // ───────────────────────── ledger -> pool ─────────────────────────

    /// @notice Called by a token's ReputationLedger. `budgetIn` / `depositIn` / `fundIn` are quote units this trade already
    ///         paid to the pool (honest pool share, fresh deposit, whole pool share of a flagged wallet); `bonusIn` is the
    ///         bonus right granted to an honest wallet (not paid in; it is owed from the fund). `unlock*` are amounts
    ///         released by a sale (or migration) at `ts`.
    function report(
        address token,
        address wallet,
        uint256 budgetIn,
        uint256 depositIn,
        uint256 fundIn,
        uint256 bonusIn,
        uint256 unlockDeposit,
        uint256 unlockFee,
        uint256 unlockBonus,
        uint64 ts
    ) external {
        Ledger memory l = ledgerOf[msg.sender];
        if (l.token == address(0)) l = _verify(msg.sender, token);
        else if (l.token != token) revert NotOurLedger();
        address asset = l.quoteAsset;

        if (budgetIn != 0 || depositIn != 0 || fundIn != 0 || bonusIn != 0) {
            budgetPool[asset] += budgetIn;
            depositPool[asset] += depositIn;
            fund[asset] += fundIn;
            bonusLiability[asset] += bonusIn;
            emit Inflow(asset, wallet, budgetIn, depositIn, fundIn, bonusIn);
            // Solvency: the module pays the tiers to the pool before the ledger reports, so the pool must really hold
            // everything it now owes in cash (open deposits + budget + fund). A short payment reverts the whole trade.
            if (IERC20(asset).balanceOf(address(this)) < depositPool[asset] + budgetPool[asset] + fund[asset]) {
                revert Underfunded();
            }
        }
        if (unlockDeposit != 0 || unlockFee != 0 || unlockBonus != 0) {
            Unlocked storage u = unlocked[asset][l.token][wallet];
            u.deposit += unlockDeposit;
            u.fee += unlockFee;
            u.bonus += unlockBonus;
            if (ts > u.ts) u.ts = ts;
            emit Unlock(asset, wallet, unlockDeposit, unlockFee, unlockBonus, ts);
        }
    }

    /// @dev Core says: `token` exists, was created with our preset, and `ledger` is its customData instance.
    function _verify(address ledger, address token) private returns (Ledger memory l) {
        if (!presetBound) revert PresetNotBound();
        (,, uint256 pid,,,,,,, address quote,,,,,, address cd,, bool exists,,) = CORE.tokens(token);
        if (!exists || pid != presetId || cd != ledger || !allowedAsset[quote]) revert NotOurLedger();
        l = Ledger(token, quote);
        ledgerOf[ledger] = l;
        emit LedgerVerified(ledger, token, quote);
    }

    // ───────────────────────── claim ─────────────────────────

    /// @notice Pays out what the wallet's sales of `token` unlocked. Anyone may trigger it (e.g. a custodial terminal's user from
    ///         another wallet; the caller pays the gas), but funds only ever go to `wallet`.
    /// @dev Requires `registry.coveredUntil >= bucket timestamp`: a complete publication covers the sale, so a sale that
    ///      was part of a group dump is already flagged. A sale at or after the wallet's `flaggedFrom` (rug start): nothing, its deposit moves to the budget.
    ///      Otherwise the deposit is refunded in full, then cashback = min(released own fees, budgetPool); if the budget
    ///      is short, the unpaid remainder of the fee entitlement stays in the bucket and can be claimed later.
    function claim(address asset, address token, address wallet) external nonReentrant returns (uint256 depositOut, uint256 cashback) {
        return _claim(asset, token, wallet, false);
    }

    /// @notice The wallet itself accepts a partial bonus: like `claim`, but when the fund is short the bonus right is paid
    ///         pro rata `fund * right / bonusLiability` and the unpaid rest of that right is written off. Only the wallet
    ///         may call it (nobody else can make it give up part of its bonus). The fund-to-liability ratio does not
    ///         change, so the order of such claims never changes anyone's share.
    function claimBonusPartial(address asset, address token) external nonReentrant returns (uint256 depositOut, uint256 cashback) {
        return _claim(asset, token, msg.sender, true);
    }

    function _claim(address asset, address token, address wallet, bool takePartial) private returns (uint256 depositOut, uint256 cashback) {
        Unlocked memory u = _covered(asset, token, wallet);
        if (_rugSale(wallet, u.ts)) {
            _forfeit(asset, token, wallet, u);
            return (0, 0);
        }
        depositOut = u.deposit;
        cashback = u.fee < budgetPool[asset] ? u.fee : budgetPool[asset];
        depositPool[asset] -= depositOut;
        budgetPool[asset] -= cashback;
        (uint256 bonus, bool settled) = _payBonus(asset, u.bonus, takePartial);
        Unlocked storage s = unlocked[asset][token][wallet];
        s.deposit = 0;
        s.bonus = settled ? 0 : u.bonus; // an unpaid right stays whole in the bucket and in `bonusLiability`
        s.fee = u.fee - cashback; // unpaid remainder stays claimable
        if (s.fee == 0 && s.bonus == 0) delete unlocked[asset][token][wallet];
        if (depositOut + cashback + bonus != 0) IERC20(asset).safeTransfer(wallet, depositOut + cashback + bonus);
        emit Claimed(asset, wallet, msg.sender, depositOut, cashback, bonus);
    }

    /// @dev Bonus right `c` is paid in full when fund >= liability. When the fund is short: a plain claim pays nothing and
    ///      leaves the right untouched (so repeated or third-party claims can neither drain the fund nor write anything
    ///      off); the wallet's own partial claim pays `fund * c / liability` and writes off the rest of the right.
    function _payBonus(address asset, uint256 c, bool takePartial) private returns (uint256 b, bool settled) {
        if (c == 0) return (0, true);
        uint256 f = fund[asset];
        uint256 liability = bonusLiability[asset];
        if (f >= liability) b = c;
        else if (takePartial) b = Math.mulDiv(f, c, liability);
        else return (0, false);
        fund[asset] = f - b;
        bonusLiability[asset] = liability - c;
        return (b, true);
    }

    /// @notice Sends the part of the fund that exceeds every outstanding bonus right to the registry's treasury. Anyone
    ///         may call. Never touches deposits or the cashback budget.
    function sweepSurplus(address asset) external nonReentrant returns (uint256 amount) {
        uint256 f = fund[asset];
        uint256 liability = bonusLiability[asset];
        if (f <= liability) revert NothingToSweep();
        amount = f - liability;
        fund[asset] = liability;
        address treasury = REGISTRY.config().treasury;
        if (treasury == address(this)) revert NothingToSweep(); // a transfer to itself would drop the amount from the books
        IERC20(asset).safeTransfer(treasury, amount);
        emit Swept(asset, treasury, amount);
    }

    /// @notice Anyone may confiscate the deposit of a wallet that is flagged by a publication covering its sale.
    ///         Honest wallets cannot be touched this way: the flag is required.
    function forfeit(address asset, address token, address wallet) external nonReentrant {
        Unlocked memory u = _covered(asset, token, wallet);
        if (!_rugSale(wallet, u.ts)) revert NotFlagged();
        _forfeit(asset, token, wallet, u);
    }

    /// @dev Decided by the append-only flag history, not by today's flag: the bucket is forfeited when the wallet's rug activity
    ///      started at or before its (latest) sale. A wallet unflagged later stays forfeited; a wallet flagged only later keeps
    ///      the buckets of sales made before the rug started.
    function _rugSale(address wallet, uint64 saleTs) private view returns (bool) {
        uint64 f = REGISTRY.flaggedFrom(wallet);
        return f != 0 && f <= saleTs;
    }

    function _covered(address asset, address token, address wallet) private view returns (Unlocked memory u) {
        u = unlocked[asset][token][wallet];
        if (u.deposit == 0 && u.fee == 0 && u.bonus == 0) revert NothingToClaim();
        if (REGISTRY.coveredUntil() < u.ts) revert FlagsNotPublished();
    }

    /// @dev Confiscation: the deposit and the (budget-backed) cashback right move to the fund, the bonus right is
    ///      written off. The cashback right moves only as far as the budget still holds it.
    function _forfeit(address asset, address token, address wallet, Unlocked memory u) private {
        delete unlocked[asset][token][wallet];
        uint256 fee = u.fee < budgetPool[asset] ? u.fee : budgetPool[asset];
        depositPool[asset] -= u.deposit;
        budgetPool[asset] -= fee;
        fund[asset] += u.deposit + fee;
        bonusLiability[asset] -= u.bonus;
        emit Forfeited(asset, wallet, u.deposit, fee, u.bonus);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IOpenFourTradeModule} from "./vendor/openfour/interfaces/IOpenFourTradeModule.sol";
import {IOpenFourModuleSchema} from "./vendor/openfour/interfaces/IOpenFourModuleSchema.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "./vendor/openfour/libraries/OpenFourTypes.sol";
import {ReputationRegistry} from "./ReputationRegistry.sol";

/// @title ReputationTradeModule
/// @notice OpenFour Trade module that prices every curve trade by the on-chain reputation of the wallet.
/// @dev Creator-proof by construction: no init params, and the registry is an `immutable` of the implementation
///      (EIP-1167 clones delegate to this bytecode, so it carries over). All parameters live in the registry and
///      are controlled by the protocol admin only. The extra fee goes to protocol-set recipients, never the creator.
///
///      Wallet resolution: `ctx.trader` is frequently a terminal/router contract, so
///      `wallet = ctx.trader.code.length > 0 ? tx.origin : ctx.trader`.
///      KNOWN LIMITATION: with ERC-4337 bundlers or other relayers `tx.origin` is the relayer, not the user, so
///      such trades are priced by the relayer's reputation. Smart-contract wallets thus score as their origin.
///      `tx.origin` is used only for pricing in a view function, never for authorization.
contract ReputationTradeModule is Initializable, IOpenFourTradeModule, IOpenFourModuleSchema {
    ReputationRegistry public immutable REGISTRY;

    address public boundToken;
    address public fourCore;
    bytes private _initParams;
    string private _moduleVersion;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ReputationRegistry registry_) {
        require(address(registry_) != address(0), "Trade: zero registry");
        REGISTRY = registry_;
        _disableInitializers();
    }

    /// @dev No access control on purpose, same as OpenFour's own trade modules (`SimpleTradeModule`): OpenFour's
    ///      Deployer creates the per-token clone and calls `init` in the same transaction, `initializer` blocks any
    ///      second call, and the implementation itself is locked by `_disableInitializers()` in the constructor.
    function init(address token, address fourCore_, bytes calldata params, string calldata moduleVersion_)
        external
        override
        initializer
    {
        require(fourCore_ != address(0), "Trade: zero fourCore");
        require(params.length == 0, "Trade: params not empty");
        _initParams = params;
        _moduleVersion = moduleVersion_;
        boundToken = token;
        fourCore = fourCore_;
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.trade.reputation";
        return (bytes8(keccak256(bytes(tag))), tag, _moduleVersion);
    }

    function evaluate(OpenFourTypes.TradeContext calldata ctx)
        external
        view
        override
        returns (OpenFourTypes.TradeResult memory result)
    {
        require(fourCore != address(0), "Trade: not initialized");
        require(ctx.token == boundToken, "Trade: wrong token");

        address wallet = resolveWallet(ctx.trader);
        (uint256 total, uint256 treasuryBps, uint256 rewardsBps, address treasury, address rewards) =
            REGISTRY.quote(wallet, ctx.isBuy);

        result.maxAmount = type(uint256).max;
        result.allowed = true; // nobody is banned: every wallet trades at the fee its score gives
        result.fees = _tiers(total, treasuryBps, rewardsBps, treasury, rewards);
    }

    /// @notice Wallet whose reputation prices a trade by `trader`: the trader itself, or tx.origin for contracts.
    function resolveWallet(address trader) public view returns (address) {
        return trader.code.length > 0 ? tx.origin : trader;
    }

    /// @notice UI helper: fee in bps (total extra, on top of OpenFour fees) a wallet would pay on a buy/sell.
    function quoteFeeBps(address wallet, bool isBuy) external view returns (uint256) {
        return REGISTRY.quoteFeeBps(wallet, isBuy);
    }

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        return ModuleEncodeSchema("trade", 1, new ParamDescriptor[](0));
    }

    function getInitParams() external view returns (bytes memory) {
        return _initParams;
    }

    /// @dev At most two tiers; zero-bps tiers are skipped. Registry guarantees non-zero recipients and total <= 1000.
    function _tiers(uint256 total, uint256 treasuryBps, uint256 rewardsBps, address treasury, address rewards)
        private
        pure
        returns (OpenFourTypes.FeeTier[] memory tiers)
    {
        require(total <= 1000, "Trade: fee cap");
        if (treasury == rewards) {
            // one recipient: a single tier carrying the whole fee (the FeeRouter may reject duplicate recipients)
            tiers = new OpenFourTypes.FeeTier[](total > 0 ? 1 : 0);
            if (total > 0) tiers[0] = OpenFourTypes.FeeTier(treasury, uint16(total));
            return tiers;
        }
        uint256 n = (treasuryBps > 0 ? 1 : 0) + (rewardsBps > 0 ? 1 : 0);
        tiers = new OpenFourTypes.FeeTier[](n);
        uint256 i;
        if (treasuryBps > 0) tiers[i++] = OpenFourTypes.FeeTier(treasury, uint16(treasuryBps));
        if (rewardsBps > 0) tiers[i] = OpenFourTypes.FeeTier(rewards, uint16(rewardsBps));
    }
}

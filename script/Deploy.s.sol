// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ReputationTradeModule} from "../src/ReputationTradeModule.sol";
import {Config} from "../src/ReputationTypes.sol";
import {ReputationLockedToken} from "../src/ReputationLockedToken.sol";
import {CashbackPool} from "../src/CashbackPool.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";

/// @notice Deploys CashbackPool + ReputationLedger (customData implementation) + ReputationRegistry + ReputationTradeModule (implementation) + ReputationLockedToken (token implementation).
/// @dev Env: DEPLOYER_PRIVATE_KEY (required), REGISTRY_OWNER, UPDATER, TREASURY, OPENFOUR_CORE (required: OpenFourCore of the chain / fork), QUOTE_ASSET (required: the one allowed quote asset, WBNB for the demo), ZERO_BPS (fee of a score-0 wallet, default 50), FRESH_DEPOSIT_BPS (default 640), PENALTY_BPS (default 640; owner options: deposit = penalty = 900 or 640),
///      BAB_TOKEN (BABT SBT, mainnet 0x2B09d47D550061f995A3b5C6F0Fd58005215D7c8) / AGENT_ID_TOKEN (SPACE ID Agent ID ERC-721, mainnet 0x60b9262456de011f7d15a54cdd8c48baaa8b022f); default 0 = disabled, BAB_IDENTITY / AGENT_IDENTITY
///      (default 700 / 500), CONFIG_DELAY (seconds; default 0 on local/testnet chain ids 31337/97/5611, otherwise 86400).
///      Writes addresses to $POR_OUT_JSON (default deployments/por-deployment.json).
contract Deploy is Script {
    function _isTestChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 97 || block.chainid == 5611;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner_ = vm.envOr("REGISTRY_OWNER", deployer);
        address updater_ = vm.envOr("UPDATER", deployer);

        // The pool is the rewardsPool recipient and needs the registry; the registry config needs the pool address:
        // the pool is the deployer's next contract after the registry (nonce + 1).
        address core = vm.envAddress("OPENFOUR_CORE");
        address poolAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        Config memory c = Config({
            wVolume: 30,
            wActivity: 25,
            wHolding: 25,
            wIdentity: 20,
            penaltyWeight: 1000,
            flagThreshold: 700,
            neutralScore: 400,
            zeroBps: uint16(vm.envOr("ZERO_BPS", uint256(50))),
            neutralBps: 50,
            minBps: 0,
            sellCapBps: 100,
            treasuryShareBps: 5000,
            treasury: vm.envOr("TREASURY", deployer),
            rewardsPool: poolAddr,
            configDelay: uint32(vm.envOr("CONFIG_DELAY", _isTestChain() ? uint256(0) : uint256(86400))),
            babToken: vm.envOr("BAB_TOKEN", address(0)),
            agentIdToken: vm.envOr("AGENT_ID_TOKEN", address(0)),
            babIdentity: uint16(vm.envOr("BAB_IDENTITY", uint256(700))),
            agentIdentity: uint16(vm.envOr("AGENT_IDENTITY", uint256(500))),
            freshDepositBps: uint16(vm.envOr("FRESH_DEPOSIT_BPS", uint256(640))),
            penaltyBps: uint16(vm.envOr("PENALTY_BPS", uint256(640)))
        });

        vm.startBroadcast(pk);
        ReputationRegistry registry = new ReputationRegistry(owner_, updater_, c);
        address[] memory quoteAssets = new address[](1);
        quoteAssets[0] = vm.envAddress("QUOTE_ASSET");
        CashbackPool pool = new CashbackPool(owner_, core, address(registry), quoteAssets);
        require(address(pool) == poolAddr, "Deploy: pool address mismatch");
        ReputationLedger ledger = new ReputationLedger(registry, pool);
        ReputationTradeModule module_ = new ReputationTradeModule(registry);
        ReputationLockedToken lockedToken = new ReputationLockedToken(registry);
        vm.stopBroadcast();

        console2.log("ReputationLockedToken", address(lockedToken));
        console2.log("CashbackPool         ", address(pool));
        console2.log("ReputationLedger     ", address(ledger));
        console2.log("ReputationRegistry   ", address(registry));
        console2.log("ReputationTradeModule", address(module_));

        string memory k = "por";
        vm.serializeAddress(k, "pool", address(pool));
        vm.serializeAddress(k, "ledger", address(ledger));
        vm.serializeAddress(k, "registry", address(registry));
        vm.serializeAddress(k, "tradeModule", address(module_));
        string memory json = vm.serializeAddress(k, "lockedToken", address(lockedToken));
        vm.writeJson(json, vm.envOr("POR_OUT_JSON", string("deployments/por-deployment.json")));
    }
}

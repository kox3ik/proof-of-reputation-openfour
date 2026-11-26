// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {Components, Config} from "../src/ReputationTypes.sol";

/// @dev Shared fixtures: default config, deployed registry, helpers to publish components.
abstract contract Base is Test {
    address internal admin = makeAddr("admin");
    address internal updater = makeAddr("updater");
    address internal treasury = makeAddr("treasury");
    address internal rewards = makeAddr("rewards");
    address internal alice = makeAddr("alice");

    ReputationRegistry internal registry;

    function defaultConfig() internal view returns (Config memory) {
        return Config({
            wVolume: 30,
            wActivity: 25,
            wHolding: 25,
            wIdentity: 20,
            penaltyWeight: 1000,
            flagThreshold: 700,
            neutralScore: 400,
            zeroBps: 300,
            neutralBps: 100,
            minBps: 0,
            sellCapBps: 100,
            treasuryShareBps: 5000,
            treasury: treasury,
            rewardsPool: rewards,
            configDelay: 1 days,
            babToken: address(0),
            agentIdToken: address(0),
            babIdentity: 700,
            agentIdentity: 500,
            freshDepositBps: 0,
            penaltyBps: 0
        });
    }

    function _deploy(Config memory c) internal {
        registry = new ReputationRegistry(admin, updater, c);
    }

    /// @dev `publish` bound to the previous block (the caller sets vm.prank first; blockhash is not an external call).
    function _pub(uint64 epoch, address[] memory w, Components[] memory c, uint64 cov) internal {
        uint64[] memory since = new uint64[](w.length);
        for (uint256 i; i < w.length; ++i) since[i] = cov; // flags are dated at the coverage edge unless a test says otherwise
        registry.publish(epoch, w, c, cov, uint64(block.number - 1), blockhash(block.number - 1), since);
    }

    uint64 internal flagEpoch = 1000;

    /// @dev Flag `wallet` with its rug activity starting at `from`, in a complete publication covering up to `cov`.
    function _flagSince(address wallet, uint64 from, uint64 cov) internal {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        uint64[] memory since = new uint64[](1);
        w[0] = wallet;
        c[0] = Components(0, 0, 0, 0, 900);
        since[0] = from;
        vm.prank(updater);
        registry.publish(++flagEpoch, w, c, cov, uint64(block.number - 1), blockhash(block.number - 1), since);
    }

    /// @dev `publish` with explicit `flaggedFrom` per wallet.
    function _pubSince(uint64 epoch, address[] memory w, Components[] memory c, uint64 cov, uint64[] memory since) internal {
        registry.publish(epoch, w, c, cov, uint64(block.number - 1), blockhash(block.number - 1), since);
    }

    /// @dev Publish components with all four positive parts = `pos` and the given penalty.
    function _publish(address wallet, uint16 pos, uint16 penalty) internal {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        w[0] = wallet;
        c[0] = Components(pos, pos, pos, pos, penalty);
        vm.prank(updater);
        registry.setScores(1, w, c);
    }
}

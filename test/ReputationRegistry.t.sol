// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {ReputationMath} from "../src/ReputationMath.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {Components, Config, PendingConfig} from "../src/ReputationTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ReputationRegistryTest is Base {
    function setUp() public {
        _deploy(defaultConfig());
    }

    // ── curve ──

    function test_curveEndpoints() public view {
        Config memory c = defaultConfig();
        assertEq(ReputationMath.feeBps(0, c), c.zeroBps);
        assertEq(ReputationMath.feeBps(c.neutralScore, c), c.neutralBps);
        assertEq(ReputationMath.feeBps(1000, c), c.minBps);
    }

    function test_curveMonotonicAllScores() public view {
        Config memory c = defaultConfig();
        uint256 prev = type(uint256).max;
        for (uint256 s; s <= 1000; ++s) {
            uint256 f = ReputationMath.feeBps(s, c);
            assertLe(f, prev, "not monotonic");
            assertLe(f, c.zeroBps);
            assertGe(f, c.minBps);
            prev = f;
        }
    }

    function test_curveSmoothNoLargeStep() public view {
        Config memory c = defaultConfig();
        for (uint256 s; s < 1000; ++s) {
            uint256 a = ReputationMath.feeBps(s, c);
            uint256 b = ReputationMath.feeBps(s + 1, c);
            assertLe(a - b, 2, "step too large");
        }
    }

    function test_sellFeeCappedAndMonotonicAllScores() public {
        uint256 prev = type(uint256).max;
        for (uint16 s; s <= 1000; ++s) {
            _publish(alice, s, 0);
            assertEq(registry.scoreOf(alice), s);
            uint256 buy = registry.quoteFeeBps(alice, true);
            uint256 sell = registry.quoteFeeBps(alice, false);
            assertLe(sell, 100, "sell cap");
            assertLe(sell, buy);
            assertLe(buy, prev);
            prev = buy;
        }
    }

    function test_unknownWalletIsFreshAndPaysMax() public view {
        assertEq(registry.scoreOf(alice), 0);
        assertEq(registry.quoteFeeBps(alice, true), 300);
        assertEq(registry.quoteFeeBps(alice, false), 100);
    }

    // ── score ──

    function test_scoreWeightedAverageMinusPenalty() public {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        w[0] = alice;
        c[0] = Components(1000, 0, 0, 0, 0);
        vm.prank(updater);
        registry.setScores(1, w, c);
        assertEq(registry.scoreOf(alice), 300); // 1000 * 30 / 100
        c[0] = Components(1000, 1000, 1000, 1000, 100);
        vm.prank(updater);
        registry.setScores(1, w, c);
        assertEq(registry.scoreOf(alice), 900);
        c[0] = Components(100, 100, 100, 100, 500);
        vm.prank(updater);
        registry.setScores(1, w, c);
        assertEq(registry.scoreOf(alice), 0); // clamped
    }

    function test_flagged() public {
        _publish(alice, 500, 699);
        assertFalse(registry.isFlagged(alice));
        _publish(alice, 500, 700);
        assertTrue(registry.isFlagged(alice));
    }

    function test_feeSplitSumsToTotal() public {
        for (uint16 s; s <= 1000; s += 7) {
            _publish(alice, s, 0);
            (uint256 total, uint256 t, uint256 r,,) = registry.quote(alice, true);
            assertEq(t + r, total);
            assertLe(total, 1000);
        }
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(ReputationRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), admin);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.renounceOwnership();
    }

    function test_flaggedSellAndBuyBothUncapped() public {
        _publish(alice, 0, 900);
        assertTrue(registry.isFlagged(alice));
        assertEq(registry.quoteFeeBps(alice, false), 300); // sell cap does not apply to flagged wallets
        assertEq(registry.quoteFeeBps(alice, true), 300);
    }

    // ── access control ──

    function test_onlyUpdaterSetsScores() public {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotUpdater.selector);
        registry.setScores(1, w, c);
        vm.prank(admin);
        vm.expectRevert(ReputationRegistry.NotUpdater.selector);
        registry.setScores(1, w, c);
    }

    function test_setScoresEmitsEpochAndValidates() public {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        w[0] = alice;
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.ScoresUpdated(5, 1);
        vm.prank(updater);
        registry.setScores(5, w, c);
        assertEq(registry.currentEpoch(), 5);

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.EpochRegression.selector, 4, 5));
        registry.setScores(4, w, c);

        c[0].penalty = 1001;
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ComponentOutOfRange.selector, alice));
        registry.setScores(5, w, c);

        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.LengthMismatch.selector);
        registry.setScores(5, w, new Components[](0));
    }

    function test_onlyAdminProposes() public {
        Config memory c = defaultConfig();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.proposeConfig(c);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, updater));
        registry.setUpdater(alice);
    }

    // ── timelock ──

    function test_configDelayEnforced() public {
        Config memory c = defaultConfig();
        c.zeroBps = 500;
        vm.prank(admin);
        registry.proposeConfig(c);
        uint64 at = uint64(block.timestamp + 1 days);
        assertEq(registry.pendingConfig().activateAt, at);

        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.TooEarly.selector, at));
        registry.activateConfig();
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.TooEarly.selector, at));
        registry.activateConfig();
        assertEq(registry.config().zeroBps, 300);

        vm.warp(at);
        registry.activateConfig();
        assertEq(registry.config().zeroBps, 500);
        assertEq(registry.pendingConfig().activateAt, 0);
        vm.expectRevert(ReputationRegistry.NothingPending.selector);
        registry.activateConfig();
    }

    function test_cancelPending() public {
        vm.startPrank(admin);
        vm.expectRevert(ReputationRegistry.NothingPending.selector);
        registry.cancelPendingConfig();
        registry.proposeConfig(defaultConfig());
        registry.cancelPendingConfig();
        vm.stopPrank();
        vm.expectRevert(ReputationRegistry.NothingPending.selector);
        registry.activateConfig();
    }

    // ── config validation ──

    function _expectInvalid(Config memory c, string memory reason) internal {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, reason));
        registry.proposeConfig(c);
    }

    function test_invalidConfigsRejected() public {
        Config memory c = defaultConfig();
        c.wVolume = 0;
        c.wActivity = 0;
        c.wHolding = 0;
        c.wIdentity = 0;
        _expectInvalid(c, "weights sum zero");

        c = defaultConfig();
        c.treasury = address(0);
        _expectInvalid(c, "zero recipient");
        c = defaultConfig();
        c.rewardsPool = address(0);
        _expectInvalid(c, "zero recipient");

        c = defaultConfig();
        c.zeroBps = 1001;
        _expectInvalid(c, "zeroBps > cap");
        c = defaultConfig();
        c.sellCapBps = 1001;
        _expectInvalid(c, "sellCap > cap");
        c = defaultConfig();
        c.neutralBps = 301;
        _expectInvalid(c, "curve order");
        c = defaultConfig();
        c.minBps = 101;
        _expectInvalid(c, "curve order");
        c = defaultConfig();
        c.neutralScore = 1000;
        _expectInvalid(c, "neutralScore");
        c = defaultConfig();
        c.flagThreshold = 0;
        _expectInvalid(c, "flagThreshold");
        c = defaultConfig();
        c.treasuryShareBps = 10_001;
        _expectInvalid(c, "treasuryShare");
        c = defaultConfig();
        c.configDelay = 8 days;
        _expectInvalid(c, "configDelay");
    }

    function test_constructorValidates() public {
        Config memory c = defaultConfig();
        c.treasury = address(0);
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "zero recipient"));
        new ReputationRegistry(admin, updater, c);
    }

    function test_fuzzCurveMonotonic(uint16 z, uint16 n, uint16 m, uint16 ns, uint16 s) public pure {
        z = uint16(bound(z, 0, 1000));
        n = uint16(bound(n, 0, z));
        m = uint16(bound(m, 0, n));
        Config memory c;
        c.neutralScore = uint16(bound(ns, 1, 999));
        c.zeroBps = z;
        c.neutralBps = n;
        c.minBps = m;
        uint256 sc = bound(s, 0, 999);
        assertGe(ReputationMath.feeBps(sc, c), ReputationMath.feeBps(sc + 1, c));
        assertLe(ReputationMath.feeBps(sc, c), z);
    }

    // ── real-time publish (batch + coveredUntil in one tx) ──

    function _batch(uint256 n, uint16 pen) internal pure returns (address[] memory w, Components[] memory c) {
        w = new address[](n);
        c = new Components[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = address(uint160(0x1000 + i));
            c[i] = Components(700, 600, 500, 0, pen);
        }
    }

    function test_publishWritesBatchAndAdvancesCoverage() public {
        vm.warp(10_000);
        (address[] memory w, Components[] memory c) = _batch(2, 1000);
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.ScoresUpdated(3, 2);
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.EpochFinalized(3, 9_990);
        vm.prank(updater);
        _pub(3, w, c, 9_990);
        assertEq(registry.currentEpoch(), 3);
        assertEq(registry.coveredUntil(), 9_990);
        assertTrue(registry.isFlagged(w[0]));
        assertEq(registry.componentsOf(w[1]).volume, 700);
    }

    function test_publishEmptyBatchMovesCoverageOnly() public {
        vm.warp(10_000);
        vm.prank(updater);
        _pub(1, new address[](0), new Components[](0), 9_000);
        vm.prank(updater);
        _pub(2, new address[](0), new Components[](0), 9_000); // same coverage is allowed
        assertEq(registry.coveredUntil(), 9_000);
        assertEq(registry.currentEpoch(), 2);
    }

    function test_publishIsBoundToItsSourceBlock() public {
        vm.warp(10_000);
        vm.roll(1_000);
        (address[] memory w, Components[] memory c) = _batch(1, 1000);
        uint64[] memory sn = new uint64[](1);
        sn[0] = 9_000;
        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.BadSource.selector);
        registry.publish(1, w, c, 9_000, 999, bytes32(uint256(1)), sn); // hash of another branch
        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.BadSource.selector);
        registry.publish(1, w, c, 9_000, 999, bytes32(0), sn);
        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.BadSource.selector);
        registry.publish(1, w, c, 9_000, 1_000, blockhash(999), sn); // source must be an earlier block
        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.BadSource.selector);
        registry.publish(1, w, c, 9_000, 600, blockhash(600), sn); // older than 256 blocks
        vm.prank(updater);
        registry.publish(1, w, c, 9_000, 999, blockhash(999), sn);
        assertEq(registry.coveredUntil(), 9_000);
        // the same call is replayed after a reorg: blockhash(999) differs on the new branch
        vm.roll(1_000);
        vm.setBlockhash(999, bytes32(uint256(0xbeef)));
        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.BadSource.selector);
        registry.publish(2, w, c, 9_001, 999, keccak256(abi.encodePacked(uint256(999))), sn);
    }

    function test_publishChecks() public {
        vm.warp(10_000);
        (address[] memory w, Components[] memory c) = _batch(1, 0);
        vm.prank(alice);
        vm.expectRevert(ReputationRegistry.NotUpdater.selector);
        _pub(1, w, c, 9_000);

        vm.prank(updater);
        vm.expectRevert(ReputationRegistry.LengthMismatch.selector);
        _pub(1, w, new Components[](0), 9_000);

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.BadFinalization.selector));
        _pub(1, w, c, 10_000); // coverage must lie strictly in the past

        c[0].identity = 1001;
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.ComponentOutOfRange.selector, w[0]));
        _pub(1, w, c, 9_000);
        c[0].identity = 0;

        vm.prank(updater);
        _pub(5, w, c, 9_000);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.EpochRegression.selector, 4, 5));
        _pub(4, w, c, 9_500);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.BadFinalization.selector));
        _pub(6, w, c, 8_999); // coverage never moves back
    }

    function test_publishRevertRollsBackBatch() public {
        vm.warp(10_000);
        (address[] memory w, Components[] memory c) = _batch(1, 1000);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.BadFinalization.selector));
        _pub(1, w, c, 10_001);
        assertFalse(registry.isFlagged(w[0]));
        assertEq(registry.currentEpoch(), 0);
    }

    function test_oldFunctionsStillWork() public {
        vm.warp(10_000);
        (address[] memory w, Components[] memory c) = _batch(1, 1000);
        vm.startPrank(updater);
        registry.setScores(7, w, c);
        registry.finalizeEpoch(7, 9_000);
        _pub(7, w, c, 9_100); // publish may reuse the epoch of the last batch (same checks as setScores)
        vm.stopPrank();
        assertEq(registry.coveredUntil(), 9_100);
    }

    function _gasOfPublish(uint256 n, uint64 epoch) internal returns (uint256 used) {
        (address[] memory w, Components[] memory c) = _batch(n, 1000);
        vm.prank(updater);
        uint256 g = gasleft();
        _pub(epoch, w, c, 9_000 + epoch);
        used = g - gasleft();
    }

    /// @dev Gas of one publish with 1 / 10 / 100 NEW wallets (cold writes: worst case) and then 100 rewrites.
    function test_publishGas() public {
        vm.warp(10_000);
        uint256 g1 = _gasOfPublish(1, 1);
        uint256 g10 = _gasOfPublish(10, 2); // wallets 0..9 already exist: rewrites
        registry.currentEpoch();
        emit log_named_uint("publish gas, 1 wallet (new)", g1);
        emit log_named_uint("publish gas, 10 wallets (1 rewrite + 9 new)", g10);
        (address[] memory w, Components[] memory c) = _batch(100, 1000);
        for (uint256 i; i < 100; ++i) w[i] = address(uint160(0x9000 + i));
        vm.prank(updater);
        uint256 g = gasleft();
        _pub(3, w, c, 9_100);
        uint256 g100 = g - gasleft();
        emit log_named_uint("publish gas, 100 wallets (new)", g100);
        vm.prank(updater);
        g = gasleft();
        _pub(4, w, c, 9_101);
        emit log_named_uint("publish gas, 100 wallets (rewrite, same values)", g - gasleft());
        assertLt(g100, 5_500_000); // every wallet here is a flag: its flaggedFrom is one more new slot
    }
}

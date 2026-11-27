// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {ReputationMath} from "../src/ReputationMath.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {Components, Config} from "../src/ReputationTypes.sol";
import {
    MockIdentityToken,
    RevertingToken,
    GuzzlerToken,
    ShortReturnToken,
    ReturnBombToken,
    GarbageToken
} from "./mocks/IdentityMocks.sol";

contract IdentityTest is Base {
    MockIdentityToken internal bab;
    MockIdentityToken internal agent;
    address internal bob = makeAddr("bob");

    function setUp() public {
        bab = new MockIdentityToken();
        agent = new MockIdentityToken();
        Config memory c = defaultConfig();
        c.babToken = address(bab);
        c.agentIdToken = address(agent);
        _deploy(c);
        _set(alice, 300, 0); // alice: stored positives 300, stored identity 0 -> set below
    }

    function _set(address w, uint16 pos, uint16 identity) internal {
        address[] memory ws = new address[](1);
        Components[] memory cs = new Components[](1);
        ws[0] = w;
        cs[0] = Components(pos, pos, pos, identity, 0);
        vm.prank(updater);
        registry.setScores(1, ws, cs);
    }

    function _deployWith(address babAddr, address agentAddr) internal {
        Config memory c = defaultConfig();
        c.babToken = babAddr;
        c.agentIdToken = agentAddr;
        _deploy(c);
        _set(alice, 300, 0);
    }

    function test_noTokenHeldKeepsStored() public view {
        assertEq(registry.effectiveIdentity(alice), 0);
    }

    function test_babRaisesIdentityAndLowersFee() public {
        uint256 before_ = registry.quoteFeeBps(alice, true);
        uint256 scoreBefore = registry.scoreOf(alice);
        bab.mint(alice);
        assertEq(registry.effectiveIdentity(alice), 700);
        assertGt(registry.scoreOf(alice), scoreBefore);
        assertLt(registry.quoteFeeBps(alice, true), before_);
        (uint256 total,,,,) = registry.quote(alice, true);
        assertEq(total, registry.quoteFeeBps(alice, true));
    }

    function test_agentIdRaisesIdentity() public {
        agent.mint(alice);
        assertEq(registry.effectiveIdentity(alice), 500);
    }

    function test_bothTakesMax() public {
        bab.mint(alice);
        agent.mint(alice);
        assertEq(registry.effectiveIdentity(alice), 700);
        // other order of magnitudes: agent worth more than bab
        Config memory c = defaultConfig();
        c.babToken = address(bab);
        c.agentIdToken = address(agent);
        c.babIdentity = 400;
        c.agentIdentity = 900;
        _deploy(c);
        assertEq(registry.effectiveIdentity(alice), 900);
    }

    function test_storedHigherThanGrantedIsKept() public {
        _set(alice, 300, 950);
        bab.mint(alice);
        agent.mint(alice);
        assertEq(registry.effectiveIdentity(alice), 950);
    }

    function test_zeroAddressDisablesChecks() public {
        _deployWith(address(0), address(0));
        assertEq(registry.effectiveIdentity(alice), 0);
        assertEq(registry.effectiveIdentity(address(0)), 0);
    }

    function test_otherWalletUnaffected() public {
        bab.mint(alice);
        assertEq(registry.effectiveIdentity(bob), 0);
    }

    function test_unknownWalletWithBabGetsIdentityScore() public {
        bab.mint(bob);
        // unknown wallet: only identity weight (20/100) * 700 = 140
        assertEq(registry.scoreOf(bob), 140);
    }

    function test_flaggedWalletStaysFlaggedDespiteBab() public {
        address[] memory ws = new address[](1);
        Components[] memory cs = new Components[](1);
        ws[0] = alice;
        cs[0] = Components(900, 900, 900, 900, 800);
        vm.prank(updater);
        registry.setScores(2, ws, cs);
        bab.mint(alice);
        assertTrue(registry.isFlagged(alice));
    }

    // ── config validation ──

    function test_configRejectsNonContractIdentityAddresses() public {
        Config memory c = defaultConfig();
        c.babToken = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "babToken not a contract"));
        vm.prank(admin);
        registry.proposeConfig(c);

        c.babToken = address(bab);
        c.agentIdToken = makeAddr("eoa2");
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "agentIdToken not a contract"));
        vm.prank(admin);
        registry.proposeConfig(c);

        c.agentIdToken = makeAddr("eoa3");
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "agentIdToken not a contract"));
        new ReputationRegistry(admin, updater, c);
    }

    function test_configRejectsIdentityValueAboveMax() public {
        Config memory c = defaultConfig();
        c.babIdentity = 1001;
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "identity value"));
        vm.prank(admin);
        registry.proposeConfig(c);
        c.babIdentity = 1000;
        c.agentIdentity = 1001;
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "identity value"));
        vm.prank(admin);
        registry.proposeConfig(c);
        c.agentIdentity = 1000; // boundary is fine
        vm.prank(admin);
        registry.proposeConfig(c);
    }

    // ── hostile tokens: never revert, behaviour is defined ──

    function _gasOfScore() internal view returns (uint256 g) {
        g = gasleft();
        registry.scoreOf(alice);
        registry.quoteFeeBps(alice, true);
        g = g - gasleft();
    }

    function test_revertingTokenCountsAsNotHeld() public {
        _deployWith(address(new RevertingToken()), address(new RevertingToken()));
        assertEq(registry.effectiveIdentity(alice), 0);
        assertEq(registry.quoteFeeBps(alice, true), registry.quoteFeeBps(alice, true));
    }

    function test_guzzlerTokenIsGasBoundedAndNotHeld() public {
        _deployWith(address(new GuzzlerToken()), address(new GuzzlerToken()));
        uint256 g = _gasOfScore();
        assertEq(registry.effectiveIdentity(alice), 0);
        // 2 tokens x 2 calls x 30k cap + overhead, well under 300k
        assertLt(g, 300_000, "scoring gas not bounded");
    }

    function test_shortReturnCountsAsNotHeld() public {
        _deployWith(address(new ShortReturnToken()), address(new ShortReturnToken()));
        assertEq(registry.effectiveIdentity(alice), 0);
    }

    function test_returnBombHugeIsNotHeldAndBounded() public {
        // 1 MB: memory expansion on the callee side exceeds the 30k cap -> out of gas -> not held
        _deployWith(address(new ReturnBombToken(1_000_000)), address(new ReturnBombToken(1_000_000)));
        uint256 g = _gasOfScore();
        assertEq(registry.effectiveIdentity(alice), 0);
        assertLt(g, 300_000);
    }

    function test_returnBombSmallOnlyFirstWordRead() public {
        // 3000 bytes fits inside the cap; only the first 32 bytes are copied back (word = 1 -> held)
        _deployWith(address(new ReturnBombToken(3000)), address(0));
        uint256 g = _gasOfScore();
        assertEq(registry.effectiveIdentity(alice), 700);
        assertLt(g, 300_000);
    }

    function test_garbageNonZeroWordCountsAsHeld() public {
        // documented behaviour: any non-zero word = held; tokens are chosen by the timelocked owner
        _deployWith(address(new GarbageToken()), address(0));
        assertEq(registry.effectiveIdentity(alice), 700);
        assertLe(registry.scoreOf(alice), 1000);
    }

    function test_realTokenGasIsSmall() public {
        bab.mint(alice);
        agent.mint(alice);
        assertLt(_gasOfScore(), 80_000);
    }

    // ── freshness: the soulbound but cheaply minted Agent ID never waives the deposit, the non-transferable BAB does ──

    function _freshDepositConfig() internal {
        Config memory c = defaultConfig();
        c.babToken = address(bab);
        c.agentIdToken = address(agent);
        c.freshDepositBps = 150;
        _deploy(c);
    }

    /// @dev The deposit falls smoothly with the score: identity (Agent ID 500, BAB 700, weight 20 %) lowers it gradually.
    function test_agentIdLowersDepositSmoothlyButDoesNotWaiveIt() public {
        _freshDepositConfig();
        uint256 none = registry.quoteDetailed(bob, true).depositBps;
        assertEq(none, 150); // score 0: full deposit
        agent.mint(bob);
        assertEq(registry.effectiveIdentity(bob), 500);
        assertEq(registry.quoteDetailed(bob, true).depositBps, 112); // score 100: 150 * 300 / 400
    }

    function test_agentIdOnManyCheapWalletsPaysTheSameSmoothDeposit() public {
        _freshDepositConfig();
        for (uint256 i; i < 5; ++i) {
            address w = address(uint160(0xA000 + i));
            agent.mint(w);
            assertEq(registry.quoteDetailed(w, true).depositBps, 112);
        }
    }

    function test_babHolderPaysASmallerDeposit() public {
        _freshDepositConfig();
        bab.mint(bob);
        assertEq(registry.quoteDetailed(bob, true).depositBps, 97); // score 140: 150 * 260 / 400
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";
import {TestToken} from "./CashbackDistributor.t.sol";

/// @dev Proves the off-chain builder (scripts/cashback_root.py) and the contract agree on leaf and tree format.
///      Fixture: test/fixtures/cashback-output.json, produced by
///      `python3 scripts/cashback_root.py test/fixtures/cashback-input.json -o test/fixtures/cashback-output.json`.
contract CashbackFixtureTest is Test {
    CashbackDistributor internal d;
    address internal updater = makeAddr("updater");
    string internal json;

    function setUp() public {
        vm.warp(1000 days);
        d = new CashbackDistributor(makeAddr("owner"), updater, 30 days);
        json = vm.readFile("test/fixtures/cashback-output.json");
    }

    function _key(uint256 r, string memory f) internal pure returns (string memory) {
        return string.concat(".rounds[", vm.toString(r), "].", f);
    }

    function _claimKey(uint256 r, uint256 i, string memory f) internal pure returns (string memory) {
        return string.concat(".rounds[", vm.toString(r), "].claims[", vm.toString(i), "].", f);
    }

    function _publishAndClaimAll(uint256 r, uint256 claimCount) internal {
        uint64 epoch = uint64(vm.parseJsonUint(json, _key(r, "epoch")));
        address asset = vm.parseJsonAddress(json, _key(r, "asset"));
        bytes32 root = vm.parseJsonBytes32(json, _key(r, "root"));
        uint256 total = vm.parseJsonUint(json, _key(r, "total"));
        vm.prank(updater);
        d.publishRoot(epoch, asset, root, total);
        uint256 sum;
        for (uint256 i; i < claimCount; ++i) {
            address w = vm.parseJsonAddress(json, _claimKey(r, i, "wallet"));
            uint256 amt = vm.parseJsonUint(json, _claimKey(r, i, "amount"));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, _claimKey(r, i, "proof"));
            d.claim(epoch, asset, w, amt, proof);
            sum += amt;
            if (asset == address(0)) assertEq(w.balance, amt);
            else assertEq(TestToken(asset).balanceOf(w), amt);
        }
        assertEq(sum, total);
        assertEq(d.allocated(asset), 0);
    }

    function test_nativeRoundFromScript() public {
        vm.deal(address(d), 1 ether);
        _publishAndClaimAll(0, 5);
    }

    function test_erc20RoundFromScript() public {
        address asset = vm.parseJsonAddress(json, _key(1, "asset"));
        vm.etch(asset, address(new TestToken()).code);
        TestToken(asset).mint(address(d), 10e18);
        _publishAndClaimAll(1, 2);
    }
}

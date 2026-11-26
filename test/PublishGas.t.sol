// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Components} from "../src/ReputationTypes.sol";

/// @dev Gas of one real-time `publish` for N wallets: first write of each wallet (cold, zero -> nonzero) and a re-write
///      with different components (nonzero -> nonzero). Transaction gas = execution + 21000 intrinsic + calldata (measured
///      on the local fork by the rehearsal); these tests print the execution part. Run: forge test --match-contract PublishGas -vv
contract PublishGasTest is Base {
    uint64 internal epoch;

    function setUp() public {
        _deploy(defaultConfig());
        vm.warp(1_000_000);
    }

    function _batch(uint256 n, uint16 v) internal pure returns (address[] memory w, Components[] memory c) {
        w = new address[](n);
        c = new Components[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = address(uint160(0x1000 + i));
            c[i] = Components(v, v, v, 0, 0);
        }
    }

    function _measure(uint256 n, uint16 v) internal returns (uint256 used) {
        (address[] memory w, Components[] memory c) = _batch(n, v);
        ++epoch;
        vm.prank(updater);
        uint256 g = gasleft();
        _pub(epoch, w, c, uint64(block.timestamp - 1));
        used = g - gasleft();
    }

    function test_gasPublishNewWallets() public {
        emit log_named_uint("publish 0 wallets (execution)", _measure(0, 1));
        uint256[3] memory sizes = [uint256(1), 10, 100];
        for (uint256 i; i < 3; ++i) {
            // fresh addresses per size: shift by size so wallets are new each time
            address[] memory w = new address[](sizes[i]);
            Components[] memory c = new Components[](sizes[i]);
            for (uint256 k; k < sizes[i]; ++k) {
                w[k] = address(uint160(0x100000 * (i + 1) + k));
                c[k] = Components(300, 400, 500, 0, 0);
            }
            ++epoch;
            vm.prank(updater);
            uint256 g = gasleft();
            _pub(epoch, w, c, uint64(block.timestamp - 1));
            emit log_named_uint(string.concat("publish new wallets x", vm.toString(sizes[i])), g - gasleft());
        }
    }

    function test_gasPublishRewrite() public {
        uint256[3] memory sizes = [uint256(1), 10, 100];
        for (uint256 i; i < 3; ++i) {
            _measure(sizes[i], 5);
            emit log_named_uint(string.concat("publish rewrite x", vm.toString(sizes[i])), _measure(sizes[i], 6));
        }
    }
}

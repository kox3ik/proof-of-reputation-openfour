// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract DeployScriptTest is Test {
    function _run(uint256 chainId, string memory out) internal returns (ReputationRegistry) {
        vm.chainId(chainId);
        // public Anvil default dev key, not a secret
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        vm.setEnv("POR_OUT_JSON", out);
        vm.setEnv("QUOTE_ASSET", "0x00000000000000000000000000000000000b0b01");
        vm.setEnv("OPENFOUR_CORE", "0x00000000000000000000000000000000000c0de1");
        new Deploy().run();
        return ReputationRegistry(vm.parseJsonAddress(vm.readFile(out), ".registry"));
    }

    function test_configDelayDefaultsByChain() public {
        assertEq(_run(97, "deployments/test-97.json").config().configDelay, 0);
        assertEq(_run(56, "deployments/test-56.json").config().configDelay, 86400);
        vm.setEnv("CONFIG_DELAY", "3600");
        assertEq(_run(56, "deployments/test-56b.json").config().configDelay, 3600);
        vm.setEnv("CONFIG_DELAY", "");
    }

    function test_rateDefaultsAndOwnerOptions() public {
        ReputationRegistry r = _run(97, "deployments/test-97.json");
        assertEq(r.config().zeroBps, 50);
        assertEq(r.config().freshDepositBps, 640);
        assertEq(r.config().penaltyBps, 640);
        vm.setEnv("FRESH_DEPOSIT_BPS", "900");
        vm.setEnv("PENALTY_BPS", "900");
        r = _run(97, "deployments/test-97.json");
        assertEq(r.config().freshDepositBps, 900);
        assertEq(r.config().penaltyBps, 900);
        assertEq(r.config().zeroBps + r.config().penaltyBps, 950); // exactly the cap
        vm.setEnv("FRESH_DEPOSIT_BPS", "");
        vm.setEnv("PENALTY_BPS", "");
    }
}

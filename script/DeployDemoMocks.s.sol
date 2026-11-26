// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockIdentityToken} from "../test/mocks/IdentityMocks.sol";

/// @notice LOCAL DEMO ONLY: stand-ins for BABT and the SPACE ID Agent ID on a local fork (the real mainnet contracts
///         are not on BSC testnet). Output JSON: deployments/demo-mocks.json (babToken, agentIdToken).
contract DeployDemoMocks is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        MockIdentityToken bab = new MockIdentityToken();
        MockIdentityToken agent = new MockIdentityToken();
        vm.stopBroadcast();
        console2.log("mock BABT    ", address(bab));
        console2.log("mock Agent ID", address(agent));
        vm.serializeAddress("m", "babToken", address(bab));
        string memory json = vm.serializeAddress("m", "agentIdToken", address(agent));
        vm.writeJson(json, vm.envOr("MOCKS_OUT_JSON", string("deployments/demo-mocks.json")));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {V4AgenticVaultFactory} from "../src/V4AgenticVaultFactory.sol";

contract DeployVaultFactory is Script {
    // Uniswap v4 mainnet addresses
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (V4AgenticVaultFactory factory) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console2.log("Deploying V4AgenticVaultFactory to Ethereum mainnet...");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        console2.log("PositionManager:", POSITION_MANAGER);
        console2.log("UniversalRouter:", UNIVERSAL_ROUTER);
        console2.log("Permit2:", PERMIT2);

        vm.startBroadcast(deployerPrivateKey);

        factory = new V4AgenticVaultFactory(POSITION_MANAGER, UNIVERSAL_ROUTER, PERMIT2);

        vm.stopBroadcast();

        console2.log("V4AgenticVaultFactory deployed at:", address(factory));
    }
}

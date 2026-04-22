// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BondFactory} from "../src/BondFactory.sol";

interface IUUPSProxy {
    function upgradeTo(address newImplementation) external;
}

contract UpgradeFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryProxy = 0x0FEc8e923caFd7238b4D0493F27bEce3733d2A13;

        vm.startBroadcast(deployerKey);

        // Deploy new implementation
        BondFactory newImpl = new BondFactory();
        console2.log("New BondFactory impl:", address(newImpl));

        // Upgrade proxy — use upgradeTo instead of upgradeToAndCall
        IUUPSProxy(factoryProxy).upgradeTo(address(newImpl));
        console2.log("Factory upgraded successfully");

        vm.stopBroadcast();
    }
}

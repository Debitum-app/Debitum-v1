// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {BondNFT}             from "../src/BondNFT.sol";
import {VestingDistributor}  from "../src/VestingDistributor.sol";

/// @notice Deploy VestingDistributor and grant it MINTER_ROLE on BondNFT.
///         Requires the caller to hold DEFAULT_ADMIN_ROLE on BondNFT.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY  — private key with DEFAULT_ADMIN_ROLE on BondNFT
///           BOND_NFT              — deployed BondNFT proxy address
///           VESTING_MODULE        — deployed VestingModule address
contract DeployVestingDistributor is Script {
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function run() external {
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address bondNFT        = vm.envAddress("BOND_NFT");
        address vestingModule  = vm.envAddress("VESTING_MODULE");

        vm.startBroadcast(deployerKey);

        VestingDistributor distributor = new VestingDistributor(bondNFT, vestingModule);

        BondNFT(bondNFT).grantRole(MINTER_ROLE, address(distributor));

        vm.stopBroadcast();

        console2.log("=== VestingDistributor Deployment ===");
        console2.log("BondNFT:            ", bondNFT);
        console2.log("VestingModule:      ", vestingModule);
        console2.log("VestingDistributor: ", address(distributor));
    }
}

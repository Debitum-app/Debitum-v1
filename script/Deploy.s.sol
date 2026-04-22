// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondFactory}   from "../src/BondFactory.sol";
import {BondContract}  from "../src/BondContract.sol";
import {BondNFT}       from "../src/BondNFT.sol";
import {VestingModule} from "../src/VestingModule.sol";
import {TokenGate}     from "../src/TokenGate.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        VestingModule vesting = new VestingModule();
        TokenGate gate        = new TokenGate();
        BondContract bondImpl = new BondContract();

        BondNFT nftImpl = new BondNFT();
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl),
            abi.encodeCall(BondNFT.initialize, (deployer, deployer, 250)));

        BondFactory factoryImpl = new BondFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl),
            abi.encodeCall(BondFactory.initialize, (
                deployer, address(bondImpl), address(vesting),
                address(nftProxy), address(gate), deployer, 0)));

        BondNFT(address(nftProxy)).grantRole(keccak256("REGISTRAR_ROLE"), address(factoryProxy));

        vm.stopBroadcast();

        console2.log("BondNFT:          ", address(nftProxy));
        console2.log("VestingModule:    ", address(vesting));
        console2.log("TokenGate:        ", address(gate));
        console2.log("BondContract impl:", address(bondImpl));
        console2.log("BondFactory:      ", address(factoryProxy));
    }
}

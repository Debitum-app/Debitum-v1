// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}   from "forge-std/Script.sol";
import {ERC1967Proxy}       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondFactory}        from "../src/BondFactory.sol";
import {BondContract}       from "../src/BondContract.sol";
import {BondNFT}            from "../src/BondNFT.sol";
import {VestingModule}      from "../src/VestingModule.sol";
import {TokenGate}          from "../src/TokenGate.sol";
import {VestingDistributor} from "../src/VestingDistributor.sol";

contract Deploy is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant REGISTRAR_ROLE     = keccak256("REGISTRAR_ROLE");
    bytes32 constant MINTER_ROLE        = keccak256("MINTER_ROLE");

    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address admin        = vm.envOr("ADMIN_ADDRESS",    deployer);
        address feeCollector = vm.envOr("FEE_COLLECTOR",    deployer);
        uint256 feeBps       = vm.envOr("PROTOCOL_FEE_BPS", uint256(30));
        uint16  maxDiscount  = uint16(vm.envOr("MAX_DISCOUNT_CAP_BPS", uint256(3000)));

        vm.startBroadcast(deployerKey);

        // 1. Stateless / non-upgradeable contracts
        VestingModule vesting  = new VestingModule();
        BondContract  bondImpl = new BondContract();

        // 2. TokenGate proxy — deployer as temp admin so we can wire factory later
        TokenGate gateImpl = new TokenGate();
        ERC1967Proxy gateProxy = new ERC1967Proxy(address(gateImpl),
            abi.encodeCall(TokenGate.initialize, (deployer, address(0), maxDiscount)));

        // 3. BondNFT proxy — deployer as temp admin and temp factory/registrar
        BondNFT nftImpl = new BondNFT();
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl),
            abi.encodeCall(BondNFT.initialize, (deployer, deployer, 250)));

        // 4. BondFactory proxy — deployer as temp admin
        BondFactory factoryImpl = new BondFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl),
            abi.encodeCall(BondFactory.initialize, (
                deployer,
                address(bondImpl),
                address(vesting),
                address(nftProxy),
                address(gateProxy),
                feeCollector,
                feeBps
            )));

        // 5. Wire: grant BondFactory REGISTRAR_ROLE on BondNFT (deployer has DEFAULT_ADMIN_ROLE)
        BondNFT(address(nftProxy)).grantRole(REGISTRAR_ROLE, address(factoryProxy));

        // 6. Wire: point TokenGate to deployed factory
        TokenGate(address(gateProxy)).setBondFactory(address(factoryProxy));

        // 6b. Deploy VestingDistributor and grant it MINTER_ROLE — must happen before
        //     role transfer since deployer holds DEFAULT_ADMIN_ROLE here
        VestingDistributor distributor = new VestingDistributor(address(nftProxy), address(vesting));
        BondNFT(address(nftProxy)).grantRole(MINTER_ROLE, address(distributor));

        // 7. Transfer all admin roles to the actual admin (if different from deployer)
        if (admin != deployer) {
            // BondNFT
            BondNFT(address(nftProxy)).grantRole(DEFAULT_ADMIN_ROLE, admin);
            BondNFT(address(nftProxy)).grantRole(ADMIN_ROLE, admin);
            BondNFT(address(nftProxy)).revokeRole(REGISTRAR_ROLE, deployer);
            BondNFT(address(nftProxy)).revokeRole(ADMIN_ROLE, deployer);
            BondNFT(address(nftProxy)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);

            // TokenGate
            TokenGate(address(gateProxy)).grantRole(DEFAULT_ADMIN_ROLE, admin);
            TokenGate(address(gateProxy)).grantRole(ADMIN_ROLE, admin);
            TokenGate(address(gateProxy)).revokeRole(ADMIN_ROLE, deployer);
            TokenGate(address(gateProxy)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);

            // BondFactory
            BondFactory(address(factoryProxy)).grantRole(DEFAULT_ADMIN_ROLE, admin);
            BondFactory(address(factoryProxy)).grantRole(ADMIN_ROLE, admin);
            BondFactory(address(factoryProxy)).revokeRole(ADMIN_ROLE, deployer);
            BondFactory(address(factoryProxy)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        }

        vm.stopBroadcast();

        console2.log("=== Debitum Protocol Deployment ===");
        console2.log("Deployer:            ", deployer);
        console2.log("Admin:               ", admin);
        console2.log("Fee collector:       ", feeCollector);
        console2.log("Protocol fee bps:    ", feeBps);
        console2.log("---");
        console2.log("VestingModule:       ", address(vesting));
        console2.log("BondContract impl:   ", address(bondImpl));
        console2.log("TokenGate:           ", address(gateProxy));
        console2.log("BondNFT:             ", address(nftProxy));
        console2.log("BondFactory:         ", address(factoryProxy));
        console2.log("VestingDistributor:  ", address(distributor));
    }
}

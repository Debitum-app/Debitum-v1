// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BondFactory}    from "../../src/BondFactory.sol";
import {BondContract}   from "../../src/BondContract.sol";
import {BondNFT}        from "../../src/BondNFT.sol";
import {VestingModule}  from "../../src/VestingModule.sol";
import {TokenGate}      from "../../src/TokenGate.sol";
import {IBondFactory}   from "../../src/interfaces/IBondFactory.sol";
import {IVestingModule} from "../../src/interfaces/IModules.sol";

import {MockERC20, MockUSDT}  from "./MockERC20.sol";
import {MockPriceFeed}        from "./MockPriceFeed.sol";

abstract contract Fixtures is Test {
    // ── Actors ────────────────────────────────────────────────────────────────
    address internal admin        = makeAddr("admin");
    address internal creator      = makeAddr("creator");
    address internal buyer        = makeAddr("buyer");
    address internal buyer2       = makeAddr("buyer2");
    address internal feeCollector = makeAddr("feeCollector");

    // ── Protocol contracts ────────────────────────────────────────────────────
    BondFactory   internal factory;
    BondNFT       internal nft;
    VestingModule internal vesting;
    TokenGate     internal gate;

    // ── Tokens ────────────────────────────────────────────────────────────────
    MockERC20 internal principal;   // 18-decimal principal token
    MockERC20 internal payment;     // 6-decimal payment token (like USDC)

    // ── Helper: deploy the whole protocol ─────────────────────────────────────
    function _deployProtocol() internal {
        // Stateless module — no proxy needed
        vesting = new VestingModule();

        // BondContract — implementation only (cloned per bond)
        BondContract bondImpl = new BondContract();

        // BondNFT via ERC1967 proxy
        // We pass admin as temporary factory (registrar); we'll grant the real factory later
        BondNFT nftImpl = new BondNFT();
        bytes memory nftInit = abi.encodeCall(BondNFT.initialize, (admin, admin, 250));
        nft = BondNFT(address(new ERC1967Proxy(address(nftImpl), nftInit)));

        // TokenGate via ERC1967 proxy (pass admin as factory placeholder)
        TokenGate gateImpl = new TokenGate();
        bytes memory gateInit = abi.encodeCall(TokenGate.initialize, (admin, admin, 3_000));
        gate = TokenGate(address(new ERC1967Proxy(address(gateImpl), gateInit)));

        // BondFactory via ERC1967 proxy
        BondFactory factoryImpl = new BondFactory();
        bytes memory factInit = abi.encodeCall(
            BondFactory.initialize,
            (admin, address(bondImpl), address(vesting), address(nft), address(gate), feeCollector, 100)
        );
        factory = BondFactory(address(new ERC1967Proxy(address(factoryImpl), factInit)));

        // Wire up: grant REGISTRAR_ROLE on BondNFT to the real factory
        vm.startPrank(admin);
        nft.grantRole(nft.REGISTRAR_ROLE(), address(factory));
        // Update TokenGate's factory reference
        gate.setBondFactory(address(factory));
        vm.stopPrank();

        // Tokens
        principal = new MockERC20("Principal", "PRIN", 18);
        payment   = new MockERC20("Payment",   "PAY",   6);
    }

    // ── Helper: build a standard linear-vesting bond params ───────────────────
    function _linearParams(uint64 duration) internal pure returns (bytes memory) {
        return abi.encode(IVestingModule.LinearParams({ duration: duration }));
    }

    function _cliffParams(uint64 cliff, uint64 total) internal pure returns (bytes memory) {
        return abi.encode(IVestingModule.CliffParams({ cliffDuration: cliff, totalDuration: total }));
    }

    function _stepParams(uint16 steps, uint64 stepDuration) internal pure returns (bytes memory) {
        return abi.encode(IVestingModule.StepParams({ steps: steps, stepDuration: stepDuration }));
    }

    function _defaultBondParams() internal view returns (IBondFactory.BondParams memory) {
        return IBondFactory.BondParams({
            paymentToken:         address(payment),
            principalToken:       address(principal),
            capacityInPrincipal:  1_000_000e18,
            pricePerPrincipal:    1e6,            // 1 payment token per principal (6 dec)
            discountBps:          0,
            minPurchasePrincipal: 1e18,
            maxPurchasePrincipal: 1_000_000e18,
            vestingType:          uint8(IVestingModule.VestingType.Linear),
            vestingParams:        _linearParams(30 days),
            gateTokens:           new address[](0),
            gateConfig:           "",
            isOTC:                false,
            depositPrincipal:     false,
            priceFeed:            address(0),
            maxPriceAge:          0
        });
    }

    // ── Helper: create a bond with the creator holding enough principal ────────
    function _createDefaultBond() internal returns (address bond) {
        IBondFactory.BondParams memory p = _defaultBondParams();
        vm.prank(creator);
        bond = factory.createBond(p, new address[](0));
    }
}

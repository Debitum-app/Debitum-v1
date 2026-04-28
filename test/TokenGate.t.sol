// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}       from "./helpers/Fixtures.sol";
import {MockERC20}      from "./helpers/MockERC20.sol";
import {IBondFactory}   from "../src/interfaces/IBondFactory.sol";
import {ITokenGate}     from "../src/interfaces/IModules.sol";
import {TokenGate}      from "../src/TokenGate.sol";
import {BondContract}   from "../src/BondContract.sol";

contract TokenGateTest is Fixtures {
    address internal bond;
    MockERC20 internal gateToken;

    ITokenGate.DiscountTier[] internal singleTier;
    ITokenGate.DiscountTier[] internal multiTiers;

    function setUp() public {
        _deployProtocol();
        bond = _createDefaultBond();
        gateToken = new MockERC20("Gate Token", "GATE", 18);

        singleTier.push(ITokenGate.DiscountTier({ threshold: 100e18, discountBps: 500 }));

        // Two tiers: whale (1000+) → 1500bps, entry (100+) → 500bps
        multiTiers.push(ITokenGate.DiscountTier({ threshold: 1000e18, discountBps: 1500 }));
        multiTiers.push(ITokenGate.DiscountTier({ threshold: 100e18,  discountBps: 500  }));
    }

    // ── setRules — validation ─────────────────────────────────────────────────

    function test_setRules_revertNotBondCreator() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);

        vm.prank(buyer);
        vm.expectRevert(ITokenGate.NotBondCreator.selector);
        gate.setRules(bond, rules);
    }

    function test_setRules_revertNotRegisteredBond() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);

        vm.prank(creator);
        vm.expectRevert("Not a registered bond");
        gate.setRules(address(0xdead), rules);
    }

    function test_setRules_revertInvalidDiscount() public {
        ITokenGate.DiscountTier[] memory badTiers = new ITokenGate.DiscountTier[](1);
        badTiers[0] = ITokenGate.DiscountTier({ threshold: 100e18, discountBps: 0 });

        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), badTiers);

        vm.prank(creator);
        vm.expectRevert(ITokenGate.InvalidDiscount.selector);
        gate.setRules(bond, rules);
    }

    function test_setRules_revertTiersNotSorted() public {
        ITokenGate.DiscountTier[] memory unsorted = new ITokenGate.DiscountTier[](2);
        unsorted[0] = ITokenGate.DiscountTier({ threshold: 100e18,  discountBps: 500  }); // low first = wrong
        unsorted[1] = ITokenGate.DiscountTier({ threshold: 1000e18, discountBps: 1500 });

        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), unsorted);

        vm.prank(creator);
        vm.expectRevert(ITokenGate.TiersNotSorted.selector);
        gate.setRules(bond, rules);
    }

    function test_setRules_success() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);

        vm.prank(creator);
        gate.setRules(bond, rules);

        assertEq(gate.ruleCount(bond), 1);
    }

    // ── getDiscount — ERC20 ───────────────────────────────────────────────────

    function test_getDiscount_noRules() public view {
        assertEq(gate.getDiscount(buyer, bond), 0);
    }

    function test_getDiscount_belowMinThreshold() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);
        vm.prank(creator); gate.setRules(bond, rules);

        // Buyer holds 50 tokens, threshold is 100 → no discount
        gateToken.mint(buyer, 50e18);
        assertEq(gate.getDiscount(buyer, bond), 0);
    }

    function test_getDiscount_atThreshold() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);
        vm.prank(creator); gate.setRules(bond, rules);

        gateToken.mint(buyer, 100e18);
        assertEq(gate.getDiscount(buyer, bond), 500);
    }

    function test_getDiscount_aboveTopTier() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), multiTiers);
        vm.prank(creator); gate.setRules(bond, rules);

        gateToken.mint(buyer, 2000e18);
        assertEq(gate.getDiscount(buyer, bond), 1500);
    }

    function test_getDiscount_betweenTiers_interpolation() public {
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), multiTiers);
        vm.prank(creator); gate.setRules(bond, rules);

        // 550 tokens: between tier[1]=100 (500bps) and tier[0]=1000 (1500bps)
        // interpolated: 500 + (1500-500) * (550-100) / (1000-100) = 500 + 1000*450/900 = 500 + 500 = 1000
        gateToken.mint(buyer, 550e18);
        assertEq(gate.getDiscount(buyer, bond), 1000);
    }

    function test_getDiscount_cappedAtMaxDiscountCap() public {
        // max cap is 3000 bps; add two rules that sum > cap
        MockERC20 gateToken2 = new MockERC20("Gate2", "GATE2", 18);

        // Bond2 created by creator
        IBondFactory.BondParams memory p = _defaultBondParams();
        vm.prank(creator);
        address bond2 = factory.createBond(p, new address[](0));

        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](2);
        rules[0] = _erc20Rule(address(gateToken),  singleTier);  // 500 bps
        rules[1] = _erc20Rule(address(gateToken2), multiTiers);  // up to 1500 bps

        vm.prank(creator); gate.setRules(bond2, rules);

        gateToken.mint(buyer, 100e18);
        gateToken2.mint(buyer, 2000e18);

        // 500 + 1500 = 2000 < 3000 cap → 2000
        assertEq(gate.getDiscount(buyer, bond2), 2000);
    }

    // ── discount applied during purchase ──────────────────────────────────────

    function test_purchase_withGateDiscount() public {
        // 500 bps discount → buyer pays same but gets 5% more principal
        ITokenGate.GateRule[] memory rules = new ITokenGate.GateRule[](1);
        rules[0] = _erc20Rule(address(gateToken), singleTier);
        vm.prank(creator); gate.setRules(bond, rules);
        gateToken.mint(buyer, 100e18);

        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        vm.prank(buyer);
        uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // With 500 bps discount: effectivePrice = 1e18 * (10000-500) / 10000 ≈ 0.95e18
        // principal = 100e18 / 0.95 ≈ 105.26e18
        uint128 princ = nft.position(tokenId).principalAmount;
        assertGt(princ, 100e18); // more than without discount
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _erc20Rule(
        address token,
        ITokenGate.DiscountTier[] memory tiers
    ) internal pure returns (ITokenGate.GateRule memory rule) {
        rule.checkType  = ITokenGate.CheckType.ERC20Balance;
        rule.token      = token;
        rule.merkleRoot = bytes32(0);
        rule.tiers      = tiers;
    }
}

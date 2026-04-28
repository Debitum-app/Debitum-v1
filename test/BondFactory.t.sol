// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}       from "./helpers/Fixtures.sol";
import {MockPriceFeed, BrokenPriceFeed, NodecimalsFeed} from "./helpers/MockPriceFeed.sol";
import {IBondFactory}   from "../src/interfaces/IBondFactory.sol";
import {BondFactory}    from "../src/BondFactory.sol";
import {BondContract}   from "../src/BondContract.sol";
import {IVestingModule} from "../src/interfaces/IModules.sol";

contract BondFactoryTest is Fixtures {
    function setUp() public {
        _deployProtocol();
    }

    // ── createBond — happy path ───────────────────────────────────────────────

    function test_createBond_basicLinear() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        assertTrue(factory.isBond(bond));
        assertEq(factory.bondCount(), 1);
        assertEq(factory.allBonds(0), bond);
        assertEq(factory.bondsByCreator(creator).length, 1);
    }

    function test_createBond_emitsBondCreated() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit IBondFactory.BondCreated(address(0), creator, 0);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_withPriceFeed() public {
        MockPriceFeed feed = new MockPriceFeed(8, 1e8); // $1.00

        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed          = address(feed);
        p.pricePerPrincipal  = 0; // use feed
        p.maxPriceAge        = 3600;

        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));
        assertTrue(factory.isBond(bond));
    }

    function test_createBond_OTC() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.isOTC = true;
        address[] memory wl = new address[](1);
        wl[0] = buyer;

        vm.prank(creator);
        address bond = factory.createBond(p, wl);
        assertTrue(factory.isBond(bond));
    }

    function test_createBond_escrowDeposit() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.depositPrincipal = true;

        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));
        assertTrue(factory.isBond(bond));
    }

    // ── createBond — reverts ─────────────────────────────────────────────────

    function test_createBond_revertZeroAddress_principalToken() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.principalToken = address(0);
        vm.prank(creator);
        vm.expectRevert(IBondFactory.ZeroAddress.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertInvalidCapacity_zero() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.capacityInPrincipal = 0;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidCapacity.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertInvalidCapacity_minGtMax() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.minPurchasePrincipal = 100e18;
        p.maxPurchasePrincipal = 50e18;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidCapacity.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertInvalidCapacity_maxGtCapacity() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.capacityInPrincipal  = 100e18;
        p.maxPurchasePrincipal = 200e18;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidCapacity.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertInvalidDiscount() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.discountBps = 10_000;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidDiscount.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertInvalidPrice_noPriceFeedAndNoPrice() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(0);
        p.pricePerPrincipal = 0;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertOTCRequiresWhitelist() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.isOTC = true;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.OTCWhitelistRequired.selector);
        factory.createBond(p, new address[](0));
    }

    // ── Issue 1: oracle validation ────────────────────────────────────────────

    function test_createBond_revertBrokenFeed() public {
        BrokenPriceFeed feed = new BrokenPriceFeed();
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertNegativeAnswerFeed() public {
        MockPriceFeed feed = new MockPriceFeed(8, -1); // negative answer
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertZeroAnswerFeed() public {
        MockPriceFeed feed = new MockPriceFeed(8, 0);
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_revertMaxPriceAgeExceedsLimit() public {
        MockPriceFeed feed = new MockPriceFeed(8, 1e8);
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = uint32(factory.MAX_PRICE_AGE()) + 1;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    function test_createBond_maxPriceAgeAtLimit() public {
        MockPriceFeed feed = new MockPriceFeed(8, 1e8);
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = uint32(factory.MAX_PRICE_AGE());
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));
        assertTrue(factory.isBond(bond));
    }

    function test_createBond_revertFeedWithNoDecimalsFunction() public {
        NodecimalsFeed feed = new NodecimalsFeed();
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        vm.expectRevert(IBondFactory.InvalidPrice.selector);
        factory.createBond(p, new address[](0));
    }

    // ── Admin functions ───────────────────────────────────────────────────────

    function test_setProtocolFee() public {
        vm.prank(admin);
        factory.setProtocolFee(200);
        assertEq(factory.protocolFeeBps(), 200);
    }

    function test_setProtocolFee_revertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(IBondFactory.FeeTooHigh.selector);
        factory.setProtocolFee(501);
    }

    function test_setFeeCollector() public {
        address newCollector = makeAddr("newCollector");
        vm.prank(admin);
        factory.setFeeCollector(newCollector);
        assertEq(factory.feeCollector(), newCollector);
    }

    function test_setFeeCollector_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IBondFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
    }

    function test_adminFunctions_revertNonAdmin() public {
        vm.prank(buyer);
        vm.expectRevert();
        factory.setProtocolFee(100);

        vm.prank(buyer);
        vm.expectRevert();
        factory.setFeeCollector(makeAddr("x"));
    }
}

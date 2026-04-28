// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}       from "./helpers/Fixtures.sol";
import {MockERC20, MockUSDT} from "./helpers/MockERC20.sol";
import {MockPriceFeed}  from "./helpers/MockPriceFeed.sol";
import {IBondFactory}   from "../src/interfaces/IBondFactory.sol";
import {IBondContract}  from "../src/interfaces/IBondContract.sol";
import {IVestingModule} from "../src/interfaces/IModules.sol";
import {BondContract}   from "../src/BondContract.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BondContractTest is Fixtures {
    address internal bond;

    function setUp() public {
        _deployProtocol();
        bond = _createDefaultBond();
    }

    // ── config ────────────────────────────────────────────────────────────────

    function test_config_setCorrectly() public view {
        IBondContract.BondConfig memory cfg = BondContract(bond).config();
        assertEq(cfg.creator,             creator);
        assertEq(cfg.principalToken,      address(principal));
        assertEq(cfg.paymentToken,        address(payment));
        assertEq(cfg.capacityInPrincipal, 1_000_000e18);
        assertEq(cfg.pricePerPrincipal,   1e6);
        assertEq(cfg.discountBps,         0);
        assertFalse(cfg.isOTC);
    }

    // ── Issue 2: forceApprove — USDT-style token must not brick initialization ─

    function test_initialize_USDTStyleToken_doesNotRevert() public {
        MockUSDT usdt = new MockUSDT();
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.principalToken    = address(usdt);
        p.pricePerPrincipal = 1e6;

        vm.prank(creator);
        address usdtBond = factory.createBond(p, new address[](0));
        assertTrue(factory.isBond(usdtBond));
        // The bond now has a max allowance set to nft
        assertEq(IERC20(address(usdt)).allowance(usdtBond, address(nft)), type(uint256).max);
    }

    // ── purchase — ERC20 payment ──────────────────────────────────────────────

    function test_purchase_basic() public {
        uint256 payAmt = 100e6; // 100 USDC-like

        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);

        vm.prank(buyer);
        payment.approve(bond, payAmt);

        vm.prank(creator);
        principal.approve(bond, type(uint256).max);

        vm.prank(buyer);
        uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // Buyer should own NFT #0
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function test_purchase_principalAmountCorrect() public {
        // price = 1 payment-token per principal-token (1e6 per 1e18)
        // 100 USDC paid → 100 principal tokens
        uint256 payAmt = 100e6;

        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);

        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        vm.prank(buyer);
        uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // paymentAmount18 = 100e6 * 1e12 = 100e18
        // effectivePrice  = 1e6 * 1e12  = 1e18
        // principal       = 100e18 * 1e18 / 1e18 = 100e18
        assertEq(nft.position(tokenId).principalAmount, 100e18);
    }

    function test_purchase_feeDistribution() public {
        // Factory deployed with 100 bps (1%) fee
        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);

        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        uint256 creatorBefore      = payment.balanceOf(creator);
        uint256 feeCollectorBefore = payment.balanceOf(feeCollector);

        vm.prank(buyer);
        BondContract(bond).purchase(payAmt, 0);

        // 1% fee → feeCollector gets 1e6, creator gets 99e6
        assertEq(payment.balanceOf(feeCollector) - feeCollectorBefore, 1e6);
        assertEq(payment.balanceOf(creator)      - creatorBefore,       99e6);
    }

    function test_purchase_revertBelowMinPrincipal() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.minPurchasePrincipal = 200e18;
        vm.prank(creator);
        address b = factory.createBond(p, new address[](0));

        payment.mint(buyer, 100e6);
        principal.mint(creator, 200e18);

        vm.prank(buyer); payment.approve(b, 100e6);
        vm.prank(creator); principal.approve(b, type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.BelowMinPurchase.selector);
        BondContract(b).purchase(100e6, 0);
    }

    function test_purchase_revertExceedsCapacity() public {
        // capacity=50e18, max=50e18; buyer1 buys 30e18, buyer2 tries 30e18 → total 60e18 > 50e18
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.capacityInPrincipal  = 50e18;
        p.maxPurchasePrincipal = 50e18;
        vm.prank(creator);
        address b = factory.createBond(p, new address[](0));

        principal.mint(creator, 100e18);
        vm.prank(creator); principal.approve(b, type(uint256).max);

        payment.mint(buyer, 30e6);
        vm.prank(buyer); payment.approve(b, 30e6);
        vm.prank(buyer); BondContract(b).purchase(30e6, 0);

        payment.mint(buyer2, 30e6);
        vm.prank(buyer2); payment.approve(b, 30e6);
        vm.prank(buyer2);
        vm.expectRevert(IBondContract.ExceedsCapacity.selector);
        BondContract(b).purchase(30e6, 0);
    }

    function test_purchase_revertSlippage() public {
        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.SlippageExceeded.selector);
        BondContract(bond).purchase(payAmt, 1_000_000e18); // unreachable min
    }

    function test_purchase_revertWhenPaused() public {
        vm.prank(creator);
        BondContract(bond).setPaused(true);

        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(bond, 100e6);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.BondPaused.selector);
        BondContract(bond).purchase(100e6, 0);
    }

    function test_purchase_revertWhenClosed() public {
        vm.prank(creator);
        BondContract(bond).closeBond();

        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(bond, 100e6);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.BondIsClosed.selector);
        BondContract(bond).purchase(100e6, 0);
    }

    function test_purchase_OTC_revertNonWhitelisted() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.isOTC = true;
        address[] memory wl = new address[](1);
        wl[0] = buyer;
        vm.prank(creator);
        address otcBond = factory.createBond(p, wl);

        payment.mint(buyer2, 100e6);
        principal.mint(creator, 200e18);
        vm.prank(buyer2); payment.approve(otcBond, 100e6);
        vm.prank(creator); principal.approve(otcBond, type(uint256).max);

        vm.prank(buyer2);
        vm.expectRevert(IBondContract.NotWhitelisted.selector);
        BondContract(otcBond).purchase(100e6, 0);
    }

    function test_purchase_OTC_allowsWhitelisted() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.isOTC = true;
        address[] memory wl = new address[](1);
        wl[0] = buyer;
        vm.prank(creator);
        address otcBond = factory.createBond(p, wl);

        payment.mint(buyer, 100e6);
        principal.mint(creator, 200e18);
        vm.prank(buyer); payment.approve(otcBond, 100e6);
        vm.prank(creator); principal.approve(otcBond, type(uint256).max);

        vm.prank(buyer);
        uint256 tokenId = BondContract(otcBond).purchase(100e6, 0);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    // ── purchaseWithETH ───────────────────────────────────────────────────────

    function test_purchaseWithETH() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.paymentToken      = address(0); // ETH
        p.pricePerPrincipal = 1e18;       // 1 ETH per principal (18-dec price)

        vm.prank(creator);
        address ethBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        vm.prank(creator); principal.approve(ethBond, type(uint256).max);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 tokenId = BondContract(ethBond).purchaseWithETH{value: 1 ether}(0);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function test_purchaseWithETH_creatorCanWithdraw() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.paymentToken      = address(0);
        p.pricePerPrincipal = 1e18;
        vm.prank(creator);
        address ethBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        vm.prank(creator); principal.approve(ethBond, type(uint256).max);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        BondContract(ethBond).purchaseWithETH{value: 1 ether}(0);

        uint256 beforeCreator = creator.balance;
        vm.prank(creator);
        BondContract(ethBond).withdrawETH();
        // 1% fee → creator gets 0.99 ETH
        assertApproxEqAbs(creator.balance - beforeCreator, 0.99 ether, 1e10);
    }

    // ── Escrow deposit ────────────────────────────────────────────────────────

    function test_escrow_depositAndPurchase() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.depositPrincipal    = true;
        p.capacityInPrincipal = 100e18;
        p.maxPurchasePrincipal= 100e18;
        vm.prank(creator);
        address escrowBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 100e18);
        vm.prank(creator); principal.approve(escrowBond, 100e18);
        vm.prank(creator); BondContract(escrowBond).depositEscrow();
        assertTrue(BondContract(escrowBond).escrowDeposited());

        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(escrowBond, 100e6);
        vm.prank(buyer); BondContract(escrowBond).purchase(100e6, 0);
    }

    function test_escrow_revertPurchaseBeforeDeposit() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.depositPrincipal = true;
        vm.prank(creator);
        address escrowBond = factory.createBond(p, new address[](0));

        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(escrowBond, 100e6);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.EscrowNotDeposited.selector);
        BondContract(escrowBond).purchase(100e6, 0);
    }

    function test_escrow_revertDoubleDeposit() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.depositPrincipal    = true;
        p.capacityInPrincipal = 100e18;
        p.maxPurchasePrincipal= 100e18;
        vm.prank(creator);
        address escrowBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        vm.prank(creator); principal.approve(escrowBond, 200e18);
        vm.prank(creator); BondContract(escrowBond).depositEscrow();

        vm.prank(creator);
        vm.expectRevert(IBondContract.EscrowAlreadyDeposited.selector);
        BondContract(escrowBond).depositEscrow();
    }

    // ── Oracle-priced bond ────────────────────────────────────────────────────

    function test_purchase_oraclePricedBond() public {
        MockPriceFeed feed = new MockPriceFeed(8, 2e8); // price = 2.00 (8 dec → 2e18 when normalized)

        IBondFactory.BondParams memory p = _defaultBondParams();
        p.paymentToken      = address(payment); // 6-dec
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;

        vm.prank(creator);
        address oracleBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        payment.mint(buyer, 200e6);
        vm.prank(creator); principal.approve(oracleBond, type(uint256).max);
        vm.prank(buyer);   payment.approve(oracleBond, 200e6);

        vm.prank(buyer);
        uint256 tokenId = BondContract(oracleBond).purchase(200e6, 0);
        // 200 USDC at price $2 → 100 principal tokens
        assertEq(nft.position(tokenId).principalAmount, 100e18);
    }

    function test_purchase_revertStaleOracle() public {
        MockPriceFeed feed = new MockPriceFeed(8, 1e8);

        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        address oracleBond = factory.createBond(p, new address[](0));

        // Move time past maxPriceAge
        vm.warp(block.timestamp + 3601);

        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(oracleBond, 100e6);

        vm.prank(buyer);
        vm.expectRevert(IBondContract.StaleOracle.selector);
        BondContract(oracleBond).purchase(100e6, 0);
    }

    // ── previewPurchase ───────────────────────────────────────────────────────

    function test_previewPurchase_matchesPurchase() public {
        uint256 payAmt = 100e6;
        (uint256 previewPrincipal,) = BondContract(bond).previewPurchase(buyer, payAmt);
        assertEq(previewPrincipal, 100e18);
    }

    function test_previewPurchase_zeroInput() public {
        (uint256 a, uint256 b) = BondContract(bond).previewPurchase(buyer, 0);
        assertEq(a, 0);
        assertEq(b, 0);
    }

    // ── remainingCapacity ─────────────────────────────────────────────────────

    function test_remainingCapacity_decreasesOnPurchase() public {
        uint256 before = BondContract(bond).remainingCapacity();

        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(buyer); BondContract(bond).purchase(payAmt, 0);

        assertEq(BondContract(bond).remainingCapacity(), before - 100e18);
    }

    // ── whitelist management ──────────────────────────────────────────────────

    function test_addRemoveWhitelist() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.isOTC = true;
        address[] memory wl = new address[](1);
        wl[0] = buyer;
        vm.prank(creator);
        address otcBond = factory.createBond(p, wl);

        assertTrue(BondContract(otcBond).isWhitelisted(buyer));
        assertFalse(BondContract(otcBond).isWhitelisted(buyer2));

        address[] memory add = new address[](1);
        add[0] = buyer2;
        vm.prank(creator);
        BondContract(otcBond).addToWhitelist(add);
        assertTrue(BondContract(otcBond).isWhitelisted(buyer2));

        vm.prank(creator);
        BondContract(otcBond).removeFromWhitelist(add);
        assertFalse(BondContract(otcBond).isWhitelisted(buyer2));
    }

    function test_isWhitelisted_alwaysTrueForPublicBond() public view {
        assertTrue(BondContract(bond).isWhitelisted(buyer));
        assertTrue(BondContract(bond).isWhitelisted(address(0)));
    }

    // ── closeBond / setPaused ─────────────────────────────────────────────────

    function test_closeBond_onlyCreator() public {
        vm.prank(buyer);
        vm.expectRevert(IBondContract.NotCreator.selector);
        BondContract(bond).closeBond();
    }

    function test_setPaused_onlyCreator() public {
        vm.prank(buyer);
        vm.expectRevert(IBondContract.NotCreator.selector);
        BondContract(bond).setPaused(true);
    }

    function test_bondClosesAutomaticallyAtCapacity() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.capacityInPrincipal  = 100e18;
        p.maxPurchasePrincipal = 100e18;
        p.minPurchasePrincipal = 1e18;
        vm.prank(creator);
        address smallBond = factory.createBond(p, new address[](0));

        principal.mint(creator, 100e18);
        payment.mint(buyer, 100e6);
        vm.prank(creator); principal.approve(smallBond, type(uint256).max);
        vm.prank(buyer); payment.approve(smallBond, 100e6);
        vm.prank(buyer); BondContract(smallBond).purchase(100e6, 0);

        IBondContract.BondState memory st = BondContract(smallBond).state();
        assertTrue(st.closed);
    }
}

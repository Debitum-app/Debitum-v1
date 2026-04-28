// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}       from "../helpers/Fixtures.sol";
import {MockPriceFeed}  from "../helpers/MockPriceFeed.sol";
import {IBondFactory}   from "../../src/interfaces/IBondFactory.sol";
import {IBondContract}  from "../../src/interfaces/IBondContract.sol";
import {IVestingModule} from "../../src/interfaces/IModules.sol";
import {ITokenGate}     from "../../src/interfaces/IModules.sol";
import {BondContract}   from "../../src/BondContract.sol";

/// @notice End-to-end flow: create → purchase → vest → claim across all vesting types.
contract FullFlowTest is Fixtures {
    function setUp() public {
        _deployProtocol();
    }

    // ── Linear vesting full lifecycle ─────────────────────────────────────────

    function test_linearVesting_fullLifecycle() public {
        // Creator creates a bond
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.vestingParams = _linearParams(90 days);
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        // Buyer purchases
        uint256 payAmt = 900e6; // 900 USDC
        principal.mint(creator, 1000e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer);  payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(buyer);
        uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // Position: 900 principal, 0 claimed
        assertEq(nft.position(tokenId).principalAmount, 900e18);
        assertEq(nft.position(tokenId).claimedAmount,   0);

        // Day 30: claim 1/3
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer); nft.claim(tokenId);
        assertApproxEqAbs(nft.position(tokenId).claimedAmount, 300e18, 1e15);

        // Day 60: claim another 1/3
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer); nft.claim(tokenId);
        assertApproxEqAbs(nft.position(tokenId).claimedAmount, 600e18, 1e15);

        // Day 90: claim final 1/3
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer); nft.claim(tokenId);
        assertEq(nft.position(tokenId).claimedAmount, 900e18);
        assertEq(principal.balanceOf(buyer), 900e18);
    }

    // ── Cliff vesting ─────────────────────────────────────────────────────────

    function test_cliffVesting_fullLifecycle() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.vestingType   = uint8(IVestingModule.VestingType.Cliff);
        p.vestingParams = _cliffParams(30 days, 90 days);
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        // Pre-warp to a known base so absolute timestamps are predictable (via_ir may re-read block.timestamp)
        vm.warp(100_000);
        vm.prank(buyer); uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // Before cliff — nothing
        vm.warp(100_000 + 20 days);
        assertEq(nft.claimable(tokenId), 0);

        // At cliff (day 30) — linear post-cliff starts at 0 elapsed
        vm.warp(100_000 + 30 days);
        assertEq(nft.claimable(tokenId), 0);

        // Day 60 — 30/60 days post-cliff = 50%
        vm.warp(100_000 + 60 days);
        assertApproxEqAbs(nft.claimable(tokenId), 50e18, 1e15);

        // Day 90 — fully vested
        vm.warp(100_000 + 90 days);
        assertEq(nft.claimable(tokenId), 100e18);
        vm.prank(buyer); nft.claim(tokenId);
        assertEq(principal.balanceOf(buyer), 100e18);
    }

    // ── Step vesting ──────────────────────────────────────────────────────────

    function test_stepVesting_fullLifecycle() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.vestingType   = uint8(IVestingModule.VestingType.Step);
        p.vestingParams = _stepParams(4, 30 days);
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        uint256 payAmt = 100e6;
        principal.mint(creator, 200e18);
        payment.mint(buyer, payAmt);
        vm.prank(buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        vm.warp(100_000);
        vm.prank(buyer); uint256 tokenId = BondContract(bond).purchase(payAmt, 0);

        // Each step unlocks 25%
        for (uint256 step = 1; step <= 4; step++) {
            vm.warp(100_000 + step * 30 days);
            uint128 claimAmt = nft.claimable(tokenId);
            assertApproxEqAbs(claimAmt, 25e18, 1e15);
            vm.prank(buyer); nft.claim(tokenId);
        }

        assertEq(principal.balanceOf(buyer), 100e18);
    }

    // ── Oracle-priced bond ────────────────────────────────────────────────────

    function test_oraclePricedBond_priceUpdates() public {
        MockPriceFeed feed = new MockPriceFeed(8, 1e8); // $1

        IBondFactory.BondParams memory p = _defaultBondParams();
        p.priceFeed         = address(feed);
        p.pricePerPrincipal = 0;
        p.maxPriceAge       = 3600;
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        principal.mint(creator, 500e18);
        payment.mint(buyer, 100e6);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(buyer); payment.approve(bond, 100e6);

        // At $1: 100 USDC → 100 principal
        vm.prank(buyer);
        uint256 tokenId1 = BondContract(bond).purchase(100e6, 0);
        assertEq(nft.position(tokenId1).principalAmount, 100e18);

        // Price doubles to $2
        feed.setAnswer(2e8);
        feed.setUpdatedAt(block.timestamp);

        payment.mint(buyer2, 100e6);
        vm.prank(buyer2); payment.approve(bond, 100e6);
        vm.prank(buyer2);
        uint256 tokenId2 = BondContract(bond).purchase(100e6, 0);
        // At $2: 100 USDC → 50 principal
        assertEq(nft.position(tokenId2).principalAmount, 50e18);
    }

    // ── Escrow bond — full lifecycle ──────────────────────────────────────────

    function test_escrowBond_fullLifecycle() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.depositPrincipal    = true;
        p.capacityInPrincipal = 100e18;
        p.maxPurchasePrincipal= 100e18;
        p.vestingParams       = _linearParams(60 days);
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        // Creator deposits escrow
        principal.mint(creator, 100e18);
        vm.prank(creator); principal.approve(bond, 100e18);
        vm.prank(creator); BondContract(bond).depositEscrow();

        // Buyer purchases
        payment.mint(buyer, 100e6);
        vm.prank(buyer); payment.approve(bond, 100e6);
        vm.prank(buyer); uint256 tokenId = BondContract(bond).purchase(100e6, 0);

        // Bond is now at capacity → closed automatically
        assertTrue(BondContract(bond).state().closed);

        // Creator withdraws unsold escrow (0 in this case — fully sold)
        vm.prank(creator); BondContract(bond).withdrawEscrow();

        // Buyer claims at vesting end
        vm.warp(block.timestamp + 61 days);
        vm.prank(buyer); nft.claim(tokenId);
        assertEq(principal.balanceOf(buyer), 100e18);
    }

    // ── NFT transfer — claim rights pass to new owner ─────────────────────────

    function test_nftTransfer_claimRightsPassToNewOwner() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.vestingParams = _linearParams(60 days);
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        payment.mint(buyer, 100e6);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(buyer); payment.approve(bond, 100e6);
        vm.prank(buyer); uint256 tokenId = BondContract(bond).purchase(100e6, 0);

        // Buyer claims at day 30 (50%)
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(buyer), 50e18, 1e15);

        // Buyer sells NFT to buyer2
        vm.prank(buyer); nft.transferFrom(buyer, buyer2, tokenId);

        // buyer2 claims remainder at day 60
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(buyer2); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(buyer2), 50e18, 1e15);
    }

    // ── Multiple buyers ───────────────────────────────────────────────────────

    function test_multipleBuyers() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.capacityInPrincipal  = 500e18;
        p.maxPurchasePrincipal = 300e18;
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        principal.mint(creator, 600e18);
        vm.prank(creator); principal.approve(bond, type(uint256).max);

        payment.mint(buyer,  200e6);
        payment.mint(buyer2, 200e6);
        vm.prank(buyer);  payment.approve(bond, 200e6);
        vm.prank(buyer2); payment.approve(bond, 200e6);

        vm.prank(buyer);  BondContract(bond).purchase(200e6, 0);
        vm.prank(buyer2); BondContract(bond).purchase(200e6, 0);

        IBondContract.BondState memory st = BondContract(bond).state();
        assertEq(st.totalSold, 400e18);
    }

    // ── Discount bond ─────────────────────────────────────────────────────────

    function test_discountBond_buyerGetsMorePrincipal() public {
        IBondFactory.BondParams memory p = _defaultBondParams();
        p.discountBps = 1000; // 10% discount
        vm.prank(creator);
        address bond = factory.createBond(p, new address[](0));

        principal.mint(creator, 200e18);
        payment.mint(buyer, 100e6);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(buyer); payment.approve(bond, 100e6);

        vm.prank(buyer);
        uint256 tokenId = BondContract(bond).purchase(100e6, 0);

        // 100 USDC at 10% discount: effective price = 0.9, principal ≈ 111.11e18
        uint128 princ = nft.position(tokenId).principalAmount;
        assertGt(princ, 100e18);
        assertApproxEqAbs(princ, 111_111_111_111_111_111_111, 1e12);
    }
}

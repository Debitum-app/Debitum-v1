// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}       from "./helpers/Fixtures.sol";
import {IBondContract}  from "../src/interfaces/IBondContract.sol";
import {IBondNFT}       from "../src/interfaces/IModules.sol";
import {IVestingModule} from "../src/interfaces/IModules.sol";
import {BondContract}   from "../src/BondContract.sol";
import {BondNFT}        from "../src/BondNFT.sol";

contract BondNFTTest is Fixtures {
    address internal bond;

    function setUp() public {
        _deployProtocol();
        bond = _createDefaultBond();
    }

    // ── mint ──────────────────────────────────────────────────────────────────

    function test_mint_tokenIdIncrementsCorrectly() public {
        uint256 tokenId0 = _buy(buyer,  100e6);
        uint256 tokenId1 = _buy(buyer2, 100e6);
        assertEq(tokenId0, 0);
        assertEq(tokenId1, 1);
    }

    function test_mint_positionDataCorrect() public {
        uint256 tokenId = _buy(buyer, 100e6);
        IBondNFT.Position memory pos = nft.position(tokenId);
        assertEq(pos.principalToken,   address(principal));
        assertEq(pos.paymentToken,     address(payment));
        assertEq(pos.principalAmount,  100e18);
        assertEq(pos.claimedAmount,    0);
        assertEq(pos.purchasePrice,    100e6);
        assertEq(pos.bondContract,     bond);
        assertEq(pos.vestingModule,    address(vesting));
    }

    function test_mint_revertNonMinter() public {
        IVestingModule.Schedule memory s;
        vm.prank(buyer);
        vm.expectRevert();
        nft.mint(buyer, bond, s, address(principal), address(payment), 100e6);
    }

    // ── claim ─────────────────────────────────────────────────────────────────

    function test_claim_afterFullVesting() public {
        uint256 tokenId = _buy(buyer, 100e6);

        // Warp past vesting end (30 days linear)
        vm.warp(block.timestamp + 31 days);

        // Creator needs to have approved the bond for pulling principal
        // (already set in _buy via principal.approve)
        // But claim pulls from bond contract — bond has to have tokens
        // In non-escrow mode, principal is pulled from creator at purchase time
        // so bond already holds the tokens

        uint256 balBefore = principal.balanceOf(buyer);

        vm.prank(buyer);
        nft.claim(tokenId);

        assertEq(principal.balanceOf(buyer) - balBefore, 100e18);
        assertEq(nft.position(tokenId).claimedAmount, 100e18);
    }

    function test_claim_partialVesting() public {
        uint256 tokenId = _buy(buyer, 100e6);

        // 15 days = 50% through 30-day linear vesting
        vm.warp(block.timestamp + 15 days);

        uint256 balBefore = principal.balanceOf(buyer);
        vm.prank(buyer);
        nft.claim(tokenId);

        uint256 claimed = principal.balanceOf(buyer) - balBefore;
        assertApproxEqAbs(claimed, 50e18, 1e15); // ~50 tokens ±0.001
    }

    function test_claim_revertNothingToClaim() public {
        uint256 tokenId = _buy(buyer, 100e6);
        // Don't warp — nothing unlocked yet at t=0 (startTime = block.timestamp, no time elapsed)

        vm.prank(buyer);
        vm.expectRevert(IBondNFT.NothingToClaim.selector);
        nft.claim(tokenId);
    }

    function test_claim_revertNotOwner() public {
        uint256 tokenId = _buy(buyer, 100e6);
        vm.warp(block.timestamp + 31 days);

        vm.prank(buyer2);
        vm.expectRevert(IBondNFT.NotOwner.selector);
        nft.claim(tokenId);
    }

    function test_claim_twice_doesNotDoubleWithdraw() public {
        uint256 tokenId = _buy(buyer, 100e6);
        vm.warp(block.timestamp + 31 days);

        vm.prank(buyer); nft.claim(tokenId);

        uint256 balAfterFirst = principal.balanceOf(buyer);

        // Second claim — nothing left
        vm.prank(buyer);
        vm.expectRevert(IBondNFT.NothingToClaim.selector);
        nft.claim(tokenId);

        assertEq(principal.balanceOf(buyer), balAfterFirst);
    }

    // ── claimFor ──────────────────────────────────────────────────────────────

    function test_claimFor_approvedOperator() public {
        uint256 tokenId = _buy(buyer, 100e6);
        vm.warp(block.timestamp + 31 days);

        address operator = makeAddr("operator");
        vm.prank(buyer);
        nft.setApprovalForAll(operator, true);

        vm.prank(operator);
        nft.claimFor(tokenId, buyer);
        assertEq(principal.balanceOf(buyer), 100e18);
    }

    function test_claimFor_revertUnauthorized() public {
        uint256 tokenId = _buy(buyer, 100e6);
        vm.warp(block.timestamp + 31 days);

        vm.prank(buyer2);
        vm.expectRevert(IBondNFT.NotOwner.selector);
        nft.claimFor(tokenId, buyer);
    }

    // ── transfer semantics ────────────────────────────────────────────────────

    function test_transfer_newOwnerClaimsRemainder() public {
        uint256 tokenId = _buy(buyer, 100e6);

        // Buyer claims at 50%
        vm.warp(block.timestamp + 15 days);
        vm.prank(buyer); nft.claim(tokenId);

        // Buyer transfers NFT to buyer2
        vm.prank(buyer);
        nft.transferFrom(buyer, buyer2, tokenId);

        // Warp to full vesting
        vm.warp(block.timestamp + 15 days + 1);
        uint256 balBefore = principal.balanceOf(buyer2);
        vm.prank(buyer2); nft.claim(tokenId);

        // buyer2 should receive ~50 tokens (the remaining 50%)
        assertApproxEqAbs(principal.balanceOf(buyer2) - balBefore, 50e18, 1e15);
    }

    // ── claimable view ────────────────────────────────────────────────────────

    function test_claimable_view() public {
        uint256 tokenId = _buy(buyer, 100e6);
        vm.warp(block.timestamp + 15 days);
        uint128 c = nft.claimable(tokenId);
        assertApproxEqAbs(c, 50e18, 1e15);
    }

    // ── tokenURI ──────────────────────────────────────────────────────────────

    function test_tokenURI_returnsBase64JSON() public {
        uint256 tokenId = _buy(buyer, 100e6);
        string memory uri = nft.tokenURI(tokenId);
        // Should start with data:application/json;base64,
        bytes memory b = bytes(uri);
        assertTrue(b.length > 50);
        // Prefix check
        assertEq(bytes(uri)[0], "d");
        assertEq(bytes(uri)[4], ":");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _buy(address _buyer, uint256 payAmt) internal returns (uint256 tokenId) {
        principal.mint(creator, payAmt * 2e12); // ensure creator has enough principal
        payment.mint(_buyer, payAmt);
        vm.prank(_buyer); payment.approve(bond, payAmt);
        vm.prank(creator); principal.approve(bond, type(uint256).max);
        vm.prank(_buyer);
        tokenId = BondContract(bond).purchase(payAmt, 0);
    }
}

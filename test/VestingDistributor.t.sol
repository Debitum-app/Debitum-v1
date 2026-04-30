// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixtures}           from "./helpers/Fixtures.sol";
import {MockERC20, MockUSDT} from "./helpers/MockERC20.sol";
import {VestingDistributor} from "../src/VestingDistributor.sol";
import {IBondNFT}           from "../src/interfaces/IModules.sol";
import {IVestingModule}     from "../src/interfaces/IModules.sol";
import {IERC20}             from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

contract VestingDistributorTest is Fixtures {
    VestingDistributor internal distributor;

    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    function setUp() public {
        _deployProtocol();

        distributor = new VestingDistributor(address(nft), address(vesting));

        vm.startPrank(admin);
        nft.grantRole(nft.MINTER_ROLE(), address(distributor));
        vm.stopPrank();
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(distributor.bondNFT()),       address(nft));
        assertEq(address(distributor.vestingModule()), address(vesting));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(VestingDistributor.ZeroAddress.selector);
        new VestingDistributor(address(0), address(vesting));

        vm.expectRevert(VestingDistributor.ZeroAddress.selector);
        new VestingDistributor(address(nft), address(0));
    }

    function test_distributionCount_startsAtZero() public view {
        assertEq(distributor.distributionCount(), 0);
    }

    function test_distributionsByCreator_unknownReturnsEmpty() public {
        uint256[] memory ids = distributor.distributionsByCreator(makeAddr("nobody"));
        assertEq(ids.length, 0);
    }

    // ── Input validation ──────────────────────────────────────────────────────

    function test_distribute_rejectsZeroToken() public {
        address[] memory recips  = _oneRecipient(alice);
        uint128[]  memory amounts = _oneAmount(100e18);
        vm.expectRevert(VestingDistributor.ZeroToken.selector);
        distributor.distribute(address(0), recips, amounts, 0, _linearParams(30 days));
    }

    function test_distribute_rejectsNoRecipients() public {
        vm.expectRevert(VestingDistributor.NoRecipients.selector);
        distributor.distribute(
            address(principal),
            new address[](0),
            new uint128[](0),
            0,
            _linearParams(30 days)
        );
    }

    function test_distribute_rejectsTooManyRecipients() public {
        uint256 n = distributor.MAX_RECIPIENTS() + 1;
        address[] memory recips  = new address[](n);
        uint128[]  memory amounts = new uint128[](n);
        for (uint256 i; i < n; i++) {
            recips[i]  = makeAddr(string(abi.encode(i)));
            amounts[i] = 1e18;
        }

        principal.mint(address(this), n * 1e18);
        principal.approve(address(distributor), type(uint256).max);

        vm.expectRevert(VestingDistributor.TooManyRecipients.selector);
        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
    }

    function test_distribute_exactlyMaxRecipients_succeeds() public {
        uint256 n = distributor.MAX_RECIPIENTS();
        address[] memory recips  = new address[](n);
        uint128[]  memory amounts = new uint128[](n);
        for (uint256 i; i < n; i++) {
            recips[i]  = makeAddr(string(abi.encode(i)));
            amounts[i] = 1e18;
        }

        principal.mint(address(this), n * 1e18);
        principal.approve(address(distributor), type(uint256).max);

        uint256 id = distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
        assertEq(distributor.getDistribution(id).count, n);
    }

    function test_distribute_rejectsLengthMismatch() public {
        address[] memory recips  = new address[](2);
        recips[0] = alice; recips[1] = bob;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 100e18;

        vm.expectRevert(VestingDistributor.LengthMismatch.selector);
        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
    }

    function test_distribute_rejectsZeroRecipientAddress() public {
        address[] memory recips  = new address[](1);
        recips[0] = address(0);
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 100e18;

        principal.mint(address(this), 100e18);
        principal.approve(address(distributor), type(uint256).max);

        vm.expectRevert(VestingDistributor.ZeroAddress.selector);
        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
    }

    function test_distribute_rejectsZeroAmountInMiddle() public {
        address[] memory recips  = new address[](3);
        recips[0] = alice; recips[1] = bob; recips[2] = charlie;
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 100e18; amounts[1] = 0; amounts[2] = 100e18;

        principal.mint(address(this), 200e18);
        principal.approve(address(distributor), type(uint256).max);

        vm.expectRevert(VestingDistributor.ZeroAmount.selector);
        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
    }

    // ── Linear vesting distribution ───────────────────────────────────────────

    function test_distribute_linear_singleRecipient() public {
        uint128 amount = 1_000e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        uint256 distId = distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Linear),
            _linearParams(90 days)
        );

        assertEq(distId, 0);
        assertEq(distributor.distributionCount(), 1);

        VestingDistributor.DistributionRecord memory rec = distributor.getDistribution(0);
        assertEq(rec.creator,      address(this));
        assertEq(rec.token,        address(principal));
        assertEq(rec.totalAmount,  amount);
        assertEq(rec.count,        1);

        // Tokens pulled from creator
        assertEq(principal.balanceOf(address(this)),        0);
        assertEq(principal.balanceOf(address(distributor)), amount);

        // NFT position data correct
        uint256 tokenId = rec.firstTokenId;
        assertEq(nft.position(tokenId).principalAmount, amount);
        assertEq(nft.position(tokenId).claimedAmount,   0);
    }

    function test_distribute_linear_multipleRecipients() public {
        address[] memory recips  = new address[](3);
        recips[0] = alice; recips[1] = bob; recips[2] = charlie;
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 100e18; amounts[1] = 200e18; amounts[2] = 300e18;
        uint128 total = 600e18;

        principal.mint(address(this), total);
        principal.approve(address(distributor), total);

        distributor.distribute(
            address(principal),
            recips, amounts,
            uint8(IVestingModule.VestingType.Linear),
            _linearParams(60 days)
        );

        VestingDistributor.DistributionRecord memory rec = distributor.getDistribution(0);
        assertEq(rec.totalAmount, total);
        assertEq(rec.count,       3);

        assertEq(nft.position(rec.firstTokenId).principalAmount,     100e18);
        assertEq(nft.position(rec.firstTokenId + 1).principalAmount, 200e18);
        assertEq(nft.position(rec.firstTokenId + 2).principalAmount, 300e18);
    }

    // ── NFT position metadata ─────────────────────────────────────────────────

    function test_position_metadata_bondContractIsDistributor() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).bondContract, address(distributor));
    }

    function test_position_metadata_principalTokenSet() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).principalToken, address(principal));
    }

    function test_position_metadata_vestingModuleSnapshotted() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).vestingModule, address(vesting));
    }

    function test_position_metadata_paymentTokenIsZero() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).paymentToken, address(0));
    }

    // ── Cliff vesting distribution ────────────────────────────────────────────

    function test_distribute_cliff_claimableBeforeAndAfterCliff() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.warp(100_000);
        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Cliff),
            _cliffParams(30 days, 90 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Before cliff — nothing
        vm.warp(100_000 + 20 days);
        assertEq(nft.claimable(tokenId), 0);

        // At cliff — still 0 (linear starts at 0 elapsed post-cliff)
        vm.warp(100_000 + 30 days);
        assertEq(nft.claimable(tokenId), 0);

        // Day 60 — 50%
        vm.warp(100_000 + 60 days);
        assertApproxEqAbs(nft.claimable(tokenId), 50e18, 1e15);

        // Day 90 — 100%, claim
        vm.warp(100_000 + 90 days);
        vm.prank(alice);
        nft.claim(tokenId);
        assertEq(principal.balanceOf(alice), amount);
    }

    // ── Step vesting distribution ─────────────────────────────────────────────

    function test_distribute_step_claimsEachStep() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.warp(100_000);
        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Step),
            _stepParams(4, 30 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Before first step — nothing
        vm.warp(100_000 + 15 days);
        assertEq(nft.claimable(tokenId), 0);

        for (uint256 step = 1; step <= 4; step++) {
            vm.warp(100_000 + step * 30 days);
            assertApproxEqAbs(nft.claimable(tokenId), 25e18, 1e15);
            vm.prank(alice); nft.claim(tokenId);
        }
        assertEq(principal.balanceOf(alice), amount);
        assertEq(nft.claimable(tokenId), 0);
    }

    // ── Claim mechanics — tokens come from distributor ────────────────────────

    function test_claim_transfersFromDistributorToOwner() public {
        uint128 amount = 500e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Linear),
            _linearParams(60 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        vm.warp(block.timestamp + 61 days);

        assertEq(principal.balanceOf(address(distributor)), amount);

        vm.prank(alice);
        nft.claim(tokenId);

        assertEq(principal.balanceOf(alice),                amount);
        assertEq(principal.balanceOf(address(distributor)), 0);
    }

    function test_claim_partialThenFull() public {
        uint128 amount = 120e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.warp(100_000);
        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Linear),
            _linearParams(60 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Day 20: claim 1/3
        vm.warp(100_000 + 20 days);
        vm.prank(alice); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(alice), 40e18, 1e15);

        // Day 40: claim another 1/3
        vm.warp(100_000 + 40 days);
        vm.prank(alice); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(alice), 80e18, 1e15);

        // Day 60: final 1/3
        vm.warp(100_000 + 60 days);
        vm.prank(alice); nft.claim(tokenId);
        assertEq(principal.balanceOf(alice), amount);
        assertEq(nft.position(tokenId).claimedAmount, amount);
    }

    function test_claim_nothingToClaimReverts() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Nothing claimable yet (before vesting starts returning anything meaningful)
        vm.expectRevert();
        vm.prank(alice); nft.claim(tokenId);
    }

    // ── NFT transfer — new owner claims ──────────────────────────────────────

    function test_claim_afterNftTransfer_newOwnerReceivesTokens() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Linear),
            _linearParams(60 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Alice claims 50% at day 30
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(alice), 50e18, 1e15);

        // Alice transfers NFT to bob
        vm.prank(alice); nft.transferFrom(alice, bob, tokenId);

        // Bob claims remaining 50% at day 60
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(bob); nft.claim(tokenId);
        assertApproxEqAbs(principal.balanceOf(bob), 50e18, 1e15);

        // Alice keeps what she already claimed; bob gets the remainder
        assertApproxEqAbs(principal.balanceOf(alice) + principal.balanceOf(bob), amount, 1e15);
    }

    // ── Multiple distributions ────────────────────────────────────────────────

    function test_multipleDistributions_trackedPerCreator() public {
        principal.mint(address(this), 300e18);
        principal.approve(address(distributor), 300e18);

        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(100e18), 0, _linearParams(30 days));
        distributor.distribute(address(principal), _oneRecipient(bob),   _oneAmount(200e18), 0, _linearParams(60 days));

        assertEq(distributor.distributionCount(), 2);

        uint256[] memory ids = distributor.distributionsByCreator(address(this));
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);

        assertEq(distributor.getDistribution(0).totalAmount, 100e18);
        assertEq(distributor.getDistribution(1).totalAmount, 200e18);
    }

    function test_multipleDistributions_firstTokenIdSequential() public {
        principal.mint(address(this), 300e18);
        principal.approve(address(distributor), 300e18);

        // 2-recipient distribution first
        address[] memory recips2 = new address[](2);
        uint128[]  memory amounts2 = new uint128[](2);
        recips2[0] = alice;   recips2[1] = bob;
        amounts2[0] = 100e18; amounts2[1] = 100e18;
        distributor.distribute(address(principal), recips2, amounts2, 0, _linearParams(30 days));

        // 1-recipient distribution second
        distributor.distribute(address(principal), _oneRecipient(charlie), _oneAmount(100e18), 0, _linearParams(30 days));

        VestingDistributor.DistributionRecord memory d0 = distributor.getDistribution(0);
        VestingDistributor.DistributionRecord memory d1 = distributor.getDistribution(1);

        // d1's firstTokenId = d0's firstTokenId + d0's count
        assertEq(d1.firstTokenId, d0.firstTokenId + d0.count);
    }

    function test_twoCreators_separateDistributions() public {
        address creator1 = makeAddr("creator1");
        address creator2 = makeAddr("creator2");
        principal.mint(creator1, 100e18);
        principal.mint(creator2, 200e18);

        vm.prank(creator1); principal.approve(address(distributor), 100e18);
        vm.prank(creator2); principal.approve(address(distributor), 200e18);

        vm.prank(creator1);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(100e18), 0, _linearParams(30 days));
        vm.prank(creator2);
        distributor.distribute(address(principal), _oneRecipient(bob),   _oneAmount(200e18), 0, _linearParams(60 days));

        assertEq(distributor.distributionsByCreator(creator1).length, 1);
        assertEq(distributor.distributionsByCreator(creator2).length, 1);
        assertEq(distributor.getDistribution(0).creator, creator1);
        assertEq(distributor.getDistribution(1).creator, creator2);
    }

    // ── createdAt timestamp ───────────────────────────────────────────────────

    function test_distribute_createdAtTimestamp() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        uint256 ts = 1_700_000_000;
        vm.warp(ts);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        assertEq(distributor.getDistribution(0).createdAt, ts);
    }

    // ── USDT-style token (forceApprove) ───────────────────────────────────────

    function test_distribute_usdtStyleToken_works() public {
        MockUSDT usdt = new MockUSDT();

        // Grant MINTER_ROLE for distributor already done; but we need to also ensure
        // distributor can give BondNFT approval of usdt. forceApprove handles this.
        uint128 amount = 1_000e6; // 1000 USDT (6 decimals)
        usdt.mint(address(this), amount);
        usdt.approve(address(distributor), amount);

        uint256 distId = distributor.distribute(
            address(usdt),
            _oneRecipient(alice),
            _oneAmount(amount),
            0,
            _linearParams(30 days)
        );

        VestingDistributor.DistributionRecord memory rec = distributor.getDistribution(distId);
        assertEq(rec.totalAmount, amount);
        assertEq(usdt.balanceOf(address(distributor)), amount);
    }

    function test_distribute_usdtStyleToken_secondDistribution_noDoubleApprove() public {
        MockUSDT usdt = new MockUSDT();
        uint128 amount = 500e6;

        usdt.mint(address(this), uint256(amount) * 2);
        usdt.approve(address(distributor), uint256(amount) * 2);

        // First distribution sets max approval
        distributor.distribute(address(usdt), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        // Second distribution — should NOT call forceApprove again (already maxed)
        // If it tried to approve again on a USDT-style token, it could fail
        // Here it succeeds because _maxApproved[token] = true skips the approval
        distributor.distribute(address(usdt), _oneRecipient(bob), _oneAmount(amount), 0, _linearParams(30 days));

        assertEq(usdt.balanceOf(address(distributor)), uint256(amount) * 2);
    }

    // ── Multiple tokens in different distributions ────────────────────────────

    function test_distribute_twoTokens_independentApprovals() public {
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 6);

        uint128 amtA = 100e18;
        uint128 amtB = 100e6;

        tokenA.mint(address(this), amtA);
        tokenB.mint(address(this), amtB);
        tokenA.approve(address(distributor), amtA);
        tokenB.approve(address(distributor), amtB);

        distributor.distribute(address(tokenA), _oneRecipient(alice), _oneAmount(amtA), 0, _linearParams(30 days));
        distributor.distribute(address(tokenB), _oneRecipient(bob),   _oneAmount(amtB), 0, _linearParams(30 days));

        assertEq(tokenA.balanceOf(address(distributor)), amtA);
        assertEq(tokenB.balanceOf(address(distributor)), amtB);

        assertEq(nft.position(distributor.getDistribution(0).firstTokenId).principalToken, address(tokenA));
        assertEq(nft.position(distributor.getDistribution(1).firstTokenId).principalToken, address(tokenB));
    }

    // ── 8-decimal token (WBTC-style) ─────────────────────────────────────────

    function test_distribute_8decimalToken() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        uint128 amount = 1e8; // 1 WBTC

        wbtc.mint(address(this), amount);
        wbtc.approve(address(distributor), amount);

        distributor.distribute(address(wbtc), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(365 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).principalAmount, amount);
        assertEq(nft.position(tokenId).principalToken, address(wbtc));

        // After full vesting, claim
        vm.warp(block.timestamp + 366 days);
        vm.prank(alice); nft.claim(tokenId);
        assertEq(wbtc.balanceOf(alice), amount);
    }

    // ── Max approval is set once per token ───────────────────────────────────

    function test_distribute_maxApprovalSetOnce() public {
        principal.mint(address(this), 200e18);
        principal.approve(address(distributor), 200e18);

        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(100e18), 0, _linearParams(30 days));
        distributor.distribute(address(principal), _oneRecipient(bob),   _oneAmount(100e18), 0, _linearParams(30 days));

        uint256 id1 = distributor.getDistribution(0).firstTokenId;
        uint256 id2 = distributor.getDistribution(1).firstTokenId;
        assertEq(nft.position(id1).principalAmount, 100e18);
        assertEq(nft.position(id2).principalAmount, 100e18);
    }

    // ── Event emission ────────────────────────────────────────────────────────

    function test_distribute_emitsEvent() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.expectEmit(true, true, true, true);
        emit VestingDistributor.Distributed(0, address(this), address(principal), amount, 1);

        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));
    }

    function test_distribute_emitsEvent_correctRecipientCount() public {
        address[] memory recips  = new address[](3);
        recips[0] = alice; recips[1] = bob; recips[2] = charlie;
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 10e18; amounts[1] = 20e18; amounts[2] = 30e18;
        uint128 total = 60e18;

        principal.mint(address(this), total);
        principal.approve(address(distributor), total);

        vm.expectEmit(true, true, true, true);
        emit VestingDistributor.Distributed(0, address(this), address(principal), total, 3);

        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));
    }

    // ── purchasePrice is 0 on minted positions ────────────────────────────────

    function test_distribute_purchasePriceIsZero() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.position(tokenId).purchasePrice, 0);
    }

    // ── NFT ownership ─────────────────────────────────────────────────────────

    function test_distribute_nftMintedToRecipient() public {
        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);
        distributor.distribute(address(principal), _oneRecipient(alice), _oneAmount(amount), 0, _linearParams(30 days));

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_distribute_multipleRecipients_eachOwnsTheirNft() public {
        address[] memory recips  = new address[](3);
        recips[0] = alice; recips[1] = bob; recips[2] = charlie;
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 10e18; amounts[1] = 20e18; amounts[2] = 30e18;

        principal.mint(address(this), 60e18);
        principal.approve(address(distributor), 60e18);
        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));

        uint256 first = distributor.getDistribution(0).firstTokenId;
        assertEq(nft.ownerOf(first),     alice);
        assertEq(nft.ownerOf(first + 1), bob);
        assertEq(nft.ownerOf(first + 2), charlie);
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    /// @notice Fuzz: any valid amount distributes correctly and is fully claimable.
    function testFuzz_distribute_linear_anyAmount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= type(uint128).max / 2);

        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.warp(100_000);
        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            0,
            _linearParams(30 days)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;
        vm.warp(100_000 + 31 days);
        vm.prank(alice); nft.claim(tokenId);
        assertEq(principal.balanceOf(alice), amount);
    }

    /// @notice Fuzz: variable number of recipients (1..20), total always transferred correctly.
    function testFuzz_distribute_variableRecipients(uint8 n) public {
        n = uint8(bound(n, 1, 20));

        address[] memory recips  = new address[](n);
        uint128[]  memory amounts = new uint128[](n);
        uint256 total;
        for (uint256 i; i < n; i++) {
            recips[i]  = makeAddr(string(abi.encode("fuzz", i)));
            amounts[i] = 1e18;
            total     += 1e18;
        }

        principal.mint(address(this), total);
        principal.approve(address(distributor), total);

        distributor.distribute(address(principal), recips, amounts, 0, _linearParams(30 days));

        assertEq(principal.balanceOf(address(distributor)), total);
        assertEq(distributor.getDistribution(0).count, n);
        assertEq(distributor.getDistribution(0).totalAmount, total);
    }

    /// @notice Fuzz: cliff duration always < total duration, valid schedule produced.
    function testFuzz_distribute_cliffParams(uint64 cliff, uint64 total_) public {
        vm.assume(cliff > 0 && cliff < 365 days);
        vm.assume(total_ > cliff && total_ <= 3650 days);

        uint128 amount = 100e18;
        principal.mint(address(this), amount);
        principal.approve(address(distributor), amount);

        vm.warp(1_000_000);
        distributor.distribute(
            address(principal),
            _oneRecipient(alice),
            _oneAmount(amount),
            uint8(IVestingModule.VestingType.Cliff),
            _cliffParams(cliff, total_)
        );

        uint256 tokenId = distributor.getDistribution(0).firstTokenId;

        // Before cliff: claimable = 0
        vm.warp(1_000_000 + cliff / 2);
        assertEq(nft.claimable(tokenId), 0);

        // After full vesting: claimable = full amount
        vm.warp(1_000_000 + total_);
        assertEq(nft.claimable(tokenId), amount);
    }

    // ── Reentrancy guard ──────────────────────────────────────────────────────

    function test_distribute_reentrantTokenReverts() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(distributor), address(nft));

        // Grant MINTER_ROLE so the attacker's inner call would theoretically succeed
        vm.startPrank(admin);
        nft.grantRole(nft.MINTER_ROLE(), address(attacker));
        vm.stopPrank();

        uint128 amount = 100e18;
        attacker.prepare(alice, amount);

        vm.expectRevert();
        attacker.attack();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _oneRecipient(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _oneAmount(uint128 a) internal pure returns (uint128[] memory r) {
        r = new uint128[](1);
        r[0] = a;
    }
}

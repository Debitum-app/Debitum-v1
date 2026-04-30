// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBondNFT}       from "./interfaces/IModules.sol";
import {IVestingModule} from "./interfaces/IModules.sol";

/// @title  VestingDistributor
/// @author Debitum
/// @notice Distribute tokens to multiple recipients with vesting schedules — no payment required.
///         Each recipient receives a BondNFT position representing their vesting rights.
///         They can claim unlocked tokens at any time via the existing BondNFT.claim() flow.
///
/// @dev    FLOW
///         1. Creator calls distribute(token, recipients, amounts, vestingType, vestingParams)
///         2. Contract pulls total tokens from creator (requires prior ERC20 approval)
///         3. One NFT is minted per recipient — each NFT carries its own vesting schedule
///         4. Recipients call BondNFT.claim(tokenId) to withdraw unlocked tokens
///
///         CLAIM MECHANICS
///         BondNFT.claim() calls safeTransferFrom(vestingDistributor, owner, amount).
///         This works because VestingDistributor holds the tokens and has given BondNFT
///         a max allowance on creation (via forceApprove, so USDT-style tokens work too).
///
///         RECIPIENT LIMIT
///         Capped at MAX_RECIPIENTS per call to avoid out-of-gas on large batches.
///         For larger distributions, split into multiple calls.
contract VestingDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_RECIPIENTS = 200;

    IBondNFT       public immutable bondNFT;
    IVestingModule public immutable vestingModule;

    // Track max-approval state per token — forceApprove once, never reset needed
    mapping(address => bool) private _maxApproved;

    struct DistributionRecord {
        address creator;
        address token;
        uint256 totalAmount;
        uint64  createdAt;
        uint256 firstTokenId;
        uint256 count;
    }

    DistributionRecord[] public distributions;
    mapping(address => uint256[]) private _byCreator;

    error ZeroAddress();
    error ZeroToken();
    error NoRecipients();
    error TooManyRecipients();
    error LengthMismatch();
    error ZeroAmount();

    event Distributed(
        uint256 indexed distributionId,
        address indexed creator,
        address indexed token,
        uint256 totalAmount,
        uint256 recipients
    );

    constructor(address bondNFT_, address vestingModule_) {
        if (bondNFT_ == address(0) || vestingModule_ == address(0)) revert ZeroAddress();
        bondNFT       = IBondNFT(bondNFT_);
        vestingModule = IVestingModule(vestingModule_);
    }

    /// @notice Distribute tokens with vesting to multiple recipients in one transaction.
    /// @param token         ERC20 token to distribute (caller must have approved this contract)
    /// @param recipients    Addresses to receive NFT vesting positions
    /// @param amounts       Token amounts per recipient (same units as the token)
    /// @param vestingType   0=Linear, 1=Cliff, 2=Step
    /// @param vestingParams ABI-encoded LinearParams | CliffParams | StepParams
    /// @return distributionId Index into the distributions array
    function distribute(
        address         token,
        address[] calldata recipients,
        uint128[] calldata amounts,
        uint8             vestingType,
        bytes    calldata vestingParams
    ) external nonReentrant returns (uint256 distributionId) {
        if (token == address(0))                     revert ZeroToken();
        if (recipients.length == 0)                  revert NoRecipients();
        if (recipients.length > MAX_RECIPIENTS)      revert TooManyRecipients();
        if (recipients.length != amounts.length)     revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < recipients.length;) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0)             revert ZeroAmount();
            total += amounts[i];
            unchecked { ++i; }
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), total);

        // One-time max approval per token — forceApprove handles USDT-style tokens
        if (!_maxApproved[token]) {
            IERC20(token).forceApprove(address(bondNFT), type(uint256).max);
            _maxApproved[token] = true;
        }

        uint256 firstId = bondNFT.nextTokenId();
        uint64  now_    = uint64(block.timestamp);

        for (uint256 i; i < recipients.length;) {
            IVestingModule.Schedule memory schedule = vestingModule.buildSchedule(
                vestingType, vestingParams, amounts[i], now_
            );
            bondNFT.mint(recipients[i], address(this), schedule, token, address(0), 0);
            unchecked { ++i; }
        }

        distributionId = distributions.length;
        distributions.push(DistributionRecord({
            creator:      msg.sender,
            token:        token,
            totalAmount:  total,
            createdAt:    now_,
            firstTokenId: firstId,
            count:        recipients.length
        }));
        _byCreator[msg.sender].push(distributionId);

        emit Distributed(distributionId, msg.sender, token, total, recipients.length);
    }

    function distributionCount()                               external view returns (uint256)   { return distributions.length; }
    function distributionsByCreator(address c)                 external view returns (uint256[] memory) { return _byCreator[c]; }
    function getDistribution(uint256 id)                       external view returns (DistributionRecord memory) { return distributions[id]; }
}

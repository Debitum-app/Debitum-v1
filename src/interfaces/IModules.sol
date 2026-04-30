// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// IVestingModule
// ─────────────────────────────────────────────────────────────────────────────

interface IVestingModule {
    enum VestingType { Linear, Cliff, Step }

    struct LinearParams  { uint64 duration; }
    struct CliffParams   { uint64 cliffDuration; uint64 totalDuration; }
    struct StepParams    { uint64 stepDuration;  uint16 steps; }

    struct Schedule {
        VestingType vestingType;
        uint64      startTime;
        uint128     totalAmount;
        bytes       params;
    }

    error InvalidDuration();
    error CliffExceedsTotal();
    error ZeroSteps();
    error ZeroStepDuration();

    function buildSchedule(uint8 vestingType, bytes calldata params, uint128 amount, uint64 startTime) external pure returns (Schedule memory);
    function claimable(Schedule calldata schedule, uint128 alreadyClaimed) external view returns (uint128);
    function claimableAt(Schedule calldata schedule, uint128 alreadyClaimed, uint64 timestamp) external pure returns (uint128);
    function totalUnlocked(Schedule calldata schedule) external view returns (uint128);
    function vestingEnd(Schedule calldata schedule) external pure returns (uint64);
}

// ─────────────────────────────────────────────────────────────────────────────
// IBondNFT
// ─────────────────────────────────────────────────────────────────────────────

interface IBondNFT {
    struct Position {
        address vestingModule;   // snapshotted at mint — immutable per position
        address bondContract;
        address principalToken;
        address paymentToken;
        uint128 principalAmount;
        uint128 claimedAmount;
        uint128 purchasePrice;
        IVestingModule.Schedule schedule;
    }

    event Claimed(uint256 indexed tokenId, address indexed owner, uint128 amount);

    error NotOwner();
    error NothingToClaim();
    error NotBondContract();

    function mint(address to, address bondContract, IVestingModule.Schedule calldata schedule, address principalToken, address paymentToken, uint128 purchasePrice) external returns (uint256 tokenId);
    function claim(uint256 tokenId) external;
    function claimable(uint256 tokenId) external view returns (uint128);
    function position(uint256 tokenId) external view returns (Position memory);
    function nextTokenId() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// ITokenGate
// ─────────────────────────────────────────────────────────────────────────────

interface ITokenGate {
    enum CheckType { ERC20Balance, ERC721Balance, VotingEscrow, StakingContract, MerkleProof }

    /// @notice A single discount tier: balance threshold → discount in bps.
    ///         Tiers within a rule MUST be sorted in descending order by threshold.
    struct DiscountTier {
        uint128 threshold;   // minimum balance required for this tier
        uint16  discountBps; // discount applied when threshold is met (basis points)
    }

    /// @notice A single discount rule attached to a bond.
    ///         Discount is always computed via linear interpolation between tiers.
    ///         The higher the balance, the higher the discount — continuously.
    ///
    ///         Example: tiers = [1000e18->1500, 500e18->1000, 100e18->500]
    ///           balance=600e18  => 1000 + (1500-1000)*(600-500)/(1000-500) = 1100 bps
    ///           balance=9999e18 => 1500 bps (cap at top tier, no upward extrapolation)
    ///           balance=50e18   => 0 bps    (below min tier)
    struct GateRule {
        CheckType      checkType;
        address        token;        // token / ve-contract / staking contract address
        DiscountTier[] tiers;        // ≥1 tier, sorted descending by threshold
        bytes32        merkleRoot;   // only for MerkleProof check type
    }

    event RulesSet(address indexed bond, uint256 ruleCount);

    error NotBondCreator();
    error TooManyRules();
    error TooManyTiers();       // more than MAX_TIERS tiers in a single rule
    error InvalidDiscount();
    error InvalidThreshold();
    error TiersNotSorted();     // tiers are not sorted in descending order

    function setRules(address bond, GateRule[] calldata rules) external;
    function getDiscount(address buyer, address bond) external view returns (uint16);
    function getDiscountWithProof(address buyer, address bond, bytes32[] calldata proof, uint128 allocation) external view returns (uint16);
    function getRules(address bond) external view returns (GateRule[] memory);
}

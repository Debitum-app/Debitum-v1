// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable}          from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MerkleProof}              from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20}                   from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}                  from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ITokenGate}   from "./interfaces/IModules.sol";
import {IBondFactory} from "./interfaces/IBondFactory.sol";

/// @title  TokenGate
/// @author Debitum
/// @notice Tiered discount system for bond contracts.
///
/// @dev    TIER LOGIC
///         Each rule contains an array of tiers (DiscountTier[]).
///         Tiers are sorted in descending order by threshold — the contract scans top to bottom
///         and picks the first matching tier (the highest threshold the buyer has crossed).
///
///         Example for veCRV (3 tiers):
///           tiers[0]: threshold=1000e18, discountBps=1500  // whale: 15%
///           tiers[1]: threshold=500e18,  discountBps=1000  // mid:   10%
///           tiers[2]: threshold=100e18,  discountBps=500   // entry:  5%
///
///         Buyer with 600 veCRV → checks tiers: 1000? no → 500? yes → discount 1000 bps.
///         Buyer with 50  veCRV → no tier matched → discount 0.
///
///         NFT (ERC721Balance) — tier logic works for NFT collections;
///         a single tier acts as a binary gate, multiple tiers enable NFT-count-based discounts
///         (e.g. 1 NFT / 3 NFTs / 10 NFTs). Just add tiers as needed.
///
///         AGGREGATION ACROSS RULES
///         Discounts from different rules are summed and capped at maxDiscountCap.
///
///         CHECK TYPES
///         ERC20Balance    — balanceOf(buyer)
///         ERC721Balance   — balanceOf(buyer) [tiers by NFT count]
///         VotingEscrow    — locked(buyer).amount [veCRV, veBAL, veFXS and any fork]
///         StakingContract — stakedBalanceOf(buyer) [custom staking contract]
///         MerkleProof     — off-chain snapshot, first tier threshold = min allocation
contract TokenGate is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ITokenGate
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant MAX_RULES = 10;
    uint256 public constant MAX_TIERS = 8;  // gas safety: max 8 tiers per rule

    // ── Storage ───────────────────────────────────────────────────────────────

    address public bondFactory;
    uint16  public maxDiscountCap;

    /// @dev bond address → rules
    mapping(address => GateRule[]) private _rules;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address bondFactory_, uint16 maxDiscountCap_) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        if (bondFactory_ == address(0)) revert InvalidThreshold();
        if (maxDiscountCap_ == 0 || maxDiscountCap_ >= 10_000) revert InvalidDiscount();
        bondFactory    = bondFactory_;
        maxDiscountCap = maxDiscountCap_;
    }

    function setBondFactory(address newFactory) external onlyRole(ADMIN_ROLE) {
        if (newFactory == address(0)) revert InvalidThreshold();
        bondFactory = newFactory;
    }

    /// @notice Update the global discount cap (admin only)
    function setMaxDiscountCap(uint16 newCap) external onlyRole(ADMIN_ROLE) {
        if (newCap == 0 || newCap >= 10_000) revert InvalidDiscount();
        maxDiscountCap = newCap;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // setRules
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITokenGate
    function setRules(address bond, GateRule[] calldata rules) external {
        // Verify bond is registered in factory to prevent spoofing
        require(IBondFactory(bondFactory).isBond(bond), "Not a registered bond");
        // Verify the caller is the bond creator
        address creator;
        (bool ok, bytes memory data) = bond.staticcall(abi.encodeWithSignature("config()"));
        if (ok && data.length >= 32) {
            assembly { creator := mload(add(data, 32)) }
        }
        if (msg.sender != creator) revert NotBondCreator();
        if (rules.length > MAX_RULES) revert TooManyRules();

        // Validate each rule
        for (uint256 i = 0; i < rules.length; ) {
            GateRule calldata rule = rules[i];

            // At least one tier is required
            if (rule.tiers.length == 0) revert InvalidThreshold();
            if (rule.tiers.length > MAX_TIERS) revert TooManyTiers();

            // Non-Merkle rules require a token address
            if (rule.checkType != CheckType.MerkleProof) {
                if (rule.token == address(0)) revert InvalidThreshold();
            }

            // Merkle rules require a non-empty root
            if (rule.checkType == CheckType.MerkleProof) {
                if (rule.merkleRoot == bytes32(0)) revert InvalidThreshold();
            }

            // Validate tiers:
            // 1. each tier's discountBps is within valid range
            // 2. tiers are sorted descending by threshold (first = highest)
            for (uint256 t = 0; t < rule.tiers.length; ) {
                DiscountTier calldata tier = rule.tiers[t];
                if (tier.discountBps == 0 || tier.discountBps >= 10_000) revert InvalidDiscount();
                // Each subsequent tier must have a LOWER threshold
                if (t > 0 && tier.threshold >= rule.tiers[t - 1].threshold) revert TiersNotSorted();
                unchecked { ++t; }
            }

            unchecked { ++i; }
        }

        // Replace rules entirely
        delete _rules[bond];
        for (uint256 i = 0; i < rules.length; ) {
            _rules[bond].push(rules[i]);
            unchecked { ++i; }
        }

        emit RulesSet(bond, rules.length);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getDiscount — primary call from BondContract.purchase()
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITokenGate
    /// @dev Sums tier discounts across all matched rules (MerkleProof rules are skipped).
    function getDiscount(address buyer, address bond) external view returns (uint16) {
        return _sumDiscount(buyer, bond, new bytes32[](0), 0, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getDiscountWithProof — for MerkleProof rules
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITokenGate
    function getDiscountWithProof(
        address   buyer,
        address   bond,
        bytes32[] calldata proof,
        uint128   allocation
    ) external view returns (uint16) {
        return _sumDiscount(buyer, bond, proof, allocation, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _sumDiscount — aggregate discounts across all rules
    // ─────────────────────────────────────────────────────────────────────────

    function _sumDiscount(
        address   buyer,
        address   bond,
        bytes32[] memory proof,
        uint128   allocation,
        bool      includeMerkle
    ) internal view returns (uint16) {
        GateRule[] storage rules = _rules[bond];
        uint256 len         = rules.length;
        uint256 accumulated = 0;
        uint256 cap         = maxDiscountCap;

        for (uint256 i = 0; i < len; ) {
            GateRule storage rule = rules[i];
            uint16 tierDiscount   = 0;

            if (rule.checkType == CheckType.MerkleProof) {
                if (includeMerkle) {
                    tierDiscount = _resolveMerkle(buyer, rule, proof, allocation);
                }
            } else {
                // Read balance once — dispatch by check type
                uint256 balance = _readBalance(buyer, rule);
                // Resolve the matching tier via linear interpolation
                tierDiscount = _resolveTier(balance, rule.tiers);
            }

            if (tierDiscount > 0) {
                accumulated += tierDiscount;
                if (accumulated >= cap) return uint16(cap); // early exit
            }

            unchecked { ++i; }
        }

        return uint16(accumulated);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _resolveTier — linear interpolation between tiers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev  Discount is computed via linear interpolation between adjacent tiers.
    ///       Tiers are sorted descending by threshold: tiers[0] = highest threshold.
    ///
    ///       balance >= max threshold → top tier discountBps (no upward extrapolation)
    ///       balance <  min threshold → 0 (no downward extrapolation)
    ///       otherwise → lowerDiscount + (upperDiscount - lowerDiscount)
    ///                                 * (balance - lowerThreshold)
    ///                                 / (upperThreshold - lowerThreshold)
    ///
    ///       PRECISION: all arithmetic in uint256 before the final cast to uint16.
    ///       max: (9999) * (2^128) / (2^128) = 9999 — safe.
    function _resolveTier(
        uint256            balance,
        DiscountTier[] storage tiers
    ) internal view returns (uint16) {
        uint256 len = tiers.length;
        if (len == 0) return 0;

        // At or above the highest threshold → maximum discount
        if (balance >= tiers[0].threshold) return tiers[0].discountBps;

        // Below the minimum threshold → 0
        if (balance < tiers[len - 1].threshold) return 0;

        // Find lower tier: first index t where tiers[t].threshold <= balance
        uint256 lowerIdx = len - 1;
        for (uint256 t = 1; t < len; ) {
            if (balance >= tiers[t].threshold) { lowerIdx = t; break; }
            unchecked { ++t; }
        }
        // upperIdx = lowerIdx - 1 (always > 0 since balance < tiers[0].threshold)
        uint256 upperIdx = lowerIdx - 1;

        uint256 lowerThreshold = tiers[lowerIdx].threshold;
        uint256 upperThreshold = tiers[upperIdx].threshold;
        uint256 lowerDiscount  = tiers[lowerIdx].discountBps;
        uint256 upperDiscount  = tiers[upperIdx].discountBps;

        // Linear interpolation
        uint256 rangeBalance  = balance        - lowerThreshold;
        uint256 rangeTier     = upperThreshold - lowerThreshold;
        uint256 rangeDiscount = upperDiscount  - lowerDiscount;

        return uint16(lowerDiscount + rangeDiscount * rangeBalance / rangeTier);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _readBalance — read balance by check type
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev  Single balance-reading entry point. Returns 0 on any error (try/catch).
    ///       For VotingEscrow — reads locked.amount (int128, cast to uint256).
    ///       For StakingContract — reads stakedBalanceOf(buyer).
    function _readBalance(
        address buyer,
        GateRule storage rule
    ) internal view returns (uint256 bal) {
        CheckType ct = rule.checkType;

        if (ct == CheckType.ERC20Balance) {
            try IERC20(rule.token).balanceOf(buyer) returns (uint256 b) {
                return b;
            } catch { return 0; }
        }

        if (ct == CheckType.ERC721Balance) {
            try IERC721(rule.token).balanceOf(buyer) returns (uint256 b) {
                return b;
            } catch { return 0; }
        }

        if (ct == CheckType.VotingEscrow) {
            // locked(address) returns (int128 amount, uint256 end)
            (bool ok, bytes memory data) = rule.token.staticcall(
                abi.encodeWithSignature("locked(address)", buyer)
            );
            if (!ok || data.length < 64) return 0;
            int128 lockedAmount;
            assembly { lockedAmount := mload(add(data, 32)) }
            return lockedAmount > 0 ? uint256(uint128(lockedAmount)) : 0;
        }

        if (ct == CheckType.StakingContract) {
            (bool ok, bytes memory data) = rule.token.staticcall(
                abi.encodeWithSignature("stakedBalanceOf(address)", buyer)
            );
            if (!ok || data.length < 32) return 0;
            uint256 staked; assembly { staked := mload(add(data, 32)) }
            return staked;
        }

        return 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _resolveMerkle — verify merkle proof and resolve discount
    // ─────────────────────────────────────────────────────────────────────────

    function _resolveMerkle(
        address buyer,
        GateRule storage rule,
        bytes32[] memory proof,
        uint128 allocation
    ) internal view returns (uint16) {
        // For Merkle: threshold of the first (and usually only) tier = min allocation
        if (rule.tiers.length == 0) return 0;
        bytes32 leaf = keccak256(abi.encodePacked(buyer, allocation));
        if (
            allocation >= rule.tiers[0].threshold &&
            MerkleProof.verify(proof, rule.merkleRoot, leaf)
        ) {
            // Multiple tiers supported — allocation is also tiered
            return _resolveTier(allocation, rule.tiers);
        }
        return 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITokenGate
    function getRules(address bond) external view returns (GateRule[] memory) {
        return _rules[bond];
    }

    function ruleCount(address bond) external view returns (uint256) {
        return _rules[bond].length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UUPS
    // ─────────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}

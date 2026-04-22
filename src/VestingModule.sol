// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVestingModule} from "./interfaces/IModules.sol";

/// @title  VestingModule
/// @author Debitum
/// @notice Stateless, pure-math vesting calculator. Immutable — cannot be upgraded.
///         All position state lives inside BondNFT.Position.
///         Each Position snapshots this contract's address at mint time, so users
///         are permanently bound to the logic that existed when they purchased.
///
/// @dev    Three schedule types are supported:
///
///         LINEAR — tokens unlock at a constant rate from startTime.
///
///           unlocked(t) = totalAmount × min(elapsed, duration) / duration
///
///           Example: 1000 tokens, 90-day duration.
///           At day 30 → 333 tokens. At day 90 → 1000 tokens.
///
///         CLIFF — zero tokens until the cliff, then linear from cliff to end.
///
///           unlocked(t) = 0                                  if t < cliff
///                       = totalAmount × (t-cliff)/(total-cliff)  if cliff ≤ t < total
///                       = totalAmount                        if t ≥ total
///
///           Example: 1000 tokens, 30-day cliff, 90-day total.
///           Day 29 → 0. Day 30 → 0 (cliff just hit, linear starts).
///           Day 60 → 500 tokens. Day 90 → 1000 tokens.
///
///         STEP — equal tranches unlock at each interval boundary.
///
///           stepsComplete(t) = floor((t - startTime) / stepDuration)
///           unlocked(t)      = totalAmount × min(stepsComplete, steps) / steps
///
///           Example: 1000 tokens, 4 steps × 30 days each.
///           Day 29 → 0. Day 30 → 250. Day 60 → 500. Day 90 → 750. Day 120 → 1000.
///
/// @dev    PRECISION NOTE
///         All intermediate math uses uint256 to avoid overflow, then downcasts
///         back to uint128 at the final step. The maximum principalAmount is
///         uint128 max ≈ 3.4 × 10^38 tokens. Multiplying by duration (max ~10 years
///         = 315_360_000 seconds ≈ 3 × 10^8) before dividing is safe within uint256.
contract VestingModule is IVestingModule {

    // ─────────────────────────────────────────────────────────────────────────
    // buildSchedule — validate + pack
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingModule
    /// @dev  Called by BondContract at purchase time.
    ///       Reverts early so the buyer's tx fails cleanly rather than minting
    ///       a broken NFT with an invalid schedule.
    ///       NOTE: startTime is not validated here — it is set to block.timestamp by
    ///       BondContract, so it is always current. Passing a past startTime is valid
    ///       by design (tokens begin unlocking immediately).
    function buildSchedule(
        uint8          vestingType,
        bytes calldata params,
        uint128        amount,
        uint64         startTime
    ) external pure returns (Schedule memory schedule) {
        VestingType vt = VestingType(vestingType);

        if (vt == VestingType.Linear) {
            LinearParams memory p = abi.decode(params, (LinearParams));
            if (p.duration == 0) revert InvalidDuration();

        } else if (vt == VestingType.Cliff) {
            CliffParams memory p = abi.decode(params, (CliffParams));
            if (p.totalDuration == 0)                  revert InvalidDuration();
            if (p.cliffDuration >= p.totalDuration)    revert CliffExceedsTotal();

        } else if (vt == VestingType.Step) {
            StepParams memory p = abi.decode(params, (StepParams));
            if (p.steps == 0)        revert ZeroSteps();
            if (p.stepDuration == 0) revert ZeroStepDuration();
        }

        schedule = Schedule({
            vestingType: vt,
            startTime:   startTime,
            totalAmount: amount,
            params:      params
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // claimable — main entry point for BondNFT.claim()
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingModule
    function claimable(
        Schedule calldata schedule,
        uint128 alreadyClaimed
    ) external view returns (uint128) {
        return claimableAt(schedule, alreadyClaimed, uint64(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // claimableAt — pure version for UI previews at arbitrary timestamps
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingModule
    function claimableAt(
        Schedule calldata schedule,
        uint128 alreadyClaimed,
        uint64  timestamp
    ) public pure returns (uint128) {
        uint128 unlocked = _unlocked(schedule, timestamp);
        if (unlocked <= alreadyClaimed) return 0;
        return unlocked - alreadyClaimed;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // totalUnlocked — how much has unlocked so far (ignores claimed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingModule
    function totalUnlocked(Schedule calldata schedule) external view returns (uint128) {
        return _unlocked(schedule, uint64(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // vestingEnd — when the position becomes 100% claimable
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IVestingModule
    function vestingEnd(Schedule calldata schedule) external pure returns (uint64) {
        if (schedule.vestingType == VestingType.Linear) {
            LinearParams memory p = abi.decode(schedule.params, (LinearParams));
            return schedule.startTime + p.duration;
        }
        if (schedule.vestingType == VestingType.Cliff) {
            CliffParams memory p = abi.decode(schedule.params, (CliffParams));
            return schedule.startTime + p.totalDuration;
        }
        if (schedule.vestingType == VestingType.Step) {
            StepParams memory p = abi.decode(schedule.params, (StepParams));
            return schedule.startTime + uint64(p.steps) * p.stepDuration;
        }
        return schedule.startTime; // unreachable
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — core unlock math per type
    // ─────────────────────────────────────────────────────────────────────────

    function _unlocked(
        Schedule calldata schedule,
        uint64 timestamp
    ) internal pure returns (uint128) {
        // Nothing unlocked before startTime (handles clock skew / early calls)
        if (timestamp <= schedule.startTime) return 0;

        uint64 elapsed = timestamp - schedule.startTime;

        if (schedule.vestingType == VestingType.Linear) {
            return _unlockedLinear(schedule, elapsed);
        }
        if (schedule.vestingType == VestingType.Cliff) {
            return _unlockedCliff(schedule, elapsed);
        }
        if (schedule.vestingType == VestingType.Step) {
            return _unlockedStep(schedule, elapsed);
        }
        return 0;
    }

    // ── Linear ────────────────────────────────────────────────────────────────

    function _unlockedLinear(
        Schedule calldata schedule,
        uint64 elapsed
    ) private pure returns (uint128) {
        LinearParams memory p = abi.decode(schedule.params, (LinearParams));

        // Fully vested
        if (elapsed >= p.duration) return schedule.totalAmount;

        // unlocked = totalAmount * elapsed / duration
        // Multiply as uint256 first to avoid overflow:
        // max: 2^128 * 2^32 = 2^160 — well within uint256
        return uint128(
            uint256(schedule.totalAmount) * uint256(elapsed) / uint256(p.duration)
        );
    }

    // ── Cliff ─────────────────────────────────────────────────────────────────

    function _unlockedCliff(
        Schedule calldata schedule,
        uint64 elapsed
    ) private pure returns (uint128) {
        CliffParams memory p = abi.decode(schedule.params, (CliffParams));

        // Before cliff: nothing
        if (elapsed < p.cliffDuration) return 0;

        // After full duration: everything
        if (elapsed >= p.totalDuration) return schedule.totalAmount;

        // Between cliff and end: linear over the post-cliff window
        // unlocked = totalAmount * (elapsed - cliffDuration) / (totalDuration - cliffDuration)
        uint64 postCliffElapsed  = elapsed            - p.cliffDuration;
        uint64 postCliffDuration = p.totalDuration    - p.cliffDuration;

        return uint128(
            uint256(schedule.totalAmount) * uint256(postCliffElapsed) / uint256(postCliffDuration)
        );
    }

    // ── Step ──────────────────────────────────────────────────────────────────

    function _unlockedStep(
        Schedule calldata schedule,
        uint64 elapsed
    ) private pure returns (uint128) {
        StepParams memory p = abi.decode(schedule.params, (StepParams));

        uint64 stepsComplete = elapsed / p.stepDuration;

        // All steps done
        if (stepsComplete >= uint64(p.steps)) return schedule.totalAmount;

        // unlocked = totalAmount * stepsComplete / steps
        // Using full uint256 precision:
        return uint128(
            uint256(schedule.totalAmount) * uint256(stepsComplete) / uint256(p.steps)
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingModule}  from "../src/VestingModule.sol";
import {IVestingModule} from "../src/interfaces/IModules.sol";

contract VestingModuleTest is Test {
    VestingModule internal vm_;

    function setUp() public {
        vm_ = new VestingModule();
    }

    // ── buildSchedule ─────────────────────────────────────────────────────────

    function test_buildSchedule_linear() public view {
        bytes memory params = abi.encode(IVestingModule.LinearParams({ duration: 30 days }));
        IVestingModule.Schedule memory s = vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Linear), params, 1000e18, uint64(block.timestamp)
        );
        assertEq(s.totalAmount, 1000e18);
        assertEq(uint8(s.vestingType), uint8(IVestingModule.VestingType.Linear));
    }

    function test_buildSchedule_cliff() public view {
        bytes memory params = abi.encode(IVestingModule.CliffParams({ cliffDuration: 10 days, totalDuration: 30 days }));
        IVestingModule.Schedule memory s = vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Cliff), params, 500e18, uint64(block.timestamp)
        );
        assertEq(s.totalAmount, 500e18);
    }

    function test_buildSchedule_step() public view {
        bytes memory params = abi.encode(IVestingModule.StepParams({ steps: 4, stepDuration: 30 days }));
        IVestingModule.Schedule memory s = vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Step), params, 1000e18, uint64(block.timestamp)
        );
        assertEq(s.totalAmount, 1000e18);
    }

    function test_buildSchedule_revertLinearZeroDuration() public {
        bytes memory params = abi.encode(IVestingModule.LinearParams({ duration: 0 }));
        vm.expectRevert(IVestingModule.InvalidDuration.selector);
        vm_.buildSchedule(uint8(IVestingModule.VestingType.Linear), params, 1000e18, uint64(block.timestamp));
    }

    function test_buildSchedule_revertCliffExceedsTotal() public {
        bytes memory params = abi.encode(IVestingModule.CliffParams({ cliffDuration: 30 days, totalDuration: 30 days }));
        vm.expectRevert(IVestingModule.CliffExceedsTotal.selector);
        vm_.buildSchedule(uint8(IVestingModule.VestingType.Cliff), params, 1000e18, uint64(block.timestamp));
    }

    function test_buildSchedule_revertStepZeroSteps() public {
        bytes memory params = abi.encode(IVestingModule.StepParams({ steps: 0, stepDuration: 30 days }));
        vm.expectRevert(IVestingModule.ZeroSteps.selector);
        vm_.buildSchedule(uint8(IVestingModule.VestingType.Step), params, 1000e18, uint64(block.timestamp));
    }

    function test_buildSchedule_revertStepZeroDuration() public {
        bytes memory params = abi.encode(IVestingModule.StepParams({ steps: 4, stepDuration: 0 }));
        vm.expectRevert(IVestingModule.ZeroStepDuration.selector);
        vm_.buildSchedule(uint8(IVestingModule.VestingType.Step), params, 1000e18, uint64(block.timestamp));
    }

    // ── Linear claimable ──────────────────────────────────────────────────────

    function test_claimableAt_linear_halfway() public {
        uint64 start = uint64(block.timestamp);
        bytes memory params = abi.encode(IVestingModule.LinearParams({ duration: 100 days }));
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);

        uint128 c = vm_.claimableAt(s, 0, start + 50 days);
        assertEq(c, 500e18);
    }

    function test_claimableAt_linear_before_start() public {
        uint64 start = uint64(block.timestamp) + 1 days;
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);
        assertEq(vm_.claimableAt(s, 0, uint64(block.timestamp)), 0);
    }

    function test_claimableAt_linear_fully_vested() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);
        assertEq(vm_.claimableAt(s, 0, start + 100 days), 1000e18);
    }

    function test_claimableAt_linear_after_vested() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);
        assertEq(vm_.claimableAt(s, 0, start + 200 days), 1000e18);
    }

    function test_claimableAt_linear_subtracts_claimed() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);
        // At 50% vested, 300e18 already claimed → only 200e18 claimable
        uint128 c = vm_.claimableAt(s, 300e18, start + 50 days);
        assertEq(c, 200e18);
    }

    function test_claimableAt_linear_claimed_exceeds_unlocked() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 100 days);
        assertEq(vm_.claimableAt(s, 600e18, start + 50 days), 0);
    }

    // ── Cliff claimable ───────────────────────────────────────────────────────

    function test_claimableAt_cliff_before_cliff() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildCliff(1000e18, start, 30 days, 90 days);
        assertEq(vm_.claimableAt(s, 0, start + 29 days), 0);
    }

    function test_claimableAt_cliff_at_cliff() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildCliff(1000e18, start, 30 days, 90 days);
        // cliff just hit — linear starts from cliff, so (30-30)/(90-30) = 0
        assertEq(vm_.claimableAt(s, 0, start + 30 days), 0);
    }

    function test_claimableAt_cliff_halfway_post_cliff() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildCliff(1000e18, start, 30 days, 90 days);
        // At day 60: (60-30)/(90-30) = 30/60 = 50%
        assertEq(vm_.claimableAt(s, 0, start + 60 days), 500e18);
    }

    function test_claimableAt_cliff_fully_vested() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildCliff(1000e18, start, 30 days, 90 days);
        assertEq(vm_.claimableAt(s, 0, start + 90 days), 1000e18);
    }

    // ── Step claimable ────────────────────────────────────────────────────────

    function test_claimableAt_step_before_first() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildStep(1000e18, start, 4, 30 days);
        assertEq(vm_.claimableAt(s, 0, start + 29 days), 0);
    }

    function test_claimableAt_step_each_tranche() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildStep(1000e18, start, 4, 30 days);
        assertEq(vm_.claimableAt(s, 0, start + 30 days),  250e18);
        assertEq(vm_.claimableAt(s, 0, start + 60 days),  500e18);
        assertEq(vm_.claimableAt(s, 0, start + 90 days),  750e18);
        assertEq(vm_.claimableAt(s, 0, start + 120 days), 1000e18);
    }

    function test_claimableAt_step_fully_vested() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildStep(1000e18, start, 4, 30 days);
        assertEq(vm_.claimableAt(s, 0, start + 200 days), 1000e18);
    }

    // ── vestingEnd ────────────────────────────────────────────────────────────

    function test_vestingEnd_linear() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(1000e18, start, 90 days);
        assertEq(vm_.vestingEnd(s), start + 90 days);
    }

    function test_vestingEnd_cliff() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildCliff(1000e18, start, 30 days, 90 days);
        assertEq(vm_.vestingEnd(s), start + 90 days);
    }

    function test_vestingEnd_step() public {
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildStep(1000e18, start, 4, 30 days);
        assertEq(vm_.vestingEnd(s), start + 120 days);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_linear_neverExceedsTotal(uint64 elapsed, uint128 total) public {
        vm.assume(total > 0 && elapsed < 365 days && elapsed > 0);
        uint64 start = uint64(block.timestamp);
        IVestingModule.Schedule memory s = _buildLinear(total, start, 90 days);
        uint128 c = vm_.claimableAt(s, 0, start + elapsed);
        assertLe(c, total);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _buildLinear(uint128 amount, uint64 start, uint64 duration)
        internal view returns (IVestingModule.Schedule memory)
    {
        return vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Linear),
            abi.encode(IVestingModule.LinearParams({ duration: duration })),
            amount, start
        );
    }

    function _buildCliff(uint128 amount, uint64 start, uint64 cliff, uint64 total)
        internal view returns (IVestingModule.Schedule memory)
    {
        return vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Cliff),
            abi.encode(IVestingModule.CliffParams({ cliffDuration: cliff, totalDuration: total })),
            amount, start
        );
    }

    function _buildStep(uint128 amount, uint64 start, uint16 steps, uint64 stepDuration)
        internal view returns (IVestingModule.Schedule memory)
    {
        return vm_.buildSchedule(
            uint8(IVestingModule.VestingType.Step),
            abi.encode(IVestingModule.StepParams({ steps: steps, stepDuration: stepDuration })),
            amount, start
        );
    }
}

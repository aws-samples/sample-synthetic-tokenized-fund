// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/CollateralizationMonitor.sol";

contract CollateralizationMonitorTest is Test {
    CollateralizationMonitor internal monitor;
    address internal owner = address(0xA11CE);
    address internal forwarder = address(0xF07DE8);
    address internal attacker = address(0xBAD);

    function setUp() public {
        // Move to a realistic wall-clock time so reports carrying real Unix timestamps are not
        // rejected as "future" by the new validation (Foundry's default block.timestamp is 1).
        vm.warp(2_000_000_000);
        vm.prank(owner);
        monitor = new CollateralizationMonitor(forwarder);
    }

    function test_ConstructorDefaults() public view {
        assertEq(monitor.owner(), owner);
        assertEq(monitor.forwarder(), forwarder);
        assertEq(monitor.minRatio(), 120);
    }

    function test_UpdateCollateral_RevertsIfNotForwarder() public {
        vm.prank(attacker);
        vm.expectRevert(CollateralizationMonitor.NotForwarder.selector);
        monitor.updateCollateral(1, 2, 3, 4, true);
    }

    function test_UpdateCollateral_SucceedsAsForwarder() public {
        vm.prank(forwarder);
        monitor.updateCollateral(100, 200, 150, 1_700_000_000, true);
        CollateralizationMonitor.CollateralData memory d = monitor.getLatestData();
        assertEq(d.price, 100);
        assertEq(d.reserves, 200);
        assertEq(d.ratio, 150);
        assertEq(d.timestamp, 1_700_000_000);
        assertTrue(d.isHealthy);
    }

    function test_OnReport_RevertsIfNotForwarder() public {
        bytes memory report = abi.encodePacked(
            bytes4(keccak256("updateCollateral(uint256,uint256,uint256,uint256,bool)")),
            abi.encode(uint256(1), uint256(2), uint256(3), uint256(4), true)
        );
        vm.prank(attacker);
        vm.expectRevert(CollateralizationMonitor.NotForwarder.selector);
        monitor.onReport("", report);
    }

    function test_OnReport_DecodesAndWrites() public {
        uint256 price = 185e8;
        uint256 reserves = 1_000_000e8;
        uint256 ratio = 150;
        uint256 ts = 1_700_000_500;
        bool healthy = true;

        bytes memory report = abi.encodePacked(
            bytes4(keccak256("updateCollateral(uint256,uint256,uint256,uint256,bool)")),
            abi.encode(price, reserves, ratio, ts, healthy)
        );
        vm.prank(forwarder);
        monitor.onReport("meta", report);

        CollateralizationMonitor.CollateralData memory d = monitor.getLatestData();
        assertEq(d.price, price);
        assertEq(d.reserves, reserves);
        assertEq(d.ratio, ratio);
        assertEq(d.timestamp, ts);
        assertTrue(d.isHealthy);
    }

    function test_SetMinRatio_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(CollateralizationMonitor.NotOwner.selector);
        monitor.setMinRatio(200);

        vm.prank(owner);
        monitor.setMinRatio(200);
        assertEq(monitor.minRatio(), 200);
    }

    function test_SetMinRatio_RejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(CollateralizationMonitor.ZeroMinRatio.selector);
        monitor.setMinRatio(0);
    }

    function test_SetForwarder_OnlyOwner() public {
        address newForwarder = address(0xCAFE);

        vm.prank(attacker);
        vm.expectRevert(CollateralizationMonitor.NotOwner.selector);
        monitor.setForwarder(newForwarder);

        vm.prank(owner);
        monitor.setForwarder(newForwarder);
        assertEq(monitor.forwarder(), newForwarder);
    }

    function test_TransferOwnership_OnlyOwner() public {
        address newOwner = address(0xB0B);

        vm.prank(attacker);
        vm.expectRevert(CollateralizationMonitor.NotOwner.selector);
        monitor.transferOwnership(newOwner);

        vm.prank(owner);
        monitor.transferOwnership(newOwner);
        assertEq(monitor.owner(), newOwner);
    }

    function test_SupportsInterface() public view {
        assertTrue(monitor.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(monitor.supportsInterface(type(IERC165).interfaceId));
        assertFalse(monitor.supportsInterface(0xdeadbeef));
    }

    // ============ Report validation (M2) ============

    /// @notice A future-dated timestamp is clamped to the current block rather than rejected, so
    ///         DON/data clock skew cannot stall the feed; the stored timestamp is never in the
    ///         future, so a consumer's staleness check can never underflow.
    function test_UpdateCollateral_ClampsFutureTimestamp() public {
        vm.prank(forwarder);
        monitor.updateCollateral(100, 200, 150, block.timestamp + 1 days, true);
        CollateralizationMonitor.CollateralData memory d = monitor.getLatestData();
        assertEq(d.timestamp, block.timestamp, "future timestamp clamped to current block");
    }

    /// @notice A stale (older) report must not overwrite fresher health data (monotonic).
    function test_UpdateCollateral_RevertsOnNonMonotonicTimestamp() public {
        vm.startPrank(forwarder);
        monitor.updateCollateral(100, 200, 150, block.timestamp - 10, true);
        vm.expectRevert(CollateralizationMonitor.StaleTimestamp.selector);
        monitor.updateCollateral(100, 200, 150, block.timestamp - 11, true);
        vm.stopPrank();
    }

    /// @notice Current-block and newer timestamps are accepted.
    function test_UpdateCollateral_AcceptsCurrentAndNewer() public {
        vm.startPrank(forwarder);
        monitor.updateCollateral(100, 200, 150, block.timestamp - 5, true);
        monitor.updateCollateral(110, 210, 160, block.timestamp, true);
        vm.stopPrank();
        CollateralizationMonitor.CollateralData memory d = monitor.getLatestData();
        assertEq(d.timestamp, block.timestamp);
        assertEq(d.price, 110);
    }

    /// @notice onReport applies the same clamping as the direct setter.
    function test_OnReport_ClampsFutureTimestamp() public {
        bytes memory report = abi.encodePacked(
            bytes4(keccak256("updateCollateral(uint256,uint256,uint256,uint256,bool)")),
            abi.encode(uint256(100), uint256(200), uint256(150), block.timestamp + 1 days, true)
        );
        vm.prank(forwarder);
        monitor.onReport("meta", report);
        CollateralizationMonitor.CollateralData memory d = monitor.getLatestData();
        assertEq(d.timestamp, block.timestamp, "future timestamp clamped via onReport");
    }
}

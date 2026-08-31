// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/PriceFeed.sol";

contract PriceFeedTest is Test {
    PriceFeed internal feed;
    address internal owner = address(0xA11CE);
    address internal forwarder = address(0xF07DE8);
    address internal attacker = address(0xBAD);

    function setUp() public {
        // Move to a realistic wall-clock time so reports carrying real Unix timestamps are not
        // rejected as "future" by the new validation (Foundry's default block.timestamp is 1).
        vm.warp(2_000_000_000);
        vm.prank(owner);
        feed = new PriceFeed(forwarder);
    }

    function test_ConstructorSetsOwnerAndForwarder() public view {
        assertEq(feed.owner(), owner);
        assertEq(feed.forwarder(), forwarder);
    }

    function test_UpdatePrice_RevertsIfNotForwarder() public {
        vm.prank(attacker);
        vm.expectRevert(PriceFeed.NotForwarder.selector);
        feed.updatePrice(100e8, block.timestamp);
    }

    function test_UpdatePrice_SucceedsAsForwarder() public {
        vm.prank(forwarder);
        feed.updatePrice(12345, 1_700_000_000);
        (uint256 p, uint256 t) = feed.getLatestPrice();
        assertEq(p, 12345);
        assertEq(t, 1_700_000_000);
    }

    function test_OnReport_RevertsIfNotForwarder() public {
        bytes memory report = abi.encodePacked(bytes4(keccak256("updatePrice(uint256,uint256)")), abi.encode(uint256(1), uint256(2)));
        vm.prank(attacker);
        vm.expectRevert(PriceFeed.NotForwarder.selector);
        feed.onReport("", report);
    }

    function test_OnReport_DecodesAndWrites() public {
        uint256 price = 185_00_000_000;
        uint256 ts = 1_700_000_500;
        bytes memory report = abi.encodePacked(bytes4(keccak256("updatePrice(uint256,uint256)")), abi.encode(price, ts));
        vm.prank(forwarder);
        feed.onReport("meta", report);
        (uint256 p, uint256 t) = feed.getLatestPrice();
        assertEq(p, price);
        assertEq(t, ts);
    }

    function test_OnReport_RevertsOnShortReport() public {
        bytes memory shortReport = hex"001122";
        vm.prank(forwarder);
        vm.expectRevert(PriceFeed.ReportTooShort.selector);
        feed.onReport("", shortReport);
    }

    function test_SetForwarder_OnlyOwner() public {
        address newForwarder = address(0xCAFE);

        vm.prank(attacker);
        vm.expectRevert(PriceFeed.NotOwner.selector);
        feed.setForwarder(newForwarder);

        vm.prank(owner);
        feed.setForwarder(newForwarder);
        assertEq(feed.forwarder(), newForwarder);
    }

    function test_SetForwarder_RejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PriceFeed.ZeroAddress.selector);
        feed.setForwarder(address(0));
    }

    function test_TransferOwnership_OnlyOwner() public {
        address newOwner = address(0xB0B);

        vm.prank(attacker);
        vm.expectRevert(PriceFeed.NotOwner.selector);
        feed.transferOwnership(newOwner);

        vm.prank(owner);
        feed.transferOwnership(newOwner);
        assertEq(feed.owner(), newOwner);
    }

    function test_SupportsInterface() public view {
        assertTrue(feed.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(feed.supportsInterface(type(IERC165).interfaceId));
        assertFalse(feed.supportsInterface(0xdeadbeef));
    }

    // ============ Report validation (M2) ============

    /// @notice A zero price is never valid and must be rejected.
    function test_UpdatePrice_RevertsOnZeroPrice() public {
        vm.prank(forwarder);
        vm.expectRevert(PriceFeed.InvalidPrice.selector);
        feed.updatePrice(0, block.timestamp);
    }

    /// @notice A future-dated timestamp is clamped to the current block rather than rejected —
    ///         DON/data time can run slightly ahead of chain time, and reverting would stall the
    ///         feed. Clamping still guarantees the stored timestamp is never in the future, so a
    ///         consumer's `block.timestamp - timestamp` staleness check can never underflow.
    function test_UpdatePrice_ClampsFutureTimestamp() public {
        vm.prank(forwarder);
        feed.updatePrice(100e8, block.timestamp + 1 days);
        (uint256 p, uint256 t) = feed.getLatestPrice();
        assertEq(p, 100e8);
        assertEq(t, block.timestamp, "future timestamp clamped to current block");
        assertLe(t, block.timestamp, "stored timestamp is never in the future");
    }

    /// @notice The current-block timestamp is accepted (boundary).
    function test_UpdatePrice_AcceptsCurrentTimestamp() public {
        vm.prank(forwarder);
        feed.updatePrice(100e8, block.timestamp);
        (uint256 p, uint256 t) = feed.getLatestPrice();
        assertEq(p, 100e8);
        assertEq(t, block.timestamp);
    }

    /// @notice A stale (older) report must not overwrite fresher data (monotonic timestamps).
    function test_UpdatePrice_RevertsOnNonMonotonicTimestamp() public {
        vm.startPrank(forwarder);
        feed.updatePrice(100e8, block.timestamp - 10);
        vm.expectRevert(PriceFeed.StaleTimestamp.selector);
        feed.updatePrice(200e8, block.timestamp - 11); // older than stored
        vm.stopPrank();
    }

    /// @notice Equal timestamp is allowed (a same-block correction), strictly newer is allowed.
    function test_UpdatePrice_AllowsEqualOrNewerTimestamp() public {
        vm.startPrank(forwarder);
        feed.updatePrice(100e8, block.timestamp - 10);
        feed.updatePrice(150e8, block.timestamp - 10); // equal: allowed
        feed.updatePrice(200e8, block.timestamp);      // newer: allowed
        vm.stopPrank();
        (uint256 p, uint256 t) = feed.getLatestPrice();
        assertEq(p, 200e8);
        assertEq(t, block.timestamp);
    }

    /// @notice onReport applies the same clamping as the direct setter.
    function test_OnReport_ClampsFutureTimestamp() public {
        bytes memory report = abi.encodePacked(
            bytes4(keccak256("updatePrice(uint256,uint256)")),
            abi.encode(uint256(100e8), block.timestamp + 1 days)
        );
        vm.prank(forwarder);
        feed.onReport("meta", report);
        (, uint256 t) = feed.getLatestPrice();
        assertEq(t, block.timestamp, "future timestamp clamped via onReport");
    }
}

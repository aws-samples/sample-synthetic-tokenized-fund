// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./keystone/IReceiver.sol";

/// @title CollateralizationMonitor
/// @notice On-chain oracle receiver that stores the protocol's collateralization
///         health as written by a Chainlink CRE workflow via the KeystoneForwarder.
///         Only the configured forwarder can deliver reports; only the owner can
///         rotate the forwarder, change minRatio, or transfer ownership.
contract CollateralizationMonitor is IReceiver {
    struct CollateralData {
        uint256 price;
        uint256 reserves;
        uint256 ratio;
        uint256 timestamp;
        bool isHealthy;
    }

    CollateralData public latestData;

    /// @notice Minimum acceptable ratio (percentage, e.g. 120 = 120%).
    uint256 public minRatio = 120;

    /// @notice Owner with admin rights (setMinRatio, rotate forwarder, transfer ownership).
    address public owner;

    /// @notice Address of the KeystoneForwarder authorized to deliver reports.
    ///         Can be address(0) immediately after deployment until setForwarder is called.
    address public forwarder;

    event CollateralUpdated(
        uint256 price,
        uint256 reserves,
        uint256 ratio,
        bool isHealthy,
        uint256 timestamp
    );
    event ThresholdBreached(uint256 ratio, uint256 minRatio);
    event MinRatioUpdated(uint256 previousMinRatio, uint256 newMinRatio);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotForwarder();
    error ZeroAddress();
    error ZeroMinRatio();
    error ReportTooShort();
    error StaleTimestamp();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyForwarder() {
        if (msg.sender != forwarder) revert NotForwarder();
        _;
    }

    /// @param _forwarder Initial KeystoneForwarder address. Pass address(0) to defer
    ///                   configuration and set it later via setForwarder.
    constructor(address _forwarder) {
        owner = msg.sender;
        forwarder = _forwarder;
        emit OwnershipTransferred(address(0), msg.sender);
        emit ForwarderUpdated(address(0), _forwarder);
    }

    /// @notice Writes a new collateralization snapshot. Restricted to the configured
    ///         forwarder so only DON-signed reports can mutate state.
    /// @dev A timestamp ahead of the current block is CLAMPED to `block.timestamp` (the DON/data
    ///      timestamp can run slightly ahead of chain time due to clock skew, and reverting would
    ///      stall the feed); clamping still guarantees the stored timestamp is never in the future,
    ///      so a consumer's staleness check can never underflow. Non-monotonic timestamps (a
    ///      replayed/stale report overwriting fresher data) are rejected.
    function updateCollateral(
        uint256 _price,
        uint256 _reserves,
        uint256 _ratio,
        uint256 _timestamp,
        bool _isHealthy
    ) public onlyForwarder {
        if (_timestamp > block.timestamp) {
            _timestamp = block.timestamp;
        }
        if (_timestamp < latestData.timestamp) revert StaleTimestamp();
        latestData = CollateralData({
            price: _price,
            reserves: _reserves,
            ratio: _ratio,
            timestamp: _timestamp,
            isHealthy: _isHealthy
        });

        emit CollateralUpdated(_price, _reserves, _ratio, _isHealthy, _timestamp);

        if (!_isHealthy) {
            emit ThresholdBreached(_ratio, minRatio);
        }
    }

    function getLatestData() external view returns (CollateralData memory) {
        return latestData;
    }

    /// @notice Update the minimum collateralization ratio. Owner only.
    function setMinRatio(uint256 _minRatio) external onlyOwner {
        if (_minRatio == 0) revert ZeroMinRatio();
        uint256 old = minRatio;
        minRatio = _minRatio;
        emit MinRatioUpdated(old, _minRatio);
    }

    /// @notice Rotate the authorized forwarder. Owner only.
    function setForwarder(address _newForwarder) external onlyOwner {
        if (_newForwarder == address(0)) revert ZeroAddress();
        address old = forwarder;
        forwarder = _newForwarder;
        emit ForwarderUpdated(old, _newForwarder);
    }

    /// @notice Transfer admin ownership. Use carefully.
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = _newOwner;
        emit OwnershipTransferred(old, _newOwner);
    }

    /// @inheritdoc IReceiver
    /// @dev Forwarder-only entry point. The report payload is the full encoded
    ///      function call (selector + ABI-encoded params). We skip the 4-byte
    ///      selector and decode the params. The internal call to updateCollateral
    ///      preserves msg.sender == forwarder so its modifier passes.
    function onReport(bytes calldata /* metadata */, bytes calldata report) external override onlyForwarder {
        if (report.length < 4) revert ReportTooShort();
        bytes calldata params = report[4:];
        (uint256 price, uint256 reserves, uint256 ratio, uint256 timestamp, bool isHealthy) =
            abi.decode(params, (uint256, uint256, uint256, uint256, bool));
        updateCollateral(price, reserves, ratio, timestamp, isHealthy);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId ||
               interfaceId == type(IERC165).interfaceId;
    }
}

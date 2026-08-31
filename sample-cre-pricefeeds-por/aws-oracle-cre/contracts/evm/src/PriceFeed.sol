// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./keystone/IReceiver.sol";

/// @title PriceFeed
/// @notice On-chain oracle receiver for an asset price written by a Chainlink CRE
///         workflow via the KeystoneForwarder. Only the configured forwarder can
///         deliver reports; only the owner can rotate the forwarder or ownership.
contract PriceFeed is IReceiver {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    PriceData public latestPrice;

    /// @notice Owner with admin rights (rotate forwarder, transfer ownership).
    address public owner;

    /// @notice Address of the KeystoneForwarder authorized to deliver reports.
    ///         Can be address(0) immediately after deployment until setForwarder is called.
    address public forwarder;

    event PriceUpdated(uint256 price, uint256 timestamp);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotForwarder();
    error ZeroAddress();
    error ReportTooShort();
    error InvalidPrice();
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

    /// @notice Writes a new (price, timestamp) pair. Restricted to the configured
    ///         forwarder so only DON-signed reports can mutate state.
    /// @dev Validates the report so a malformed or out-of-order delivery cannot poison the feed:
    ///      the price must be non-zero, and it cannot move backwards in time (monotonic),
    ///      preventing a replayed/stale report from overwriting fresher data. A timestamp ahead of
    ///      the current block is CLAMPED to `block.timestamp` rather than rejected: the DON/data
    ///      timestamp can run slightly ahead of chain time due to clock skew, and reverting would
    ///      stall the feed. Clamping still guarantees a stored timestamp is never in the future, so
    ///      a consumer's `block.timestamp - timestamp` staleness check can never underflow.
    function updatePrice(uint256 _price, uint256 _timestamp) public onlyForwarder {
        if (_price == 0) revert InvalidPrice();
        if (_timestamp > block.timestamp) {
            _timestamp = block.timestamp;
        }
        if (_timestamp < latestPrice.timestamp) revert StaleTimestamp();
        latestPrice = PriceData(_price, _timestamp);
        emit PriceUpdated(_price, _timestamp);
    }

    function getLatestPrice() external view returns (uint256, uint256) {
        return (latestPrice.price, latestPrice.timestamp);
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
    ///      selector and decode (price, timestamp). The internal call to
    ///      updatePrice preserves msg.sender == forwarder so its modifier passes.
    function onReport(bytes calldata /* metadata */, bytes calldata report) external override onlyForwarder {
        if (report.length < 4) revert ReportTooShort();
        bytes calldata params = report[4:];
        (uint256 price, uint256 timestamp) = abi.decode(params, (uint256, uint256));
        updatePrice(price, timestamp);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId ||
               interfaceId == type(IERC165).interfaceId;
    }
}

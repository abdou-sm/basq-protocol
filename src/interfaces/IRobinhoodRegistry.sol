// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Robinhood asset invariant registry
/// @notice Authoritative allowlist of ERC-20 stock/ETF tokens that an ETF basket may hold.
///         Enforced at creation and on every rebalance via `isRobinhoodAsset`.
interface IRobinhoodRegistry {
    error ZeroAddress();
    error NotAContract(address account);
    error AssetAlreadyListed(address token);
    error AssetNotListed(address token);
    error InvalidAssetDecimals(uint8 decimals);

    event RobinhoodAssetAdded(address indexed token);
    event RobinhoodAssetRemoved(address indexed token);

    function isRobinhoodAsset(address token) external view returns (bool);
}

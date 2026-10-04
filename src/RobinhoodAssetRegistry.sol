// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IRobinhoodRegistry } from "./interfaces/IRobinhoodRegistry.sol";

/// @title Robinhood Asset Invariant Registry
/// @notice Allowlist of Robinhood stock/ETF ERC-20 tokens. Baskets enforce `isRobinhoodAsset`
///         at creation and on every rebalance. Only listed tokens can ever become constituents.
contract RobinhoodAssetRegistry is Ownable, IRobinhoodRegistry {
    mapping(address token => bool listed) private _listed;
    address[] private _assets;

    constructor(address initialOwner) Ownable(initialOwner) { }

    function addAsset(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NotAContract(token);
        if (_listed[token]) revert AssetAlreadyListed(token);
        uint8 dec;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert NotAContract(token);
        }
        if (dec != 18) revert InvalidAssetDecimals(dec);
        // Optional ERC-8056 probe: do not require it, stock tokens expose uiMultiplier()
        // but forward-compat demands we accept any 18-decimal ERC-20 the owner vouches for.
        _listed[token] = true;
        _assets.push(token);
        emit RobinhoodAssetAdded(token);
    }

    function removeAsset(address token) external onlyOwner {
        if (!_listed[token]) revert AssetNotListed(token);
        _listed[token] = false;
        emit RobinhoodAssetRemoved(token);
    }

    function isRobinhoodAsset(address token) external view returns (bool) {
        return _listed[token];
    }

    function assetsLength() external view returns (uint256) {
        return _assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return _assets[index];
    }
}

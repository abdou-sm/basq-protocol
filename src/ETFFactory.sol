// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { ETFToken } from "./ETFToken.sol";
import { BasketTypes } from "./types/BasketTypes.sol";

/// @title Onchain ETF factory (plain baskets)
/// @notice The platform fee is fixed here, not by creators: every basket must route
///         at least `minPlatformShareBps` of its streaming flow to `platformTreasury`.
contract ETFFactory {
    error InvalidPlatformTreasury();
    error InvalidMinPlatformShare(uint16 shareBps);
    error WrongPlatformTreasury(address expected, address actual);
    error InsufficientPlatformShare(uint16 minimum, uint16 actual);

    /// @dev Must stay in sync with `ETFToken.MAX_PLATFORM_SHARE_BPS`.
    uint16 public constant MAX_PLATFORM_SHARE_BPS = 5000;

    /// @notice Fixed protocol treasury. Set once at deployment, never changeable.
    address public immutable platformTreasury;
    /// @notice Minimum platform cut (bps of creator flow) enforced on every basket.
    uint16 public immutable minPlatformShareBps;
    struct ETFParams {
        string name;
        string symbol;
        address[] tokens;
        uint256[] weights;
        address oracle;
        address owner;
        address robinhoodRegistry;
        address executionRegistry;
        address tradingHours;
        BasketTypes.FeeConfig fee;
    }

    event BasketCreated(address indexed basket, address indexed creator, address indexed owner, bool rebalancing);

    address[] private _baskets;
    mapping(address basket => bool created) private _isBasket;

    constructor(address platformTreasury_, uint16 minPlatformShareBps_) {
        if (platformTreasury_ == address(0)) revert InvalidPlatformTreasury();
        if (minPlatformShareBps_ == 0 || minPlatformShareBps_ > MAX_PLATFORM_SHARE_BPS) {
            revert InvalidMinPlatformShare(minPlatformShareBps_);
        }
        platformTreasury = platformTreasury_;
        minPlatformShareBps = minPlatformShareBps_;
    }

    function _enforcePlatformFee(BasketTypes.FeeConfig calldata fee) internal view {
        if (fee.platform != platformTreasury) revert WrongPlatformTreasury(platformTreasury, fee.platform);
        if (fee.platformShareBps < minPlatformShareBps) {
            revert InsufficientPlatformShare(minPlatformShareBps, fee.platformShareBps);
        }
    }

    function createETF(ETFParams calldata params) external returns (address basket) {
        _enforcePlatformFee(params.fee);
        basket = address(
            new ETFToken(
                params.name,
                params.symbol,
                params.tokens,
                params.weights,
                params.oracle,
                params.owner,
                params.robinhoodRegistry,
                params.executionRegistry,
                params.tradingHours,
                params.fee
            )
        );
        _baskets.push(basket);
        _isBasket[basket] = true;
        emit BasketCreated(basket, msg.sender, params.owner, false);
    }

    function baskets(uint256 index) external view returns (address) {
        return _baskets[index];
    }

    function basketsLength() external view returns (uint256) {
        return _baskets.length;
    }

    function isBasket(address candidate) external view returns (bool) {
        return _isBasket[candidate];
    }
}

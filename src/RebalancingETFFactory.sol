// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { RebalancingETFToken } from "./RebalancingETFToken.sol";
import { ETFFactory } from "./ETFFactory.sol";
import { BasketTypes } from "./types/BasketTypes.sol";

/// @title Onchain ETF factory (rebalancing baskets)
/// @notice Same fixed platform fee as `ETFFactory`: every basket must route at least
///         `minPlatformShareBps` of its streaming flow to `platformTreasury`.
contract RebalancingETFFactory {
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

    function createRebalancingETF(
        ETFFactory.ETFParams calldata params,
        BasketTypes.RiskConfig calldata risk
    )
        external
        returns (address basket)
    {
        if (params.fee.platform != platformTreasury) {
            revert WrongPlatformTreasury(platformTreasury, params.fee.platform);
        }
        if (params.fee.platformShareBps < minPlatformShareBps) {
            revert InsufficientPlatformShare(minPlatformShareBps, params.fee.platformShareBps);
        }
        basket = address(
            new RebalancingETFToken(
                params.name,
                params.symbol,
                params.tokens,
                params.weights,
                params.oracle,
                params.owner,
                params.robinhoodRegistry,
                params.executionRegistry,
                params.tradingHours,
                params.fee,
                risk
            )
        );
        _baskets.push(basket);
        _isBasket[basket] = true;
        emit BasketCreated(basket, msg.sender, params.owner, true);
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

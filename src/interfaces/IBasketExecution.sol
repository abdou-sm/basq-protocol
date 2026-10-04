// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Execution abstraction for ERC-7621 baskets
interface IBasketExecution {
    function supportsPair(address tokenIn, address tokenOut) external view returns (bool);
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut);
}

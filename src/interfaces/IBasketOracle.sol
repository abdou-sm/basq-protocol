// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Valuation abstraction for ERC-7621 baskets
interface IBasketOracle {
    function unitOfAccount() external view returns (address);
    function unitDecimals() external view returns (uint8);
    function validateAsset(address token) external view;
    function quote(address token, uint256 amount) external view returns (uint256 value);
    function quoteInverse(address token, uint256 value) external view returns (uint256 amount);
}

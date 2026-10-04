// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBasketOracle } from "src/interfaces/IBasketOracle.sol";

contract MockBasketOracle is IBasketOracle {
    error AssetNotSupported(address token);

    address private immutable _unit;
    uint8 private immutable _unitDecimals;
    mapping(address token => uint256 price) private _prices;
    mapping(address token => uint256 scale) private _scales;

    constructor(address unit_, uint8 unitDecimals_) {
        _unit = unit_;
        _unitDecimals = unitDecimals_;
    }

    function setPrice(address token, uint256 pricePerWholeToken) external {
        _prices[token] = pricePerWholeToken;
        _scales[token] = 10 ** uint256(IERC20Metadata(token).decimals());
    }

    function unitOfAccount() external view returns (address) {
        return _unit;
    }

    function unitDecimals() external view returns (uint8) {
        return _unitDecimals;
    }

    function validateAsset(address token) external view {
        if (_prices[token] == 0) revert AssetNotSupported(token);
    }

    function quote(address token, uint256 amount) external view returns (uint256 value) {
        uint256 price = _prices[token];
        if (price == 0) revert AssetNotSupported(token);
        return Math.mulDiv(amount, price, _scales[token]);
    }

    function quoteInverse(address token, uint256 value) external view returns (uint256 amount) {
        uint256 price = _prices[token];
        if (price == 0) revert AssetNotSupported(token);
        return Math.mulDiv(value, _scales[token], price);
    }
}

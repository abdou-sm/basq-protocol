// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBasketOracle } from "../interfaces/IBasketOracle.sol";

/// @notice Test/local oracle with owner-set prices. NOT for production with untrusted owner.
contract FixedPriceOracle is Ownable, IBasketOracle {
    error InvalidUnitDecimals(uint8 decimals);
    error InvalidTokenDecimals(uint8 decimals);
    error ZeroPrice();
    error AssetNotSupported(address token);

    event PriceSet(address indexed token, uint256 indexed pricePerWholeToken);
    event PriceRemoved(address indexed token);

    uint8 private constant MAX_DECIMALS = 18;

    address private immutable _unit;
    uint8 private immutable _unitDecimals;

    mapping(address token => uint256 price) private _prices;
    mapping(address token => uint256 scale) private _scales;

    constructor(address unitOfAccount_, uint8 unitDecimals_, address initialOwner) Ownable(initialOwner) {
        if (unitDecimals_ > MAX_DECIMALS) revert InvalidUnitDecimals(unitDecimals_);
        _unit = unitOfAccount_;
        _unitDecimals = unitDecimals_;
    }

    function setPrice(address token, uint256 pricePerWholeToken) external onlyOwner {
        if (pricePerWholeToken == 0) revert ZeroPrice();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > MAX_DECIMALS) revert InvalidTokenDecimals(tokenDecimals);
        _prices[token] = pricePerWholeToken;
        _scales[token] = 10 ** uint256(tokenDecimals);
        emit PriceSet(token, pricePerWholeToken);
    }

    function removePrice(address token) external onlyOwner {
        if (_prices[token] == 0) revert AssetNotSupported(token);
        delete _prices[token];
        delete _scales[token];
        emit PriceRemoved(token);
    }

    function priceOf(address token) external view returns (uint256) {
        return _prices[token];
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

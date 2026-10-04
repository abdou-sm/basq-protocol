// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBasketOracle } from "../interfaces/IBasketOracle.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Production oracle for Robinhood Chain: per-asset Chainlink feeds + sequencer guard.
/// @dev Feed price already includes the ERC-8056 uiMultiplier (total-return). Do not re-apply it.
///      Reverts fail-closed on stale / non-positive / incomplete / paused feeds.
contract RobinhoodChainlinkOracle is Ownable, IBasketOracle {
    error InvalidUnitDecimals(uint8 decimals);
    error InvalidDecimals(uint8 decimals);
    error InvalidMaxAge();
    error NotAContract(address account);
    error AssetNotSupported(address token);
    error AssetPaused(address token);
    error InvalidAnswer();
    error InvalidRound();
    error StaleAnswer();
    error SequencerDown();

    event FeedSet(address indexed token, address indexed aggregator, uint32 indexed maxAge);
    event FeedRemoved(address indexed token);
    event SequencerFeedSet(address indexed feed);

    uint8 private constant MAX_DECIMALS = 18;

    struct Feed {
        address aggregator;
        uint32 maxAge;
        uint8 tokenDecimals;
    }

    address private immutable _unit;
    uint8 private immutable _unitDecimals;
    address public sequencerFeed;

    mapping(address token => Feed feed) private _feeds;

    constructor(address unitOfAccount_, uint8 unitDecimals_, address initialOwner) Ownable(initialOwner) {
        if (unitDecimals_ > MAX_DECIMALS) revert InvalidUnitDecimals(unitDecimals_);
        _unit = unitOfAccount_;
        _unitDecimals = unitDecimals_;
    }

    function setSequencerFeed(address feed) external onlyOwner {
        sequencerFeed = feed;
        emit SequencerFeedSet(feed);
    }

    function setFeed(address token, address aggregator, uint32 maxAge) external onlyOwner {
        if (token == address(0) || token.code.length == 0) revert NotAContract(token);
        if (aggregator == address(0) || aggregator.code.length == 0) revert NotAContract(aggregator);
        if (maxAge == 0) revert InvalidMaxAge();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > MAX_DECIMALS) revert InvalidDecimals(tokenDecimals);
        uint8 feedDecimals = IAggregatorV3(aggregator).decimals();
        if (feedDecimals > MAX_DECIMALS) revert InvalidDecimals(feedDecimals);
        _feeds[token] = Feed({ aggregator: aggregator, maxAge: maxAge, tokenDecimals: tokenDecimals });
        emit FeedSet(token, aggregator, maxAge);
    }

    function removeFeed(address token) external onlyOwner {
        if (_feeds[token].aggregator == address(0)) revert AssetNotSupported(token);
        delete _feeds[token];
        emit FeedRemoved(token);
    }

    function feedOf(address token) external view returns (address aggregator, uint32 maxAge, uint8 tokenDecimals) {
        Feed memory f = _feeds[token];
        return (f.aggregator, f.maxAge, f.tokenDecimals);
    }

    function unitOfAccount() external view returns (address) {
        return _unit;
    }

    function unitDecimals() external view returns (uint8) {
        return _unitDecimals;
    }

    function validateAsset(address token) external view {
        _readPrice(token);
    }

    function quote(address token, uint256 amount) external view returns (uint256 value) {
        (uint256 price, uint8 inputDecimals) = _readPrice(token);
        if (inputDecimals >= _unitDecimals) {
            return Math.mulDiv(amount, price, 10 ** uint256(inputDecimals - _unitDecimals));
        }
        // Divide before scaling up so `amount * price` never overflows in 256-bit math.
        uint256 wholeUnits = Math.mulDiv(amount, price, 10 ** uint256(inputDecimals));
        return wholeUnits * (10 ** uint256(_unitDecimals));
    }

    function quoteInverse(address token, uint256 value) external view returns (uint256 amount) {
        (uint256 price, uint8 inputDecimals) = _readPrice(token);
        if (inputDecimals >= _unitDecimals) {
            return Math.mulDiv(value, 10 ** uint256(inputDecimals - _unitDecimals), price);
        }
        uint256 scale = 10 ** uint256(_unitDecimals - inputDecimals);
        if (price > type(uint256).max / scale) return 0;
        return value / (price * scale);
    }

    function _checkSequencer() private view {
        address seq = sequencerFeed;
        if (seq == address(0)) return;
        (, int256 status, uint256 startedAt,,) = IAggregatorV3(seq).latestRoundData();
        if (status != 0) revert SequencerDown();
        if (startedAt > block.timestamp || block.timestamp - startedAt <= 3600) revert SequencerDown();
    }

    function _isPaused(address token) private view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (bool));
    }

    function _readPrice(address token) private view returns (uint256 price, uint8 inputDecimals) {
        _checkSequencer();
        Feed memory f = _feeds[token];
        if (f.aggregator == address(0)) revert AssetNotSupported(token);
        if (_isPaused(token)) revert AssetPaused(token);
        IAggregatorV3 agg = IAggregatorV3(f.aggregator);
        uint8 feedDecimals = agg.decimals();
        if (feedDecimals > MAX_DECIMALS) revert InvalidDecimals(feedDecimals);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = agg.latestRoundData();
        if (answer <= 0) revert InvalidAnswer();
        if (updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) revert InvalidRound();
        if (block.timestamp - updatedAt > f.maxAge) revert StaleAnswer();
        return (uint256(answer), f.tokenDecimals + feedDecimals);
    }
}

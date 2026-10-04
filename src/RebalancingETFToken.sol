// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ETFToken } from "./ETFToken.sol";
import { IBasketExecution } from "./interfaces/IBasketExecution.sol";
import { IBasketOracle } from "./interfaces/IBasketOracle.sol";
import { BasketTypes } from "./types/BasketTypes.sol";

/// @title Rebalancing ETF with oracle-bounded, permissionless keeper trades
contract RebalancingETFToken is ETFToken {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_SLIPPAGE_BPS_CAP = 1000;
    uint16 internal constant MAX_KEEPER_REWARD_BPS_CAP = 100;
    uint16 internal constant MAX_REBALANCE_BAND_BPS_CAP = 5000;

    error InvalidRiskConfig();
    error NoTrade();
    error UnprotectedDust(address token);

    event RiskConfigUpdated(BasketTypes.RiskConfig risk);
    event RebalanceTraded(
        address indexed keeper,
        address indexed adapter,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 keeperReward
    );

    BasketTypes.RiskConfig private _risk;

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens,
        uint256[] memory weights,
        address oracle_,
        address initialOwner,
        address robinhoodRegistry_,
        address executionRegistry_,
        address tradingHours_,
        BasketTypes.FeeConfig memory fee_,
        BasketTypes.RiskConfig memory risk_
    )
        ETFToken(
            name_,
            symbol_,
            tokens,
            weights,
            oracle_,
            initialOwner,
            robinhoodRegistry_,
            executionRegistry_,
            tradingHours_,
            fee_
        )
    {
        _setRiskConfig(risk_);
    }

    function riskConfig() external view returns (BasketTypes.RiskConfig memory) {
        return _risk;
    }

    function setRiskConfig(BasketTypes.RiskConfig calldata risk_) external onlyOwner {
        _accrueFees();
        _setRiskConfig(risk_);
    }

    function _setRiskConfig(BasketTypes.RiskConfig memory risk_) private {
        if (risk_.maxTradeValue == 0) revert InvalidRiskConfig();
        if (risk_.minTradeValue > risk_.maxTradeValue) revert InvalidRiskConfig();
        if (risk_.maxSlippageBps > MAX_SLIPPAGE_BPS_CAP) revert InvalidRiskConfig();
        if (risk_.keeperRewardBps > MAX_KEEPER_REWARD_BPS_CAP) revert InvalidRiskConfig();
        if (risk_.rebalanceBandBps > MAX_REBALANCE_BAND_BPS_CAP) revert InvalidRiskConfig();
        _risk = risk_;
        emit RiskConfigUpdated(risk_);
    }

    function previewRebalanceTrade(
        address tokenIn,
        address tokenOut
    )
        public
        view
        returns (BasketTypes.TradePreview memory preview)
    {
        uint256 inIndex = _constituentIndex(tokenIn);
        uint256 outIndex = _constituentIndex(tokenOut);
        if (inIndex == 0 || outIndex == 0 || tokenIn == tokenOut) return preview;
        (uint256 basketValue,) = _basketState();
        if (basketValue == 0) return preview;

        uint256 surplus;
        uint256 deficit;
        {
            IBasketOracle oracle_ = oracle;
            uint256 inValue = oracle_.quote(tokenIn, _reserveOf(tokenIn));
            uint256 inTarget = Math.mulDiv(basketValue, _weightAt(inIndex - 1), TOTAL_WEIGHT_BPS);
            if (inValue <= inTarget) return preview;
            surplus = inValue - inTarget;
            uint256 outValue = oracle_.quote(tokenOut, _reserveOf(tokenOut));
            uint256 outTarget = Math.mulDiv(basketValue, _weightAt(outIndex - 1), TOTAL_WEIGHT_BPS);
            if (outValue >= outTarget) return preview;
            deficit = outTarget - outValue;
        }

        BasketTypes.RiskConfig memory risk_ = _risk;
        uint256 band = Math.mulDiv(basketValue, risk_.rebalanceBandBps, TOTAL_WEIGHT_BPS);
        if (surplus <= band || deficit <= band) return preview;
        uint256 tradeValue = Math.min(Math.min(surplus, deficit), risk_.maxTradeValue);
        if (tradeValue < risk_.minTradeValue) return preview;
        uint256 amountIn = Math.min(oracle.quoteInverse(tokenIn, tradeValue), _reserveOf(tokenIn));
        if (amountIn == 0) return preview;
        return _finishPreview(tokenIn, tokenOut, amountIn, risk_.minTradeValue);
    }

    function previewRetire(address token, address into) public view returns (BasketTypes.TradePreview memory preview) {
        uint256 tokenIndex = _constituentIndex(token);
        uint256 intoIndex = _constituentIndex(into);
        if (tokenIndex == 0 || intoIndex == 0 || token == into) return preview;
        if (_weightAt(tokenIndex - 1) != 0) return preview;
        uint256 reserve = _reserveOf(token);
        if (reserve == 0) return preview;
        IBasketOracle oracle_ = oracle;
        uint256 maxTradeValue = _risk.maxTradeValue;
        uint256 fullValue = oracle_.quote(token, reserve);
        uint256 amountIn = fullValue <= maxTradeValue ? reserve : oracle_.quoteInverse(token, maxTradeValue);
        if (amountIn == 0) return preview;
        return _finishPreview(token, into, amountIn, 0);
    }

    function _finishPreview(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minTradeValue
    )
        private
        view
        returns (BasketTypes.TradePreview memory preview)
    {
        IBasketOracle oracle_ = oracle;
        uint256 tradeValue = oracle_.quote(tokenIn, amountIn);
        if (tradeValue < minTradeValue) return preview;
        uint256 expectedAmountOut = oracle_.quoteInverse(tokenOut, tradeValue);
        if (expectedAmountOut == 0) return preview;
        uint256 slippageFloorBps = TOTAL_WEIGHT_BPS - _risk.maxSlippageBps;
        uint256 minAmountOut = Math.mulDiv(expectedAmountOut, slippageFloorBps, TOTAL_WEIGHT_BPS);
        if (minAmountOut == 0) return preview;
        preview = BasketTypes.TradePreview({
            executable: true,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            tradeValue: tradeValue,
            expectedAmountOut: expectedAmountOut,
            minAmountOut: minAmountOut
        });
    }

    function rebalanceTrade(
        address tokenIn,
        address tokenOut,
        address adapter
    )
        external
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut, uint256 keeperReward)
    {
        _accrueFees();
        BasketTypes.TradePreview memory preview = previewRebalanceTrade(tokenIn, tokenOut);
        if (!preview.executable) revert NoTrade();
        return _executeTrade(preview, adapter);
    }

    function retireConstituent(
        address token,
        address into,
        address adapter
    )
        external
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut, uint256 keeperReward)
    {
        _accrueFees();
        BasketTypes.TradePreview memory preview = previewRetire(token, into);
        if (!preview.executable) {
            uint256 index = _constituentIndex(token);
            bool destinationValid = _constituentIndex(into) != 0 && into != token;
            if (destinationValid && index != 0 && _weightAt(index - 1) == 0 && _reserveOf(token) != 0) {
                revert UnprotectedDust(token);
            }
            revert NoTrade();
        }
        return _executeTrade(preview, adapter);
    }

    function _executeTrade(
        BasketTypes.TradePreview memory preview,
        address adapter
    )
        internal
        returns (uint256 amountIn, uint256 amountOut, uint256 keeperReward)
    {
        _requireTradable(preview.tokenIn);
        _requireTradable(preview.tokenOut);
        _requireAdapter(adapter, preview.tokenIn, preview.tokenOut);
        amountIn = preview.amountIn;
        amountOut = _swapVia(adapter, preview.tokenIn, preview.tokenOut, amountIn, preview.minAmountOut);
        keeperReward = _keeperReward(preview.tokenOut, amountOut);
        _decreaseReserve(preview.tokenIn, amountIn);
        _increaseReserve(preview.tokenOut, amountOut - keeperReward);
        if (keeperReward != 0) _push(preview.tokenOut, msg.sender, keeperReward);
        emit RebalanceTraded(msg.sender, adapter, preview.tokenIn, preview.tokenOut, amountIn, amountOut, keeperReward);
    }

    function _keeperReward(address tokenOut, uint256 amountOut) private view returns (uint256) {
        BasketTypes.RiskConfig memory risk_ = _risk;
        if (risk_.keeperRewardBps == 0 || risk_.maxKeeperRewardValue == 0) return 0;
        uint256 byShare = Math.mulDiv(amountOut, risk_.keeperRewardBps, TOTAL_WEIGHT_BPS);
        uint256 ceiling = oracle.quoteInverse(tokenOut, risk_.maxKeeperRewardValue);
        return Math.min(byShare, ceiling);
    }
}

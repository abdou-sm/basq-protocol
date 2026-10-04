// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ETFToken } from "./ETFToken.sol";
import { IBasketOracle } from "./interfaces/IBasketOracle.sol";
import { IBasketExecution } from "./interfaces/IBasketExecution.sol";
import { IExecutionRegistry } from "./interfaces/IExecutionRegistry.sol";
import { ITradingHours } from "./interfaces/ITradingHours.sol";

/// @title CashGateway — single-cash entry/exit router for Robinhood ETF baskets
/// @notice Stateless router (holds no funds between calls). Entry pulls USDG, swaps into
///         each constituent pro-rata by weight at the oracle floor, then calls the basket's
///         standard `contribute`. Exit pulls ETF shares via `transferFrom`, calls the
///         basket's proportional `withdraw` to itself, swaps legs into USDG, forwards USDG.
/// @dev Keeping swaps out of the share token shrinks basket bytecode so factories stay
///      under EIP-170. Every swap enforces the allowlist, the oracle slippage floor, and
///      balance deltas; tradability is checked per swapped leg before funds move.
contract CashGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotAContract(address account);
    error AdapterNotAllowed(address adapter);
    error PairNotSupported(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOut);
    error InsufficientShares(uint256 minimum, uint256 actual);
    error ZeroAmount();
    error ZeroAddress();
    error MarketClosed(address token);
    error BalanceDeltaMismatch(address token);

    event CashContributed(
        address indexed caller,
        address indexed receiver,
        address indexed basket,
        uint256 usdgSpent,
        uint256 lpAmount,
        uint256[] amountsIn
    );
    event CashWithdrawn(
        address indexed caller,
        address indexed receiver,
        address indexed basket,
        uint256 lpAmount,
        uint256 usdgOut
    );

    uint256 internal constant TOTAL_WEIGHT_BPS = 10_000;
    uint256 internal constant MINIMUM_SHARES = 1000;
    uint8 internal constant SHARE_DECIMALS = 18;

    IERC20 public immutable USDG;
    uint8 public immutable usdgDecimals;
    IExecutionRegistry public immutable executionRegistry;

    constructor(address usdg_, address executionRegistry_) {
        if (usdg_ == address(0) || usdg_.code.length == 0) revert NotAContract(usdg_);
        if (executionRegistry_ == address(0) || executionRegistry_.code.length == 0) {
            revert NotAContract(executionRegistry_);
        }
        USDG = IERC20(usdg_);
        usdgDecimals = IERC20Metadata(usdg_).decimals();
        executionRegistry = IExecutionRegistry(executionRegistry_);
    }

    // --- previews (exact: pending streaming fees included) ---

    function previewContributeWithUSDG(address basket, uint256 usdgAmount) public view returns (uint256 shares) {
        if (usdgAmount == 0) return 0;
        ETFToken etf = ETFToken(basket);
        uint256 value = _usdgToUnit(address(etf.oracle()), usdgAmount);
        if (value == 0) return 0;
        (uint256 cShares, uint256 pShares) = etf.previewAccruedFees();
        uint256 supply = etf.totalSupply() + cShares + pShares;
        uint256 basketValue = etf.totalBasketValue();
        uint256 initialScale = 10 ** uint256(SHARE_DECIMALS - etf.oracle().unitDecimals());
        if (supply == 0) {
            uint256 gross = value * initialScale;
            return gross <= MINIMUM_SHARES ? 0 : gross - MINIMUM_SHARES;
        }
        if (basketValue == 0) return value * initialScale;
        return Math.mulDiv(value, supply, basketValue);
    }

    function previewWithdrawToUSDG(address basket, uint256 lpAmount) public view returns (uint256 usdgOut) {
        if (lpAmount == 0) return 0;
        ETFToken etf = ETFToken(basket);
        if (etf.totalSupply() == 0) return 0;
        uint256[] memory legs = etf.previewWithdraw(lpAmount);
        (address[] memory tokens,) = etf.getConstituents();
        uint256 accValue;
        for (uint256 i; i < tokens.length; ++i) {
            if (legs[i] == 0) continue;
            accValue += etf.oracle().quote(tokens[i], legs[i]);
        }
        return _unitToUsdg(address(etf.oracle()), accValue);
    }

    // --- entry ---

    function contributeWithUSDG(
        address basket,
        uint256 usdgAmount,
        address receiver,
        uint256 minShares,
        address adapter
    )
        external
        nonReentrant
        returns (uint256 lpAmount, uint256[] memory amountsIn)
    {
        if (usdgAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        ETFToken etf = ETFToken(basket);
        IBasketOracle oracle = etf.oracle();
        (address[] memory tokens, uint256[] memory weights) = etf.getConstituents();
        uint256 n = tokens.length;
        amountsIn = new uint256[](n);

        uint256 unitValue = _usdgToUnit(address(oracle), usdgAmount);
        if (unitValue == 0) revert ZeroAmount();

        for (uint256 i; i < n; ++i) {
            if (weights[i] == 0) continue;
            _requireTradable(address(etf.tradingHours()), tokens[i]);
            _requireAdapter(adapter, address(USDG), tokens[i]);
        }

        {
            uint256 selfBefore = USDG.balanceOf(address(this));
            USDG.safeTransferFrom(msg.sender, address(this), usdgAmount);
            if (USDG.balanceOf(address(this)) - selfBefore != usdgAmount) {
                revert BalanceDeltaMismatch(address(USDG));
            }
        }

        uint256 accValue;
        for (uint256 i; i < n; ++i) {
            uint256 legValue = Math.mulDiv(unitValue, weights[i], TOTAL_WEIGHT_BPS);
            if (legValue == 0) continue;
            uint256 fairAmount = oracle.quoteInverse(tokens[i], legValue);
            if (fairAmount == 0) continue;
            uint256 minOut = Math.mulDiv(fairAmount, TOTAL_WEIGHT_BPS - 100, TOTAL_WEIGHT_BPS);
            uint256 legUsdg = Math.mulDiv(usdgAmount, weights[i], TOTAL_WEIGHT_BPS);
            if (legUsdg == 0) continue;
            uint256 got = _swap(adapter, address(USDG), tokens[i], legUsdg, minOut);
            amountsIn[i] = got;
            IERC20(tokens[i]).forceApprove(basket, got);
            accValue += oracle.quote(tokens[i], got);
        }
        if (accValue == 0) revert ZeroAmount();

        uint256[] memory contrib = amountsIn;
        lpAmount = etf.contribute(contrib, receiver, minShares);

        uint256 dust = USDG.balanceOf(address(this));
        if (dust > 0) USDG.safeTransfer(receiver, dust);

        emit CashContributed(msg.sender, receiver, basket, usdgAmount, lpAmount, amountsIn);
    }

    // --- exit ---

    function withdrawToUSDG(
        address basket,
        uint256 lpAmount,
        address receiver,
        uint256 minUsdgOut,
        address adapter
    )
        external
        nonReentrant
        returns (uint256 usdgOut)
    {
        if (lpAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        ETFToken etf = ETFToken(basket);
        IBasketOracle oracle = etf.oracle();
        (address[] memory tokens,) = etf.getConstituents();

        uint256[] memory legs = etf.previewWithdraw(lpAmount);
        for (uint256 i; i < tokens.length; ++i) {
            if (legs[i] == 0) continue;
            _requireTradable(address(etf.tradingHours()), tokens[i]);
            _requireAdapter(adapter, tokens[i], address(USDG));
        }

        IERC20(basket).safeTransferFrom(msg.sender, address(this), lpAmount);
        uint256[] memory zeros = new uint256[](tokens.length);
        etf.withdraw(lpAmount, address(this), zeros);

        for (uint256 i; i < tokens.length; ++i) {
            uint256 leg = IERC20(tokens[i]).balanceOf(address(this));
            if (leg == 0) continue;
            uint256 fairUsdg = _unitToUsdg(address(oracle), oracle.quote(tokens[i], leg));
            uint256 minOut = Math.mulDiv(fairUsdg, TOTAL_WEIGHT_BPS - 100, TOTAL_WEIGHT_BPS);
            usdgOut += _swap(adapter, tokens[i], address(USDG), leg, minOut);
        }
        if (usdgOut < minUsdgOut) revert InsufficientOutput(minUsdgOut, usdgOut);
        if (usdgOut == 0) revert ZeroAmount();

        USDG.safeTransfer(receiver, usdgOut);
        emit CashWithdrawn(msg.sender, receiver, basket, lpAmount, usdgOut);
    }

    // --- internals ---

    function _requireTradable(address tradingHours, address token) private view {
        if (tradingHours == address(0)) return;
        if (!ITradingHours(tradingHours).isTradable(token)) revert MarketClosed(token);
    }

    function _requireAdapter(address adapter, address tokenIn, address tokenOut) private view {
        if (adapter == address(0) || adapter.code.length == 0) revert NotAContract(adapter);
        if (!executionRegistry.isExecutionAdapter(adapter)) revert AdapterNotAllowed(adapter);
        if (!IBasketExecution(adapter).supportsPair(tokenIn, tokenOut)) {
            revert PairNotSupported(tokenIn, tokenOut);
        }
    }

    function _swap(
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        private
        returns (uint256 amountOut)
    {
        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 inBefore = input.balanceOf(address(this));
        uint256 outBefore = output.balanceOf(address(this));
        input.forceApprove(adapter, amountIn);
        amountOut = IBasketExecution(adapter).swap(tokenIn, tokenOut, amountIn, minAmountOut);
        input.forceApprove(adapter, 0);
        if (inBefore - input.balanceOf(address(this)) != amountIn) revert BalanceDeltaMismatch(tokenIn);
        if (output.balanceOf(address(this)) - outBefore != amountOut) revert BalanceDeltaMismatch(tokenOut);
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);
    }

    function _usdgToUnit(address oracle, uint256 usdgAmount) private view returns (uint256 value) {
        uint8 unitDec = IBasketOracle(oracle).unitDecimals();
        if (usdgDecimals == unitDec) return usdgAmount;
        if (usdgDecimals > unitDec) return usdgAmount / (10 ** uint256(usdgDecimals - unitDec));
        return usdgAmount * (10 ** uint256(unitDec - usdgDecimals));
    }

    function _unitToUsdg(address oracle, uint256 value) private view returns (uint256 usdgAmount) {
        uint8 unitDec = IBasketOracle(oracle).unitDecimals();
        if (usdgDecimals == unitDec) return value;
        if (usdgDecimals > unitDec) return value * (10 ** uint256(usdgDecimals - unitDec));
        return value / (10 ** uint256(unitDec - usdgDecimals));
    }
}

// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { BasketToken } from "./BasketToken.sol";
import { IBasketOracle } from "./interfaces/IBasketOracle.sol";
import { IBasketExecution } from "./interfaces/IBasketExecution.sol";
import { IExecutionRegistry } from "./interfaces/IExecutionRegistry.sol";
import { IRobinhoodRegistry } from "./interfaces/IRobinhoodRegistry.sol";
import { ITradingHours } from "./interfaces/ITradingHours.sol";
import { BasketTypes } from "./types/BasketTypes.sol";

/// @title ETFToken — customized ERC-7621 for Robinhood stock baskets
/// @notice Adds: (1) Robinhood asset invariant, (2) continuous streaming creator/platform fee,
///         (3) trading-hours gate. Single-cash entry/exit lives in `CashGateway.sol` (separate
///         router) so the share token stays under EIP-170 and factories can embed it.
contract ETFToken is BasketToken {
    using SafeERC20 for IERC20;

    error NotRobinhoodAsset(address token);
    error InvalidFeeConfig();
    error UnauthorizedFeeUpdate();
    error AdapterNotAllowed(address adapter);
    error PairNotSupported(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOut);
    error MarketClosed(address token);

    event FeesAccrued(address indexed creator, address indexed platform, uint256 creatorShares, uint256 platformShares);
    event FeeConfigUpdated(BasketTypes.FeeConfig fee);

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint16 internal constant MAX_CREATOR_RATE_BPS = 500; // 5%/yr cap
    uint16 internal constant MAX_PLATFORM_SHARE_BPS = 5000; // 50% of creator flow cap

    IRobinhoodRegistry public immutable robinhoodRegistry;
    IExecutionRegistry public immutable executionRegistry;
    ITradingHours public immutable tradingHours;

    BasketTypes.FeeConfig private _fee;
    uint256 public lastFeeAccrual;

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
        BasketTypes.FeeConfig memory fee_
    )
        BasketToken(name_, symbol_, tokens, weights, oracle_, initialOwner)
    {
        if (robinhoodRegistry_ == address(0) || robinhoodRegistry_.code.length == 0) {
            revert NotAContract(robinhoodRegistry_);
        }
        if (executionRegistry_ == address(0) || executionRegistry_.code.length == 0) {
            revert NotAContract(executionRegistry_);
        }
        if (tradingHours_ != address(0) && tradingHours_.code.length == 0) revert NotAContract(tradingHours_);
        robinhoodRegistry = IRobinhoodRegistry(robinhoodRegistry_);
        executionRegistry = IExecutionRegistry(executionRegistry_);
        tradingHours = ITradingHours(tradingHours_);
        // Base constructor already ran `_validateWeights` while immutables were still zero,
        // so it skipped (see override below). Enforce the invariant now that state is set.
        for (uint256 i; i < tokens.length; ++i) {
            if (!IRobinhoodRegistry(robinhoodRegistry_).isRobinhoodAsset(tokens[i])) {
                revert NotRobinhoodAsset(tokens[i]);
            }
        }
        _setFeeConfig(fee_);
        lastFeeAccrual = block.timestamp;
    }

    // --- Robinhood invariant ---

    function _validateWeights(address[] memory tokens, uint256[] memory) internal view override {
        // During BasketToken construction immutables are not yet assigned (base runs first),
        // so skip here; the ETFToken constructor re-validates explicitly after assignment.
        if (address(robinhoodRegistry) == address(0)) return;
        IRobinhoodRegistry reg = robinhoodRegistry;
        for (uint256 i; i < tokens.length; ++i) {
            if (!reg.isRobinhoodAsset(tokens[i])) revert NotRobinhoodAsset(tokens[i]);
        }
    }

    // --- Trading-hours gate ---

    /// @notice Value-based mints are blocked when any constituent is closed; proportional
    ///         `withdraw` stays 24/7 (no oracle, no swaps), `rebalance` (targets only) stays open.
    ///         Previews are price-only and ignore hours; actions revert with `MarketClosed`.
    function _isTradable(address token) internal view returns (bool) {
        if (address(tradingHours) == address(0)) return true;
        return tradingHours.isTradable(token);
    }

    function _requireTradable(address token) internal view {
        if (!_isTradable(token)) revert MarketClosed(token);
    }

    function _requireBasketTradable() internal view {
        if (address(tradingHours) == address(0)) return;
        address[] memory tokens = _constituentsArray();
        for (uint256 i; i < tokens.length; ++i) {
            if (!tradingHours.isTradable(tokens[i])) revert MarketClosed(tokens[i]);
        }
    }

    function _authorizeContribution(address, address) internal view override {
        _requireBasketTradable();
    }

    // --- Streaming fee ---

    function feeConfig() external view returns (BasketTypes.FeeConfig memory) {
        return _fee;
    }

    function _setFeeConfig(BasketTypes.FeeConfig memory fee_) private {
        if (fee_.creator == address(0) || fee_.platform == address(0)) revert InvalidFeeConfig();
        if (fee_.creatorRateBpsAnnual > MAX_CREATOR_RATE_BPS) revert InvalidFeeConfig();
        if (fee_.platformShareBps > MAX_PLATFORM_SHARE_BPS) revert InvalidFeeConfig();
        _fee = fee_;
        emit FeeConfigUpdated(fee_);
    }

    /// @notice Recipient changes and rate increases both require the current creator;
    ///         the owner alone may only lower the rate with recipients unchanged.
    function setFeeConfig(BasketTypes.FeeConfig calldata fee_) external onlyOwner {
        BasketTypes.FeeConfig memory cur = _fee;
        bool recipientsChanged = fee_.creator != cur.creator || fee_.platform != cur.platform;
        if ((fee_.creatorRateBpsAnnual > cur.creatorRateBpsAnnual || recipientsChanged) && msg.sender != cur.creator) {
            revert UnauthorizedFeeUpdate();
        }
        _accrueFees();
        _setFeeConfig(fee_);
    }

    function previewAccruedFees() public view returns (uint256 creatorShares, uint256 platformShares) {
        BasketTypes.FeeConfig memory fee_ = _fee;
        if (fee_.creatorRateBpsAnnual == 0) return (0, 0);
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        uint256 dt = block.timestamp - lastFeeAccrual;
        if (dt == 0) return (0, 0);
        uint256 gross = Math.mulDiv(supply, uint256(fee_.creatorRateBpsAnnual) * dt, SECONDS_PER_YEAR * 10_000);
        uint256 plat = Math.mulDiv(gross, fee_.platformShareBps, 10_000);
        return (gross - plat, plat);
    }

    function accrueFees() external returns (uint256 creatorShares, uint256 platformShares) {
        return _accrueFees();
    }

    function _accrueFees() internal returns (uint256 creatorShares, uint256 platformShares) {
        (creatorShares, platformShares) = previewAccruedFees();
        lastFeeAccrual = block.timestamp;
        if (creatorShares == 0 && platformShares == 0) return (0, 0);
        BasketTypes.FeeConfig memory fee_ = _fee;
        if (creatorShares > 0) _mint(fee_.creator, creatorShares);
        if (platformShares > 0) _mint(fee_.platform, platformShares);
        emit FeesAccrued(fee_.creator, fee_.platform, creatorShares, platformShares);
    }

    function _beforeMutate() internal override {
        _accrueFees();
    }

    // --- execution helper (used by RebalancingETFToken keeper trades) ---

    function _requireAdapter(address adapter, address tokenIn, address tokenOut) internal view {
        if (adapter == address(0) || adapter.code.length == 0) revert NotAContract(adapter);
        if (!executionRegistry.isExecutionAdapter(adapter)) revert AdapterNotAllowed(adapter);
        if (!IBasketExecution(adapter).supportsPair(tokenIn, tokenOut)) {
            revert PairNotSupported(tokenIn, tokenOut);
        }
    }

    function _swapVia(
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        internal
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
}

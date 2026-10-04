// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IBasketExecution } from "src/interfaces/IBasketExecution.sol";
import { MockBasketOracle } from "tests/mocks/MockBasketOracle.sol";
import { MockERC20 } from "tests/mocks/MockERC20.sol";

contract MockBasketExecution is IBasketExecution {
    using SafeERC20 for IERC20;

    error MockSwapFailed();
    error MockSlippage(uint256 minAmountOut, uint256 amountOut);

    uint256 private constant BPS = 10_000;
    MockBasketOracle public immutable oracle;
    uint256 public slippageBps;
    bool public shouldRevert;
    mapping(bytes32 pair => bool supported) private _pairs;

    constructor(MockBasketOracle oracle_) {
        oracle = oracle_;
    }

    function setPair(address tokenIn, address tokenOut, bool supported) external {
        _pairs[keccak256(abi.encode(tokenIn, tokenOut))] = supported;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function supportsPair(address tokenIn, address tokenOut) external view returns (bool) {
        return _pairs[keccak256(abi.encode(tokenIn, tokenOut))];
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        if (shouldRevert) revert MockSwapFailed();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 fair = oracle.quoteInverse(tokenOut, oracle.quote(tokenIn, amountIn));
        amountOut = fair - ((fair * slippageBps) / BPS);
        if (amountOut < minAmountOut) revert MockSlippage(minAmountOut, amountOut);
        MockERC20(tokenOut).mint(address(this), amountOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}

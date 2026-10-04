// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IBasketExecution } from "../interfaces/IBasketExecution.sol";

interface IUniswapV2StyleRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        returns (uint256[] memory amounts);
}

/// @notice Example execution module routing through a Uniswap-V2-shaped router.
contract UniswapV2StyleExecution is Ownable, IBasketExecution {
    using SafeERC20 for IERC20;

    error NotAContract(address account);
    error InvalidPath();
    error PathNotConfigured(address tokenIn, address tokenOut);
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOut);

    event PathSet(address indexed tokenIn, address indexed tokenOut);
    event PathRemoved(address indexed tokenIn, address indexed tokenOut);

    address public immutable router;
    mapping(bytes32 pair => address[] path) private _paths;

    constructor(address router_, address initialOwner) Ownable(initialOwner) {
        if (router_ == address(0) || router_.code.length == 0) revert NotAContract(router_);
        router = router_;
    }

    function setPath(address tokenIn, address tokenOut, address[] calldata path) external onlyOwner {
        if (path.length < 2 || path[0] != tokenIn || path[path.length - 1] != tokenOut) revert InvalidPath();
        if (tokenIn == tokenOut) revert InvalidPath();
        _paths[_key(tokenIn, tokenOut)] = path;
        emit PathSet(tokenIn, tokenOut);
    }

    function removePath(address tokenIn, address tokenOut) external onlyOwner {
        delete _paths[_key(tokenIn, tokenOut)];
        emit PathRemoved(tokenIn, tokenOut);
    }

    function pathOf(address tokenIn, address tokenOut) external view returns (address[] memory) {
        return _paths[_key(tokenIn, tokenOut)];
    }

    function supportsPair(address tokenIn, address tokenOut) external view returns (bool) {
        return _paths[_key(tokenIn, tokenOut)].length >= 2;
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
        address[] memory path = _paths[_key(tokenIn, tokenOut)];
        if (path.length < 2) revert PathNotConfigured(tokenIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 callerBefore = IERC20(tokenOut).balanceOf(msg.sender);
        IERC20(tokenIn).forceApprove(router, amountIn);
        IUniswapV2StyleRouter(router)
            .swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, block.timestamp);
        IERC20(tokenIn).forceApprove(router, 0);
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - callerBefore;
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);
    }

    function _key(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut));
    }
}

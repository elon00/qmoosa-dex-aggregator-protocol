// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IQmoosaDexAggregator {
    struct SwapLeg {
        address pool;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
    }

    struct AggregatedSwapParams {
        address tokenIn;
        address tokenOut;
        uint256 totalAmountIn;
        uint256 minAmountOut;
        address recipient;
        uint256 deadline;
        SwapLeg[] legs;
    }

    function executeSwap(AggregatedSwapParams calldata params) external returns (uint256 totalAmountOut);
}

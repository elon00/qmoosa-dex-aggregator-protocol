// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IDexPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint256 amountIn, address tokenIn, address to) external returns (uint256 amountOut);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);
}

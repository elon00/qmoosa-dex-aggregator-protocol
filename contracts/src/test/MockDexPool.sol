// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../interfaces/IERC20.sol";
import "../interfaces/IDexPool.sol";
import "../interfaces/IQmoosaDexAggregator.sol";

contract MockDexPool is IDexPool {
    address public override token0;
    address public override token1;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public feeBps;

    bool public maliciousReentrant;
    address public aggregatorTarget;

    constructor(
        address _token0,
        address _token1,
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 _feeBps
    ) {
        token0 = _token0;
        token1 = _token1;
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        feeBps = _feeBps;
    }

    function setMaliciousReentrant(address _aggregator) external {
        maliciousReentrant = true;
        aggregatorTarget = _aggregator;
    }

    function getAmountOut(uint256 amountIn, address tokenIn) public view override returns (uint256 amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN");
        bool isZero = tokenIn == token0;
        uint256 rIn = isZero ? reserve0 : reserve1;
        uint256 rOut = isZero ? reserve1 : reserve0;

        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * rOut;
        uint256 denominator = (rIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function swap(
        uint256 amountIn,
        address tokenIn,
        address to
    ) external override returns (uint256 amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN");
        bool isZero = tokenIn == token0;
        address tokenOut = isZero ? token1 : token0;

        amountOut = getAmountOut(amountIn, tokenIn);

        // Pull tokenIn from caller
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "POOL_TRANSFER_IN_FAILED");

        // If configured as malicious reentrant pool, attempt hostile callback
        if (maliciousReentrant && aggregatorTarget != address(0)) {
            IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
            legs[0] = IQmoosaDexAggregator.SwapLeg({
                pool: address(this),
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: 1000
            });
            IQmoosaDexAggregator(aggregatorTarget).executeSwap(
                IQmoosaDexAggregator.AggregatedSwapParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    totalAmountIn: 1000,
                    minAmountOut: 1,
                    recipient: to,
                    deadline: block.timestamp + 300,
                    legs: legs
                })
            );
        }

        // Update reserves
        if (isZero) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Transfer tokenOut to recipient
        require(IERC20(tokenOut).transfer(to, amountOut), "POOL_TRANSFER_OUT_FAILED");

        return amountOut;
    }
}

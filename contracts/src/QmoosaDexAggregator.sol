// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./interfaces/IERC20.sol";
import "./interfaces/IDexPool.sol";
import "./interfaces/IQmoosaDexAggregator.sol";

/**
 * @title QmoosaDexAggregator
 * @notice Production-grade multi-DEX aggregator smart contract with atomic execution,
 * strict deadline enforcement, slippage protection, and non-reentrancy guards.
 */
contract QmoosaDexAggregator is IQmoosaDexAggregator {
    address public owner;

    // Non-reentrancy guard
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    mapping(address => bool) public approvedPools;

    event PoolApprovalUpdated(address indexed pool, bool approved);
    event SwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 totalAmountIn,
        uint256 totalAmountOut,
        address recipient
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED: Only owner");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY_GUARD_TRIGGERED: Reentrant call prohibited");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() {
        owner = msg.sender;
        _status = _NOT_ENTERED;
    }

    function setPoolApproval(address pool, bool approved) external onlyOwner {
        require(pool != address(0), "INVALID_POOL_ADDRESS");
        approvedPools[pool] = approved;
        emit PoolApprovalUpdated(pool, approved);
    }

    function executeSwap(
        AggregatedSwapParams calldata params
    ) external override nonReentrant returns (uint256 totalAmountOut) {
        // Strict deadline validation
        require(block.timestamp <= params.deadline, "TRANSACTION_EXPIRED: Deadline has passed");
        require(params.totalAmountIn > 0, "ZERO_INPUT_AMOUNT: Input amount must be strictly positive");
        require(params.minAmountOut > 0, "ZERO_MIN_OUTPUT: Min output must be strictly positive");
        require(params.recipient != address(0), "INVALID_RECIPIENT: Recipient cannot be zero address");
        require(params.legs.length > 0, "EMPTY_SWAP_LEGS: At least one swap leg required");

        // Verify conservation of input split
        uint256 sumIn = 0;
        for (uint256 i = 0; i < params.legs.length; i++) {
            SwapLeg calldata leg = params.legs[i];
            require(approvedPools[leg.pool], "UNAPPROVED_POOL: Target liquidity pool is not approved");
            require(leg.tokenIn == params.tokenIn, "TOKEN_IN_MISMATCH: Leg tokenIn does not match swap tokenIn");
            require(leg.tokenOut == params.tokenOut, "TOKEN_OUT_MISMATCH: Leg tokenOut does not match swap tokenOut");
            require(leg.amountIn > 0, "ZERO_LEG_AMOUNT: Leg amount must be positive");
            sumIn += leg.amountIn;
        }
        require(sumIn == params.totalAmountIn, "INPUT_SUM_MISMATCH: Sum of leg inputs does not match totalAmountIn");

        // Transfer total tokenIn from caller into aggregator
        require(
            IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.totalAmountIn),
            "TRANSFER_IN_FAILED: Could not transfer tokenIn from sender"
        );

        // Record recipient's balance before swaps
        uint256 balanceBefore = IERC20(params.tokenOut).balanceOf(params.recipient);

        // Execute parallel swap legs across underlying DEX pools
        for (uint256 i = 0; i < params.legs.length; i++) {
            SwapLeg calldata leg = params.legs[i];

            // Approve pool to pull leg input
            require(IERC20(leg.tokenIn).approve(leg.pool, leg.amountIn), "APPROVE_POOL_FAILED");

            // Execute pool swap with output directed to recipient
            uint256 legOut = IDexPool(leg.pool).swap(leg.amountIn, leg.tokenIn, params.recipient);
            totalAmountOut += legOut;
        }

        // Verify recipient balance delta
        uint256 balanceAfter = IERC20(params.tokenOut).balanceOf(params.recipient);
        require(balanceAfter >= balanceBefore + totalAmountOut, "BALANCE_DELTA_DEFICIT: Output balance deficit");

        // Slippage protection: revert if net output is less than minimum guaranteed
        require(
            totalAmountOut >= params.minAmountOut,
            "SLIPPAGE_LIMIT_EXCEEDED: Realized output is below minAmountOut"
        );

        emit SwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.totalAmountIn,
            totalAmountOut,
            params.recipient
        );

        return totalAmountOut;
    }
}

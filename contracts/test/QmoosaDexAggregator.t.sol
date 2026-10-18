// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/QmoosaDexAggregator.sol";
import "../src/test/MockERC20.sol";
import "../src/test/MockDexPool.sol";

contract QmoosaDexAggregatorTest is Test {
    QmoosaDexAggregator public aggregator;
    MockERC20 public usdc;
    MockERC20 public weth;

    MockDexPool public poolA; // DEX A (e.g. Uniswap)
    MockDexPool public poolB; // DEX B (e.g. Sushiswap)

    address public user = address(0x111);
    address public recipient = address(0x222);

    uint256 public constant INITIAL_USDC_RESERVES = 1_000_000 * 1e6;
    uint256 public constant INITIAL_WETH_RESERVES = 500 * 1e18;

    function setUp() public {
        aggregator = new QmoosaDexAggregator();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy two DEX pools with identical reserves and 30 bps fee
        poolA = new MockDexPool(
            address(usdc),
            address(weth),
            INITIAL_USDC_RESERVES,
            INITIAL_WETH_RESERVES,
            30
        );
        poolB = new MockDexPool(
            address(usdc),
            address(weth),
            INITIAL_USDC_RESERVES,
            INITIAL_WETH_RESERVES,
            30
        );

        // Fund pools with initial liquidity
        usdc.mint(address(poolA), INITIAL_USDC_RESERVES);
        weth.mint(address(poolA), INITIAL_WETH_RESERVES);
        usdc.mint(address(poolB), INITIAL_USDC_RESERVES);
        weth.mint(address(poolB), INITIAL_WETH_RESERVES);

        // Approve pools in aggregator
        aggregator.setPoolApproval(address(poolA), true);
        aggregator.setPoolApproval(address(poolB), true);

        // Fund user with USDC
        usdc.mint(user, 100_000 * 1e6);
    }

    function test_DirectSinglePoolSwap() public {
        uint256 swapAmount = 10_000 * 1e6;
        uint256 expectedOut = poolA.getAmountOut(swapAmount, address(usdc));

        vm.startPrank(user);
        usdc.approve(address(aggregator), swapAmount);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: swapAmount
        });

        uint256 amountOut = aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: swapAmount,
                minAmountOut: expectedOut,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut);
        assertEq(weth.balanceOf(recipient), expectedOut);
    }

    function test_SplitSwapAcrossTwoPools() public {
        uint256 totalSwapAmount = 50_000 * 1e6; // 50k USDC
        uint256 splitIn = totalSwapAmount / 2; // 25k to Pool A, 25k to Pool B

        uint256 outA = poolA.getAmountOut(splitIn, address(usdc));
        uint256 outB = poolB.getAmountOut(splitIn, address(usdc));
        uint256 expectedTotalOut = outA + outB;

        // Compare with swapping 100% in Pool A
        uint256 singlePoolOut = poolA.getAmountOut(totalSwapAmount, address(usdc));
        // Split swap must yield strictly more output due to convex price impact
        assertGt(expectedTotalOut, singlePoolOut);

        vm.startPrank(user);
        usdc.approve(address(aggregator), totalSwapAmount);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](2);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: splitIn
        });
        legs[1] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolB),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: splitIn
        });

        uint256 realizedOut = aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: totalSwapAmount,
                minAmountOut: expectedTotalOut,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();

        assertEq(realizedOut, expectedTotalOut);
        assertEq(weth.balanceOf(recipient), expectedTotalOut);
    }

    function test_RevertWhen_SlippageExceeded() public {
        uint256 swapAmount = 10_000 * 1e6;
        uint256 expectedOut = poolA.getAmountOut(swapAmount, address(usdc));

        vm.startPrank(user);
        usdc.approve(address(aggregator), swapAmount);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: swapAmount
        });

        // Demanding more output than pool can provide -> must revert with slippage limit
        vm.expectRevert("SLIPPAGE_LIMIT_EXCEEDED: Realized output is below minAmountOut");
        aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: swapAmount,
                minAmountOut: expectedOut + 1 ether,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();
    }

    function test_RevertWhen_DeadlineExpired() public {
        uint256 swapAmount = 10_000 * 1e6;

        vm.startPrank(user);
        usdc.approve(address(aggregator), swapAmount);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: swapAmount
        });

        vm.warp(block.timestamp + 1000);

        vm.expectRevert("TRANSACTION_EXPIRED: Deadline has passed");
        aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: swapAmount,
                minAmountOut: 1,
                recipient: recipient,
                deadline: block.timestamp - 1, // Past deadline
                legs: legs
            })
        );
        vm.stopPrank();
    }

    function test_RevertWhen_UnapprovedPool() public {
        address unapprovedPool = address(0x9999);

        vm.startPrank(user);
        usdc.approve(address(aggregator), 10_000 * 1e6);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: unapprovedPool,
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 10_000 * 1e6
        });

        vm.expectRevert("UNAPPROVED_POOL: Target liquidity pool is not approved");
        aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: 10_000 * 1e6,
                minAmountOut: 1,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();
    }

    function test_RevertWhen_InputSumMismatch() public {
        vm.startPrank(user);
        usdc.approve(address(aggregator), 10_000 * 1e6);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 5_000 * 1e6 // Legs sum to 5k but totalAmountIn declared as 10k
        });

        vm.expectRevert("INPUT_SUM_MISMATCH: Sum of leg inputs does not match totalAmountIn");
        aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: 10_000 * 1e6,
                minAmountOut: 1,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();
    }

    function test_RevertWhen_ReentrantAttackAttempted() public {
        poolA.setMaliciousReentrant(address(aggregator));

        vm.startPrank(user);
        usdc.approve(address(aggregator), 10_000 * 1e6);

        IQmoosaDexAggregator.SwapLeg[] memory legs = new IQmoosaDexAggregator.SwapLeg[](1);
        legs[0] = IQmoosaDexAggregator.SwapLeg({
            pool: address(poolA),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 10_000 * 1e6
        });

        vm.expectRevert("REENTRANCY_GUARD_TRIGGERED: Reentrant call prohibited");
        aggregator.executeSwap(
            IQmoosaDexAggregator.AggregatedSwapParams({
                tokenIn: address(usdc),
                tokenOut: address(weth),
                totalAmountIn: 10_000 * 1e6,
                minAmountOut: 1,
                recipient: recipient,
                deadline: block.timestamp + 300,
                legs: legs
            })
        );
        vm.stopPrank();
    }
}

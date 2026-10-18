import { test } from "node:test";
import assert from "node:assert/strict";
import {
  calculateConstantProductOutput,
  calculateSlippageBounds,
  calculatePriceImpact,
  calculateMultiHopOutput,
  calculateOptimalSplit
} from "../dist/index.js";

test("1. Constant product output calculation & boundary checks", () => {
  // Pool: 1,000,000 USDC / 500 ETH (0.3% fee = 30 bps)
  const reserveIn = 1_000_000n * 10n ** 6n;
  const reserveOut = 500n * 10n ** 18n;
  const amountIn = 10_000n * 10n ** 6n; // 10,000 USDC swap

  const amountOut = calculateConstantProductOutput(amountIn, reserveIn, reserveOut, 30n);
  assert.ok(amountOut > 0n);

  // Exact math:
  // inWithFee = 10,000 * 9,970 = 99,700,000
  // num = 99,700,000 * 500 = 49,850,000,000
  // den = 1,000,000 * 10,000 + 99,700,000 = 10,099,700,000
  // out = ~4.93578 ETH
  assert.ok(amountOut > 4n * 10n ** 18n && amountOut < 5n * 10n ** 18n);

  // Negative & zero amounts must throw RangeError
  assert.throws(() => calculateConstantProductOutput(0n, reserveIn, reserveOut), /INSUFFICIENT_INPUT_AMOUNT/);
  assert.throws(() => calculateConstantProductOutput(-10n, reserveIn, reserveOut), /INSUFFICIENT_INPUT_AMOUNT/);
  assert.throws(() => calculateConstantProductOutput(amountIn, 0n, reserveOut), /INSUFFICIENT_LIQUIDITY/);
});

test("2. Slippage bounds calculation", () => {
  const expectedOut = 100_000n;
  const toleranceBps = 50n; // 0.5%

  const { minAmountOut, maxSlippageAmount } = calculateSlippageBounds(expectedOut, toleranceBps);
  assert.equal(maxSlippageAmount, 500n);
  assert.equal(minAmountOut, 99_500n);
  assert.equal(minAmountOut + maxSlippageAmount, expectedOut);
});

test("3. Price impact calculation", () => {
  const reserveIn = 1_000_000n * 10n ** 6n;
  const reserveOut = 1_000_000n * 10n ** 6n;

  // Small trade (100 USDC in 1M pool) -> negligible impact (< 1 bp)
  const smallIn = 100n * 10n ** 6n;
  const smallOut = calculateConstantProductOutput(smallIn, reserveIn, reserveOut, 30n);
  const smallImpact = calculatePriceImpact(smallIn, smallOut, reserveIn, reserveOut);
  assert.ok(smallImpact < 50n); // Less than 0.5% (mostly the 30 bp fee)

  // Large trade (200,000 USDC in 1M pool = 20% of pool) -> significant impact (> 1500 bps)
  const largeIn = 200_000n * 10n ** 6n;
  const largeOut = calculateConstantProductOutput(largeIn, reserveIn, reserveOut, 30n);
  const largeImpact = calculatePriceImpact(largeIn, largeOut, reserveIn, reserveOut);
  assert.ok(largeImpact > 1500n);
});

test("4. Multi-hop sequential routing output", () => {
  // Path: USDC -> WETH -> DAI
  // Hop 1: USDC (1M * 1e6) -> WETH (500 * 1e18)
  // Hop 2: WETH (500 * 1e18) -> DAI (1M * 1e18)
  const hop1 = { reserveIn: 1_000_000n * 10n ** 6n, reserveOut: 500n * 10n ** 18n, feeBps: 30n };
  const hop2 = { reserveIn: 500n * 10n ** 18n, reserveOut: 1_000_000n * 10n ** 18n, feeBps: 30n };

  const amountIn = 10_000n * 10n ** 6n; // 10,000 USDC
  const finalOut = calculateMultiHopOutput(amountIn, [hop1, hop2]);

  const expectedMin = 9700n * 10n ** 18n;
  const expectedMax = 9800n * 10n ** 18n;
  assert.ok(
    finalOut > expectedMin && finalOut < expectedMax,
    `finalOut ${finalOut} should be between ${expectedMin} and ${expectedMax}`
  );
});

test("5. Optimal split routing strictly outperforms single-pool routing under heavy volume", () => {
  // Pool A: 500,000 In / 500,000 Out (30 bps fee)
  // Pool B: 500,000 In / 500,000 Out (30 bps fee)
  const poolA = { reserveIn: 500_000n, reserveOut: 500_000n, feeBps: 30n };
  const poolB = { reserveIn: 500_000n, reserveOut: 500_000n, feeBps: 30n };

  const totalAmountIn = 200_000n; // Swap 200,000

  // If swapped 100% through Pool A alone:
  const singlePoolOut = calculateConstantProductOutput(totalAmountIn, poolA.reserveIn, poolA.reserveOut, poolA.feeBps);

  // If split optimally between Pool A and Pool B:
  const splitResult = calculateOptimalSplit(totalAmountIn, poolA, poolB);

  // Conservation invariant: amountInA + amountInB === totalAmountIn
  assert.equal(splitResult.amountInA + splitResult.amountInB, totalAmountIn);

  // Split should be close to 50/50 since pools are identical
  assert.equal(splitResult.percentA, 5000n);
  assert.equal(splitResult.percentB, 5000n);

  // Crucial invariant: Split routing produces strictly higher net output than single pool!
  assert.ok(
    splitResult.totalAmountOut > singlePoolOut,
    `Split output ${splitResult.totalAmountOut} must be greater than single pool output ${singlePoolOut}`
  );
});

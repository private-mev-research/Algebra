// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './FullMath.sol';
import './TokenDeltaMath.sol';
import './TickMath.sol';
import './Constants.sol';
import 'hardhat/console.sol';

/// @title Computes the result of price movement
/// @notice Contains methods for computing the result of price movement within a single tick price range.
library PriceMovementMath {
  using LowGasSafeMath for uint256;
  using SafeCast for uint256;

  /// @notice Gets the next sqrt price given an input amount of token0 or token1
  /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
  /// @param price The starting Q64.96 sqrt price, i.e., before accounting for the input amount
  /// @param liquidity The amount of usable liquidity
  /// @param input How much of token0, or token1, is being swapped in
  /// @param zeroToOne Whether the amount in is token0 or token1
  /// @return resultPrice The Q64.96 sqrt price after adding the input amount to token0 or token1
  function getNewPriceAfterInput(
    bool zeroToOne,
    uint160 price,
    uint128 liquidity,
    uint256 input
  ) internal pure returns (uint160 resultPrice) {
    return getNewPrice(price, liquidity, input, zeroToOne, true);
  }

  /// @notice Gets the next sqrt price given an output amount of token0 or token1
  /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
  /// @param price The starting Q64.96 sqrt price before accounting for the output amount
  /// @param liquidity The amount of usable liquidity
  /// @param output How much of token0, or token1, is being swapped out
  /// @param zeroToOne Whether the amount out is token0 or token1
  /// @return resultPrice The Q64.96 sqrt price after removing the output amount of token0 or token1
  function getNewPriceAfterOutput(
    bool zeroToOne,
    uint160 price,
    uint128 liquidity,
    uint256 output
  ) internal pure returns (uint160 resultPrice) {
    return getNewPrice(price, liquidity, output, zeroToOne, false);
  }

  function getNewPrice(
    uint160 price,
    uint128 liquidity,
    uint256 amount,
    bool zeroToOne,
    bool fromInput
  ) internal pure returns (uint160 resultPrice) {
    require(price > 0);
    require(liquidity > 0);

    if (zeroToOne == fromInput) {
      // rounding up or down
      if (amount == 0) return price;
      uint256 liquidityShifted = uint256(liquidity) << Constants.RESOLUTION;

      if (fromInput) {
        uint256 product;
        if ((product = amount * price) / amount == price) {
          uint256 denominator = liquidityShifted + product;
          if (denominator >= liquidityShifted) return uint160(FullMath.mulDivRoundingUp(liquidityShifted, price, denominator)); // always fits in 160 bits
        }

        return uint160(FullMath.divRoundingUp(liquidityShifted, (liquidityShifted / price).add(amount)));
      } else {
        uint256 product;
        require((product = amount * price) / amount == price); // if the product overflows, we know the denominator underflows
        require(liquidityShifted > product); // in addition, we must check that the denominator does not underflow
        return FullMath.mulDivRoundingUp(liquidityShifted, price, liquidityShifted - product).toUint160();
      }
    } else {
      // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
      // in both cases, avoid a mulDiv for most inputs
      if (fromInput) {
        return
          uint256(price)
            .add(amount <= type(uint160).max ? (amount << Constants.RESOLUTION) / liquidity : FullMath.mulDiv(amount, Constants.Q96, liquidity))
            .toUint160();
      } else {
        uint256 quotient = amount <= type(uint160).max
          ? FullMath.divRoundingUp(amount << Constants.RESOLUTION, liquidity)
          : FullMath.mulDivRoundingUp(amount, Constants.Q96, liquidity);

        require(price > quotient);
        return uint160(price - quotient); // always fits 160 bits
      }
    }
  }

  function getTokenADelta01(
    uint160 to,
    uint160 from,
    uint128 liquidity
  ) internal pure returns (uint256) {
    return TokenDeltaMath.getToken0Delta(to, from, liquidity, true);
  }

  function getTokenADelta10(
    uint160 to,
    uint160 from,
    uint128 liquidity
  ) internal pure returns (uint256) {
    return TokenDeltaMath.getToken1Delta(from, to, liquidity, true);
  }

  function getTokenBDelta01(
    uint160 to,
    uint160 from,
    uint128 liquidity
  ) internal pure returns (uint256) {
    return TokenDeltaMath.getToken1Delta(to, from, liquidity, false);
  }

  function getTokenBDelta10(
    uint160 to,
    uint160 from,
    uint128 liquidity
  ) internal pure returns (uint256) {
    return TokenDeltaMath.getToken0Delta(from, to, liquidity, false);
  }

  function calculatePriceImpactFee(
    int24 startTick,
    uint160 currentPrice,
    uint160 endPrice
  ) internal view returns (uint256 feeAmount) {
    int24 currentTick = TickMath.getTickAtSqrtRatio(currentPrice);
    int24 endTick = TickMath.getTickAtSqrtRatio(endPrice);

    uint160 currentPriceRounded = TickMath.getSqrtRatioAtTick(currentTick);
    uint160 endPriceRounded = TickMath.getSqrtRatioAtTick(endTick);

    if (endPriceRounded < endPrice) {
      uint160 endPriceRoundedUp = TickMath.getSqrtRatioAtTick(endTick + 1);
      uint160 subTick = (100 * (endPrice - endPriceRounded)) / (endPriceRoundedUp - endPriceRounded);
      if (subTick * (endPriceRoundedUp - endPriceRounded) < 100 * (endPrice - endPriceRounded)) {
        subTick += 1;
      }
      endTick = endTick * 100 + int24(subTick);
    } else endTick = endTick * 100;

    if (currentPriceRounded < currentPrice) {
      uint160 currentPriceRoundedUp = TickMath.getSqrtRatioAtTick(currentTick + 1);
      uint160 subTick = (100 * (currentPrice - currentPriceRounded)) / (currentPriceRoundedUp - currentPriceRounded);
      if (subTick * (currentPriceRoundedUp - currentPriceRounded) < 100 * (currentPrice - currentPriceRounded)) {
        subTick += 1;
      }
      currentTick = currentTick * 100 + int24(subTick);
    } else currentTick = currentTick * 100;

    startTick *= 100;

    if (currentPriceRounded == endPrice) return 0;

    if (endTick < currentTick) {
      int256 x = int256(currentPrice) *
        (startTick - endTick) -
        int256(endPrice) *
        (startTick - currentTick) -
        int256(200 * (currentPrice - endPrice) * Constants.Ln);
      feeAmount = FullMath.mulDivRoundingUp(Constants.K, uint256(x), 100 * (currentPrice - endPrice) * Constants.Ln);
    } else {
      int256 y = int256(endPrice) *
        (endTick - startTick) -
        int256(currentPrice) *
        (currentTick - startTick) -
        int256(200 * (endPrice - currentPrice) * Constants.Ln);
      feeAmount = FullMath.mulDivRoundingUp(Constants.K, uint256(y), 100 * (endPrice - currentPrice) * Constants.Ln);
    }

    if (feeAmount > 20000) feeAmount = 20000;
  }

  /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
  /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
  /// @param currentPrice The current Q64.96 sqrt price of the pool
  /// @param targetPrice The Q64.96 sqrt price that cannot be exceeded, from which the direction of the swap is inferred
  /// @param liquidity The usable liquidity
  /// @param amountAvailable How much input or output amount is remaining to be swapped in/out
  /// @param fee The fee taken from the input amount, expressed in hundredths of a bip
  /// @return resultPrice The Q64.96 sqrt price after swapping the amount in/out, not to exceed the price target
  /// @return input The amount to be swapped in, of either token0 or token1, based on the direction of the swap
  /// @return output The amount to be received, of either token0 or token1, based on the direction of the swap
  /// @return feeAmount The amount of input that will be taken as a fee
  function movePriceTowardsTarget(
    bool zeroToOne,
    uint160 currentPrice,
    uint160 targetPrice,
    uint128 liquidity,
    int256 amountAvailable,
    int24 startTick,
    uint16 fee
  )
    internal
    view
    returns (
      uint160 resultPrice,
      uint256 input,
      uint256 output,
      uint256 feeAmount
    )
  {
    function(uint160, uint160, uint128) pure returns (uint256) getAmountA = zeroToOne ? getTokenADelta01 : getTokenADelta10;
    if (amountAvailable >= 0) {
      // exactIn or not
      {
        uint256 amountAvailableAfterFee = FullMath.mulDiv(uint256(amountAvailable), 1e6 - fee, 1e6);
        input = getAmountA(targetPrice, currentPrice, liquidity);

        if (amountAvailableAfterFee >= input) {
          resultPrice = targetPrice;
          feeAmount = FullMath.mulDivRoundingUp(input, fee, 1e6 - fee);
        } else {
          resultPrice = getNewPriceAfterInput(zeroToOne, currentPrice, liquidity, amountAvailableAfterFee);
          if (targetPrice != resultPrice) {
            input = getAmountA(resultPrice, currentPrice, liquidity);

            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountAvailable) - input;
          } else {
            feeAmount = FullMath.mulDivRoundingUp(input, fee, 1e6 - fee);
          }
        }
      }

      output = (zeroToOne ? getTokenBDelta01 : getTokenBDelta10)(resultPrice, currentPrice, liquidity);

      uint256 priceImpactFee = calculatePriceImpactFee(startTick, currentPrice, resultPrice);
    } else {
      function(uint160, uint160, uint128) pure returns (uint256) getAmountB = zeroToOne ? getTokenBDelta01 : getTokenBDelta10;

      output = getAmountB(targetPrice, currentPrice, liquidity);
      amountAvailable = -amountAvailable;
      if (uint256(amountAvailable) >= output) resultPrice = targetPrice;
      else {
        resultPrice = getNewPriceAfterOutput(zeroToOne, currentPrice, liquidity, uint256(amountAvailable));

        if (targetPrice != resultPrice) {
          output = getAmountB(resultPrice, currentPrice, liquidity);
        }

        // cap the output amount to not exceed the remaining output amount
        if (output > uint256(amountAvailable)) {
          output = uint256(amountAvailable);
        }
      }

      input = getAmountA(resultPrice, currentPrice, liquidity);
      feeAmount = FullMath.mulDivRoundingUp(input, fee, 1e6 - fee);
      //feeAmount += calculatePriceImpactFee(startTick, currentPrice, resultPrice);
    }
  }
}

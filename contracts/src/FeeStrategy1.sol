// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title FeeStrategy1 - Dual Quadratic P Controller with Independent EMAs
/// @notice Two independent controllers for bid and ask fees with quadratic
///         correction: fee = BASE + KP1*err + KP2*err^2. The quadratic term
///         provides stronger protection at large deviations (arb events) while
///         being gentle at small deviations (retail noise).
contract Strategy is AMMStrategyBase {
    // ── Storage slot assignments ──────────────────────────────────────
    uint256 constant SLOT_EMA_XY = 0;  // EMA of reserveX/reserveY (WAD)
    uint256 constant SLOT_EMA_YX = 1;  // EMA of reserveY/reserveX (WAD)

    // ── Tunable parameters ────────────────────────────────────────────
    uint256 public constant BASE_FEE  = 29 * BPS;

    uint256 public constant KP1_BID   = 5080 * BPS;    // linear gain for bid
    uint256 public constant KP2_BID   = 57000 * BPS;   // quadratic gain for bid
    uint256 public constant ALPHA_BID = 260e14;         // EMA smoothing for bid (0.026)

    uint256 public constant KP1_ASK   = 5080 * BPS;    // linear gain for ask
    uint256 public constant KP2_ASK   = 65000 * BPS;   // quadratic gain for ask
    uint256 public constant ALPHA_ASK = 275e14;         // EMA smoothing for ask (0.0275)

    // ── Initialization ────────────────────────────────────────────────
    function afterInitialize(uint256 initialX, uint256 initialY)
        external override returns (uint256, uint256)
    {
        writeSlot(SLOT_EMA_XY, wdiv(initialX, initialY));
        writeSlot(SLOT_EMA_YX, wdiv(initialY, initialX));
        return (BASE_FEE, BASE_FEE);
    }

    // ── Fee update after every swap ───────────────────────────────────
    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256, uint256)
    {
        uint256 currentXY = wdiv(trade.reserveX, trade.reserveY);
        uint256 currentYX = wdiv(trade.reserveY, trade.reserveX);

        uint256 bidFee = _controller(currentXY, SLOT_EMA_XY, ALPHA_BID, KP1_BID, KP2_BID);
        uint256 askFee = _controller(currentYX, SLOT_EMA_YX, ALPHA_ASK, KP1_ASK, KP2_ASK);

        return (clampFee(bidFee), clampFee(askFee));
    }

    // ── Quadratic P controller ──────────────────────────────────────
    function _controller(
        uint256 current,
        uint256 slotEma,
        uint256 alpha,
        uint256 kp1,
        uint256 kp2
    ) internal returns (uint256) {
        uint256 ema = readSlot(slotEma);
        uint256 newEma = wmul(alpha, current) + wmul(WAD - alpha, ema);
        writeSlot(slotEma, newEma);

        // Normalized error = |ema - current| / ema (scale-invariant)
        uint256 errorAbs = newEma >= current
            ? newEma - current
            : current - newEma;
        uint256 normError = wdiv(errorAbs, newEma);

        // Quadratic correction: KP1*err + KP2*err^2
        uint256 correction = wmul(kp1, normError) + wmul(kp2, wmul(normError, normError));

        if (newEma >= current) {
            return BASE_FEE + correction;
        } else {
            return BASE_FEE > correction ? BASE_FEE - correction : 0;
        }
    }

    // ── Name ──────────────────────────────────────────────────────────
    function getName() external pure override returns (string memory) {
        return "FeeStrategy1";
    }
}

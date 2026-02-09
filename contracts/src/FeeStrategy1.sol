// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title FeeStrategy1 - Direction-Dependent Alpha Quadratic Controller
/// @notice Quadratic P-controller with asymmetric EMA update speed:
///         when price moves AWAY from EMA (arb), alpha is high (fast tracking);
///         when price moves TOWARD EMA (retail), alpha is low (stable reference).
///         Correction: fee = BASE + KP1*err + KP2*err^2.
contract Strategy is AMMStrategyBase {
    // ── Storage slot assignments ──────────────────────────────────────
    uint256 constant SLOT_EMA_XY  = 0;  // EMA of reserveX/reserveY (WAD)
    uint256 constant SLOT_EMA_YX  = 1;  // EMA of reserveY/reserveX (WAD)
    uint256 constant SLOT_PREV_XY = 2;  // Previous reserveX/reserveY
    uint256 constant SLOT_PREV_YX = 3;  // Previous reserveY/reserveX

    // ── Tunable parameters ────────────────────────────────────────────
    uint256 public constant BASE_FEE     = 30 * BPS;
    uint256 public constant KP1          = 5656 * BPS;    // linear gain
    uint256 public constant KP2          = 53806 * BPS;   // quadratic gain
    uint256 public constant ALPHA_TOWARD = 1045e12;       // 0.001045 - slow when reverting
    uint256 public constant ALPHA_AWAY   = 520e14;        // 0.052 - fast when deviating

    // ── Initialization ────────────────────────────────────────────────
    function afterInitialize(uint256 initialX, uint256 initialY)
        external override returns (uint256, uint256)
    {
        uint256 xy = wdiv(initialX, initialY);
        uint256 yx = wdiv(initialY, initialX);
        writeSlot(SLOT_EMA_XY, xy);
        writeSlot(SLOT_EMA_YX, yx);
        writeSlot(SLOT_PREV_XY, xy);
        writeSlot(SLOT_PREV_YX, yx);
        return (BASE_FEE, BASE_FEE);
    }

    // ── Fee update after every swap ───────────────────────────────────
    function afterSwap(TradeInfo calldata trade)
        external override returns (uint256, uint256)
    {
        uint256 currentXY = wdiv(trade.reserveX, trade.reserveY);
        uint256 currentYX = wdiv(trade.reserveY, trade.reserveX);

        uint256 bidFee = _controller(currentXY, SLOT_EMA_XY, SLOT_PREV_XY);
        uint256 askFee = _controller(currentYX, SLOT_EMA_YX, SLOT_PREV_YX);

        return (clampFee(bidFee), clampFee(askFee));
    }

    // ── Direction-dependent alpha quadratic controller ─────────────────
    function _controller(
        uint256 current,
        uint256 slotEma,
        uint256 slotPrev
    ) internal returns (uint256) {
        uint256 ema = readSlot(slotEma);
        uint256 prev = readSlot(slotPrev);
        writeSlot(slotPrev, current);

        // Direction detection: is price moving toward or away from EMA?
        uint256 prevDist = ema >= prev ? ema - prev : prev - ema;
        uint256 currDist = ema >= current ? ema - current : current - ema;
        uint256 alpha = currDist > prevDist ? ALPHA_AWAY : ALPHA_TOWARD;

        uint256 newEma = wmul(alpha, current) + wmul(WAD - alpha, ema);
        writeSlot(slotEma, newEma);

        // Normalized error = |ema - current| / ema (scale-invariant)
        uint256 errorAbs = newEma >= current
            ? newEma - current
            : current - newEma;
        uint256 normError = wdiv(errorAbs, newEma);

        // Quadratic correction: KP1*err + KP2*err^2
        uint256 correction = wmul(KP1, normError) + wmul(KP2, wmul(normError, normError));

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

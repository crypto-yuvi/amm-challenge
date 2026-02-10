// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title FeeStrategy1 - Dual-Alpha Size-Aware Quadratic Controller
/// @notice Quadratic P-controller with trade-size-based mode switching:
///         detects arb vs retail trades by amountY/reserveY ratio.
///         After arb (large trade): slow alpha-away (don't chase corrected price).
///         After retail (small trade): fast alpha-away (track new price quickly).
///         Correction: fee = BASE + KP1*err + KP2*err^2.
contract Strategy is AMMStrategyBase {
    // ── Storage slot assignments ──────────────────────────────────────
    uint256 constant SLOT_EMA_XY  = 0;  // EMA of reserveX/reserveY (WAD)
    uint256 constant SLOT_EMA_YX  = 1;  // EMA of reserveY/reserveX (WAD)
    uint256 constant SLOT_PREV_XY = 2;  // Previous reserveX/reserveY
    uint256 constant SLOT_PREV_YX = 3;  // Previous reserveY/reserveX

    // ── Tunable parameters ────────────────────────────────────────────
    uint256 public constant BASE_FEE     = 28 * BPS;
    uint256 public constant KP1          = 6535 * BPS;    // linear gain
    uint256 public constant KP2          = 34244 * BPS;   // quadratic gain
    // Arb mode (large trade detected): slow tracking
    uint256 public constant AT_ARB       = 1156e12;       // 0.001156
    uint256 public constant AA_ARB       = 119e14;        // 0.0119
    // Retail mode (small trade detected): fast tracking
    uint256 public constant AT_RET       = 1150e12;       // 0.001150
    uint256 public constant AA_RET       = 989e14;        // 0.0989
    // Size threshold: amountY/reserveY > THRESH => arb
    uint256 public constant THRESH       = 2705e12;       // 0.002705

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

        // Classify trade: large = arb (mode 1), small = retail (mode 0)
        uint256 sizeRatio = wdiv(trade.amountY, trade.reserveY);
        uint256 mode = sizeRatio > THRESH ? 1 : 0;

        uint256 bidFee = _controller(currentXY, SLOT_EMA_XY, SLOT_PREV_XY, mode);
        uint256 askFee = _controller(currentYX, SLOT_EMA_YX, SLOT_PREV_YX, mode);

        return (clampFee(bidFee), clampFee(askFee));
    }

    // ── Size-aware dual-alpha quadratic controller ────────────────────
    function _controller(
        uint256 current,
        uint256 slotEma,
        uint256 slotPrev,
        uint256 mode
    ) internal returns (uint256) {
        uint256 ema = readSlot(slotEma);
        uint256 prev = readSlot(slotPrev);
        writeSlot(slotPrev, current);

        // Direction detection: is price moving toward or away from EMA?
        uint256 prevDist = ema >= prev ? ema - prev : prev - ema;
        uint256 currDist = ema >= current ? ema - current : current - ema;

        // Select alpha based on mode (arb vs retail) and direction
        uint256 alpha;
        if (mode == 1) {
            alpha = currDist > prevDist ? AA_ARB : AT_ARB;
        } else {
            alpha = currDist > prevDist ? AA_RET : AT_RET;
        }

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

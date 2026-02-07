// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title FeeStrategy1 - Dual PI Controller Strategy
/// @notice Two separate PI controllers for bid and ask fees that steer reserves
///         back toward the initial ratio by adjusting fees dynamically.
contract Strategy is AMMStrategyBase {
    // ── Storage slot assignments ──────────────────────────────────────
    uint256 constant SLOT_TARGET_RATIO   = 0;  // reserveX/reserveY at init (WAD)
    uint256 constant SLOT_INTEGRAL_ABS   = 1;  // |accumulated error * dt|
    uint256 constant SLOT_INTEGRAL_SIGN  = 2;  // 0 = positive, 1 = negative
    uint256 constant SLOT_LAST_TIMESTAMP = 3;  // timestamp of previous trade

    // ── Tunable parameters ────────────────────────────────────────────
    uint256 public constant BASE_FEE = 30 * BPS;   // 30 bps baseline
    uint256 public constant KP       = 50 * BPS;   // proportional gain
    uint256 public constant KI       =  5 * BPS;   // integral gain

    // ── Initialization ────────────────────────────────────────────────
    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256, uint256)
    {
        writeSlot(SLOT_TARGET_RATIO, wdiv(initialX, initialY));
        writeSlot(SLOT_INTEGRAL_ABS, 0);
        writeSlot(SLOT_INTEGRAL_SIGN, 0);
        writeSlot(SLOT_LAST_TIMESTAMP, 0);
        return (BASE_FEE, BASE_FEE);
    }

    // ── Fee update after every swap ───────────────────────────────────
    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256, uint256)
    {
        uint256 targetRatio  = readSlot(SLOT_TARGET_RATIO);
        uint256 currentRatio = wdiv(trade.reserveX, trade.reserveY);

        // error = targetRatio − currentRatio  (signed)
        bool errorPositive = targetRatio >= currentRatio;
        uint256 errorAbs   = errorPositive
            ? targetRatio - currentRatio
            : currentRatio - targetRatio;

        // dt = steps since last trade
        uint256 lastTs = readSlot(SLOT_LAST_TIMESTAMP);
        uint256 dt     = trade.timestamp - lastTs;
        writeSlot(SLOT_LAST_TIMESTAMP, trade.timestamp);

        // Update integral: integral += error * dt  (signed addition)
        uint256 integralAbs      = readSlot(SLOT_INTEGRAL_ABS);
        bool    integralPositive = readSlot(SLOT_INTEGRAL_SIGN) == 0;
        uint256 deltaIntegral    = errorAbs * dt;

        if (errorPositive == integralPositive) {
            integralAbs = integralAbs + deltaIntegral;
        } else if (deltaIntegral >= integralAbs) {
            integralAbs      = deltaIntegral - integralAbs;
            integralPositive = errorPositive;
        } else {
            integralAbs = integralAbs - deltaIntegral;
        }

        writeSlot(SLOT_INTEGRAL_ABS, integralAbs);
        writeSlot(SLOT_INTEGRAL_SIGN, integralPositive ? 0 : 1);

        // P + I correction (magnitude)
        uint256 pTerm      = wmul(KP, errorAbs);
        uint256 iTerm      = wmul(KI, integralAbs);
        uint256 correction = pTerm + iTerm;

        // Apply correction with opposite signs to bid vs ask:
        //   error > 0  →  ratio below target  →  decrease bid, increase ask
        //     (cheapen buying X into AMM, make selling X from AMM pricier)
        //   error < 0  →  ratio above target  →  increase bid, decrease ask
        //     (discourage selling X to AMM, cheapen buying X from AMM)
        uint256 bidFee;
        uint256 askFee;

        if (errorPositive) {
            bidFee = BASE_FEE > correction ? BASE_FEE - correction : 0;
            askFee = BASE_FEE + correction;
        } else {
            bidFee = BASE_FEE + correction;
            askFee = BASE_FEE > correction ? BASE_FEE - correction : 0;
        }

        return (clampFee(bidFee), clampFee(askFee));
    }

    // ── Name ──────────────────────────────────────────────────────────
    function getName() external pure override returns (string memory) {
        return "FeeStrategy1";
    }
}

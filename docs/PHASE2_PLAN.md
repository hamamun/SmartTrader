# SmartTrader — Phase 2 Plan: Auto-Trading

Phase 1 (this release) already produces everything a human decides before clicking "Buy":
a **validated setup** with **entry, SL, TP1, TP2, expected duration and expiry**.
Phase 2 turns that decision into an order — nothing in the analysis changes.

## 1. Execution model

When a setup reaches `VALIDATED` and auto-trading is enabled:

1. **One position per forecast** — while a forecast is ACTIVE, no new position on the symbol.
2. **Market order** in the forecast direction at the open of the bar after the signal.
3. **SL / TP1** attached to the order (broker-side, survives terminal restart).
4. **Lot size from risk** (the human "position sizing" step):

```
riskMoney      = Balance * RiskPercent / 100          (or fixed money)
slPoints       = |entry - SL| / Point
lotValuePerPt  = tick value per 1.0 lot per point     (SymbolInfoDouble)
rawLot         = riskMoney / (slPoints * lotValuePerPt)
lot            = clamp(rawLot, minLot, maxLot) rounded to lot step
```

5. **Trade management** (inputs on/off):
   - move SL to breakeven when price reaches TP1 distance;
   - optional close-half-at-TP1, let the rest run to TP2;
   - optional ATR trailing stop;
   - time-based exit when the signal expires without hitting levels.

## 2. Safety rails (all configurable)

- Max risk per trade (%), max daily loss, max positions per day
- Trading session filter (e.g. only 08:00–20:00 server time)
- Spread filter (skip entries when spread > X points)
- Magic number + comment `SmartTrader` for clean identification
- Global master switch `InpAutoTradeEnabled` (default **false**) — Phase 2 ships
  with trading OFF, exactly like a human's "practice mode"

## 3. Open questions for you (needed before Phase 2 is coded)

| # | Question | Default proposal |
|---|----------|------------------|
| 1 | Symbols you trade? (single-symbol EA per chart, or one EA scanning several) | single chart symbol |
| 2 | Risk per trade? | 1% of balance |
| 3 | Close half at TP1 and trail the rest, or full close at TP1? | half at TP1 |
| 4 | Which account type: netting or hedging? | either handled |
| 5 | Min win-rate from the history check below which the EA skips trading the setup? | 45% with ≥ 10 samples |

## 4. Notes

- The Phase 1 history replay ("what past history says") is the backbone of the
  Phase 2 quality filter — setups with poor historical win-rate are watched, not traded.
- All Phase 1 panel/alerts stay exactly the same; a `TRADE` section is added to the panel.

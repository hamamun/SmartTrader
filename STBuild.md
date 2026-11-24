# STBuild.md — SmartTrader build log & living spec

One page on purpose: short notes of what each approved step must implement later.
Rule: no step is built until the user approves it here. Each step = few words, not essays.

---

## Ground rules (agreed)

- Target: an automated bot that trades on behalf of the user — maximum
  successful direction/projection/trade, built simple: few items, accurate, sophisticated.
- Timeframes: M5 and M15 only. Closed candles only, never repaint.
- Each timeframe is read on its own nature (M5 not slaved to M15).
- Safety rails exist but must never block a valid projection; user can override.
- Two trade modes: SCALP (M5, short horizon) and INTRADAY (M15, ~1–1.5 hour horizon —
  choppy market changes the story fast, so not the whole day).

## Build steps tracker

- [x] Step 1 — Trend definition (approved)
- [ ] Step 2 — Reversal candle worth watching (proposal next)
- [ ] Step 3 — Signal validation checklist (few tools, few checks)
- [ ] Step 4 — Forecast: entry / SL / TP / horizon (natural targets)
- [ ] Step 5 — History exam (replay approved rules, honest stats)
- [ ] Step 6 — Proof stage (true vs false reversal before acting)
- [ ] Step 7 — Demo forward test (scoreboard)
- [ ] Step 8 — Autotrading (Phase 2: risk lots, order management, overridable rails)

---

## Step 1 — TREND (approved)

The bot reads trend like human eyes, then confirms with tools:

- **Eyes = price structure itself.** Mark swing highs/lows from raw price
  (zig-zag). Sequence decides: HH+HL = UP, LH+LL = DOWN, overlapping = SIDEWAYS.
  Also measure pullback depth (trend health) and trend age (young/old).
- **Tools = confirmation only, never the boss:**
  - EMA 20 + EMA 50 — slope, order, price side
  - Choppiness Index — trend vs box regime (>61.8 box / <38.2 trend)
  - ATR 14 — the ruler; makes swing thresholds, stops, targets, horizons
    symbol-adaptive (same brain on gold and EURUSD)
- **Verdict output:** direction + confidence + age + health
  (e.g. "UP, strong, young" / "UP, weakening, old — pullbacks deepening").
- Momentum oscillators (RSI/MACD/Stochastic…) are NOT trend tools — they may
  appear later only in signal validation, reduced list.

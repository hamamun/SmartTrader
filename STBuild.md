# STBuild.md — SmartTrader build log & living spec

One page on purpose: short notes of what each approved step must implement later.
Rule: no step is built until the user approves it here. Each step = few words, not essays.

---

## FUNDAMENTALS (fixed by user — every step must respect these)

- **F1. Timeframe guard:** M5 / M15 only. Any other chart → message
  "out of range — return to M5/M15", EA does not run.
- **F2. One instance, two horizons:** attached to either M5 or M15, the EA
  computes and forecasts BOTH timeframes (its own chart TF + the other one).
  Two independent reads, each on its own nature.
- **F3. Market state first — before anything:** on every check the EA determines
  OPEN / CLOSED / HOLD (broker maintenance, trade disabled).
  - OPEN → full forecast work
  - CLOSED → "market closed — opens <day date time> MT5 server time" (server
    time shown, never local PC time); no forecasting
  - HOLD (session break / trade disabled) → shown, no forecasting
- **F4. Symbol type classification:** currency (forex), metals (gold/silver),
  energy (oil), indices, crypto, etc. Each type has different trade statistics,
  sessions and behavior.
- **F5. Auto-parameters per symbol type:** all internal parameters are defined
  automatically from the symbol type profile — expert-tuned, no user tuning.
  Rule: every parameter value must come from (a) market convention, (b) the
  symbol-type statistics, or (c) evidence from the Step 5 history exam —
  never arbitrary. Indicator periods themselves (EMA 20/50, ATR 14, CHOP
  61.8/38.2) stay standard/universal; the type profiles vary the calibrations
  and weights around them, not the tools.

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
- [x] Fundamentals F1–F5 (approved)
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

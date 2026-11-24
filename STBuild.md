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
- [x] Step 2 — The map of levels (approved)
- [ ] Step 3 — Candle setups at locations (proposal next)
- [ ] Step 4 — Signal validation checklist (few tools, few checks)
- [ ] Step 5 — Forecast: entry / SL / TP / horizon (natural targets)
- [ ] Step 6 — History exam (replay approved rules, honest stats)
- [ ] Step 7 — Proof stage (true vs false reversal before acting)
- [ ] Step 8 — Demo forward test (scoreboard)
- [ ] Step 9 — Autotrading (Phase 2: risk lots, order management, overridable rails)

---

## Step 2 — THE PRECISION MAP (approved, final)

The trader's pencil work in the bot's own working area (panel table, NOT chart
lines). Levels = prices where the market has memory; fights happen there.

**Process:**
1. Level sources (5): swing highs/lows (Step 1 structure), trend lifeline
   (last HL/LH), session extremes (day high/low + Asian range for forex),
   round numbers (grid per symbol type), Fibonacci pause-zones (38.2/50/61.8%
   of last completed leg — measured with structure, never naked).
2. Levels become thin ZONES, thickness scaled by ATR per symbol type.
3. Strength = touches x drama x recency + stack-bonus per independent reason
   (fib overlap, heavy volume node, round number, VWAP touch). Confluence rule:
   a naked level is a coin flip; stacked = setup.
4. Volume-at-price grade per zone (tick volume): fought-over = strong,
   thin = dropped.
5. VWAP session line: intraday control read + confluence reason.
6. IF/THEN plan per zone (bounce-watch / break-watch / lifeline test) decided
   BEFORE price arrives — pre-commitment, no in-the-moment decisions.
7. Risk geometry per zone: "where am I wrong" = just beyond the zone;
   stop skeleton known in advance.
8. Refresh every closed bar: new fights add zones, weak fade, broken zones
   flip role (old resistance -> expected support), fibs re-anchor to newest leg.

**Outcomes:**
- Panel map table: strongest 3-6 zones (price, type, strength, stack reasons,
  IF/THEN expectation).
- Price location classified: at zone / between zones / at lifeline.
  LOCATION IS THE PRIMARY GATE - no candle judged mid-air.
- Risk skeleton per zone, ready before any setup (feeds forecast/SL, Phase 2
  lot sizing).
- The prediction part done in advance: IF/THEN branches ARE the forecast;
  arriving candles only select which branch executes.
- Living map - refreshed continuously like the professional watches.

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

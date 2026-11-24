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

## Step 2 — THE MAP (approved)

After trend, the trader draws the map; SmartTrader draws it in its own
working area (panel table), NOT as chart lines.

- **Levels (keep only strongest 3–6, ranked):** recent swing highs/lows,
  trend lifeline (last HL in up-trend / LH in down-trend), session extremes
  (day high/low; Asian range for forex), round numbers (grid per symbol type).
- **Strength score** = touches × drama of the fight × recency; map refreshes
  every closed bar (new fights add strength, old weak levels fade).
- **Price location classified vs map:** at a level / between levels / at lifeline.
- **Location is a PRIMARY GATE:** candles are only judged AT a location —
  pattern without location = noise.
- **What the map GIVES / what the bot does with it (the human's results):**
  1. waiting list — no action between levels (patience is a plan)
  2. IF/THEN pre-commitment per level: bounce-watch or break-watch decided
     BEFORE price arrives (no in-the-moment decisions)
  3. risk geometry: the level defines "where am I wrong" (just beyond it) —
     stop skeleton known before any candle/setup appears
  4. behavior read at arrival: violent rejection = defenders won (bounce
     scenario); slow grind + close beyond = defenders lost (break scenario);
     two-sided wicks = stand aside
  5. flip rule: broken level reverses role (old resistance becomes expected
     support and vice versa); map updater applies this automatically

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

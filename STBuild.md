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
- [x] Step 2 — The precision map (approved, final)
- [x] Step 3 — The verdict: scenario-tree forecast (approved)
- [x] Step 4 — Branch execution: detect, re-validate, declare (approved)
- [x] Mi1 UI contract (approved)
- [x] BUILD: Mi1 v2.00 implemented (SmartTrader.mq5) - pending user verification in MT5
- [x] Mi2 Part 1 — Autotrading ORDER PLACEMENT (approved, section below)
- [ ] Mi2 Part 2 — Order follow-up / close / exit, open + limit orders (design next)
- [ ] BUILD: Mi2 autotrading (after Part 2 approved; brain untouched, hands added)
- [ ] Step 5 — History exam (replay approved rules, honest stats; must also report
      how autotrading functioned) — done AFTER autotrading per user re-ordering
- [ ] Step 6 — Demo forward test (scoreboard)

---

## Mi2 Part 1 — AUTOTRADING: ORDER PLACEMENT (approved)

The hands: a TRANSLATOR, never a thinker. It follows the declaration exactly
(latest living values at order time); zero new calculations, no new decisions.
The brain (Mi1) is untouched - declarations stay forecasts; the hands also act
on them when the switch is on.

**Inputs (UI contract amendment: exactly 5 now):**
- Risk % per trade (1.0), popup alert (true), ShowDetails (false) - unchanged
- **Autotrading (default FALSE)** - the master switch; default-off is the
  real-account guard (user decision, replaces any confirm dialog)
- **Autotrading mode** - BOTH / only-M5 / only-M15 (user tool against
  opposite M5/M15 plans)
- Status line ALWAYS shows the mode in gold: "AUTOTRADING OFF - forecast
  only" / "AUTOTRADING ON (both TFs)" etc.

**Placement rules:**
1. Orders only while market state OPEN (F3) and only on the TFs the mode allows.
2. Identity: every bot order/position carries a magic-number tag. Manual user
   positions are invisible to the bot - never counted, touched, or closed.
3. Entry following (user's rule, BUY example, plan entry = 5):
   - price still at/better than entry (bid/ask straddles 5) → resting order AT
     the entry price (named limit or stop per side, whichever the broker
     demands; fills naturally at the planned price)
   - fast market crossed past the entry within the plan's BIRTH BAR and the
     gap entry→current ask/bid is <= 25% of the entry→stop distance →
     MARKET order at current price ("don't lose the bar's trade")
   - crossed past beyond 25% → resting order at entry anyway (never deep chase)
   - chase window = birth bar only
4. Protection from birth: every order carries its SL + TP attached from the
   first millisecond (broker-side lines survive disconnect/terminal death).
5. Lot: the 1%-risk formula at the REAL fill price - a chase fill takes a
   smaller lot, money risk stays exactly the budget.
6. Limits: one position per timeframe, max two total; margin/volume pre-flight
   checks; any failure = no order, event logged, forecast stays forecast.
7. Resting-order lifetime + all cancellation = Part 2 (exit design), pending.

**Parked to Mi2 Part 2 (design discussion next, before build):**
- when a resting order is cancelled (order dies with its declaration)
- follow-up/exit of OPEN positions: partial at +1R, BE stop, living TP
  modifications, time-stop, closed-early, supersede handover
- late-fill handover to the caretaker (edge 2)
- netting vs hedging account detection
- terminal-restart recovery (plan persisted to disk, reconcile tagged positions)
- user-interference handling (position closed/changed by hand → step away)

---

## Mi2 Part 2 — AUTOTRADING: FOLLOW-UP (approved items)

The bridge between brain and real orders: the real position/order always
mirrors what the living plan says. SL may only move in the SAFE direction
(BE after +1R, never backward to widen risk); TP may move both ways.

**a. Open (placed) position:**
1. Magic-number tracking survives restarts: positions/orders live at the
   broker; only the brain's memory dies. Active plans persist to a small
   disk file; on startup the bot matches tagged positions to saved plans and
   resumes caretaking where it left off.
2. Brain↔order bridge: trend weakens after several bars while price is away
   from TP → position TP modified to the tightened destination (broker-side
   line follows the living plan).
3. Reversible: strength returns → TP extended further, same bridge.

**b. Resting (limit/stop at entry) order:**
1. Stays alive and follows the brain's status - TP/SL/lot updated to the
   plan's latest values (if the broker refuses a modification: retry on
   later candles, log the refusal, the order is never left without its SL).
2. LIFETIME (user confirmed): the resting order lives exactly as long as its
   declaration lives. The moment the plan ends (timed out / superseded /
   closed early / any of the six endings), the order is cancelled the same
   second - no fills into dead stories.

**Safety rules (user agreed):**
- One captain per ship: if the USER closes a bot position or moves its
  SL/TP by hand, the bot logs "manual override", steps aside, and only
  watches - never reopens, never fights. (Ground rule: user can override.)
- Netting vs hedging: account type detected at startup. Hedging (user's
  broker) → normal operation, two TF positions may coexist. Netting → max
  ONE bot position on the symbol; while one exists, any new order (either
  direction) is skipped with a logged event - the hands never merge or
  implicitly close.
- Broker-rejection discipline: every placement/modification checked;
  refusals retried, then logged as events - never silent, never half-done.
- Late-fill handover: a filled resting order becomes a tracked position at
  the fill instant - full caretaking from birth (SL/TP already on the order).

**Parked to Mi2 Part 3 (closing factors - next discussion):**
- the six plan endings as real actions (partial close at +1R, BE move,
  time-stop market close, closed-early market close, supersede close,
  SL/TP endings noticed + recorded)
**Parked (separate discussion):**
- autotrading panel section (mode, per-TF state, real SL/TP, P/L in R)

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

## Step 3 — THE VERDICT (scenario-tree forecast, approved)

After trend + map, on every closed bar the bot formulates the working verdict -
the human's example: "price 1.5, trend up, drawing says next ~4 bars up to 2.5;
if it reverses there -> down to 1; if it keeps going -> 4; other outcomes ->
more IF/THEN branches."

Rules of the verdict:
1. NOT one prediction - a SCENARIO TREE ranked by probability:
   base case / alternate case(s) / stall-timeout branch. Max 3-4 live branches.
2. Every number is SOURCED, never guessed:
   - targets = map zones + fib extensions of the leg (2.5, 4.0)
   - reversal destination = lower zone / lifeline (1.0)
   - time = ATR-based speed ("~4 bars" to target)
   - invalidation per branch = beyond that zone's risk line
3. Every branch is time-boxed: if the deadline passes without the move,
   the branch dies and the tree is rebuilt.
4. Branch selectors: the map's IF/THEN tripwires (zone tests + candle events,
   Step 4) decide which branch becomes reality - the bot keeps watching.
5. The tree refreshes every closed bar - the verdict is a living document.
6. Panel shows the tree: base/alt/stall, each with target, time window and
   invalidation price; the panel highlights which branch price is tracking.
7. NOTE (user): example numbers (1.5 / 2.5 / 4 / 1) were ILLUSTRATIVE ONLY -
   nothing is hardcoded. All values are computed dynamically from the map,
   zones, fibs, ATR speed and symbol-type stats. The tree may hold many
   computed IF/THEN branches; only the top-ranked few stay live/displayed
   (a management discipline, not a numeric limit).
8. Coverage guarantee: up-branches + down-branches + the stall/timeout branch
   together cover ALL outcomes - the market always meets some branch (by
   design, since the tree is rebuilt every closed bar).

---

## Step 4 — BRANCH EXECUTION (approved)

Role: precise WITNESS, not fortune-teller. Step 3 did the heavy work; Step 4
detects which branch the market is making true, verifies, declares.

1. Watch only at live branches' selector zones (no zone = no watch).
2. Detect the selector: the 4 candle events at zones (rejection / dominance
   flip / decisive break / false break) + zone tests decide WHICH branch is
   coming true.
3. Re-validate ("pencil -> ink"): before declaring, re-check the branch's
   Step-3 numbers against the CURRENT refreshed map/tree (zones fade/move,
   ATR regime shifts). Stale -> recompute or demote; never execute stale
   numbers.
4. Declare the order plan from the branch: entry (trigger confirmation),
   SL (zone risk line), TP(s) (branch targets), suggested lot size
   (risk budget / stop distance), expected duration (branch time window),
   management rules (breakeven point, partial-exit level, time-stop).
5. Arriving behavior matches no valid selector -> nothing declared (noise
   filter); timeout branch eventually consumes the scenario, tree rebuilds.
6. Output: declaration panel/alert (branch name, entry/SL/TP/lot/duration,
   management). Placing REAL orders stays Phase 2 (Step 7).

**AMENDMENT (approved after Mi1 live observation, 2025-11):** the user watched
4 hours of live BTCUSDm M5: direction followed, but price kept reversing before
the fixed TP1 — "the TP fixation process is not correct." Redesigned:

- **ONE target only.** TP2 removed entirely. A declaration carries a single TP.
- **Initial target = the NATURAL DESTINATION, planned like a human.** At
  planning the trader states not just the direction but the PORTION the move
  should travel - where it naturally ends: fading/reversing the last leg aims
  at its far end (full retrace = the opposite edge of the range); riding the
  last leg aims at its 1.272 extension (the measured portion the structure
  promises). Fallback when no leg is on the map: nearest minor swing shelf
  (>= 0.8R trending / >= 0.6R choppy, >= 0.2 ATR beyond entry) - never an
  invented price. The destination must still pay for the risk (the minR
  floor) and fit on the road: capped just before the next map zone (any
  strength); if the floor does not fit before that zone, the setup is PASSED
  - "not every setup deserves a trade."
- **The target is LIVING.** After declaration the bot does what the human
  described — keeps checking every closed candle: if the move is still healthy,
  the TP is extended to the next natural pause; if the candles start
  disagreeing, the TP is tightened to the nearest shelf (take what the market
  gives). Health = closing-direction body + retrace giveback (≥50% warning,
  ≥61.8% red) + higher-TF regime against the idea. Every move is logged in the
  event line and the panel shows "(updated Nx by candles)".
- **Management:** partial at +1R (half banked), stop to breakeven, remainder
  rides the living TP.
- **Tighten safety (bugfix after live test):** a tightened target may NEVER
  cross back through the entry (a BUY's TP stays above entry, a SELL's below).
  Tighten only arms once the move has >= 0.5R of substance (before that the SL
  protects and early jitter must not chase the target). If no natural pause
  remains past the entry, the move has failed -> the declaration closes early
  with an honest "closed early" outcome instead of aiming at an impossible
  target. Stopped-at-breakeven is reported as such in memory, not as an
  invalidation.

---

## Mi1 UI CONTRACT (approved)

Milestone Mi1 = Steps 1-4 (the brain). Panel + inputs are part of Mi1.

**MAIN PANEL** (always; sections in this order):
1. STATUS - symbol + type (forex/metals/energy/index/crypto), market state
   OPEN / CLOSED (opens XX:XX server time) / HOLD, spread, bar countdown.
   When market closed: only this section lives, all analysis frozen.
2. TREND READ - one line per timeframe, BOTH always shown (own nature each):
   direction + confidence + age + health (e.g. "M5: UP strong young -
   pullback shallow").
3. (nothing - map lives in details panel)
4. (nothing - verdict lives in details panel)
5. DECLARATION - when a branch executes: entry / SL / TP(s) / suggested lot /
   expected duration / management rules; below: short memory list of recent
   declarations and their outcomes (target hit / invalidated / timed out).
6. EVENT LINE - rolling one-line log of what just happened ("zone B tested -
   rejection", "alt branch died (timeout), tree rebuilt").

**DETAILS PANEL** - secondary, input ShowDetails default FALSE:
- false: engine still computes map/verdict every bar (declarations stay
  valid), but panel does not paint them
- true: renders RIGHT OF the main panel - full zone table (price, type, strength,
  stack reasons, IF/THEN expectation), full branch tree (target, time window,
  invalidation, which branch price is tracking), expanded declaration history
- own summary line on main panel even when hidden (pending user OK):
  "map: 4 zones - verdict: base UP->X (N bars) - tracking: base"
- styling: font hardcoded 10, main panel top-left corner hardcoded; DETAILS
  panel appears IMMEDIATELY RIGHT OF THE MAIN PANEL (x = main panel right
  edge + gap, same top line) - NOT at the chart's right corner (would hide
  candles there). Positioned relative to the main panel so it follows it
  as the main panel width grows with autotrading later; details panel width
  capped so the pair never covers most of the chart; same color language
  (green up / red down / gold attention / gray neutral)

**INPUTS - exactly 3, no others:**
- Risk % per trade (default 1.0) - feeds suggested lot size
- Popup alert (default true) - also everything logged to Experts journal
- ShowDetails (default false) - secondary panel toggle (right side of main panel)
Font size = hardcoded 10. Main panel corner = hardcoded top-left. Push/e-mail
alerts dropped for Mi1.

**EVENT CATALOG (what the event line / journal / popup can say):**

Popup + journal + event line (attention events):
1. "DECLARED BUY/SELL [TF] <branch> - <selector event> at zone ..." - a plan
   is born: full entry/SL/TP/lot/duration/time-stop attached.
2. "declaration target hit" - the destination was reached.
3. "declaration invalidated" - the stop line was hit before earning anything.
4. "declaration stopped at breakeven - half was banked" - earned +1R first,
   then came back to entry; scratch exit, half the position booked at +1R.
5. "declaration timed out (time-stop)" - the plan's clock ran out; setup had
   its chance.
6. "declaration closed early - move failed (no pause past entry)" - the
   candles turned against the idea and no honest target remained.
7. "[TF] TP tightened to X (weakening)" - the living target pulled closer.
8. "[TF] TP extended to X (move healthy)" - the living target pushed further.
9. "selector rejected: stop tighter than 2x spread" - a setup was seen but
   the road is too thin to pay spreads.
10. "selector rejected: lot could not be computed" - broker reference data
    missing/broken (rare).

Journal + event line only (calm events - no popup):
11. "[TF] +1R reached - half banked, stop to breakeven"
12. "[TF] selector passed: no room to the next zone (N pts) - not every setup
    deserves a trade"
13. "[TF] old plan superseded - a new selector took over"

Memory-line endings (one word per retired plan): target hit / invalidated /
timed out / superseded / closed early / stopped at BE.

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

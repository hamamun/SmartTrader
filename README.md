# SmartTrader

A human-style trading assistant for **MetaTrader 5 (PC terminal)**, written in **MQL5**.
It works the way a person sits at the chart: reads the candles, reads the trend, waits
for a reversal candle that confirms, validates the idea with indicators, then forecasts
entry, stop loss, take profit, how long the move may last — and only then acts.

Built phase by phase:

| Phase | Scope | Status |
|-------|-------|--------|
| **1** | Market watch & forecast — reads candles/trend, validates signals, publishes forecast + history win-rate on the chart. **No orders.** | ✅ `SmartTrader.mq5` |
| **2** | Auto-trading — converts a validated forecast into a real order (lot size from risk, SL/TP, trade management). | planned, see `docs/PHASE2_PLAN.md` |

**Hard rule (as requested): SmartTrader only runs on M5 and M15 charts.**
Attaching it to any other timeframe refuses to start with a clear alert.

---

## 1. Installation (MT5 PC terminal)

1. Open MT5 → `File` → `Open Data Folder` → `MQL5` → `Experts`.
2. Copy `SmartTrader.mq5` there.
3. Open MetaEditor (F4 in MT5), open the file, press **F7 (Compile)** — it must report
   `0 errors`.
4. Back in MT5: open an **M5 or M15** chart of any symbol, drag *SmartTrader* from the
   Navigator (Expert Advisors) onto the chart.
5. In the dialog, allow **"Allow modification of Signal settings"** is NOT needed —
   Phase 1 never trades, so *"Algo Trading"* can stay OFF. Approve the inputs and press OK.
6. The SmartTrader panel appears in the top-left corner of the chart.

To receive push alerts: MT5 → `Tools → Options → Notifications` → enable and set your
MetaQuotes ID, then set `InpAlertPush = true` in the EA inputs.

---

## 2. How it mirrors a human trader — the 3-stage pipeline

A human does not shout "SELL!" the second a reversal candle closes. He **detects**,
then **proves**, then **projects** — SmartTrader now works in the same three stages:

| Stage | What a human does | What SmartTrader does |
|---|---|---|
| **1. DETECT** | Watches every completed candle, knows what candles mean, reads the trend, spots a reversal in context, double-checks with indicator tools | Detects **19 patterns** (§3) on the **last closed** M5/M15 candle, reads trend (EMA + swing structure + ADX), runs the **7-point validation checklist** (§4) with self-adapting thresholds |
| **2. PROVE** | "Is this reversal true or false?" — he *waits*, watching the next few bars: does price break the pattern high (true) or collapse back below the low (fake)? | A validated setup opens a **CANDIDATE** with a **proof window** (3 bars): `close beyond the pattern extreme` → **proved**; `close beyond the opposite extreme` → **FALSE reversal**, killed; nothing within the window → expired. The panel shows both trigger prices live |
| **3. PROJECT** | Once proven, he looks **forward**: measuring the prior leg, he works out how far price may go over the next N bars, and only then acts | Only a **PROVED** idea issues a forecast: entry at the proof-bar close, SL behind structure, **TP1/TP2 = measured-move retracement of the prior leg (38.2% / 61.8%) with 1R/2R floors**, expected bars to TP1 from **net directional speed**, a **horizon** end time, and a live **schedule check** (`on track / behind`) comparing real progress vs the projected path |
| Watching & learning | Glances at what history says; tracks his call to the end | Past-500-bar replay of the same setup (win-rate), live forecast tracked to `TP1 OK / TP2 OK / SL X / expired`, session scoreboard. Orders: *(Phase 2)* |

---

## 3. The candles SmartTrader watches (and how)

Every **closed** candle is measured: body, range, upper wick, lower wick, and compared
against the 20-bar average body and current ATR. Detection is geometric + contextual:

| Pattern | Read | Strength |
|---|---|---|
| Morning Star / Evening Star | reversal | 3/3 |
| Three White Soldiers / Three Black Crows | momentum continuation | 3/3 |
| Bullish / Bearish Engulfing | reversal | 3/3 |
| Piercing Line / Dark Cloud Cover | reversal | 2/3 |
| Tweezer Bottom / Tweezer Top | reversal at double top/bottom | 2/3 |
| Hammer / Shooting Star | reversal (long wick rejection) | 2/3 |
| Dragonfly Doji / Gravestone Doji | reversal (rejection with no body) | 2/3 |
| Bullish / Bearish Marubozu | momentum continuation | 2/3 |
| Bullish / Bearish Harami (inside bar) | pause → possible reversal | 1/3 |
| Doji | neutral — displayed, never traded | – |

The **trend decides the meaning**: a hammer in a downtrend is a *reversal* setup, a
bullish engulfing inside an uptrend pullback is a *continuation* setup. Against a
**strong** trend, the signal needs extra validation score.

---

## 4. The indicator tools used to validate a forecast

Each validated candidate goes through a checklist; every passed item adds 1 point (max 7).
Defaults: **score ≥ 4 → VALIDATED** (forecast + alert), **3 → WATCHLIST**, else ignored.

| Check | Buy setup wants | Sell setup wants |
|---|---|---|
| **RSI(14)** zone | reversal: below its dynamic oversold percentile · continuation: above its median | reversal: above dynamic overbought percentile · continuation: below median |
| **RSI divergence** (reversals) | price lower low, RSI higher low | price higher high, RSI lower high |
| **QQE** (modern momentum) | fresh cross up of smoothed RSI over its adaptive trailing band (reversal) · smoothed RSI up & rising (continuation) | fresh cross down (reversal) · down & falling (continuation) |
| **Ehlers Fisher Transform** | crossing up from the lower half (reversal) · above zero & rising (continuation) | crossing down from upper half (reversal) · below zero & falling (continuation) |
| **Tick volume (relative)** | ≥ the symbol's own "real interest" percentile of its 20-bar average | same |
| **Bollinger(20,2) rejection** (reversals) | pierced lower band, closed back inside | pierced upper band, closed back inside |
| **Location** (reversals) | at swing low / 20-bar low | at swing high / 20-bar high |

Continuation setups swap the last check for **ADX ≥ its dynamic trend level**.

All thresholds are self-adapting (the dynamic layer re-learns them from the symbol's
own history, §4.1) — nothing for the trader to calibrate. The trading style (§6.1)
sets the overall strictness.

### 4.2 Modern engine — what replaced the classics and why

An honest research note: studies comparing indicator families find **no indicator
systematically beats the market**, and classics like MACD/RSI remain competitive —
the real edge is *context, filtering and adaptive thresholds*, not indicator novelty.
So SmartTrader keeps the classics that are still best-practice **structure and
statistics tools** (RSI + divergence, Bollinger rejection, swing location, relative
volume), and swaps/adds the modern tools that measurably do the same job better:

| Classic (removed) | Modern replacement | Why it's better |
|---|---|---|
| Stochastic(14,3,3) fixed-level cross | **QQE** — EMA-smoothed RSI inside Wilder trailing bands (factor 4.236 = φ²) | the crossover level adapts to RSI *volatility*, killing most whipsaw crosses a fixed-level Stochastic produces |
| MACD(12,26,9) histogram direction | **Ehlers Fisher Transform** | normalizes price into a sharp near-Gaussian oscillator — turns at extremes are much earlier and sharper than MACD histogram drift; needs a trend filter, which SmartTrader already is |
| (nothing — new context tool) | **Choppiness Index** (>61.8 range, <38.2 trend) | a cleaner regime dial than raw ADX thresholds; drives the breakout rule |
| (nothing — new context tool) | **TTM Squeeze** (Bollinger inside Keltner, fires on release) | detects compression→expansion; a squeeze release *exempts* a breakout from the choppy-market penalty |

The panel shows `CHOP` and the squeeze state live, and every check prints the limit
it used. Old-school purists can see exactly what changed: Stochastic and MACD are
gone; everything else was kept deliberately.

### 4.1 Smart dynamic thresholds (default: ON)

Fixed numbers like "RSI oversold = 35" cannot fit every symbol and every market phase.
Gold on M5 and EURUSD on M5 have different RSI distributions — and the *same* symbol
behaves differently in a trend, a range, or a volatility burst. So SmartTrader
**re-learns its limits from each chart symbol's own recent behavior** on every closed bar:

| Check | Static (fallback) | Dynamic behavior |
|---|---|---|
| RSI zones | fixed 35 / 65 | oversold / overbought = the **15th / 85th percentile of the symbol's own RSI** over the last 300 bars → a trending symbol automatically gets stricter zones, a ranging one looser |
| RSI "momentum side" (continuation) | fixed 50 | the symbol's **RSI median** — buys need RSI above *its own normal middle* |
| Stochastic cross zone | fixed 55 / 45 | the **median of its own %K** distribution |
| ADX trend / strong | fixed 20 / 25 | the **60th / 75th percentile of its own ADX** — a naturally choppy symbol demands more trend strength than a naturally trending one |
| Volume "real interest" | fixed 1.3× average | the **70th percentile of the symbol's volume-vs-average ratios** — adapts to session rhythm and symbol activity |
| Volatility regime | – | current ATR vs its own median → *expanding* (≥1.3×) / *normal* / *contracting* (≤0.75×). In a **contracting** market, momentum breakouts need **1 extra validation point** (they fail more often in compression) |
| Signal expiry | fixed 12 (M5) / 8 (M15) bars | scales with the market's **current speed** (~1.5× the estimated bars-to-TP1, clamped) — a slow market gets more time, a fast one less |

Already adaptive by design (no change needed): SL/TP distances are **ATR-based**
(scale with each symbol's volatility), Bollinger Bands self-adjust, and the swing /
location logic is relative to each symbol's own structure.

The panel shows the currently learned limits (blue row), and every validation check
displays the actual limit it used, tagged `dyn`. If history is too short to learn
from (< 100 bars) or you set `InpDynamic = false`, it falls back to the static inputs.

---

## 5. The forecast — only for PROVEN ideas (stage 3)

Nothing is forecast when a pattern is merely validated. The forecast is issued **only
after the proof window passes** (stage 2), and it is a genuine **forward projection**:

- **Entry** — close of the **proof bar** (the candle that confirmed the reversal),
  exactly like a human acting on confirmation, not on hope.
- **Stop loss** — beyond the proof bar's low/high **and** the nearest swing, plus a
  0.3×ATR buffer, capped at 2.5×ATR so the stop stays sane.
- **Forward projection (where price may go within the horizon)** — measured move:
  TP1 = **38.2% retracement of the prior leg**, TP2 = **61.8% retracement**, with
  **R-floors** so the reward always matches the risk (Balanced ≥ 1R / ≥ 2R,
  Conservative ≥ 1.5R / ≥ 3R, Aggressive ≥ 0.8R / ≥ 1.6R). If the prior leg is too
  shallow, the R-floor takes over; if the leg is deep, the measured move extends the
  target beyond the floor — the way a human reads retracements.
- **Expected duration** — bars to TP1 from **net directional speed** (average bar
  speed × path-efficiency). A choppy market needs more time to travel the same
  distance — realistic, not optimistic.
- **Horizon (signal validation time)** — ~2× the estimated time to TP1, never shorter
  than the default window (M5 → 12 bars, M15 → 8), capped at 4×. At horizon end the
  forecast is marked `EXPIRED`.
- **Live schedule check** — the panel compares **actual progress vs the projected
  path** every bar (`on track` / `behind`, progress % vs expected %) — a human
  watching his trade knows whether it is "moving as expected" or "stalling".
- **Past-history win-rate** — the same setup replayed over the last 500 bars.
- **Spread sanity** — setups whose structure stop is tighter than 2× spread are
  skipped (costs would eat the trade).

### 5.1 Stability locks — no flip-flopping

A human does not reverse opinion with every candle color. Version 1.40 added the
patience rules that stopped the sell→buy→sell whipsaw seen in live testing:

| Lock | Rule |
|---|---|
| **Flip protection** | an opposite signal can replace an active forecast only if the forecast is **≥ 3 bars old** AND the new signal carries **extra conviction** (score ≥ threshold + 1). Otherwise it's shown on the watchlist and ignored |
| **Cooldown** | after any forecast resolves (TP/SL/expiry), new forecasts pause for **2 bars** — step back, let the dust settle |
| **Mixed-structure rule** | a *continuation* signal when swing structure is mixed needs **+1 validation point** — continuation calls in structureless chop were the main whipsaw source |
| **One idea at a time** | unchanged: one active forecast per chart; same-direction re-signals just keep it |

Session scoreboard (W/L/X/C) and the recent outcome list show how the current session
is going — the same feedback a trader gets from watching their own calls.

---

## 6. EA inputs — only 4 groups, only what a trader chooses

SmartTrader follows a simple product rule: **a trader trades, the machine tunes itself.**
Every indicator period, level, percentile and ATR multiplier is self-adapting (learned
from the symbol) or internally tuned. The input window shows only:

| Group | Inputs | Meaning |
|---|---|---|
| **Trading style** | Conservative / **Balanced** / Aggressive | the ONE real choice — how strict the judge is and the stop/target profile (see 6.1) |
| **Alerts** | popup (ON), push (OFF), e-mail (OFF), watchlist alerts (OFF) | how you get notified |
| **Panel** | corner, font size | appearance |
| **Advanced** (leave as is) | adaptive thresholds ON, signal validity override 0 = auto | escape hatches for power users |

### 6.1 What the trading style changes

| Profile | Validated signal needs | Watchlist | Stop loss | Targets (R = stop distance) |
|---|---|---|---|---|
| Conservative | 5 of 7 | 4 | wider: 0.4×ATR buffer, max 3×ATR | TP1 1.5R, TP2 3R |
| **Balanced** (default) | 4 of 7 | 3 | 0.3×ATR buffer, max 2.5×ATR | TP1 1R, TP2 2R |
| Aggressive | 3 of 7 | 3 | tighter: 0.25×ATR buffer, max 2×ATR | TP1 0.8R, TP2 1.6R |

The style also applies to the past-history replay, so the shown win-rate always
matches the way you chose to trade. The panel header shows the active style.

---

## 7. Files

```
SmartTrader.mq5          Phase 1 EA (single file, no external includes needed)
docs/PHASE2_PLAN.md      Autotrading design + open questions
```

## 8. Roadmap

- [x] **Phase 1** — market watch, candle reading, trend, validation, forecast, history check
- [ ] **Phase 2** — order execution: risk-based lot size, SL/TP from the forecast, breakeven/trailing, max trades per day, session filter
- [ ] Optional: multi-symbol scanner panel, session/profile statistics export

## Disclaimer

This software is for educational purposes. Backtest and forward-test on a **demo account**
first. Past "history win-rate" of a setup does not guarantee future results. Trading
foreign exchange / CFDs on margin carries a high level of risk.

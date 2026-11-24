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

## 2. How it mirrors a human trader

| What a human does at the chart | What SmartTrader does |
|---|---|
| Watches every completed candle | Evaluates the **last closed** M5/M15 candle the moment a new bar opens (no repainting mid-bar) |
| Knows what candles mean | Detects **19 candle patterns** (see §3) and grades them by strength |
| Reads the trend | EMA20/EMA50 alignment + price location, **swing structure** (HH/HL vs LH/LL), ADX strength → `UP strong / UP / RANGE / DOWN / DOWN strong` |
| Spots a reversal candle *in context* | A pattern only counts when its location fits (near swing support/resistance or a 20-bar extreme) |
| Estimates where price may go | Forecast = entry, SL, TP1, TP2 (ATR-based, structure-aware) |
| Estimates how far/long the move may go | ATR distance for targets; **expected bars to TP1** from the market's average speed; **expiry** = signal validation time |
| Double-checks with indicator tools | **7-point validation checklist** (see §4) — thresholds **self-adapt** to the symbol and market context |
| Glances at what history says | Scans the last 500 bars, replays **every occurrence of the same setup** and reports the real win-rate (`11/16 (69%) reached TP1 first`) |
| Places the order and keeps watching | *(Phase 2)* — for now it tracks the live forecast on the chart and marks `TP1 OK / TP2 OK / SL X / expired` when it resolves |

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
| **RSI(14)** zone | reversal: ≤ 35 · continuation: > 50 | reversal: ≥ 65 · continuation: < 50 |
| **RSI divergence** (reversals) | price lower low, RSI higher low | price higher high, RSI lower high |
| **Stochastic(14,3,3)** | cross up from oversold (≤ 55) | cross down from overbought (≥ 45) |
| **MACD(12,26,9)** histogram | rising | falling |
| **Tick volume** | ≥ 1.3× of 20-bar average (real interest behind the candle) | same |
| **Bollinger(20,2) rejection** (reversals) | pierced lower band, closed back inside | pierced upper band, closed back inside |
| **Location** (reversals) | at swing low / 20-bar low | at swing high / 20-bar high |

Continuation setups swap the last check for **ADX ≥ 20** (trend strength).

All thresholds are EA inputs — you can tighten or loosen the "human judgment".

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

## 5. The forecast

When a signal is validated, SmartTrader publishes (panel + chart lines + alert):

- **Entry** — close of the signal candle (≈ next bar open, like a human acting now).
- **Stop loss** — beyond the pattern low/high **and** the nearest swing, plus a 0.3×ATR
  buffer, capped at 2.5×ATR so the stop stays sane.
- **TP1** = 1.0×ATR, **TP2** = 2.0×ATR from entry (configurable).
- **Expected duration** — bars to TP1, estimated from the average point-per-bar speed
  of the last 50 bars.
- **Signal validation time (expiry)** — the forecast is tracked for N bars
  (default auto: M5 → 12 bars ≈ 1 hour, M15 → 8 bars ≈ 2 hours; dynamic mode scales
  this with the market's current speed). After expiry it is marked `EXPIRED` — like a
  human cancelling a setup that didn't move.
- **Past-history win-rate** — the same setup replayed over the last 500 bars.
- One forecast is tracked at a time; an opposite validated signal cancels the old one.

Session scoreboard (W/L/X/C) and the recent outcome list show how the current session
is going — the same feedback a trader gets from watching their own calls.

---

## 6. EA inputs (summary)

| Group | Inputs |
|---|---|
| Chart/basic | panel corner, font size, expiry bars (0 = auto), popup/push/e-mail alerts |
| Trend engine | EMA 20/50, ADX 14 (strong ≥ 25, trend ≥ 20), swing lookback 60 |
| Validation | RSI 14 (35/65), Stoch 14/3/3, MACD 12/26/9, BB 20/2.0, ATR 14, volume 20 bars ×1.3, location 0.5×ATR |
| **Dynamic thresholds** | master switch (ON), learning lookback 300 bars, RSI percentiles 15/85, ADX percentiles 60/75, volume percentile 70, ATR regime 1.30/0.75 |
| Scoring | validated ≥ 4, watchlist ≥ 3, +1 extra requirement against a strong trend, +1 for breakouts in contracting volatility |
| Forecast | SL buffer 0.3×ATR (max 2.5×ATR), TP1 1.0×ATR, TP2 2.0×ATR, speed window 50 bars |
| History check | 500 bars replay |

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

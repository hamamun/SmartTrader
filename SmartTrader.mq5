//+------------------------------------------------------------------+
//|                                                  SmartTrader.mq5 |
//|            SmartTrader - human-style market watch & forecast     |
//|            Phase 1 : Observation only - NO orders are placed     |
//+------------------------------------------------------------------+
//| Works like a human trader sitting at the chart:                  |
//|  1. Reads every closed M5/M15 candle (20+ candle patterns).      |
//|  2. Reads the trend (EMA alignment, swing structure, ADX).       |
//|  3. Finds reversal / continuation setups.                        |
//|  4. Validates with a modern engine: QQE (smoothed RSI + adaptive |
//|     trailing bands), Ehlers Fisher Transform, Choppiness Index,  |
//|     TTM squeeze, adaptive RSI/ADX/volume percentiles.            |
//|  5. Publishes a forecast: entry, SL, TP1, TP2, expected bars,    |
//|     expiry ("signal validation time") and past-history win-rate. |
//|  6. Tracks the live forecast until TP1 / SL / expiry.            |
//| Phase 2 (separate release) will place and manage the orders.     |
//+------------------------------------------------------------------+
#property copyright   "SmartTrader"
#property link        "https://github.com/hamamun/SmartTrader"
#property version     "1.20"
#property description "SmartTrader Phase 1 - Market Watch & Forecast."
#property description "Reads candles and trend like a human; validation thresholds self-adapt"
#property description "to each symbol and the current market context (dynamic percentiles)."
#property description "Publishes entry/SL/TP/forecast-duration/expiry + history win-rate."
#property description "Observation only: this version never sends an order."

//====================================================================//
//  INPUTS                                                            //
//====================================================================//

input group "=== A. Chart / basic rules ==="
input ENUM_BASE_CORNER InpPanelCorner      = CORNER_LEFT_UPPER; // Panel corner
input int              InpFontSize         = 9;                 // Panel font size
input int              InpSignalExpiryBars = 0;                 // Signal valid for N bars (0 = auto: M5 12 / M15 8)
input bool             InpAlertPopup       = true;              // Popup alert on validated signal
input bool             InpAlertPush        = false;             // Push notification on validated signal
input bool             InpAlertEmail       = false;             // E-mail on validated signal
input bool             InpAlertWatch       = false;             // Also alert on weak (watchlist) signals

input group "=== B. Trend engine ==="
input int              InpFastEMA          = 20;                // Fast EMA period
input int              InpSlowEMA          = 50;                // Slow EMA period
input int              InpADXPeriod        = 14;                // ADX period
input double           InpADXStrong        = 25.0;              // ADX >= this -> strong trend
input double           InpADXTrendMin      = 20.0;              // ADX >= this -> trend (else range)
input int              InpSwingLookback    = 60;                // Bars to scan for swing highs/lows

input group "=== C. Validation indicators ==="
input int              InpRSIPeriod        = 14;                // RSI period
input double           InpRSIBuyMax        = 35.0;              // RSI oversold limit (buy reversal, static fallback)
input double           InpRSISellMin       = 65.0;              // RSI overbought limit (sell reversal, static fallback)
input int              InpBBPeriod         = 20;                // Bollinger period
input double           InpBBDev            = 2.0;               // Bollinger deviation
input int              InpATRPeriod        = 14;                // ATR period
input int              InpVolAvgBars       = 20;                // Volume average bars
input double           InpVolSpikeMult     = 1.3;               // Volume spike multiplier (static fallback)
input double           InpLocATRFrac       = 0.5;               // Location: within 0.5 x ATR of swing

input group "=== C2. Dynamic (smart) thresholds ==="
input bool             InpDynamic          = true;              // Adapt thresholds to symbol & market context
input int              InpDynLookback      = 300;               // Bars used to learn the symbol's normal behavior
input double           InpDynRSIPctLow     = 15.0;              // RSI oversold = this percentile of its own history
input double           InpDynRSIPctHigh    = 85.0;              // RSI overbought percentile
input double           InpDynADXPctTrend   = 60.0;              // ADX percentile separating trend from range
input double           InpDynADXPctStrong  = 75.0;              // ADX percentile counting as "strong trend"
input double           InpDynVolPct        = 70.0;              // Volume percentile counting as real interest
input double           InpDynATRExpand     = 1.30;              // ATR now / median above this = expanding volatility
input double           InpDynATRShrink     = 0.75;              // below this = contracting volatility

input group "=== C3. Modern indicator engine ==="
input double           InpQQEFactor        = 4.236;             // QQE trailing factor (golden ratio squared)
input int              InpFisherLen        = 9;                 // Ehlers Fisher Transform lookback
input int              InpChopPeriod       = 14;                // Choppiness Index period
input double           InpChopChoppy       = 61.8;              // CHOP >= this = choppy/range regime
input double           InpChopTrend        = 38.2;              // CHOP <= this = trending regime

input group "=== D. Signal scoring ==="
input int              InpMinScoreValid    = 4;                 // Score needed for VALIDATED signal (max 7)
input int              InpMinScoreWatch    = 3;                 // Score needed for watchlist
input int              InpStrongTrendExtra = 1;                 // Extra score needed against a STRONG trend

input group "=== E. Forecast levels ==="
input double           InpSLATRBuf         = 0.3;               // SL buffer beyond structure (x ATR)
input double           InpSLMaxATR         = 2.5;               // Max SL distance (x ATR)
input double           InpTP1ATR           = 1.0;               // TP1 distance (x ATR)
input double           InpTP2ATR           = 2.0;               // TP2 distance (x ATR)
input int              InpSpeedBars        = 50;                // Bars used to estimate market speed

input group "=== F. Past-history quick check ==="
input int              InpHistoryBars      = 500;               // Bars scanned for the same setup

//====================================================================//
//  CONSTANTS / TYPES                                                 //
//====================================================================//

#define OBJ_PREFIX     "ST_"
#define MAX_ROWS       30
#define MAX_RECENT     5

// pattern classes
#define PC_NONE            0
#define PC_MORNING_STAR    1
#define PC_EVENING_STAR    2
#define PC_THREE_SOLDIERS  3
#define PC_THREE_CROWS     4
#define PC_BULL_ENGULF     5
#define PC_BEAR_ENGULF     6
#define PC_PIERCING        7
#define PC_DARK_CLOUD      8
#define PC_TWEEZER_BOTTOM  9
#define PC_TWEEZER_TOP     10
#define PC_HAMMER          11
#define PC_SHOOTING_STAR   12
#define PC_DRAGONFLY       13
#define PC_GRAVESTONE      14
#define PC_MARU_BULL       15
#define PC_MARU_BEAR       16
#define PC_HARAMI_BULL     17
#define PC_HARAMI_BEAR     18
#define PC_DOJI            19

// trend states
#define TR_DOWN_STRONG     0
#define TR_DOWN            1
#define TR_RANGE           2
#define TR_UP              3
#define TR_UP_STRONG       4

// setup types
#define SETUP_REVERSAL     0
#define SETUP_CONTINUATION 1

// decision
#define DEC_NONE           0
#define DEC_WATCH          1
#define DEC_VALID          2

// forecast status
#define FC_ACTIVE          0
#define FC_TP1             1
#define FC_TP2             2
#define FC_SL              3
#define FC_EXPIRED         4
#define FC_CANCELLED       5

// check state
#define CK_PASS            0
#define CK_FAIL            1
#define CK_NA              2

struct SPattern
  {
   int               code;
   string            name;
   int               direction;   // +1 bull, -1 bear, 0 neutral
   int               strength;    // 1..3
   int               shift;       // shift of signal bar
  };

struct SSwings
  {
   bool              hasH;        // at least 1 swing high
   bool              hasH2;       // 2 swing highs found
   bool              hasL;
   bool              hasL2;
   double            sh1, sh2;    // prices of last / previous swing high
   double            sl1, sl2;    // prices of last / previous swing low
   int               sh1s, sh2s;  // their shifts
   int               sl1s, sl2s;
  };

struct STrend
  {
   int               state;
   int               dir;         // +1 / 0 / -1
   double            adx;
   double            pdi;
   double            mdi;
   double            ema20;
   double            ema50;
   int               swingDir;    // +1 HH+HL, -1 LH+LL, 0 mixed
   string            note;
  };

struct SCheck
  {
   string            name;
   int               state;       // CK_PASS / CK_FAIL / CK_NA
   string            detail;
  };

struct SForecast
  {
   bool              used;
   int               dir;
   int               status;
   datetime          tSignal;
   string            patternName;
   int               strength;
   int               setupType;
   int               score;
   int               maxScore;
   double            entry;
   double            sl;
   double            tp1;
   double            tp2;
   double            atr;
   int               expBars;
   int               expiryBars;
   datetime          tExpire;
   int               barsLeft;
   double            histWins;
   double            histTotal;
  };

//====================================================================//
//  GLOBALS                                                           //
//====================================================================//

int      hEmaFast=INVALID_HANDLE, hEmaSlow=INVALID_HANDLE, hRSI=INVALID_HANDLE;
int      hATR=INVALID_HANDLE,     hADX=INVALID_HANDLE,     hBands=INVALID_HANDLE;

MqlRates g_rates[];
double   g_emaF[], g_emaS[], g_rsi[];
double   g_atr[], g_adx[], g_pdi[], g_mdi[];
double   g_bbUp[], g_bbLo[];
long     g_vol[];

int      g_window      = 0;      // copied bars per array
bool     g_dataOK      = false;

SPattern g_lastPat;              // pattern on last closed bar
bool     g_hasPat      = false;
STrend   g_trend;
SSwings  g_swings;
SCheck   g_checks[8];
int      g_checkCount  = 0;
int      g_score       = 0;
int      g_maxScore    = 0;
int      g_setupType   = SETUP_REVERSAL;
int      g_decision    = DEC_NONE;
string   g_decisionNote= "";

SForecast g_fc;                  // live forecast
SForecast g_lastDone;            // last resolved forecast
bool      g_hasDone   = false;
string    g_recent[MAX_RECENT];  // last outcomes, newest first
int       g_recentN    = 0;
int       g_statW=0, g_statL=0, g_statX=0, g_statC=0;

string    g_histNote  = "not scanned yet";
int       g_histKey   = -1;      // pattern code of last scan
int       g_histKeyD  = 0;
int       g_histKeyT  = -1;

datetime  g_lastBar   = 0;
string    g_statusMsg = "loading history...";

//--- dynamic context: thresholds re-learned from THIS symbol every closed bar
bool     g_dynOK        = false;
double   g_rsiLoEff     = 35.0;   // effective limits actually used by validation
double   g_rsiHiEff     = 65.0;
double   g_rsiMidEff    = 50.0;
double   g_adxTrendEff  = 20.0;
double   g_adxStrongEff = 25.0;
double   g_volMultEff   = 1.3;
double   g_atrRatio     = 1.0;    // current ATR vs its own median
int      g_volRegime    = 0;      // +1 expanding, 0 normal, -1 contracting
string   g_dynNote      = "thresholds: static (from inputs)";

//--- modern indicator engine (computed over the copied window every closed bar)
double   g_qqeRsim[];             // QQE smoothed RSI line (series indexed)
int      g_qqeTrend[];            // QQE trailing-band trend state: +1 up / -1 down
double   g_fish[];                // Ehlers Fisher Transform (series indexed)
double   g_chop1         = 50.0;  // Choppiness Index on last closed bar
bool     g_squeezeOn1    = false; // TTM squeeze ON at last closed bar (BB inside Keltner)
bool     g_squeezeFired  = false; // squeeze released recently
int      g_squeezeFiredAgo = -1;
string   g_squeezeState  = "off";

//====================================================================//
//  INIT / DEINIT                                                     //
//====================================================================//

int OnInit()
  {
   if(_Period != PERIOD_M5 && _Period != PERIOD_M15)
     {
      Alert("SmartTrader: attach this EA to an M5 or M15 chart only. Current chart: ",
            EnumToString(_Period));
      return(INIT_FAILED);
     }

   hEmaFast = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, InpATRPeriod);
   hADX     = iADX(_Symbol, _Period, InpADXPeriod);
   hBands   = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hRSI==INVALID_HANDLE ||
      hATR==INVALID_HANDLE     || hADX==INVALID_HANDLE     || hBands==INVALID_HANDLE)
     {
      Print("SmartTrader: failed to create indicator handles, error ", GetLastError());
      return(INIT_FAILED);
     }

   ResetForecast(g_fc);
   ResetForecast(g_lastDone);
   for(int i=0; i<MAX_RECENT; i++) g_recent[i]="";

   EventSetTimer(1);
   Print("SmartTrader v1.20 Phase 1 started on ", _Symbol, " ", EnumToString(_Period),
         " - market watch & forecast only, no orders will be placed.",
         (InpDynamic ? " Dynamic thresholds: ON." : " Dynamic thresholds: OFF (static inputs)."));

   PanelRender();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ChartRedraw(0);
   Print("SmartTrader Phase 1 stopped (reason ", reason, ").");
  }

//====================================================================//
//  EVENT HANDLERS                                                    //
//====================================================================//

void OnTick()
  {
   if(!IsNewBar())
      return;

   UpdateData();
   if(!g_dataOK)
     {
      PanelRender();
      return;
     }

   // 0. re-learn this symbol's normal behavior (dynamic thresholds)
   ComputeModernIndicators();
   UpdateDynamicContext();

   // 1. track the running forecast against the bar that just closed
   ForecastUpdate();

   // 2. read the last closed candle like a human trader
   AnalyzeLastBar();

   // 3. render
   ForecastDrawLevels();
   PanelRender();
  }

void OnTimer()
  {
   PanelRender();   // keeps countdown / spread / forming candle fresh between ticks
  }

//====================================================================//
//  DATA                                                              //
//====================================================================//

bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0 || t == g_lastBar)
      return(false);
   g_lastBar = t;
   return(true);
  }

void UpdateData()
  {
   g_dataOK = false;

   int available = Bars(_Symbol, _Period);
   if(available < 300)
     {
      g_statusMsg = "not enough history (" + IntegerToString(available) + " bars, need 300+)";
      return;
     }

   int want = MathMax(300, MathMin(InpHistoryBars + 10, available - 3));
   if(want < 100)
      return;

   ArraySetAsSeries(g_rates, true);
   ArraySetAsSeries(g_emaF,  true);  ArraySetAsSeries(g_emaS,  true);
   ArraySetAsSeries(g_rsi,   true);
   ArraySetAsSeries(g_atr,   true);
   ArraySetAsSeries(g_adx,   true);  ArraySetAsSeries(g_pdi,  true);
   ArraySetAsSeries(g_mdi,   true);  ArraySetAsSeries(g_bbUp, true);
   ArraySetAsSeries(g_bbLo,  true);  ArraySetAsSeries(g_vol,  true);

   int copied = CopyRates(_Symbol, _Period, 0, want, g_rates);
   if(copied < 100)
     {
      g_statusMsg = "history is loading...";
      return;
     }
   g_window = copied;

   if(CopyBuffer(hEmaFast,0,0,copied,g_emaF)  < copied) return;
   if(CopyBuffer(hEmaSlow,0,0,copied,g_emaS)  < copied) return;
   if(CopyBuffer(hRSI,    0,0,copied,g_rsi)   < copied) return;
   if(CopyBuffer(hATR,    0,0,copied,g_atr)   < copied) return;
   if(CopyBuffer(hADX,    0,0,copied,g_adx)   < copied) return;
   if(CopyBuffer(hADX,    1,0,copied,g_pdi)   < copied) return;
   if(CopyBuffer(hADX,    2,0,copied,g_mdi)   < copied) return;
   if(CopyBuffer(hBands,  1,0,copied,g_bbUp)  < copied) return;
   if(CopyBuffer(hBands,  2,0,copied,g_bbLo)  < copied) return;
   if(CopyTickVolume(_Symbol,_Period,0,copied,g_vol) < copied) return;

   g_dataOK  = true;
   g_statusMsg = "";
  }

//====================================================================//
//  MODERN INDICATOR ENGINE                                           //
//====================================================================//
//  Replacements / additions over the classic toolkit, all computed
//  from data we already copy (no extra handles needed):
//    QQE      - smoothed RSI with Wilder trailing bands (factor 4.236):
//               replaces Stochastic as the momentum-shift check, far less
//               whipsaw because the crossover level adapts to RSI volatility
//    Fisher   - Ehlers Fisher Transform: normalizes price into a sharp
//               near-Gaussian oscillator; turns at extremes are much sharper
//               than MACD histogram drift
//    CHOP     - Choppiness Index (Dreiss): >61.8 range, <38.2 trend;
//               the regime dial behind the breakout rule
//    Squeeze  - TTM squeeze (BB inside Keltner EMA20 +/- 1.5 ATR):
//               compression -> expansion detection for breakouts

void ComputeModernIndicators()
  {
   int n = g_window;
   ArrayResize(g_qqeRsim, n);
   ArrayResize(g_qqeTrend, n);
   ArrayResize(g_fish, n);

   //--- QQE: EMA(5) of RSI + Wilder(14) of its change -> trailing bands
   double rsimPrev = 0, darPrev = 0, trailPrev = 0, longPrev = 0, shortPrev = 0;
   int    trendPrev = 1;
   for(int a = 0; a < n; a++)
     {
      int s = n - 1 - a;                       // series shift of this step
      double alpha = 2.0 / 6.0;                // EMA(5)
      double rsim  = (a == 0 ? g_rsi[s] : rsimPrev + alpha * (g_rsi[s] - rsimPrev));
      double d     = (a == 0 ? 0 : MathAbs(rsim - rsimPrev));
      double dar   = (a == 0 ? d : darPrev + (d - darPrev) / 14.0);   // Wilder(14)
      double longB  = rsim - InpQQEFactor * dar;
      double shortB = rsim + InpQQEFactor * dar;
      int tr = trendPrev;
      if(a > 0)
        {
         if(tr == -1 && rsim > shortPrev) tr = 1;
         if(tr ==  1 && rsim < longPrev)  tr = -1;
        }
      double trail;
      if(a == 0)            trail = (tr == 1 ? longB : shortB);
      else if(tr == 1)      trail = MathMax(longB,  trailPrev);
      else                  trail = MathMin(shortB, trailPrev);
      if(a > 0 && tr != trendPrev)                 // trend just flipped: restart band
         trail = (tr == 1 ? longB : shortB);
      g_qqeRsim[s]  = rsim;
      g_qqeTrend[s] = tr;
      rsimPrev = rsim; darPrev = dar; trailPrev = trail;
      longPrev = longB; shortPrev = shortB; trendPrev = tr;
     }

   //--- Ehlers Fisher Transform over median price
   double valPrev = 0, fishPrev = 0;
   for(int a = 0; a < n; a++)
     {
      int s = n - 1 - a;
      int len = MathMin(InpFisherLen, s + 1);
      double hh = -DBL_MAX, ll = DBL_MAX;
      for(int k = 0; k < len; k++)
        {
         double mid = 0.5 * (g_rates[s + k].high + g_rates[s + k].low);
         if(mid > hh) hh = mid;
         if(mid < ll) ll = mid;
        }
      double mid0 = 0.5 * (g_rates[s].high + g_rates[s].low);
      double raw  = (hh - ll > 0 ? 2.0 * (mid0 - ll) / (hh - ll) - 1.0 : 0.0);
      double val  = 0.33 * raw + 0.67 * valPrev;
      if(val >  0.999) val =  0.999;
      if(val < -0.999) val = -0.999;
      double fish = 0.5 * MathLog((1 + val) / (1 - val)) + 0.5 * fishPrev;
      g_fish[s]  = fish;
      valPrev = val; fishPrev = fish;
     }

   //--- Choppiness Index on the last closed bar
   int per = MathMin(InpChopPeriod, g_window - 2);
   double chH = HighestHigh(1, per), chL = LowestLow(1, per);
   double sumA = 0;
   for(int k = 1; k <= per; k++) sumA += g_atr[k];
   g_chop1 = 100.0 * MathLog10((chH - chL) > 0 ? sumA / (chH - chL) : 1.0000001) / MathLog10((double)per);

   //--- TTM squeeze state (Bollinger inside Keltner = compression)
   g_squeezeOn1 = (g_bbUp[1] < g_emaF[1] + 1.5 * g_atr[1]) && (g_bbLo[1] > g_emaF[1] - 1.5 * g_atr[1]);
   g_squeezeFired = false;
   g_squeezeFiredAgo = -1;
   if(!g_squeezeOn1)
     {
      for(int s = 2; s <= 8 && s < g_window; s++)
        {
         bool on = (g_bbUp[s] < g_emaF[s] + 1.5 * g_atr[s]) &&
                   (g_bbLo[s] > g_emaF[s] - 1.5 * g_atr[s]);
         if(on) { g_squeezeFired = true; g_squeezeFiredAgo = s - 1; break; }
        }
     }
   g_squeezeState = g_squeezeOn1 ? "ON (compressed)"
                                 : (g_squeezeFired ? "FIRED " + IntegerToString(g_squeezeFiredAgo) + " bars ago" : "off");
  }

//====================================================================//
//  DYNAMIC CONTEXT (smart, self-adapting thresholds)                 //
//====================================================================//
//  A fixed "RSI oversold = 35" cannot fit every symbol and every
//  market phase: gold on M5 and EURUSD on M5 have different RSI
//  distributions, and the same symbol behaves differently in a trend,
//  a range, or a volatility burst. So SmartTrader re-learns its
//  limits from the symbol's OWN recent behavior on every closed bar:
//    - RSI / Stochastic zones  = percentiles of their own history
//    - ADX trend/strong levels = percentiles of its own history
//    - volume "real interest"  = percentile of volume-vs-average ratios
//    - volatility regime       = current ATR vs its median (expanding /
//                                normal / contracting) -> adjusts scoring
//    - signal expiry           = scales with the market's current speed
//  Falls back to the static group-C inputs when disabled or when
//  history is too short to learn from.

void UpdateDynamicContext()
  {
   // defaults = static inputs (fallback when dynamic mode off / not enough data)
   g_rsiLoEff     = InpRSIBuyMax;
   g_rsiHiEff     = InpRSISellMin;
   g_rsiMidEff    = 50.0;
   g_adxTrendEff  = InpADXTrendMin;
   g_adxStrongEff = InpADXStrong;
   g_volMultEff   = InpVolSpikeMult;
   g_atrRatio     = 1.0;
   g_volRegime    = 0;
   g_dynOK        = false;
   g_dynNote      = "thresholds: static (from inputs)";

   if(!InpDynamic)
      return;

   int n = MathMin(InpDynLookback, g_window - 3);
   if(n < 100)
     {
      g_dynNote = "dynamic: learning needs more history (" + IntegerToString(n) + "/" +
                  IntegerToString(InpDynLookback) + " bars) - using static limits";
      return;
     }

   double tmp[];
   ArrayResize(tmp, n);

   //--- RSI zones from the symbol's own RSI distribution
   for(int i = 0; i < n; i++) tmp[i] = g_rsi[1 + i];
   g_rsiLoEff  = PercentileOf(tmp, n, InpDynRSIPctLow);
   g_rsiHiEff  = PercentileOf(tmp, n, InpDynRSIPctHigh);
   g_rsiMidEff = PercentileOf(tmp, n, 50.0);

   //--- ADX trend / strong levels
   for(int i = 0; i < n; i++) tmp[i] = g_adx[1 + i];
   g_adxTrendEff  = PercentileOf(tmp, n, InpDynADXPctTrend);
   g_adxStrongEff = PercentileOf(tmp, n, InpDynADXPctStrong);

   //--- volume: percentile of "volume vs its own 20-bar average" ratios
   double rat[];
   ArrayResize(rat, n);
   for(int i = 0; i < n; i++)
     {
      double a = AvgVol(InpVolAvgBars, 2 + i);
      rat[i] = (a > 0 ? (double)g_vol[1 + i] / a : 0);
     }
   double pv = PercentileOf(rat, n, InpDynVolPct);
   g_volMultEff = (pv > 0 ? pv : InpVolSpikeMult);

   //--- volatility regime: current ATR vs its own median
   for(int i = 0; i < n; i++) tmp[i] = g_atr[1 + i];
   double medAtr = PercentileOf(tmp, n, 50.0);
   if(medAtr > 0)
      g_atrRatio = g_atr[1] / medAtr;
   if(g_atrRatio >= InpDynATRExpand)      g_volRegime =  1;
   else if(g_atrRatio <= InpDynATRShrink) g_volRegime = -1;

   g_dynOK = true;
   g_dynNote = StringFormat("thresholds: DYNAMIC  RSI %.1f/%.1f  ADX %.0f/%.0f  Vol >= %.2fx  ATR %.2fx med",
                            g_rsiLoEff, g_rsiHiEff,
                            g_adxTrendEff, g_adxStrongEff, g_volMultEff, g_atrRatio);
  }

//====================================================================//
//  CANDLE METRICS & PATTERN ENGINE                                   //
//====================================================================//

double Body(int i)       { return(MathAbs(g_rates[i].close - g_rates[i].open)); }
double Range(int i)      { return(g_rates[i].high - g_rates[i].low); }
double UpWick(int i)     { return(g_rates[i].high - MathMax(g_rates[i].open, g_rates[i].close)); }
double LoWick(int i)     { return(MathMin(g_rates[i].open, g_rates[i].close) - g_rates[i].low); }
bool   BullBar(int i)    { return(g_rates[i].close > g_rates[i].open); }
bool   BearBar(int i)    { return(g_rates[i].close < g_rates[i].open); }

double BodyAvg(int n, int s)
  {
   if(s + n >= g_window) n = g_window - s - 1;
   if(n <= 0) return(0);
   double sum = 0;
   for(int i = s; i < s + n; i++) sum += Body(i);
   return(sum / n);
  }

double LowestLow(int s, int n)
  {
   if(s + n >= g_window) n = g_window - s - 1;
   double v = g_rates[s].low;
   for(int i = s; i < s + n; i++) if(g_rates[i].low < v) v = g_rates[i].low;
   return(v);
  }

double HighestHigh(int s, int n)
  {
   if(s + n >= g_window) n = g_window - s - 1;
   double v = g_rates[s].high;
   for(int i = s; i < s + n; i++) if(g_rates[i].high > v) v = g_rates[i].high;
   return(v);
  }

double AvgVol(int n, int s)
  {
   if(s + n >= g_window) n = g_window - s - 1;
   if(n <= 0) return(0);
   double sum = 0;
   for(int i = s; i < s + n; i++) sum += (double)g_vol[i];
   return(sum / n);
  }

double AvgSpeed(int n, int s)
  {
   if(s + n + 1 >= g_window) n = g_window - s - 2;
   if(n <= 0) return(0);
   double sum = 0;
   for(int i = s; i < s + n; i++) sum += MathAbs(g_rates[i].close - g_rates[i+1].close);
   return(sum / n);
  }

// value at a given percentile (0..100) of arr[0..count-1]; sorts a copy region in place
double PercentileOf(double &arr[], int count, double pct)
  {
   if(count <= 0) return(0);
   if(count == 1) return(arr[0]);
   ArraySort(arr);
   double idx = (pct / 100.0) * (count - 1);
   int lo = (int)MathFloor(idx);
   int hi = (int)MathCeil(idx);
   if(lo < 0) lo = 0;
   if(hi > count - 1) hi = count - 1;
   if(lo == hi) return(arr[lo]);
   double frac = idx - lo;
   return(arr[lo] * (1.0 - frac) + arr[hi] * frac);
  }

// detect a pattern whose SIGNAL bar is at 's' (older bars s+1, s+2 used as context)
bool DetectPatternAt(int s, SPattern &p)
  {
   p.code = PC_NONE; p.name = ""; p.direction = 0; p.strength = 0; p.shift = s;
   if(s + 2 >= g_window) return(false);

   double b0 = Body(s),  r0 = Range(s);
   if(r0 <= 0) return(false);
   double uw0 = UpWick(s), lw0 = LoWick(s);
   double b1 = Body(s+1), r1 = Range(s+1);
   double avg0 = BodyAvg(20, s);
   if(avg0 <= 0) return(false);
   double atr0 = (g_atr[s] > 0 ? g_atr[s] : avg0);
   double midP2 = (g_rates[s+2].open + g_rates[s+2].close) / 2.0;   // midpoint of the oldest bar body
   double midP1 = (g_rates[s+1].open + g_rates[s+1].close) / 2.0;

   //--- 3-bar: Morning / Evening star ---------------------------------
   if(s + 2 < g_window)
     {
      bool bigBear2 = BearBar(s+2) && Body(s+2) >= 0.8 * BodyAvg(20, s+2);
      bool bigBull2 = BullBar(s+2) && Body(s+2) >= 0.8 * BodyAvg(20, s+2);
      bool smallMid = Body(s+1) <= 0.35 * Body(s+2);

      if(bigBear2 && smallMid && BullBar(s) && g_rates[s].close > midP2)
        { p.code=PC_MORNING_STAR; p.name="Morning Star";       p.direction= 1; p.strength=3; return(true); }
      if(bigBull2 && smallMid && BearBar(s) && g_rates[s].close < midP2)
        { p.code=PC_EVENING_STAR; p.name="Evening Star";       p.direction=-1; p.strength=3; return(true); }
     }

   //--- 3-bar: Three White Soldiers / Three Black Crows ----------------
   if(BullBar(s) && BullBar(s+1) && BullBar(s+2) &&
      g_rates[s].close > g_rates[s+1].close && g_rates[s+1].close > g_rates[s+2].close &&
      Body(s) >= 0.55*r0 && Body(s+1) >= 0.55*r1 && Body(s+2) >= 0.55*Range(s+2) &&
      UpWick(s) <= 0.6*Body(s))
     { p.code=PC_THREE_SOLDIERS; p.name="Three White Soldiers"; p.direction= 1; p.strength=3; return(true); }

   if(BearBar(s) && BearBar(s+1) && BearBar(s+2) &&
      g_rates[s].close < g_rates[s+1].close && g_rates[s+1].close < g_rates[s+2].close &&
      Body(s) >= 0.55*r0 && Body(s+1) >= 0.55*r1 && Body(s+2) >= 0.55*Range(s+2) &&
      LoWick(s) <= 0.6*Body(s))
     { p.code=PC_THREE_CROWS; p.name="Three Black Crows";   p.direction=-1; p.strength=3; return(true); }

   //--- 2-bar: Engulfing ------------------------------------------------
   if(BearBar(s+1) && BullBar(s) &&
      g_rates[s].open <= g_rates[s+1].close && g_rates[s].close >= g_rates[s+1].open &&
      b0 >= MathMax(0.6*avg0, b1))
     { p.code=PC_BULL_ENGULF; p.name="Bullish Engulfing";   p.direction= 1; p.strength=3; return(true); }

   if(BullBar(s+1) && BearBar(s) &&
      g_rates[s].open >= g_rates[s+1].close && g_rates[s].close <= g_rates[s+1].open &&
      b0 >= MathMax(0.6*avg0, b1))
     { p.code=PC_BEAR_ENGULF; p.name="Bearish Engulfing";   p.direction=-1; p.strength=3; return(true); }

   //--- 2-bar: Piercing / Dark Cloud -----------------------------------
   if(BearBar(s+1) && Body(s+1) >= 0.8*BodyAvg(20,s+1) && BullBar(s) &&
      g_rates[s].open < g_rates[s+1].close &&
      g_rates[s].close > midP1 && g_rates[s].close < g_rates[s+1].open)
     { p.code=PC_PIERCING; p.name="Piercing Line";          p.direction= 1; p.strength=2; return(true); }

   if(BullBar(s+1) && Body(s+1) >= 0.8*BodyAvg(20,s+1) && BearBar(s) &&
      g_rates[s].open > g_rates[s+1].close &&
      g_rates[s].close < midP1 && g_rates[s].close > g_rates[s+1].open)
     { p.code=PC_DARK_CLOUD; p.name="Dark Cloud Cover";     p.direction=-1; p.strength=2; return(true); }

   //--- 2-bar: Tweezers -------------------------------------------------
   double tol = 0.12 * atr0;
   if(BearBar(s+1) && BullBar(s) && MathAbs(g_rates[s].low - g_rates[s+1].low) <= tol &&
      LoWick(s) >= 0.5*b0)
     { p.code=PC_TWEEZER_BOTTOM; p.name="Tweezer Bottom";   p.direction= 1; p.strength=2; return(true); }

   if(BullBar(s+1) && BearBar(s) && MathAbs(g_rates[s].high - g_rates[s+1].high) <= tol &&
      UpWick(s) >= 0.5*b0)
     { p.code=PC_TWEEZER_TOP; p.name="Tweezer Top";         p.direction=-1; p.strength=2; return(true); }

   //--- 1-bar: Hammer / Shooting Star (real body present) ---------------
   if(b0 >= 0.08*r0)
     {
      if(lw0 >= 2.0*b0 && uw0 <= 0.3*b0 + 0.1*r0 &&
         (MathMin(g_rates[s].open, g_rates[s].close) - g_rates[s].low) >= 0.55*r0)
        { p.code=PC_HAMMER; p.name="Hammer";                p.direction= 1; p.strength=2; return(true); }

      if(uw0 >= 2.0*b0 && lw0 <= 0.3*b0 + 0.1*r0 &&
         (g_rates[s].high - MathMax(g_rates[s].open, g_rates[s].close)) >= 0.55*r0)
        { p.code=PC_SHOOTING_STAR; p.name="Shooting Star";  p.direction=-1; p.strength=2; return(true); }
     }

   //--- 1-bar: Dragonfly / Gravestone doji ------------------------------
   if(b0 <= 0.1*r0)
     {
      if(lw0 >= 0.6*r0 && uw0 <= 0.1*r0)
        { p.code=PC_DRAGONFLY; p.name="Dragonfly Doji";     p.direction= 1; p.strength=2; return(true); }
      if(uw0 >= 0.6*r0 && lw0 <= 0.1*r0)
        { p.code=PC_GRAVESTONE; p.name="Gravestone Doji";   p.direction=-1; p.strength=2; return(true); }
      if(b0 <= 0.05*r0)
        { p.code=PC_DOJI; p.name="Doji";                    p.direction= 0; p.strength=1; return(true); }
     }

   //--- 1-bar: Marubozu (momentum continuation) -------------------------
   if(b0 >= 0.85*r0 && r0 >= 1.4*avg0)
     {
      if(BullBar(s)) { p.code=PC_MARU_BULL; p.name="Bullish Marubozu"; p.direction= 1; p.strength=2; return(true); }
      if(BearBar(s)) { p.code=PC_MARU_BEAR; p.name="Bearish Marubozu"; p.direction=-1; p.strength=2; return(true); }
     }

   //--- 2-bar: Harami / inside bar --------------------------------------
   if(g_rates[s].high < g_rates[s+1].high && g_rates[s].low > g_rates[s+1].low &&
      b1 >= 1.2*BodyAvg(20,s+1) && b0 > 0 && b0 <= 0.4*b1)
     {
      if(BearBar(s+1) && BullBar(s))
        { p.code=PC_HARAMI_BULL; p.name="Bullish Harami";   p.direction= 1; p.strength=1; return(true); }
      if(BullBar(s+1) && BearBar(s))
        { p.code=PC_HARAMI_BEAR; p.name="Bearish Harami";   p.direction=-1; p.strength=1; return(true); }
     }

   return(false);
  }

//====================================================================//
//  TREND ENGINE                                                      //
//====================================================================//

void FindSwings(int s, int lookback, SSwings &sw)
  {
   sw.hasH=false; sw.hasH2=false; sw.hasL=false; sw.hasL2=false;
   sw.sh1=0; sw.sh2=0; sw.sl1=0; sw.sl2=0;
   sw.sh1s=-1; sw.sh2s=-1; sw.sl1s=-1; sw.sl2s=-1;

   int foundH=0, foundL=0;
   int last = MathMin(s + lookback, g_window - 3);

   for(int i = s + 2; i <= last; i++)
     {
      bool isSH = g_rates[i].high > g_rates[i-1].high && g_rates[i].high > g_rates[i-2].high &&
                  g_rates[i].high > g_rates[i+1].high && g_rates[i].high > g_rates[i+2].high;
      bool isSL = g_rates[i].low  < g_rates[i-1].low  && g_rates[i].low  < g_rates[i-2].low &&
                  g_rates[i].low  < g_rates[i+1].low  && g_rates[i].low  < g_rates[i+2].low;

      if(isSH && foundH < 2)
        {
         if(foundH == 0) { sw.sh1 = g_rates[i].high; sw.sh1s = i; sw.hasH = true; }
         else            { sw.sh2 = g_rates[i].high; sw.sh2s = i; sw.hasH2 = true; }
         foundH++;
        }
      if(isSL && foundL < 2)
        {
         if(foundL == 0) { sw.sl1 = g_rates[i].low; sw.sl1s = i; sw.hasL = true; }
         else            { sw.sl2 = g_rates[i].low; sw.sl2s = i; sw.hasL2 = true; }
         foundL++;
        }
      if(foundH >= 2 && foundL >= 2)
         break;
     }
  }

void TrendAt(int s, STrend &t, SSwings &sw)
  {
   t.ema20 = g_emaF[s];
   t.ema50 = g_emaS[s];
   t.adx   = g_adx[s];
   t.pdi   = g_pdi[s];
   t.mdi   = g_mdi[s];
   double c = g_rates[s].close;

   FindSwings(s, InpSwingLookback, sw);

   t.swingDir = 0;
   if(sw.hasH2 && sw.hasL2)
     {
      if(sw.sh1 > sw.sh2 && sw.sl1 > sw.sl2)      t.swingDir =  1;   // HH + HL
      else if(sw.sh1 < sw.sh2 && sw.sl1 < sw.sl2) t.swingDir = -1;   // LH + LL
     }

   int dir = 0;
   if(t.ema20 > t.ema50 && c > t.ema50) dir =  1;
   if(t.ema20 < t.ema50 && c < t.ema50) dir = -1;
   if(dir != 0 && t.swingDir != 0 && t.swingDir != dir)
      dir = 0;                                     // EMA and structure disagree -> range

   t.dir = dir;
   if(dir == 0)                               t.state = TR_RANGE;
   else if(dir > 0 && t.adx >= g_adxStrongEff) t.state = TR_UP_STRONG;
   else if(dir > 0)                           t.state = TR_UP;
   else if(t.adx >= g_adxStrongEff)           t.state = TR_DOWN_STRONG;
   else                                       t.state = TR_DOWN;

   t.note = "EMA" + IntegerToString(InpFastEMA) + (t.ema20 > t.ema50 ? ">" : (t.ema20 < t.ema50 ? "<" : "=")) +
            "EMA" + IntegerToString(InpSlowEMA) +
            ", structure " + (t.swingDir > 0 ? "HH+HL" : (t.swingDir < 0 ? "LH+LL" : "mixed")) +
            (t.adx >= g_adxTrendEff ? ", trending" : ", weak/range");
  }

int TrendDirQuick(int s)
  {
   if(s + 1 >= g_window) return(0);
   double eF = g_emaF[s], eS = g_emaS[s], c = g_rates[s].close;
   if(eF > eS && c > eS) return(1);
   if(eF < eS && c < eS) return(-1);
   return(0);
  }

string TrendStateText(int st)
  {
   switch(st)
     {
      case TR_UP_STRONG:  return("UP (strong)");
      case TR_UP:         return("UP (moderate)");
      case TR_RANGE:      return("RANGE");
      case TR_DOWN:       return("DOWN (moderate)");
      case TR_DOWN_STRONG:return("DOWN (strong)");
     }
   return("?");
  }

string SetupTypeName(int t) { return(t == SETUP_REVERSAL ? "reversal" : "continuation"); }

//====================================================================//
//  VALIDATION (the indicator tools a human uses)                     //
//====================================================================//

void AddCheck(SCheck &ck[], int &n, string name, int state, string detail)
  {
   if(n >= 8) return;
   ck[n].name   = name;
   ck[n].state  = state;
   ck[n].detail = detail;
   n++;
  }

void ValidateSetup(const SPattern &pat, const STrend &tr, const SSwings &sw,
                   SCheck &ck[], int &n, int &score, int &maxScore, int &setupType)
  {
   n = 0; score = 0; maxScore = 0;
   int    d   = pat.direction;
   double atr = (g_atr[1] > 0 ? g_atr[1] : 0);
   bool   reversal = (tr.dir != d);          // against trend or in range -> reversal context
   setupType = reversal ? SETUP_REVERSAL : SETUP_CONTINUATION;
   const string dyn = (g_dynOK ? " dyn" : "");

   //--- 1. RSI zone -----------------------------------------------------
   // dynamic mode: limits are percentiles of this symbol's own RSI history,
   // so a trending symbol automatically gets stricter zones than a ranging one
   bool okR = false; string detR = "";
   if(reversal)
     {
      if(d > 0) { okR = (g_rsi[1] <= g_rsiLoEff);  detR = StringFormat("%.1f (limit %.1f%s)",  g_rsi[1], g_rsiLoEff, dyn); }
      else      { okR = (g_rsi[1] >= g_rsiHiEff);  detR = StringFormat("%.1f (limit %.1f%s)",  g_rsi[1], g_rsiHiEff, dyn); }
     }
   else
     {
      if(d > 0) { okR = (g_rsi[1] > g_rsiMidEff);  detR = StringFormat("%.1f (limit >%.1f%s)", g_rsi[1], g_rsiMidEff, dyn); }
      else      { okR = (g_rsi[1] < g_rsiMidEff);  detR = StringFormat("%.1f (limit <%.1f%s)", g_rsi[1], g_rsiMidEff, dyn); }
     }
   AddCheck(ck, n, "RSI", okR ? CK_PASS : CK_FAIL, detR);

   //--- 2. RSI divergence (reversal setups only) ------------------------
   if(reversal && ((d > 0 && sw.hasL2) || (d < 0 && sw.hasH2)))
     {
      bool okD = false; string detD = "";
      if(d > 0)
        {
         double recentLow  = MathMin(g_rates[1].low, sw.sl1);
         double rsiRecent  = MathMax(g_rsi[1], g_rsi[sw.sl1s]);
         okD   = (recentLow < sw.sl2) && (rsiRecent > g_rsi[sw.sl2s]);
         detD  = StringFormat("px LL %.5f<%.5f, RSI %.1f%s>%.1f", recentLow, sw.sl2, rsiRecent,
                              (rsiRecent > g_rsi[sw.sl2s] ? " " : "!"), g_rsi[sw.sl2s]);
        }
      else
        {
         double recentHigh = MathMax(g_rates[1].high, sw.sh1);
         double rsiRecent  = MathMin(g_rsi[1], g_rsi[sw.sh1s]);
         okD   = (recentHigh > sw.sh2) && (rsiRecent < g_rsi[sw.sh2s]);
         detD  = StringFormat("px HH %.5f>%.5f, RSI %.1f%s<%.1f", recentHigh, sw.sh2, rsiRecent,
                              (rsiRecent < g_rsi[sw.sh2s] ? " " : "!"), g_rsi[sw.sh2s]);
        }
      AddCheck(ck, n, "RSI divergence", okD ? CK_PASS : CK_FAIL, detD);
     }
   else
      AddCheck(ck, n, "RSI divergence", CK_NA, reversal ? "needs 2 swings in lookback" : "reversal setups only");

   //--- 3. QQE (modern momentum): smoothed RSI vs adaptive trailing bands -
   //       replaces Stochastic: the cross level adapts to RSI volatility,
   //       filtering the whipsaw crosses a fixed-level Stochastic produces
   bool qqeBuyFresh  = (g_qqeTrend[1] ==  1 && g_qqeTrend[2] == -1) ||
                       (g_qqeTrend[1] ==  1 && g_qqeTrend[2] ==  1 && g_qqeTrend[3] == -1);
   bool qqeSellFresh = (g_qqeTrend[1] == -1 && g_qqeTrend[2] ==  1) ||
                       (g_qqeTrend[1] == -1 && g_qqeTrend[2] == -1 && g_qqeTrend[3] ==  1);
   bool okQ; string detQ;
   if(reversal)
     {
      okQ  = d > 0 ? qqeBuyFresh : qqeSellFresh;
      detQ = StringFormat("smoothed RSI %.1f, trend %s%s", g_qqeRsim[1],
                          (g_qqeTrend[1] > 0 ? "up" : "down"), okQ ? ", fresh cross" : ", no fresh cross");
     }
   else
     {
      bool momUp = (g_qqeTrend[1] ==  1 && g_qqeRsim[1] > g_qqeRsim[2]);
      bool momDn = (g_qqeTrend[1] == -1 && g_qqeRsim[1] < g_qqeRsim[2]);
      okQ  = d > 0 ? momUp : momDn;
      detQ = StringFormat("smoothed RSI %.1f %s, trend %s", g_qqeRsim[1],
                          (g_qqeRsim[1] >= g_qqeRsim[2] ? "rising" : "falling"),
                          (g_qqeTrend[1] > 0 ? "up" : "down"));
     }
   AddCheck(ck, n, "QQE", okQ ? CK_PASS : CK_FAIL, detQ);

   //--- 4. Ehlers Fisher Transform: sharp turn detection -------------------
   //       replaces MACD histogram drift; the transform spikes and reverses
   //       exactly at momentum extremes, giving earlier turn confirmation
   double f1 = g_fish[1], f2 = g_fish[2];
   bool okF; string detF;
   if(reversal)
     {
      bool turnUp = (f1 > f2) && (f2 < 0.0);   // crossing up from lower half
      bool turnDn = (f1 < f2) && (f2 > 0.0);   // crossing down from upper half
      okF  = d > 0 ? turnUp : turnDn;
      detF = StringFormat("fisher %.2f -> %.2f (%s)", f2, f1, okF ? "turn confirmed" : "no turn");
     }
   else
     {
      okF  = d > 0 ? (f1 > f2 && f1 > 0) : (f1 < f2 && f1 < 0);
      detF = StringFormat("fisher %.2f %s zero, %s", f1, (f1 > 0 ? "above" : "below"),
                          (d > 0 ? (f1 > f2 ? "rising" : "flat/falling") : (f1 < f2 ? "falling" : "flat/rising")));
     }
   AddCheck(ck, n, "Fisher", okF ? CK_PASS : CK_FAIL, detF);

   //--- 5. Volume spike ---------------------------------------------------
   double vAvg = AvgVol(InpVolAvgBars, 2);
   bool okV = false; string detV;
   if(vAvg > 0)
     {
      double ratio = (double)g_vol[1] / vAvg;
      okV  = (ratio >= g_volMultEff);   // dynamic: limit = this symbol's own "high interest" percentile
      detV = StringFormat("%.2fx of avg (need %.2fx%s)", ratio, g_volMultEff, dyn);
     }
   else { detV = "no volume data"; }
   AddCheck(ck, n, "Volume", okV ? CK_PASS : CK_FAIL, detV);

   //--- 6. Bollinger rejection (reversal) / EMA20 side (continuation) ----
   bool okB; string detB; string nmB;
   if(reversal)
     {
      nmB = "BB rejection";
      if(d > 0)
        {
         okB  = (g_rates[1].low  < g_bbLo[1]) && (g_rates[1].close > g_bbLo[1]);
         detB = StringFormat("low %s vs lower %s", DoubleToString(g_rates[1].low, _Digits), DoubleToString(g_bbLo[1], _Digits));
        }
      else
        {
         okB  = (g_rates[1].high > g_bbUp[1]) && (g_rates[1].close < g_bbUp[1]);
         detB = StringFormat("high %s vs upper %s", DoubleToString(g_rates[1].high, _Digits), DoubleToString(g_bbUp[1], _Digits));
        }
     }
   else
     {
      nmB = "EMA20 side";
      if(d > 0) { okB = (g_rates[1].close > g_emaF[1]); detB = "close above EMA20"; }
      else      { okB = (g_rates[1].close < g_emaF[1]); detB = "close below EMA20"; }
     }
   AddCheck(ck, n, nmB, okB ? CK_PASS : CK_FAIL, detB);

   //--- 7. Location / ADX -------------------------------------------------
   if(reversal)
     {
      double locDist = InpLocATRFrac * atr;
      bool okL = false; string detL;
      if(d > 0)
        {
         bool nearSwing = sw.hasL && (g_rates[1].low <= sw.sl1 + locDist);
         bool barLow20  = (g_rates[1].low <= LowestLow(2, 20));
         okL  = nearSwing || barLow20;
         detL = nearSwing ? "at recent swing low" : (barLow20 ? "20-bar lowest low" : "mid-air");
        }
      else
        {
         bool nearSwing = sw.hasH && (g_rates[1].high >= sw.sh1 - locDist);
         bool barHi20   = (g_rates[1].high >= HighestHigh(2, 20));
         okL  = nearSwing || barHi20;
         detL = nearSwing ? "at recent swing high" : (barHi20 ? "20-bar highest high" : "mid-air");
        }
      AddCheck(ck, n, "Location", okL ? CK_PASS : CK_FAIL, detL);
     }
   else
     {
      bool okA = (tr.adx >= g_adxTrendEff);
      AddCheck(ck, n, "ADX strength", okA ? CK_PASS : CK_FAIL,
               StringFormat("ADX %.1f need %.1f%s (+DI %.1f / -DI %.1f)", tr.adx, g_adxTrendEff, dyn, tr.pdi, tr.mdi));
     }

   for(int i = 0; i < n; i++)
     {
      if(ck[i].state == CK_NA) continue;
      maxScore++;
      if(ck[i].state == CK_PASS) score++;
     }
  }

//====================================================================//
//  MASTER ANALYSIS OF LAST CLOSED BAR                                //
//====================================================================//

void AnalyzeLastBar()
  {
   g_hasPat = DetectPatternAt(1, g_lastPat);

   TrendAt(1, g_trend, g_swings);

   g_decision     = DEC_NONE;
   g_decisionNote = "";

   if(!g_hasPat || g_lastPat.direction == 0)
     {
      g_checkCount = 0;
      g_score = 0; g_maxScore = 0;
      return;
     }

   ValidateSetup(g_lastPat, g_trend, g_swings, g_checks, g_checkCount, g_score, g_maxScore, g_setupType);

   int need = InpMinScoreValid;
   bool againstStrong = (g_setupType == SETUP_REVERSAL &&
                         (g_trend.state == TR_UP_STRONG || g_trend.state == TR_DOWN_STRONG));
   if(againstStrong)
      need += InpStrongTrendExtra;

   // market-context rule: in a choppy regime momentum breakouts usually fail,
   // UNLESS a volatility squeeze just fired (compression released with force)
   bool chopBreakout = (g_setupType == SETUP_CONTINUATION &&
                        g_chop1 >= InpChopChoppy && !g_squeezeFired);
   if(chopBreakout)
      need += 1;

   if(g_score >= need)
     {
      g_decision = DEC_VALID;
      if(againstStrong)    g_decisionNote = "against strong trend - extra confirmation was required";
      else if(chopBreakout) g_decisionNote = "choppy market - breakout needed extra confirmation";
     }
   else if(g_score >= InpMinScoreWatch)
     {
      g_decision = DEC_WATCH;
      if(againstStrong)    g_decisionNote = "would need " + IntegerToString(need) + "/7 against a strong trend";
      else if(chopBreakout) g_decisionNote = "would need " + IntegerToString(need) + "/7 in a choppy market";
     }
   else
      g_decisionNote = "score below watchlist threshold (" + IntegerToString(InpMinScoreWatch) + ")";

   if(g_decision == DEC_VALID)
      StartForecast();
   else if(g_decision == DEC_WATCH)
     {
      DrawSignalArrow(g_lastPat, false);
      HistoryScanIfNeeded();
      if(InpAlertWatch)
         Notify(AlertText(false));
     }
  }

//====================================================================//
//  FORECAST (entry / SL / TP1 / TP2 / duration / expiry)             //
//====================================================================//

void ResetForecast(SForecast &f)
  {
   f.used = false; f.dir = 0; f.status = FC_ACTIVE; f.tSignal = 0;
   f.patternName = ""; f.strength = 0; f.setupType = SETUP_REVERSAL;
   f.score = 0; f.maxScore = 0;
   f.entry = 0; f.sl = 0; f.tp1 = 0; f.tp2 = 0; f.atr = 0;
   f.expBars = 0; f.expiryBars = 0; f.tExpire = 0; f.barsLeft = 0;
   f.histWins = 0; f.histTotal = 0;
  }

int AutoExpiryBars()
  {
   if(InpSignalExpiryBars > 0) return(InpSignalExpiryBars);
   return(_Period == PERIOD_M5 ? 12 : 8);
  }

// signal validation time: static input, or adaptive to how fast THIS market
// currently moves (a slow market gets more bars to develop, a fast one fewer)
int EffectiveExpiryBars(int expBarsEstimate)
  {
   if(!InpDynamic || !g_dynOK || expBarsEstimate <= 0)
      return(AutoExpiryBars());
   int base = AutoExpiryBars();
   int dyn  = (int)MathRound(1.5 * expBarsEstimate);   // ~1.5x its estimated time to TP1
   if(dyn < 4)        dyn = 4;
   if(dyn > 3 * base) dyn = 3 * base;
   return(dyn);
  }

double SwingLowNear(int s)
  {
   SSwings sw;
   FindSwings(s, InpSwingLookback, sw);
   return(sw.hasL ? sw.sl1 : 0);
  }

double SwingHighNear(int s)
  {
   SSwings sw;
   FindSwings(s, InpSwingLookback, sw);
   return(sw.hasH ? sw.sh1 : 0);
  }

// returns stop-loss price for direction d with signal bar at shift s
double CalcSL(int s, int d)
  {
   double atr = (g_atr[s] > 0 ? g_atr[s] : 0);
   if(atr <= 0) return(0);
   double base;
   if(d > 0)
     {
      double swLo = SwingLowNear(s);
      base = (swLo > 0 ? MathMin(g_rates[s].low, swLo) : g_rates[s].low);
      double sl = base - InpSLATRBuf * atr;
      if(g_rates[s].close - sl > InpSLMaxATR * atr)          // keep stop human-sane
         sl = g_rates[s].low - InpSLATRBuf * atr;
      return(sl);
     }
   double swHi = SwingHighNear(s);
   base = (swHi > 0 ? MathMax(g_rates[s].high, swHi) : g_rates[s].high);
   double sl = base + InpSLATRBuf * atr;
   if(sl - g_rates[s].close > InpSLMaxATR * atr)
      sl = g_rates[s].high + InpSLATRBuf * atr;
   return(sl);
  }

void StartForecast()
  {
   // one active forecast at a time - a human focuses on one trade idea
   if(g_fc.used && g_fc.status == FC_ACTIVE)
     {
      if(g_fc.dir == g_lastPat.direction)
        {
         g_decisionNote = "setup already tracked - forecast kept";
         return;
        }
      g_fc.status  = FC_CANCELLED;
      g_statC++;
      PushRecent("cancelled (opposite signal)");
      ForecastFinishDrawing();
      g_hasDone  = true;
      g_lastDone = g_fc;
      ResetForecast(g_fc);
     }

   int d = g_lastPat.direction;
   double atr = g_atr[1];
   double entry = g_rates[1].close;
   double sl = CalcSL(1, d);
   if(atr <= 0 || sl <= 0 || entry <= 0)
      return;
   double tp1 = (d > 0 ? entry + InpTP1ATR * atr : entry - InpTP1ATR * atr);
   double tp2 = (d > 0 ? entry + InpTP2ATR * atr : entry - InpTP2ATR * atr);

   double speed = AvgSpeed(InpSpeedBars, 1);
   if(speed <= 0) speed = atr * 0.3;
   int expBars = (int)MathCeil(MathAbs(tp1 - entry) / speed);

   ResetForecast(g_fc);
   g_fc.used       = true;
   g_fc.dir        = d;
   g_fc.status     = FC_ACTIVE;
   g_fc.tSignal    = g_rates[1].time;
   g_fc.patternName= g_lastPat.name;
   g_fc.strength   = g_lastPat.strength;
   g_fc.setupType  = g_setupType;
   g_fc.score      = g_score;
   g_fc.maxScore   = g_maxScore;
   g_fc.entry      = entry;
   g_fc.sl         = sl;
   g_fc.tp1        = tp1;
   g_fc.tp2        = tp2;
   g_fc.atr        = atr;
   g_fc.expBars    = expBars;
   g_fc.expiryBars = EffectiveExpiryBars(expBars);
   g_fc.tExpire    = g_rates[1].time + (long)g_fc.expiryBars * PeriodSeconds(_Period);
   g_fc.barsLeft   = g_fc.expiryBars;

   HistoryScanFor(g_lastPat.code, d, g_setupType, g_fc.histWins, g_fc.histTotal);
   UpdateHistNote(g_fc.histWins, g_fc.histTotal);

   DrawSignalArrow(g_lastPat, true);
   ForecastDrawLevels();

   Notify(AlertText(true));
  }

void ForecastUpdate()
  {
   if(!g_fc.used || g_fc.status != FC_ACTIVE)
      return;

   double hi = g_rates[1].high, lo = g_rates[1].low;
   int d = g_fc.dir;

   if(d > 0)
     {
      if(lo <= g_fc.sl)                     { ResolveForecast(FC_SL,  g_fc.sl);      return; }
      if(hi >= g_fc.tp2)                    { ResolveForecast(FC_TP2, g_fc.tp2);     return; }
      if(hi >= g_fc.tp1)                    { ResolveForecast(FC_TP1, g_fc.tp1);     return; }
     }
   else
     {
      if(hi >= g_fc.sl)                     { ResolveForecast(FC_SL,  g_fc.sl);      return; }
      if(lo <= g_fc.tp2)                    { ResolveForecast(FC_TP2, g_fc.tp2);     return; }
      if(lo <= g_fc.tp1)                    { ResolveForecast(FC_TP1, g_fc.tp1);     return; }
     }

   if(g_rates[1].time >= g_fc.tExpire)
     {
      ResolveForecast(FC_EXPIRED, g_rates[1].close);
      return;
     }

   g_fc.barsLeft = (int)((g_fc.tExpire - g_rates[1].time) / PeriodSeconds(_Period));
   if(g_fc.barsLeft < 0) g_fc.barsLeft = 0;
  }

void ResolveForecast(int status, double price)
  {
   g_fc.status    = status;
   g_fc.barsLeft  = 0;

   if(status == FC_TP1 || status == FC_TP2) { g_statW++; PushRecent("TP hit"); }
   else if(status == FC_SL)                 { g_statL++; PushRecent("SL hit"); }
   else if(status == FC_EXPIRED)            { g_statX++; PushRecent("expired"); }
   else                                     { g_statC++; PushRecent("cancelled"); }

   DrawResolveLabel(status, price);

   g_hasDone  = true;
   g_lastDone = g_fc;
   ResetForecast(g_fc);

   Print("SmartTrader forecast resolved: ", StatusText(status), " at ", DoubleToString(price, _Digits));
  }

string StatusText(int st)
  {
   switch(st)
     {
      case FC_ACTIVE:    return("ACTIVE");
      case FC_TP1:       return("TP1 HIT");
      case FC_TP2:       return("TP2 HIT");
      case FC_SL:        return("SL HIT");
      case FC_EXPIRED:   return("EXPIRED");
      case FC_CANCELLED: return("CANCELLED");
     }
   return("?");
  }

void PushRecent(string label)
  {
   string s = TimeToString(TimeCurrent(), TIME_MINUTES) + " " + label;
   for(int i = MathMin(g_recentN, MAX_RECENT - 1); i > 0; i--) g_recent[i] = g_recent[i-1];
   g_recent[0] = s;
   if(g_recentN < MAX_RECENT) g_recentN++;
  }

//====================================================================//
//  PAST-HISTORY QUICK CHECK                                          //
//====================================================================//

void HistoryScanIfNeeded()
  {
   if(g_histKey != g_lastPat.code || g_histKeyD != g_lastPat.direction || g_histKeyT != g_setupType)
     {
      double w = 0, t = 0;
      HistoryScanFor(g_lastPat.code, g_lastPat.direction, g_setupType, w, t);
      UpdateHistNote(w, t);
     }
  }

void UpdateHistNote(double w, double t)
  {
   if(t < 1)
      g_histNote = "past " + IntegerToString(InpHistoryBars) + " bars: no comparable setups";
   else
     {
      double rate = 100.0 * w / t;
      g_histNote = "past " + IntegerToString(InpHistoryBars) + " bars: " +
                   DoubleToString(w, 0) + "/" + DoubleToString(t, 0) +
                   " (" + DoubleToString(rate, 0) + "%) reached TP1 first";
     }
  }

// replay every occurrence of the same setup over recent history:
// entry = signal-bar close, SL/TP = same formulas as the live forecast,
// outcome = TP1 hit before SL within the expiry window (SL first = loss, conservative)
void HistoryScanFor(int code, int dir, int setupType, double &wins, double &total)
  {
   g_histKey = code; g_histKeyD = dir; g_histKeyT = setupType;
   wins = 0; total = 0;

   int maxExp = 3 * AutoExpiryBars();   // upper bound of the adaptive expiry
   int start  = MathMin(InpHistoryBars, g_window - maxExp - 3);

   for(int s = start; s >= 3; s--)
     {
      SPattern p;
      if(!DetectPatternAt(s, p))
         continue;
      if(p.code != code || p.direction != dir)
         continue;

      int tdir = TrendDirQuick(s);
      bool isRev = (tdir != dir);
      if((setupType == SETUP_REVERSAL) != isRev)
         continue;

      double atr = g_atr[s];
      if(atr <= 0)
         continue;
      double entry = g_rates[s].close;
      double sl    = CalcSL(s, dir);
      double tp1   = (dir > 0 ? entry + InpTP1ATR * atr : entry - InpTP1ATR * atr);
      if(sl <= 0)
         continue;

      // per-signal adaptive expiry, same formula as the live forecast
      double speedH = AvgSpeed(InpSpeedBars, s);
      int    expH   = EffectiveExpiryBars(speedH > 0 ? (int)MathCeil(MathAbs(tp1 - entry) / speedH) : 0);

      bool resolved  = false;
      int  stop      = MathMax(1, s - expH);
      for(int j = s - 1; j >= stop; j--)
        {
         if(dir > 0)
           {
            if(g_rates[j].low <= sl)   { resolved = true; break; }   // SL first = loss (conservative)
            if(g_rates[j].high >= tp1) { wins++; resolved = true; break; }
           }
         else
           {
            if(g_rates[j].high >= sl)  { resolved = true; break; }
            if(g_rates[j].low  <= tp1) { wins++; resolved = true; break; }
           }
        }
      if(resolved) total++;
     }
  }

//====================================================================//
//  DRAWING                                                           //
//====================================================================//

void DrawSignalArrow(const SPattern &pat, bool strong)
  {
   datetime t = g_rates[pat.shift].time;
   string name = OBJ_PREFIX + "SIG_" + IntegerToString((long)t);
   double price;
   if(pat.direction > 0)
     {
      price = g_rates[pat.shift].low - 0.4 * g_atr[pat.shift];
      if(ObjectCreate(0, name, OBJ_ARROW, 0, t, price))
        {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 233);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP);
         ObjectSetInteger(0, name, OBJPROP_COLOR, strong ? clrLime : clrDarkGray);
        }
     }
   else
     {
      price = g_rates[pat.shift].high + 0.4 * g_atr[pat.shift];
      if(ObjectCreate(0, name, OBJ_ARROW, 0, t, price))
        {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 234);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
         ObjectSetInteger(0, name, OBJPROP_COLOR, strong ? clrTomato : clrDarkGray);
        }
     }
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void ForecastDrawLevels()
  {
   string names[4] = { OBJ_PREFIX+"LVL_ENTRY", OBJ_PREFIX+"LVL_SL", OBJ_PREFIX+"LVL_TP1", OBJ_PREFIX+"LVL_TP2" };
   bool active = (g_fc.used && g_fc.status == FC_ACTIVE);

   for(int i = 0; i < 4; i++)
      if(ObjectFind(0, names[i]) >= 0)
         ObjectDelete(0, names[i]);

   if(!active)
      return;

   color cEntry = clrDodgerBlue, cSL = clrRed, cTP = clrLime;
   HLine(names[0], g_fc.entry, cEntry, STYLE_SOLID,  "Entry");
   HLine(names[1], g_fc.sl,    cSL,    STYLE_SOLID,  "Stop loss");
   HLine(names[2], g_fc.tp1,   cTP,    STYLE_DASH,   "TP1");
   HLine(names[3], g_fc.tp2,   cTP,    STYLE_DASH,   "TP2");
  }

void HLine(string name, double price, color clr, int style, string tip)
  {
   if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString(0, name, OBJPROP_TEXT, tip);
  }

void ForecastFinishDrawing()
  {
   // convenience wrapper: resolve-label for the forecast that just finished
   DrawResolveLabel(g_fc.status, g_rates[1].close);
  }

void DrawResolveLabel(int status, double price)
  {
   datetime t = g_rates[1].time;
   string name = OBJ_PREFIX + "RES_" + IntegerToString((long)t);
   string txt = "";
   color clr = clrGray;
   if(status == FC_TP1)          { txt = "TP1 OK";   clr = clrLime; }
   if(status == FC_TP2)          { txt = "TP2 OK";   clr = clrLime; }
   if(status == FC_SL)           { txt = "SL X";     clr = clrTomato; }
   if(status == FC_EXPIRED)      { txt = "expired";  clr = clrGold; }
   if(status == FC_CANCELLED)    { txt = "cancelled";clr = clrGray; }
   if(txt == "") return;
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
     {
      ObjectSetString(0, name, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
     }
  }

//====================================================================//
//  ALERTS                                                            //
//====================================================================//

string AlertText(bool validated)
  {
   string head = validated ? "VALIDATED" : "WATCHLIST";
   string dir  = (g_lastPat.direction > 0 ? "BUY" : "SELL");
   string body = head + " " + dir + " setup | " + _Symbol + " " + StringSubstr(EnumToString(_Period), 7) +
                 " | " + g_lastPat.name + " (" + SetupTypeName(g_setupType) + ")" +
                 " | score " + IntegerToString(g_score) + "/" + IntegerToString(g_maxScore);

   if(validated && g_fc.used)
     {
      body += "\nEntry " + DoubleToString(g_fc.entry, _Digits) +
              "  SL " + DoubleToString(g_fc.sl, _Digits) +
              "  TP1 " + DoubleToString(g_fc.tp1, _Digits) +
              "  TP2 " + DoubleToString(g_fc.tp2, _Digits) +
              "\n~" + IntegerToString(g_fc.expBars) + " bars to TP1, valid " +
              IntegerToString(g_fc.expiryBars) + " bars (until " +
              TimeToString(g_fc.tExpire, TIME_DATE|TIME_MINUTES) + ")" +
              "\n" + g_histNote;
     }
   return("SmartTrader: " + body);
  }

void Notify(string text)
  {
   Print(text);
   if(InpAlertPopup) Alert(text);
   if(InpAlertPush)
     {
      if(!SendNotification(text))
         Print("SmartTrader: push notification failed, error ", GetLastError());
     }
   if(InpAlertEmail)
     {
      if(!SendMail("SmartTrader signal", text))
         Print("SmartTrader: e-mail failed, error ", GetLastError());
     }
  }

//====================================================================//
//  PANEL                                                             //
//====================================================================//

string Marker(int state)
  {
   if(state == CK_PASS) return("OK ");
   if(state == CK_FAIL) return("no ");
   return("-- ");
  }

color DirColor(int d)
  {
   if(d > 0) return(clrLime);
   if(d < 0) return(clrTomato);
   return(clrGold);
  }

string PanelCheckLine(int from, int to)
  {
   string s = "";
   for(int i = from; i < to && i < g_checkCount; i++)
     {
      if(s != "") s += "  ";
      s += g_checks[i].name + " " + Marker(g_checks[i].state);
     }
   return(s);
  }

string FormingCandleText()
  {
   if(g_window < 2) return("");
   double b = Body(0), r = Range(0);
   if(r <= 0) return("forming candle: flat");
   int pct = (int)MathRound(100.0 * b / r);
   string mood = BullBar(0) ? "bullish" : (BearBar(0) ? "bearish" : "flat");
   string wick = "";
   if(LoWick(0) > 2.0 * MathMax(b, 0.1 * r)) wick = ", long lower wick (possible hammer forming)";
   if(UpWick(0) > 2.0 * MathMax(b, 0.1 * r)) wick = ", long upper wick (possible shooting star forming)";
   return("forming candle: " + mood + ", body " + IntegerToString(pct) + "% of range" + wick);
  }

string CountdownText()
  {
   datetime cur = iTime(_Symbol, _Period, 0);
   long left = (long)(cur + PeriodSeconds(_Period) - TimeCurrent());
   if(left < 0) left = 0;
   long mm = left / 60, ss = left % 60;
   return("candle closes in " + IntegerToString((int)mm) + ":" +
          (ss < 10 ? "0" : "") + IntegerToString((int)ss));
  }

void PanelRender()
  {
   string rows[MAX_ROWS];
   color  rc[MAX_ROWS];
   int n = 0;

   //--- header ---------------------------------------------------------
   rows[n] = "SmartTrader v1.2 - Phase 1: Market Watch & Forecast"; rc[n] = clrGold;      n++;
   rows[n] = _Symbol + "  " + StringSubstr(EnumToString(_Period), 7) +
             "  spread " + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts" +
             (g_statusMsg != "" ? "   [" + g_statusMsg + "]" : "");
   rc[n] = clrSilver; n++;

   if(!g_dataOK)
     {
      rows[n] = "Waiting for data..."; rc[n] = clrGray; n++;
      PanelShow(rows, rc, n);
      return;
     }

   //--- trend ----------------------------------------------------------
   rows[n] = "TREND  " + TrendStateText(g_trend.state) +
             "  ADX " + DoubleToString(g_trend.adx, 1) +
             "  +DI " + DoubleToString(g_trend.pdi, 1) + " / -DI " + DoubleToString(g_trend.mdi, 1);
   rc[n] = DirColor(g_trend.dir); n++;
   rows[n] = "EMA20 " + DoubleToString(g_trend.ema20, _Digits) +
             (g_trend.ema20 > g_trend.ema50 ? " > " : (g_trend.ema20 < g_trend.ema50 ? " < " : " = ")) +
             "EMA50 " + DoubleToString(g_trend.ema50, _Digits) +
             "  |  " + (g_trend.note != "" ? g_trend.note : "");
   rc[n] = clrSilver; n++;
   double atr1 = g_atr[1];
   double spd  = AvgSpeed(50, 1);
   rows[n] = "ATR(" + IntegerToString(InpATRPeriod) + ") " +
             DoubleToString(atr1 / _Point, 0) + " pts  |  avg speed " +
             DoubleToString(spd / _Point, 1) + " pts/bar" +
             (g_dynOK ? (g_volRegime > 0 ? "  |  volatility: EXPANDING" :
                        (g_volRegime < 0 ? "  |  volatility: CONTRACTING" : "  |  volatility: normal")) : "");
   rc[n] = clrSilver; n++;
   rows[n] = g_dynNote;
   rc[n]  = (g_dynOK ? clrDeepSkyBlue : clrGray); n++;
   rows[n] = "context: CHOP " + DoubleToString(g_chop1, 1) +
             (g_chop1 >= InpChopChoppy ? " (choppy/range)" :
              (g_chop1 <= InpChopTrend ? " (trending)" : " (transition)")) +
             "  |  squeeze " + g_squeezeState;
   rc[n]  = (g_chop1 >= InpChopChoppy ? clrGold : (g_chop1 <= InpChopTrend ? clrLime : clrSilver)); n++;

   //--- candle read ------------------------------------------------------
   rows[n] = "LAST CLOSED CANDLE"; rc[n] = clrGold; n++;
   if(g_hasPat && g_lastPat.direction != 0)
     {
      string ptxt = g_lastPat.name + " (" + SetupTypeName(g_setupType) + ", strength " +
                    IntegerToString(g_lastPat.strength) + "/3) -> " +
                    (g_lastPat.direction > 0 ? "bullish" : "bearish") + " read";
      rows[n] = ptxt; rc[n] = DirColor(g_lastPat.direction); n++;
     }
   else
     {
      rows[n] = "no qualified reversal/continuation pattern"; rc[n] = clrSilver; n++;
     }
   rows[n] = FormingCandleText() + "  |  " + CountdownText(); rc[n] = clrSilver; n++;

   //--- validation --------------------------------------------------------
   rows[n] = "VALIDATION (indicator tools)"; rc[n] = clrGold; n++;
   if(g_hasPat && g_checkCount > 0)
     {
      rows[n] = PanelCheckLine(0, 3);  rc[n] = clrSilver; n++;
      rows[n] = PanelCheckLine(3, 6);  rc[n] = clrSilver; n++;
      rows[n] = PanelCheckLine(6, 8);  rc[n] = clrSilver; n++;
      string dec;
      if(g_decision == DEC_VALID)      dec = "VALIDATED - forecast issued";
      else if(g_decision == DEC_WATCH) dec = "WATCHLIST - not confirmed yet";
      else                             dec = "ignored";
      rows[n] = "Score " + IntegerToString(g_score) + "/" + IntegerToString(g_maxScore) +
                " -> " + dec +
                (g_decisionNote != "" ? "  (" + g_decisionNote + ")" : "");
      rc[n] = (g_decision == DEC_VALID ? clrLime : (g_decision == DEC_WATCH ? clrGold : clrSilver));
      n++;
     }
   else
     {
      rows[n] = "waiting for a setup to validate"; rc[n] = clrSilver; n++;
     }

   //--- forecast -----------------------------------------------------------
   rows[n] = "FORECAST"; rc[n] = clrGold; n++;
   if(g_fc.used && g_fc.status == FC_ACTIVE)
     {
      rows[n] = (g_fc.dir > 0 ? "BUY " : "SELL ") + g_fc.patternName + "  since " +
                TimeToString(g_fc.tSignal, TIME_MINUTES) + "  score " +
                IntegerToString(g_fc.score) + "/" + IntegerToString(g_fc.maxScore);
      rc[n] = DirColor(g_fc.dir); n++;
      rows[n] = "Entry " + DoubleToString(g_fc.entry, _Digits) +
                "  SL " + DoubleToString(g_fc.sl, _Digits) +
                " (" + DoubleToString(MathAbs(g_fc.entry - g_fc.sl) / _Point, 0) + " pts)" +
                "  TP1 " + DoubleToString(g_fc.tp1, _Digits) +
                "  TP2 " + DoubleToString(g_fc.tp2, _Digits);
      rc[n] = clrSilver; n++;
      rows[n] = "~" + IntegerToString(g_fc.expBars) + " bars to TP1  |  expires in " +
                IntegerToString(g_fc.barsLeft) + " bars (" +
                TimeToString(g_fc.tExpire, TIME_MINUTES) + ")";
      rc[n] = clrSilver; n++;
      rows[n] = g_histNote; rc[n] = clrSilver; n++;
     }
   else if(g_hasDone)
     {
      rows[n] = "last forecast: " + StatusText(g_lastDone.status) + "  " +
                (g_lastDone.dir > 0 ? "BUY " : "SELL ") + g_lastDone.patternName +
                "  " + TimeToString(g_lastDone.tSignal, TIME_MINUTES);
      rc[n] = DirColor(g_lastDone.dir); n++;
      rows[n] = "recent: " + RecentText(); rc[n] = clrSilver; n++;
     }
   else
     {
      rows[n] = "no active forecast"; rc[n] = clrSilver; n++;
     }

   rows[n] = "tracked this session: " + IntegerToString(g_statW) + "W / " +
             IntegerToString(g_statL) + "L / " + IntegerToString(g_statX) + "X / " +
             IntegerToString(g_statC) + "C"; rc[n] = clrSilver; n++;

   rows[n] = "Phase 1: observation only - no orders are placed"; rc[n] = clrGray; n++;

   PanelShow(rows, rc, n);
  }

string RecentText()
  {
   string s = "";
   for(int i = 0; i < g_recentN; i++)
     {
      if(s != "") s += " / ";
      s += g_recent[i];
     }
   return(s);
  }

void PanelShow(string &rows[], color &rc[], int n)
  {
   int rowH   = InpFontSize + 6;
   int width  = (int)MathMax(430, 78 * InpFontSize);
   int height = n * rowH + 16;

   string bg = OBJ_PREFIX + "BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,30');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, bg, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 6);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 6);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, height);

   int anchor = ANCHOR_LEFT_UPPER;
   if(InpPanelCorner == CORNER_RIGHT_UPPER) anchor = ANCHOR_RIGHT_UPPER;
   if(InpPanelCorner == CORNER_LEFT_LOWER)  anchor = ANCHOR_LEFT_LOWER;
   if(InpPanelCorner == CORNER_RIGHT_LOWER) anchor = ANCHOR_RIGHT_LOWER;

   for(int i = 0; i < MAX_ROWS; i++)
     {
      string nm = OBJ_PREFIX + "R" + IntegerToString(i);
      if(i >= n)
        {
         if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
         continue;
        }
      if(ObjectFind(0, nm) < 0)
        {
         ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
         ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpFontSize);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, nm, OBJPROP_ANCHOR, anchor);
        }
      ObjectSetInteger(0, nm, OBJPROP_CORNER, InpPanelCorner);
      int x = 14, y;
      if(InpPanelCorner == CORNER_LEFT_LOWER || InpPanelCorner == CORNER_RIGHT_LOWER)
         y = height - 12 - i * rowH;
      else
         y = 12 + i * rowH;
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, nm, OBJPROP_TEXT, rows[i]);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, rc[i]);
     }
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                  SmartTrader.mq5 |
//|            SmartTrader - human-style market watch & forecast     |
//|            Phase 1 : Observation only - NO orders are placed     |
//+------------------------------------------------------------------+
//| Works like a human trader sitting at the chart, in 3 stages:     |
//|  1. DETECT  - reads every closed M5/M15 candle (20+ patterns),   |
//|     the trend, and validates the setup with a modern engine      |
//|     (QQE, Fisher, Choppiness, squeeze, adaptive percentiles).    |
//|  2. PROVE  - a validated setup is only a CANDIDATE. Like a human |
//|     doubting his reversal, it waits up to N bars for the market  |
//|     to prove it: close beyond the pattern extreme = true, close  |
//|     beyond the opposite extreme = FALSE reversal, else expired.  |
//|  3. PROJECT - only a PROVEN idea gets a forward-horizon forecast:|
//|     measured-move targets from the prior leg (floor 1R/2R),      |
//|     expected bars to TP1 from net directional speed, a horizon   |
//|     end time, and a live "on schedule / behind" progress check.  |
//| Phase 2 (separate release) will place and manage the orders.     |
//+------------------------------------------------------------------+
#property copyright   "SmartTrader"
#property link        "https://github.com/hamamun/SmartTrader"
#property version     "1.50"
#property description "SmartTrader Phase 1 - Market Watch & Forecast."
#property description "Reads candles and trend like a human; validation thresholds self-adapt"
#property description "to each symbol and the current market context (dynamic percentiles)."
#property description "Publishes entry/SL/TP/forecast-duration/expiry + history win-rate."
#property description "Observation only: this version never sends an order."

//====================================================================//
//  INPUTS - only what a trader actually chooses                      //
//====================================================================//
//  Every technical calibration (indicator periods, levels, percentiles,
//  ATR multipliers) is self-adapting or tuned inside the EA. A trader
//  concentrates on trading, not on settings.

enum ENUM_ST_STYLE
  {
   ST_CONSERVATIVE = 0,   // Conservative - fewer, high-conviction signals
   ST_BALANCED     = 1,   // Balanced (recommended)
   ST_AGGRESSIVE   = 2    // Aggressive - more signals, tighter stops
  };

input group "=== Trading style ==="
input ENUM_ST_STYLE InpStyle = ST_BALANCED;   // How SmartTrader should judge the market

input group "=== Alerts ==="
input bool InpAlertPopup = true;              // Popup alert on validated signal
input bool InpAlertPush  = false;             // Push notification (phone)
input bool InpAlertEmail = false;             // E-mail alert
input bool InpAlertWatch = false;             // Also alert on watchlist signals

input group "=== Panel ==="
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;  // Panel corner
input int              InpFontSize    = 9;                  // Panel font size

input group "=== Advanced (leave as is if unsure) ==="
input bool InpDynamic          = true;        // Self-adapting thresholds (recommended)
input int  InpSignalExpiryBars = 0;           // Signal valid for N bars (0 = auto)

//====================================================================//
//  CONSTANTS / TYPES                                                 //
//====================================================================//

#define OBJ_PREFIX     "ST_"
#define MAX_ROWS       30
#define MAX_RECENT     5

//--- forecast stability (human-like patience)
#define FLIP_MIN_AGE   3        // min bars of an active forecast before an opposite flip may replace it
#define COOLDOWN_BARS  2        // pause (bars) after a forecast resolves before a new one may start

//--- proof window (stage 2: a candidate must prove itself)
#define CONFIRM_BARS   3        // bars the market gets to prove a reversal true or false

//--- forward projection (stage 3: measured move of the prior leg)
#define RETR_TP1       0.382    // first projection: 38.2% retrace of the prior leg
#define RETR_TP2       0.618    // full projection: 61.8% retrace of the prior leg

//--- engine tuning (internal: self-adapting, deliberately not user inputs)
#define EMA_FAST          20     // fast EMA
#define EMA_SLOW          50     // slow EMA
#define ADX_PERIOD        14
#define RSI_PERIOD        14
#define BB_PERIOD         20     // Bollinger period
#define BB_DEV            2.0    // Bollinger deviation
#define ATR_PERIOD        14
#define VOL_AVG_BARS      20
#define SWING_LOOKBACK    60
#define SPEED_BARS        50     // bars used to estimate market speed
#define FISHER_LEN        9      // Ehlers Fisher lookback
#define CHOP_PERIOD       14     // Choppiness Index period
#define CHOP_CHOPPY       61.8   // CHOP >= this -> choppy/range regime
#define CHOP_TREND        38.2   // CHOP <= this -> trending regime
#define QQE_FACTOR        4.236  // QQE trailing factor (phi squared)
#define HISTORY_BARS      500    // past-history replay depth

//--- static fallback limits (used only until the dynamic layer has learned)
#define RSI_FALL_LO       35.0
#define RSI_FALL_HI       65.0
#define ADX_FALL_TREND    20.0
#define ADX_FALL_STRONG   25.0
#define VOL_FALL_MULT     1.3
#define LOC_ATR_FRAC      0.5    // location tolerance around a swing

//--- dynamic-learning calibration
#define DYN_LOOKBACK      300    // bars used to learn the symbol's behavior
#define DYN_RSI_PCT_LO    15.0   // RSI oversold percentile
#define DYN_RSI_PCT_HI    85.0   // RSI overbought percentile
#define DYN_ADX_PCT_TREND 60.0   // ADX percentile for "trending"
#define DYN_ADX_PCT_STRONG 75.0  // ADX percentile for "strong trend"
#define DYN_VOL_PCT       70.0   // volume "real interest" percentile
#define DYN_ATR_EXPAND    1.30   // ATR vs median: expanding
#define DYN_ATR_SHRINK    0.75   // ATR vs median: contracting

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

// stage-2 candidate: a validated setup that still waits for market proof
struct SPending
  {
   bool              used;
   int               dir;
   datetime          tDetect;
   string            patternName;
   int               code;
   int               strength;
   int               setupType;
   int               score;
   int               maxScore;
   double            zoneHigh;    // reversal zone extremes: proof triggers
   double            zoneLow;
   double            legHigh;     // prior leg extremes: measured-move projection
   double            legLow;
   double            atr;
   int               confirmBars;
   int               confirmLeft;
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

SPending  g_pend;                // stage-2 candidate waiting for proof
string    g_pendNote  = "";      // last candidate outcome
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

//--- style-driven behaviour (set once in OnInit, per trading style)
int      g_minScoreValid = 4;
int      g_minScoreWatch = 3;
int      g_strongExtra   = 1;
double   g_slBufATR      = 0.3;
double   g_slMaxATR      = 2.5;
double   g_tp1R          = 1.0;   // TP1 as R-multiple of the ACTUAL stop distance
double   g_tp2R          = 2.0;   // TP2 as R-multiple
datetime g_cooldownUntil = 0;     // stability: no new forecast before this time

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

string StyleName()
  {
   if(InpStyle == ST_CONSERVATIVE) return("Conservative");
   if(InpStyle == ST_AGGRESSIVE)   return("Aggressive");
   return("Balanced");
  }

// one human choice -> coherent parameter set (strictness + stop/target profile)
void ApplyStyle()
  {
   switch(InpStyle)
     {
      case ST_CONSERVATIVE:
         g_minScoreValid = 5; g_minScoreWatch = 4; g_strongExtra = 1;
         g_slBufATR = 0.40; g_slMaxATR = 3.0;
         g_tp1R = 1.5; g_tp2R = 3.0;      // wider targets: fewer, higher-conviction trades
         break;
      case ST_AGGRESSIVE:
         g_minScoreValid = 3; g_minScoreWatch = 3; g_strongExtra = 1;
         g_slBufATR = 0.25; g_slMaxATR = 2.0;
         g_tp1R = 0.8; g_tp2R = 1.6;      // quick scalps
         break;
      default:                        // balanced
         g_minScoreValid = 4; g_minScoreWatch = 3; g_strongExtra = 1;
         g_slBufATR = 0.30; g_slMaxATR = 2.5;
         g_tp1R = 1.0; g_tp2R = 2.0;      // risk one to make one / two
     }
  }

int OnInit()
  {
   if(_Period != PERIOD_M5 && _Period != PERIOD_M15)
     {
      Alert("SmartTrader: attach this EA to an M5 or M15 chart only. Current chart: ",
            EnumToString(_Period));
      return(INIT_FAILED);
     }

   hEmaFast = iMA(_Symbol, _Period, EMA_FAST, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, EMA_SLOW, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, _Period, RSI_PERIOD, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, ATR_PERIOD);
   hADX     = iADX(_Symbol, _Period, ADX_PERIOD);
   hBands   = iBands(_Symbol, _Period, BB_PERIOD, 0, BB_DEV, PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hRSI==INVALID_HANDLE ||
      hATR==INVALID_HANDLE     || hADX==INVALID_HANDLE     || hBands==INVALID_HANDLE)
     {
      Print("SmartTrader: failed to create indicator handles, error ", GetLastError());
      return(INIT_FAILED);
     }

   ApplyStyle();

   ResetForecast(g_fc);
   ResetForecast(g_lastDone);
   for(int i=0; i<MAX_RECENT; i++) g_recent[i]="";

   EventSetTimer(1);
   Print("SmartTrader v1.50 Phase 1 started on ", _Symbol, " ", EnumToString(_Period),
         " | style: ", StyleName(),
         " | dynamic thresholds: ", (InpDynamic ? "ON" : "OFF"),
         " - market watch & forecast only, no orders will be placed.");

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

   // 2. stage 2: does the market prove or kill the pending candidate?
   CandidateUpdate();

   // 3. read the last closed candle like a human trader (stage 1: detect)
   AnalyzeLastBar();

   // 4. render
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

   int want = MathMax(300, MathMin(HISTORY_BARS + 10, available - 3));
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
      double longB  = rsim - QQE_FACTOR * dar;
      double shortB = rsim + QQE_FACTOR * dar;
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
   // NOTE series indexing: index 0 = newest, so from bar s the available
   // OLDER bars are s..n-1  ->  lookback must be clamped to (n - s)
   if(n < FISHER_LEN + 2)
      return;
   double valPrev = 0, fishPrev = 0;
   for(int a = 0; a < n; a++)
     {
      int s = n - 1 - a;
      int len = MathMin(FISHER_LEN, n - s);
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
   int per = MathMin(CHOP_PERIOD, g_window - 2);
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
   g_rsiLoEff     = RSI_FALL_LO;
   g_rsiHiEff     = RSI_FALL_HI;
   g_rsiMidEff    = 50.0;
   g_adxTrendEff  = ADX_FALL_TREND;
   g_adxStrongEff = ADX_FALL_STRONG;
   g_volMultEff   = VOL_FALL_MULT;
   g_atrRatio     = 1.0;
   g_volRegime    = 0;
   g_dynOK        = false;
   g_dynNote      = "thresholds: static (from inputs)";

   if(!InpDynamic)
      return;

   int n = MathMin(DYN_LOOKBACK, g_window - 3);
   if(n < 100)
     {
      g_dynNote = "dynamic: learning needs more history (" + IntegerToString(n) + "/" +
                  IntegerToString(DYN_LOOKBACK) + " bars) - using static limits";
      return;
     }

   double tmp[];
   ArrayResize(tmp, n);

   //--- RSI zones from the symbol's own RSI distribution
   for(int i = 0; i < n; i++) tmp[i] = g_rsi[1 + i];
   g_rsiLoEff  = PercentileOf(tmp, n, DYN_RSI_PCT_LO);
   g_rsiHiEff  = PercentileOf(tmp, n, DYN_RSI_PCT_HI);
   g_rsiMidEff = PercentileOf(tmp, n, 50.0);

   //--- ADX trend / strong levels
   for(int i = 0; i < n; i++) tmp[i] = g_adx[1 + i];
   g_adxTrendEff  = PercentileOf(tmp, n, DYN_ADX_PCT_TREND);
   g_adxStrongEff = PercentileOf(tmp, n, DYN_ADX_PCT_STRONG);

   //--- volume: percentile of "volume vs its own 20-bar average" ratios
   double rat[];
   ArrayResize(rat, n);
   for(int i = 0; i < n; i++)
     {
      double a = AvgVol(VOL_AVG_BARS, 2 + i);
      rat[i] = (a > 0 ? (double)g_vol[1 + i] / a : 0);
     }
   double pv = PercentileOf(rat, n, DYN_VOL_PCT);
   g_volMultEff = (pv > 0 ? pv : VOL_FALL_MULT);

   //--- volatility regime: current ATR vs its own median
   for(int i = 0; i < n; i++) tmp[i] = g_atr[1 + i];
   double medAtr = PercentileOf(tmp, n, 50.0);
   if(medAtr > 0)
      g_atrRatio = g_atr[1] / medAtr;
   if(g_atrRatio >= DYN_ATR_EXPAND)      g_volRegime =  1;
   else if(g_atrRatio <= DYN_ATR_SHRINK) g_volRegime = -1;

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

// Kaufman-style path efficiency: net progress / total path travelled.
// ~1.0 = clean directional move, ~0.2 = choppy two-sided market.
// A human knows a choppy market needs far more TIME to reach the same target.
double EfficiencyRatio(int s, int n)
  {
   if(s + n + 1 >= g_window) n = g_window - s - 2;
   if(n < 5) return(1.0);
   double net  = MathAbs(g_rates[s].close - g_rates[s + n].close);
   double path = 0;
   for(int i = s; i < s + n; i++)
      path += MathAbs(g_rates[i].close - g_rates[i + 1].close);
   return(path > 0 ? net / path : 0);
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

   FindSwings(s, SWING_LOOKBACK, sw);

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

   t.note = "EMA" + IntegerToString(EMA_FAST) + (t.ema20 > t.ema50 ? ">" : (t.ema20 < t.ema50 ? "<" : "=")) +
            "EMA" + IntegerToString(EMA_SLOW) +
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
   double vAvg = AvgVol(VOL_AVG_BARS, 2);
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
      double locDist = LOC_ATR_FRAC * atr;
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

   int need = g_minScoreValid;
   bool againstStrong = (g_setupType == SETUP_REVERSAL &&
                         (g_trend.state == TR_UP_STRONG || g_trend.state == TR_DOWN_STRONG));
   if(againstStrong)
      need += g_strongExtra;

   // market-context rule: in a choppy regime momentum breakouts usually fail,
   // UNLESS a volatility squeeze just fired (compression released with force)
   bool chopBreakout = (g_setupType == SETUP_CONTINUATION &&
                        g_chop1 >= CHOP_CHOPPY && !g_squeezeFired);
   if(chopBreakout)
      need += 1;

   // a continuation call inside a structureless (mixed) market is exactly the
   // whipsaw a human avoids - demand one extra confirmation
   bool mixedContinuation = (g_setupType == SETUP_CONTINUATION && g_trend.swingDir == 0);
   if(mixedContinuation)
      need += 1;

   // flip protection: never build a new idea against a protected active forecast
   bool   flipBlocked = false;
   string gateNote    = "";
   if(g_fc.used && g_fc.status == FC_ACTIVE && g_lastPat.direction != g_fc.dir)
     {
      int age = (int)((g_rates[1].time - g_fc.tSignal) / PeriodSeconds(_Period));
      if(age < FLIP_MIN_AGE || g_score < need + 1)
        {
         flipBlocked = true;
         gateNote = "active " + (g_fc.dir > 0 ? "BUY" : "SELL") + " forecast protected - opposite setup ignored";
        }
     }

   if(g_score >= need && !flipBlocked)
     {
      g_decision = DEC_VALID;              // stage 1 passed -> candidate opens; stage 2 (proof) decides
      if(againstStrong)          g_decisionNote = "against strong trend - extra confirmation was required";
      else if(chopBreakout)      g_decisionNote = "choppy market - breakout needed extra confirmation";
      else if(mixedContinuation) g_decisionNote = "mixed structure - continuation needed extra confirmation";
     }
   else if(g_score >= need && flipBlocked)
     {
      g_decision = DEC_WATCH;              // gated: shown on watchlist, not acted on
      g_decisionNote = gateNote;
     }
   else if(g_score >= g_minScoreWatch)
     {
      g_decision = DEC_WATCH;
      if(againstStrong)          g_decisionNote = "would need " + IntegerToString(need) + "/7 against a strong trend";
      else if(chopBreakout)      g_decisionNote = "would need " + IntegerToString(need) + "/7 in a choppy market";
      else if(mixedContinuation) g_decisionNote = "would need " + IntegerToString(need) + "/7 in mixed structure";
     }
   else
      g_decisionNote = "score below watchlist threshold (" + IntegerToString(g_minScoreWatch) + ")";

   if(g_decision == DEC_VALID)
      CandidateOpen();                     // NOT a forecast yet - the market must prove it first
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
   int dyn  = 2 * expBarsEstimate;                     // ~2x its estimated time to TP1
   if(dyn < base)    dyn = base;                       // never shorter than the default window
   if(dyn > 4 * base) dyn = 4 * base;
   return(dyn);
  }

double SwingLowNear(int s)
  {
   SSwings sw;
   FindSwings(s, SWING_LOOKBACK, sw);
   return(sw.hasL ? sw.sl1 : 0);
  }

double SwingHighNear(int s)
  {
   SSwings sw;
   FindSwings(s, SWING_LOOKBACK, sw);
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
      double sl = base - g_slBufATR * atr;
      if(g_rates[s].close - sl > g_slMaxATR * atr)          // keep stop human-sane
         sl = g_rates[s].low - g_slBufATR * atr;
      return(sl);
     }
   double swHi = SwingHighNear(s);
   base = (swHi > 0 ? MathMax(g_rates[s].high, swHi) : g_rates[s].high);
   double sl = base + g_slBufATR * atr;
   if(sl - g_rates[s].close > g_slMaxATR * atr)
      sl = g_rates[s].high + g_slBufATR * atr;
   return(sl);
  }

// how many bars a pattern spans (its "reversal zone" for proof triggers)
int PatternSpan(int code)
  {
   switch(code)
     {
      case PC_MORNING_STAR:   case PC_EVENING_STAR:
      case PC_THREE_SOLDIERS: case PC_THREE_CROWS:      return(3);
      case PC_BULL_ENGULF:    case PC_BEAR_ENGULF:
      case PC_PIERCING:       case PC_DARK_CLOUD:
      case PC_TWEEZER_BOTTOM: case PC_TWEEZER_TOP:
      case PC_HARAMI_BULL:    case PC_HARAMI_BEAR:      return(2);
     }
   return(1);
  }

//====================================================================//
//  STAGE 2: CANDIDATE - "is this reversal true or false?"            //
//====================================================================//
//  A validated setup is NOT yet a forecast. Like a human who spotted
//  a hammer but waits for proof, SmartTrader opens a candidate and
//  gives the market CONFIRM_BARS bars to speak:
//    close beyond the pattern's extreme  -> TRUE  -> build projection
//    close beyond the opposite extreme   -> FALSE -> candidate killed
//    neither within the window           -> expired (never happened)

void CandidateOpen()
  {
   int span = PatternSpan(g_lastPat.code);
   int s    = g_lastPat.shift;
   int end  = s + span - 1;
   if(end + 2 >= g_window)
      return;
   int len = MathMin(SWING_LOOKBACK, g_window - end - 1);

   SPending p;
   p.used        = true;
   p.dir         = g_lastPat.direction;
   p.tDetect     = g_rates[s].time;
   p.patternName = g_lastPat.name;
   p.code        = g_lastPat.code;
   p.strength    = g_lastPat.strength;
   p.setupType   = g_setupType;
   p.score       = g_score;
   p.maxScore    = g_maxScore;
   p.zoneHigh    = HighestHigh(s, span);
   p.zoneLow     = LowestLow(s, span);
   double wHi = HighestHigh(end, len), wLo = LowestLow(end, len);
   p.legHigh  = MathMax(wHi, p.zoneHigh);      // prior leg (projection base)
   p.legLow   = MathMin(wLo, p.zoneLow);
   p.atr         = g_atr[s];
   p.confirmBars = CONFIRM_BARS;
   p.confirmLeft = CONFIRM_BARS;

   bool refreshed = g_pend.used;
   g_pend    = p;
   g_pendNote = refreshed ? "candidate refreshed with a newer " + g_lastPat.name : "";

   DrawSignalArrow(g_lastPat, true);
   HistoryScanIfNeeded();
   if(InpAlertWatch)
      Notify(AlertText(false));
  }

void CandidateUpdate()
  {
   if(!g_pend.used)
      return;

   int    d  = g_pend.dir;
   double c1 = g_rates[1].close;
   bool confirmed = (d > 0 ? c1 > g_pend.zoneHigh : c1 < g_pend.zoneLow);
   bool failed    = (d > 0 ? c1 < g_pend.zoneLow  : c1 > g_pend.zoneHigh);

   if(failed)   // the human's "this reversal was fake" moment
     {
      g_pendNote = "candidate FAILED (false reversal) at " + TimeToString(TimeCurrent(), TIME_MINUTES);
      g_pend.used = false;
      return;
     }

   if(confirmed)
     {
      // entry-time discipline: one idea at a time, flips need real conviction
      if(g_fc.used && g_fc.status == FC_ACTIVE)
        {
         if(g_fc.dir == d)
           {
            g_pendNote = "candidate proved but a forecast already tracks this direction";
            g_pend.used = false;
            return;
           }
         int age = (int)((g_rates[1].time - g_fc.tSignal) / PeriodSeconds(_Period));
         if(age >= FLIP_MIN_AGE && g_pend.score >= g_minScoreValid + 1)
           {
            g_fc.status = FC_CANCELLED;
            g_statC++;
            PushRecent("cancelled (proved flip)");
            DrawResolveLabel(FC_CANCELLED, g_rates[1].close);
            g_hasDone = true;
            g_lastDone = g_fc;
            ResetForecast(g_fc);
           }
         else
           {
            g_pendNote = "candidate proved but the active forecast is protected";
            g_pend.used = false;
            return;
           }
        }
      if(TimeCurrent() < g_cooldownUntil)
         return;                        // wait out the cooldown, keep the proof
      StartForecast();
      g_pend.used = false;
      return;
     }

   g_pend.confirmLeft--;
   if(g_pend.confirmLeft <= 0)
     {
      g_pendNote = "candidate expired (no proof in " + IntegerToString(g_pend.confirmBars) +
                   " bars) at " + TimeToString(TimeCurrent(), TIME_MINUTES);
      g_pend.used = false;
     }
  }

void DrawConfirmLabel(int d)
  {
   datetime t = g_rates[1].time;
   string name = OBJ_PREFIX + "CNF_" + IntegerToString((long)t);
   double price = (d > 0 ? g_rates[1].low - 0.8 * g_atr[1] : g_rates[1].high + 0.8 * g_atr[1]);
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
     {
      ObjectSetString(0, name, OBJPROP_TEXT, "PROVED");
      ObjectSetInteger(0, name, OBJPROP_COLOR, d > 0 ? clrLime : clrTomato);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

void StartForecast()
  {
   if(!g_pend.used)
      return;

   int    d     = g_pend.dir;
   double atr   = g_atr[1];
   double entry = g_rates[1].close;              // entry at the PROOF bar close, like a human acting on confirmation
   double sl    = CalcSL(1, d);
   if(atr <= 0 || sl <= 0 || entry <= 0)
     {
      g_pendNote = "candidate dropped (bad data at proof)";
      return;
     }
   double slDist = MathAbs(entry - sl);

   // spread sanity: costs must stay noise vs the risk
   double spreadPrice = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(slDist < 2.0 * spreadPrice)
     {
      g_pendNote = "candidate dropped: stop too tight vs spread (" +
                   DoubleToString(slDist / _Point, 0) + " pts)";
      return;
     }

   //--- FORWARD PROJECTION -------------------------------------------
   // where may price go within the horizon? A human measures the prior
   // leg and projects its retracement; the R-multiples are the floor.
   double legSize = g_pend.legHigh - g_pend.legLow;
   double tp1, tp2;
   if(legSize > 0)
     {
      if(d > 0) { tp1 = g_pend.legLow  + RETR_TP1 * legSize;  tp2 = g_pend.legLow  + RETR_TP2 * legSize; }
      else      { tp1 = g_pend.legHigh - RETR_TP1 * legSize;  tp2 = g_pend.legHigh - RETR_TP2 * legSize; }
     }
   else { tp1 = entry; tp2 = entry; }
   double r1 = (d > 0 ? entry + 1.0 * slDist : entry - 1.0 * slDist);
   double r2 = (d > 0 ? entry + 2.0 * slDist : entry - 2.0 * slDist);
   tp1 = (d > 0 ? MathMax(tp1, r1) : MathMin(tp1, r1));   // reward at least 1R
   tp2 = (d > 0 ? MathMax(tp2, r2) : MathMin(tp2, r2));   // and 2R

   //--- how long the move may take: net directional speed
   double speed = AvgSpeed(SPEED_BARS, 1);
   if(speed <= 0) speed = atr * 0.3;
   double er       = EfficiencyRatio(1, SPEED_BARS);
   double dirSpeed = MathMax(speed * MathMax(er, 0.25), _Point);
   int expBars = (int)MathCeil(MathAbs(tp1 - entry) / dirSpeed);
   int capBars = 3 * AutoExpiryBars();
   if(expBars < 3)       expBars = 3;
   if(expBars > capBars) expBars = capBars;

   ResetForecast(g_fc);
   g_fc.used       = true;
   g_fc.dir        = d;
   g_fc.status     = FC_ACTIVE;
   g_fc.tSignal    = g_rates[1].time;
   g_fc.patternName= g_pend.patternName;
   g_fc.strength   = g_pend.strength;
   g_fc.setupType  = g_pend.setupType;
   g_fc.score      = g_pend.score;
   g_fc.maxScore   = g_pend.maxScore;
   g_fc.entry      = entry;
   g_fc.sl         = sl;
   g_fc.tp1        = tp1;
   g_fc.tp2        = tp2;
   g_fc.atr        = atr;
   g_fc.expBars    = expBars;
   g_fc.expiryBars = EffectiveExpiryBars(expBars);
   g_fc.tExpire    = (datetime)(g_rates[1].time + (long)g_fc.expiryBars * PeriodSeconds(_Period));
   g_fc.barsLeft   = g_fc.expiryBars;

   HistoryScanFor(g_pend.code, d, g_pend.setupType, g_fc.histWins, g_fc.histTotal);
   UpdateHistNote(g_fc.histWins, g_fc.histTotal);

   DrawSignalArrowAt(1, d, true);
   DrawConfirmLabel(d);
   ForecastDrawLevels();

   g_pendNote = "candidate PROVED -> forecast issued at " + TimeToString(TimeCurrent(), TIME_MINUTES);
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

   // stability: brief pause before any new forecast (a human steps back after a call resolves)
   g_cooldownUntil = (datetime)(g_rates[1].time + COOLDOWN_BARS * PeriodSeconds(_Period));

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
      g_histNote = "past " + IntegerToString(HISTORY_BARS) + " bars: no comparable setups";
   else
     {
      double rate = 100.0 * w / t;
      g_histNote = "past " + IntegerToString(HISTORY_BARS) + " bars: " +
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
   int start  = MathMin(HISTORY_BARS, g_window - maxExp - 3);

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
      if(sl <= 0)
         continue;
      double slDist = MathAbs(entry - sl);
      if(slDist <= 0)
         continue;
      double tp1   = (dir > 0 ? entry + g_tp1R * slDist : entry - g_tp1R * slDist);

      // per-signal adaptive expiry, same formula as the live forecast
      double speedH = AvgSpeed(SPEED_BARS, s);
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

void DrawSignalArrowAt(int shift, int dir, bool strong)
  {
   datetime t = g_rates[shift].time;
   string name = OBJ_PREFIX + "SIG_" + IntegerToString((long)t);
   double price;
   if(dir > 0)
     {
      price = g_rates[shift].low - 0.4 * g_atr[shift];
      if(ObjectCreate(0, name, OBJ_ARROW, 0, t, price))
        {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 233);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP);
         ObjectSetInteger(0, name, OBJPROP_COLOR, strong ? clrLime : clrDarkGray);
        }
     }
   else
     {
      price = g_rates[shift].high + 0.4 * g_atr[shift];
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

void DrawSignalArrow(const SPattern &pat, bool strong)
  {
   DrawSignalArrowAt(pat.shift, pat.direction, strong);
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
   string tf = StringSubstr(EnumToString(_Period), 7);
   if(validated)   // stage 3: a PROVEN idea -> full forward forecast
      return("SmartTrader FORECAST: " + (g_fc.dir > 0 ? "BUY " : "SELL ") + g_fc.patternName +
             " PROVED | " + _Symbol + " " + tf +
             " | score " + IntegerToString(g_fc.score) + "/" + IntegerToString(g_fc.maxScore) +
             "\nEntry " + DoubleToString(g_fc.entry, _Digits) +
             "  SL " + DoubleToString(g_fc.sl, _Digits) +
             "  TP1 " + DoubleToString(g_fc.tp1, _Digits) +
             "  TP2 " + DoubleToString(g_fc.tp2, _Digits) +
             "\nHorizon " + IntegerToString(g_fc.expiryBars) + " bars (~" +
             IntegerToString(g_fc.expBars) + " to TP1), until " +
             TimeToString(g_fc.tExpire, TIME_DATE | TIME_MINUTES) +
             "\nProjection: measured move of the prior leg, floor 1R/2R" +
             "\n" + g_histNote);
   // stage 1/2 message: candidate waiting for proof
   string dir  = (g_lastPat.direction > 0 ? "BUY" : "SELL");
   return("SmartTrader CANDIDATE: " + dir + " " + g_lastPat.name +
          " (" + SetupTypeName(g_setupType) + ") | " + _Symbol + " " + tf +
          " | score " + IntegerToString(g_score) + "/" + IntegerToString(g_maxScore) +
          " | proof needed: close " + (g_lastPat.direction > 0 ? "above " : "below ") +
          DoubleToString(g_lastPat.direction > 0 ? HighestHigh(g_lastPat.shift, PatternSpan(g_lastPat.code))
                                                 : LowestLow(g_lastPat.shift, PatternSpan(g_lastPat.code)), _Digits) +
          " within " + IntegerToString(CONFIRM_BARS) + " bars");
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
   rows[n] = "SmartTrader v1.5 - Phase 1: Market Watch & Forecast  |  style: " + StyleName(); rc[n] = clrGold;      n++;
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
   rows[n] = "ATR(" + IntegerToString(ATR_PERIOD) + ") " +
             DoubleToString(atr1 / _Point, 0) + " pts  |  avg speed " +
             DoubleToString(spd / _Point, 1) + " pts/bar" +
             (g_dynOK ? (g_volRegime > 0 ? "  |  volatility: EXPANDING" :
                        (g_volRegime < 0 ? "  |  volatility: CONTRACTING" : "  |  volatility: normal")) : "");
   rc[n] = clrSilver; n++;
   rows[n] = g_dynNote;
   rc[n]  = (g_dynOK ? clrDeepSkyBlue : clrGray); n++;
   rows[n] = "context: CHOP " + DoubleToString(g_chop1, 1) +
             (g_chop1 >= CHOP_CHOPPY ? " (choppy/range)" :
              (g_chop1 <= CHOP_TREND ? " (trending)" : " (transition)")) +
             "  |  squeeze " + g_squeezeState;
   rc[n]  = (g_chop1 >= CHOP_CHOPPY ? clrGold : (g_chop1 <= CHOP_TREND ? clrLime : clrSilver)); n++;

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
      if(g_decision == DEC_VALID)      dec = "VALIDATED - candidate opened, awaiting proof";
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

   //--- candidate (stage 2) --------------------------------------------------
   rows[n] = "CANDIDATE - PROOF WINDOW"; rc[n] = clrGold; n++;
   if(g_pend.used)
     {
      rows[n] = (g_pend.dir > 0 ? "BUY " : "SELL ") + g_pend.patternName + " detected " +
                TimeToString(g_pend.tDetect, TIME_MINUTES) + "  score " +
                IntegerToString(g_pend.score) + "/" + IntegerToString(g_pend.maxScore) +
                "  - proof left " + IntegerToString(g_pend.confirmLeft) + "/" +
                IntegerToString(g_pend.confirmBars) + " bars";
      rc[n] = DirColor(g_pend.dir); n++;
      rows[n] = "true if close " + (g_pend.dir > 0 ? "> " : "< ") +
                DoubleToString(g_pend.dir > 0 ? g_pend.zoneHigh : g_pend.zoneLow, _Digits) +
                "   |   FALSE if close " + (g_pend.dir > 0 ? "< " : "> ") +
                DoubleToString(g_pend.dir > 0 ? g_pend.zoneLow : g_pend.zoneHigh, _Digits);
      rc[n] = clrSilver; n++;
     }
   else
     {
      rows[n] = (g_pendNote == "" ? "none - validated setups appear here for proof" : "last: " + g_pendNote);
      rc[n] = (StringFind(g_pendNote, "FAILED") >= 0 ? clrTomato :
              (StringFind(g_pendNote, "PROVED") >= 0 ? clrLime : clrSilver));
      n++;
     }

   //--- forecast (stage 3) -----------------------------------------------------
   rows[n] = "FORECAST - FORWARD HORIZON"; rc[n] = clrGold; n++;
   if(g_fc.used && g_fc.status == FC_ACTIVE)
     {
      int fage = (int)((TimeCurrent() - g_fc.tSignal) / PeriodSeconds(_Period));
      rows[n] = (g_fc.dir > 0 ? "BUY " : "SELL ") + g_fc.patternName + "  age " +
                IntegerToString(fage) + "/" + IntegerToString(g_fc.expiryBars) + " bars  score " +
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
      // live schedule check: is the move following the projected path?
      double denom = (g_fc.dir > 0 ? g_fc.tp1 - g_fc.entry : g_fc.entry - g_fc.tp1);
      if(denom > 0)
        {
         double progA = (g_fc.dir > 0 ? (g_rates[0].close - g_fc.entry)
                                      : (g_fc.entry - g_rates[0].close)) / denom;
         int elapsed = (int)((TimeCurrent() - g_fc.tSignal) / PeriodSeconds(_Period));
         double progE = (g_fc.expBars > 0 ? (double)elapsed / g_fc.expBars : 0.0);
         if(progA < 0) progA = 0;
         if(progA > 1) progA = 1;
         if(progE > 1) progE = 1;
         bool onTrack = (progA >= progE * 0.7);
         rows[n] = "horizon " + IntegerToString(g_fc.expiryBars) + " bars  |  schedule: " +
                   (onTrack ? "on track" : "behind") + " (progress " +
                   DoubleToString(100.0 * progA, 0) + "% vs " +
                   DoubleToString(100.0 * progE, 0) + "% expected)";
         rc[n] = (onTrack ? clrLime : clrGold); n++;
        }
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

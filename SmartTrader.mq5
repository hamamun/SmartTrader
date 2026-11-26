//+------------------------------------------------------------------+
//|                                                  SmartTrader.mq5 |
//|         SmartTrader - Mi1 (the brain): perceive, map, predict,   |
//|         select. Forecast-only build - NO orders are placed.      |
//+------------------------------------------------------------------+
//| Spec: STBuild.md (frozen Mi1 contract)                           |
//|  F1 M5/M15 charts only - else "out of range, return to M5/M15".  |
//|  F2 One instance computes BOTH timeframes, each on own nature.   |
//|  F3 Market state first: OPEN / CLOSED(opens XX:XX server) /      |
//|     HOLD - forecasting only when OPEN.                           |
//|  F4 Symbol type: forex/metals/energy/index/crypto/other.         |
//|  F5 All parameters auto from symbol-type profile (expert-tuned). |
//|  Step1 Trend: swing structure (eyes) + EMA20/50 + CHOP + ATR.    |
//|  Step2 Precision map: zones from 5 sources, confluence strength, |
//|     volume grade, VWAP, IF/THEN per zone, risk lines, flip rule. |
//|  Step3 Verdict: living scenario tree (base/alt/stall), numbers   |
//|     sourced from map/fib/ATR - nothing hardcoded.                |
//|  Step4 Branch execution: candle events at zones select branch,   |
//|     re-validate, declare entry/SL/TP/lot/duration/management.    |
//|  UI: main panel (status/trend/declaration/events) + details      |
//|     panel right of main (ShowDetails). Exactly 3 inputs.         |
//+------------------------------------------------------------------+
#property copyright   "SmartTrader"
#property link        "https://github.com/hamamun/SmartTrader"
#property version     "2.10"
#property description "SmartTrader Mi1 - the brain (Steps 1-4). Forecast only, no orders."
#property description "Reads M5+M15 on their own nature, draws the precision map, formulates"
#property description "a living scenario tree, and declares a full plan when the market"
#property description "proves a branch. Market state and symbol type checked first."

#include <Trade\Trade.mqh>

//====================================================================//
//  INPUTS (Mi2: exactly 5)                                           //
//====================================================================//

input double InpRiskPercent = 1.0;   // Risk % per trade (suggested lot sizing)
input bool   InpAlertPopup  = true;  // Popup alert on declaration
input bool   InpShowDetails = false; // Show details panel (right of main panel)

enum EAutoMode { AUTO_BOTH = 0,      // both timeframes trade
                 AUTO_M5_ONLY = 1,   // only M5 trades
                 AUTO_M15_ONLY = 2   // only M15 trades
               };
input bool      InpAutoTrade = false;      // AUTOTRADING master switch
input EAutoMode InpAutoMode  = AUTO_BOTH;  // AUTOTRADING scope

//====================================================================//
//  CONSTANTS                                                         //
//====================================================================//

#define OBJ_P        "ST1_"
#define PANEL_FONT   10
#define MAIN_W       420
#define BARS_WANT    420
#define BARS_MIN     260

// colors
#define CLR_HEAD     clrGold
#define CLR_UP       clrLime
#define CLR_DN       clrTomato
#define CLR_ATT      clrGold
#define CLR_NEUT     clrSilver
#define CLR_DIM      clrDarkGray
#define CLR_ENTRY    clrWhite
#define CLR_BG       C'15,19,28'
#define CLR_BORDER   clrDimGray

// symbol types
#define SYM_FOREX    0
#define SYM_METALS   1
#define SYM_ENERGY   2
#define SYM_INDEX    3
#define SYM_CRYPTO   4
#define SYM_OTHER    5

// market states
#define MS_OPEN      0
#define MS_CLOSED    1
#define MS_HOLD      2

// zone tags (bitmask)
#define ZG_SWING     1
#define ZG_LIFE      2
#define ZG_SESS      4
#define ZG_ROUND     8
#define ZG_FIB       16
#define ZG_VWAP      32
#define ZG_BROKEN    64

// trend fields
#define TC_WEAK      1
#define TC_MOD       2
#define TC_STRONG    3
#define TRG_BOX      0
#define TRG_TRANS    1
#define TRG_TREND    2
#define TA_YOUNG     0
#define TA_MATURE    1
#define TA_OLD       2
#define TH_SHALLOW   0
#define TH_NORMAL    1
#define TH_DEEP      2

// branch status
#define BR_WAIT      0
#define BR_TRACK     1
#define BR_EXEC      2
#define BR_DEAD      3

// declaration outcomes
#define DO_ACTIVE    0
#define DO_TP1       1
#define DO_TP2       2
#define DO_SL        3
#define DO_TIMEOUT   4
#define DO_SUPERSEDE 5
#define DO_CLOSED    6
#define DO_BE        7
#define DO_TRAIL     8

// structural constants (market convention, F5-source-a)
#define FIB_R1       0.382
#define FIB_R2       0.500
#define FIB_R3       0.618
#define FIB_E1       1.272
#define FIB_E2       1.618
#define CHOP_BOX     61.8
#define CHOP_TREND   38.2

// Mi2: the hands
#define MAGIC_BASE   20261126     // bot identity; per-TF = BASE+1 (M5) / +2 (M15)
#define TRADES_FILE  "SmartTrader_Mi2_plans.bin"

//====================================================================//
//  SYMBOL TYPE PROFILE (F4 + F5)                                     //
//====================================================================//

struct SProfile
  {
   int               type;            // SYM_*
   string            typeName;
   double            zoneATR;         // zone thickness, x ATR
   double            swingSig;        // swing pivot significance, x ATR
   double            roundGrid;       // primary round-number grid (price units)
   double            roundGrid2;      // secondary grid (0 = none)
   bool              asianRange;      // compute Asian session range (forex)
   int               asianEndHour;    // server hour when Asian range completes
   int               maxZones;        // zones kept on the map
   double            breakBuf;        // SL buffer beyond zone, x ATR
   int               stallM5;         // stall window, M5 bars
   int               stallM15;        // stall window, M15 bars
  };

SProfile g_pr;

void InitProfile(int type)
  {
   g_pr.type       = type;
   g_pr.asianRange = false;
   g_pr.asianEndHour = 7;
   switch(type)
     {
      case SYM_FOREX:
         g_pr.typeName="forex";  g_pr.zoneATR=0.45; g_pr.swingSig=0.20;
         g_pr.roundGrid=0.0100;  g_pr.roundGrid2=0.0050;
         g_pr.asianRange=true;   g_pr.maxZones=6;
         g_pr.breakBuf=0.30;     g_pr.stallM5=12;  g_pr.stallM15=8;
         break;
      case SYM_METALS:
         g_pr.typeName="metals"; g_pr.zoneATR=0.50; g_pr.swingSig=0.25;
         g_pr.roundGrid=5.0;     g_pr.roundGrid2=2.5;
         g_pr.maxZones=6;        g_pr.breakBuf=0.35;
         g_pr.stallM5=12;        g_pr.stallM15=8;
         break;
      case SYM_ENERGY:
         g_pr.typeName="energy"; g_pr.zoneATR=0.55; g_pr.swingSig=0.25;
         g_pr.roundGrid=1.0;     g_pr.roundGrid2=0.5;
         g_pr.maxZones=6;        g_pr.breakBuf=0.35;
         g_pr.stallM5=12;        g_pr.stallM15=8;
         break;
      case SYM_INDEX:
         g_pr.typeName="index";  g_pr.zoneATR=0.50; g_pr.swingSig=0.22;
         g_pr.roundGrid=100.0;   g_pr.roundGrid2=50.0;
         g_pr.maxZones=6;        g_pr.breakBuf=0.30;
         g_pr.stallM5=12;        g_pr.stallM15=8;
         break;
      case SYM_CRYPTO:
         g_pr.typeName="crypto"; g_pr.zoneATR=0.60; g_pr.swingSig=0.30;
         g_pr.roundGrid=1000.0;  g_pr.roundGrid2=500.0;
         g_pr.maxZones=6;        g_pr.breakBuf=0.40;
         g_pr.stallM5=14;        g_pr.stallM15=10;
         break;
      default:
         g_pr.typeName="other";  g_pr.zoneATR=0.50; g_pr.swingSig=0.25;
         g_pr.roundGrid=0.0;     g_pr.roundGrid2=0.0;
         g_pr.maxZones=6;        g_pr.breakBuf=0.35;
         g_pr.stallM5=12;        g_pr.stallM15=8;
     }
  }

int ClassifySymbol(string sym)
  {
   string s = sym;
   StringToUpper(s);
   // metals
   if(StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0 ||
      StringFind(s,"XAG")>=0 || StringFind(s,"SILVER")>=0 ||
      StringFind(s,"XPT")>=0 || StringFind(s,"XPD")>=0)
      return(SYM_METALS);
   // energy
   if(StringFind(s,"OIL")>=0 || StringFind(s,"WTI")>=0 || StringFind(s,"BRENT")>=0 ||
      StringFind(s,"NGAS")>=0 || StringFind(s,"NATGAS")>=0 || StringFind(s,"COAL")>=0 ||
      StringFind(s,"HEATING")>=0)
      return(SYM_ENERGY);
   // crypto
   if(StringFind(s,"BTC")>=0 || StringFind(s,"ETH")>=0 || StringFind(s,"XRP")>=0 ||
      StringFind(s,"SOL")>=0 || StringFind(s,"DOGE")>=0 || StringFind(s,"ADA")>=0 ||
      StringFind(s,"LTC")>=0 || StringFind(s,"DOT")>=0 || StringFind(s,"BCH")>=0 ||
      StringFind(s,"XLM")>=0 || StringFind(s,"AVAX")>=0 || StringFind(s,"LINK")>=0)
      return(SYM_CRYPTO);
   // indices
   if(StringFind(s,"UK100")>=0 || StringFind(s,"US30")>=0 || StringFind(s,"US100")>=0 ||
      StringFind(s,"US500")>=0 || StringFind(s,"NAS")>=0  || StringFind(s,"SPX")>=0  ||
      StringFind(s,"GER40")>=0 || StringFind(s,"DE40")>=0 || StringFind(s,"DE30")>=0 ||
      StringFind(s,"DAX")>=0  || StringFind(s,"JPN225")>=0 || StringFind(s,"FTSE")>=0 ||
      StringFind(s,"DJI")>=0  || StringFind(s,"NDX")>=0   || StringFind(s,"NIKKEI")>=0 ||
      StringFind(s,"HK50")>=0 || StringFind(s,"AUS200")>=0 || StringFind(s,"EU50")>=0 ||
      StringFind(s,"STOXX")>=0 || StringFind(s,"CAC")>=0  || StringFind(s,"IBEX")>=0 ||
      StringFind(s,"SMI")>=0  || StringFind(s,"ASX")>=0   || StringFind(s,"TSX")>=0 ||
      StringFind(s,"DOW")>=0  || StringFind(s,"SP500")>=0)
      return(SYM_INDEX);
   // forex fallback: 6 alphabetic chars (suffix-stripped)
   string letters="";
   for(int i=0; i<StringLen(sym); i++)
     {
      ushort c = StringGetCharacter(sym, i);
      if((c>='A' && c<='Z') || (c>='a' && c<='z'))
         letters += CharToString((uchar)c);
     }
   // broker suffixes (EURUSDm, EURUSD.micro...) leave extra letters: accept a
   // short tail (<=3) after the 6-letter pair
   if(StringLen(letters)>=6 && StringLen(letters)<=9)
      return(SYM_FOREX);
   return(SYM_OTHER);
  }

// risk-based suggested lot - shared by the brain (forecast) and the hands
double SuggestLotG(double slDist)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickVal <= 0 || slDist <= 0) return(0);
   double lossPerLot = slDist / tickSize * tickVal;
   if(lossPerLot <= 0) return(0);
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lot = riskMoney / lossPerLot;
   double lmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lstep= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lstep > 0) lot = MathFloor(lot/lstep)*lstep;
   if(lot < lmin) lot = lmin;
   if(lot > lmax) lot = lmax;
   int ld = 0; double s = (lstep > 0 ? lstep : 0.01);
   while(s < 1.0 && ld < 8) { s *= 10.0; ld++; }
   return(NormalizeDouble(lot, ld));
  }

//====================================================================//
//  MARKET STATE (F3)                                                 //
//====================================================================//

int      g_msState    = MS_CLOSED;
datetime g_msNextOpen = 0;
string   g_msNote     = "checking...";

void UpdateMarketState()
  {
   long tmode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tmode==SYMBOL_TRADE_MODE_DISABLED)
     { g_msState=MS_HOLD;  g_msNote="trading disabled by broker"; return; }
   if(tmode==SYMBOL_TRADE_MODE_CLOSEONLY)
     { g_msState=MS_HOLD;  g_msNote="close-only mode (broker)";  return; }

   datetime now   = TimeCurrent();
   long     secs  = (long)now % 86400;
   datetime dayStart = (datetime)((long)now - secs);
   MqlDateTime dt;
   TimeToStruct(now, dt);

   bool anySession=false, open=false;
   datetime nextOpen=0;

   for(int d=0; d<7 && !open; d++)
     {
      int dow = (dt.day_of_week + d) % 7;
      for(uint i=0; i<16; i++)
        {
         datetime sFrom = 0, sTo = 0;
         if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, sFrom, sTo))
            break;
         anySession = true;
         long from = (long)sFrom % 86400;
         long to   = (long)sTo   % 86400;
         if(to <= from)                       // overnight session
           {
            if(d==0 && (secs >= from || secs < to))
               open = true;                   // today's late-evening part or after-midnight part
           }
         else if(d==0 && secs >= from && secs < to)
            open = true;
         if(nextOpen==0)
           {
            datetime st = (datetime)((long)dayStart + (long)d*86400 + from);
            if(st > now)
               nextOpen = st;
           }
        }
     }

   if(!anySession)
     { g_msState=MS_OPEN; g_msNote="24/7 market"; return; }
   if(open)
     { g_msState=MS_OPEN; g_msNote=""; return; }

   g_msState    = MS_CLOSED;
   g_msNextOpen = nextOpen;
   g_msNote     = (nextOpen>0 ?
                   "market closed - opens " + TimeToString(nextOpen, TIME_DATE|TIME_MINUTES) + " (server time)" :
                   "market closed - broker schedule unavailable");
  }

//====================================================================//
//  SHARED STRUCTS                                                    //
//====================================================================//

struct SZone
  {
   double            price;
   double            thick;
   int               tags;          // ZG_* bitmask
   string            tagStr;
   int               touches;
   double            drama;         // avg volume ratio at touch bars
   double            recencyF;      // 0.1..1
   double            strength;      // 0..100
   double            slForBuy;      // stop level for longs from this zone
   double            slForSell;     // stop level for shorts from this zone
   bool              isLifeline;
   int               brokenDir;     // +1 broken upward, -1 broken downward, 0 none (flip rule)
  };

struct SBranch
  {
   bool              used;
   string            name;
   int               dir;           // +1 / -1 / 0 (stall)
   double            target1;
   double            target2;
   double            invalid;       // scenario invalidation price
   int               bars;          // estimated bars to target
   int               status;        // BR_*
  };

struct SDecl
  {
   bool              active;
   int               tfSlot;        // 0=M5 1=M15
   int               dir;
   datetime          tDeclare;
   string            branch;
   double            entry;
   double            sl;
   double            tp1;           // THE living target (updated by candle health)
   double            lots;
   double            remLots;       // remaining size after partial
   double            bestFav;       // best favorable excursion since entry
   int               tpUpdates;     // how many times the candles moved the target
   int               durBars;       // the ONLY clock: estimated bars to the destination
   int               outcome;       // DO_*
   int               barsAge;
   bool              beArmed;
   double            beLevel;       // +1R lock line: entry +/- 5% of risk (room), else entry
   double            risk0;         // ORIGINAL risk distance (entry->SL at birth) - trail/lock/R math
  };

//====================================================================//
//  PER-TIMEFRAME BRAIN (Steps 1-4, one per TF, independent)          //
//====================================================================//

class CTFBrain
  {
public:
   ENUM_TIMEFRAMES   tf;
   string            tfName;
   int               slot;
   datetime          lastBar;
   datetime          lastThink;    // once-per-closed-candle gate
   bool              ready;

   int               hE20;
   int               hE50;
   int               hATR;

   MqlRates          r[];
   double            e20[];
   double            e50[];
   double            atr[];
   long              v[];
   int               n;
   double            volAvg;

   // swings (newest first)
   double            swHiP[];
   int               swHiB[];
   int               nHi;
   double            swLoP[];
   int               swLoB[];
   int               nLo;

   // trend (Step 1)
   int               tDir;
   int               tConf;        // TC_*
   int               tRegime;      // TRG_*
   int               tAge;         // TA_*
   int               tAgeBars;
   int               tHealth;      // TH_*
   double            chop;
   double            vwap;
   double            speed;        // avg |close delta| per bar
   string            trendLine;

   // fib leg (map + targets source)
   double            legLow;
   double            legHigh;
   int               legDir;

   // map (Step 2)
   SZone             zones[];
   int               nZones;
   int               atZone;       // index of zone price sits in, else -1
   string            locLine;

   // verdict tree (Step 3)
   SBranch           br[3];        // 0=base 1=alt 2=stall
   string            trackLine;

   // declaration (Step 4)
   SDecl             decl;

   void Configure(ENUM_TIMEFRAMES a_tf, string a_name, int a_slot)
     {
      tf      = a_tf;
      tfName  = a_name;
      slot    = a_slot;
      lastBar = 0; lastThink = 0;
      ready   = false;
      hE20    = iMA(_Symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      hE50    = iMA(_Symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      hATR    = iATR(_Symbol, tf, 14);
      ZeroDecl();
      tDir=0; tConf=TC_WEAK; tRegime=TRG_TRANS; tAge=TA_YOUNG; tAgeBars=0;
      tHealth=TH_NORMAL; chop=50.0; vwap=0; speed=0;
      nZones=0; atZone=-1; nHi=0; nLo=0;
      legLow=0; legHigh=0; legDir=0;
     }

   void ZeroDecl()
     {
      decl.active=false; decl.tfSlot=slot; decl.dir=0; decl.tDeclare=0;
      decl.branch=""; decl.entry=0; decl.sl=0; decl.tp1=0;
      decl.lots=0; decl.remLots=0; decl.bestFav=0; decl.tpUpdates=0;
      decl.durBars=0; decl.risk0=0;
      decl.outcome=DO_ACTIVE; decl.barsAge=0; decl.beArmed=false; decl.beLevel=0;
     }

   double Body(int i)      { return(MathAbs(r[i].close - r[i].open)); }
   double Rng(int i)       { return(r[i].high - r[i].low); }
   double UpW(int i)       { return(r[i].high - MathMax(r[i].open, r[i].close)); }
   double LoW(int i)       { return(MathMin(r[i].open, r[i].close) - r[i].low); }

   //------------------------------------------------------------------
   // data load
   //------------------------------------------------------------------
   bool Load()
     {
      ready = false;
      int available = Bars(_Symbol, tf);
      if(available < BARS_MIN)
         return(false);
      int want = MathMin(BARS_WANT, available - 2);
      ArraySetAsSeries(r,   true);
      ArraySetAsSeries(e20, true);
      ArraySetAsSeries(e50, true);
      ArraySetAsSeries(atr, true);
      ArraySetAsSeries(v,   true);
      n = CopyRates(_Symbol, tf, 0, want, r);
      if(n < BARS_MIN)
         return(false);
      if(CopyBuffer(hE20, 0, 0, n, e20) < n) return(false);
      if(CopyBuffer(hE50, 0, 0, n, e50) < n) return(false);
      if(CopyBuffer(hATR, 0, 0, n, atr) < n) return(false);
      if(CopyTickVolume(_Symbol, tf, 0, n, v) < n) return(false);

      double sum=0; int cnt=0;
      for(int i=1; i<=20 && i<n-1; i++) { sum += (double)v[i]; cnt++; }
      volAvg = (cnt>0 ? sum/cnt : 0);

      double sp=0; int sc=0;
      for(int i=1; i<=50 && i<n-2; i++) { sp += MathAbs(r[i].close - r[i+1].close); sc++; }
      speed = (sc>0 ? sp/sc : 0);
      if(speed <= 0 && n>2) speed = MathMax(atr[1]*0.25, _Point);

      ready = true;
      return(true);
     }

   //------------------------------------------------------------------
   // Step 1a: swing structure (the eyes) - ATR-adaptive pivots
   //------------------------------------------------------------------
   void DetectSwings()
     {
      ArrayResize(swHiP, 0); ArrayResize(swHiB, 0);
      ArrayResize(swLoP, 0); ArrayResize(swLoB, 0);
      nHi=0; nLo=0;

      double sig = g_pr.swingSig;
      int pT[];  double pP[];  int pB[];
      ArrayResize(pT,0); ArrayResize(pP,0); ArrayResize(pB,0);
      int np=0;

      for(int i=2; i<=n-3; i++)
        {
         double a = (atr[i] > 0 ? atr[i] : _Point);
         bool ph = r[i].high > r[i-1].high && r[i].high > r[i-2].high &&
                   r[i].high > r[i+1].high && r[i].high > r[i+2].high &&
                   (r[i].high - MathMax(r[i-1].high, r[i-2].high)) >= sig*a &&
                   (r[i].high - MathMax(r[i+1].high, r[i+2].high)) >= sig*a;
         bool pl = r[i].low < r[i-1].low && r[i].low < r[i-2].low &&
                   r[i].low < r[i+1].low && r[i].low < r[i+2].low &&
                   (MathMin(r[i-1].low, r[i-2].low) - r[i].low) >= sig*a &&
                   (MathMin(r[i+1].low, r[i+2].low) - r[i].low) >= sig*a;
         if(!ph && !pl) continue;
         ArrayResize(pT, np+1); ArrayResize(pP, np+1); ArrayResize(pB, np+1);
         pT[np] = (ph ? 1 : -1);
         pP[np] = (ph ? r[i].high : r[i].low);
         pB[np] = i;
         np++;
        }

      // enforce alternation, oldest -> newest (pivots collected newest-first)
      double seqP[]; int seqT[]; int seqB[];
      ArrayResize(seqP,0); ArrayResize(seqT,0); ArrayResize(seqB,0);
      int cnt=0, lastType=0;
      for(int k=np-1; k>=0; k--)
        {
         int t = pT[k];
         if(lastType==0 || t != lastType)
           {
            ArrayResize(seqP,cnt+1); ArrayResize(seqT,cnt+1); ArrayResize(seqB,cnt+1);
            seqP[cnt]=pP[k]; seqT[cnt]=t; seqB[cnt]=pB[k];
            lastType=t; cnt++;
           }
         else
           {
            if(t>0 && pP[k] > seqP[cnt-1]) { seqP[cnt-1]=pP[k]; seqB[cnt-1]=pB[k]; }
            if(t<0 && pP[k] < seqP[cnt-1]) { seqP[cnt-1]=pP[k]; seqB[cnt-1]=pB[k]; }
           }
        }

      // newest first: seq[cnt-1] is newest
      for(int k=cnt-1; k>=0; k--)
        {
         if(seqT[k] > 0 && nHi < 10)
           {
            ArrayResize(swHiP, nHi+1); ArrayResize(swHiB, nHi+1);
            swHiP[nHi]=seqP[k]; swHiB[nHi]=seqB[k]; nHi++;
           }
         if(seqT[k] < 0 && nLo < 10)
           {
            ArrayResize(swLoP, nLo+1); ArrayResize(swLoB, nLo+1);
            swLoP[nLo]=seqP[k]; swLoB[nLo]=seqB[k]; nLo++;
           }
        }

      // fib leg = last two alternating pivots
      legDir = 0; legLow=0; legHigh=0;
      if(cnt >= 2)
        {
         int newestT = seqT[cnt-1];
         double newestP = seqP[cnt-1];
         double prevP   = seqP[cnt-2];
         if(newestT > 0) { legDir=1;  legHigh=newestP; legLow=prevP; }
         if(newestT < 0) { legDir=-1; legLow=newestP;  legHigh=prevP; }
        }
     }

   //------------------------------------------------------------------
   // Step 1b: trend verdict + VWAP + CHOP
   //------------------------------------------------------------------
   void ComputeTrend()
     {
      double c1 = r[1].close;

      //--- structure (HH/HL vs LH/LL)
      int sdir = 0;
      if(nHi>=2 && nLo>=2)
        {
         if(swHiP[0] > swHiP[1] && swLoP[0] > swLoP[1]) sdir =  1;
         if(swHiP[0] < swHiP[1] && swLoP[0] < swLoP[1]) sdir = -1;
        }

      //--- EMA confirmation
      int edir = 0;
      if(e20[1] > e50[1] && c1 > e50[1]) edir =  1;
      if(e20[1] < e50[1] && c1 < e50[1]) edir = -1;

      //--- confidence: structure is the boss, EMA confirms
      int prevDir = tDir;                      // remember previous read for flip/age tracking
      if(sdir == 0)                            tConf = TC_WEAK;
      else if(sdir == edir)                    tConf = TC_STRONG;
      else if(edir == 0)                       tConf = TC_MOD;
      else                                     tConf = TC_WEAK;   // tools contradict the eyes
      tDir = sdir;

      //--- choppiness regime
      int per = MathMin(14, n-2);
      double hh = r[1].high, ll = r[1].low, sumA = 0;
      for(int i=1; i<=per; i++)
        {
         if(r[i].high > hh) hh = r[i].high;
         if(r[i].low  < ll) ll = r[i].low;
         sumA += atr[i];
        }
      double rng = hh - ll;
      chop = (rng > 0 && per > 0 ? 100.0*MathLog10(sumA/rng)/MathLog10((double)per) : 50.0);
      if(chop >= CHOP_BOX)      tRegime = TRG_BOX;
      else if(chop <= CHOP_TREND) tRegime = TRG_TREND;
      else                        tRegime = TRG_TRANS;

      //--- age (structure flip tracking)
      if(sdir != 0)
        {
         if(sdir != prevDir) tAgeBars = 1;
         else tAgeBars++;
         if(tAgeBars <= 30)      tAge = TA_YOUNG;
         else if(tAgeBars <= 80) tAge = TA_MATURE;
         else                    tAge = TA_OLD;
        }
      else { tAgeBars = 0; tAge = TA_YOUNG; }

      //--- health: pullback depth vs last leg
      tHealth = TH_NORMAL;
      if(tDir > 0 && nHi>=1 && nLo>=1 && swHiP[0] > swLoP[0])
        {
         double depth = (swHiP[0] - c1) / (swHiP[0] - swLoP[0]);
         if(depth < FIB_R1)      tHealth = TH_SHALLOW;
         else if(depth < FIB_R3) tHealth = TH_NORMAL;
         else                    tHealth = TH_DEEP;
        }
      if(tDir < 0 && nHi>=1 && nLo>=1 && swHiP[0] > swLoP[0])
        {
         double depth = (c1 - swLoP[0]) / (swHiP[0] - swLoP[0]);
         if(depth < FIB_R1)      tHealth = TH_SHALLOW;
         else if(depth < FIB_R3) tHealth = TH_NORMAL;
         else                    tHealth = TH_DEEP;
        }

      //--- VWAP (session day, server time)
      datetime now = TimeCurrent();
      datetime dayStart = (datetime)((long)now - ((long)now % 86400));
      double tpv=0, vv=0;
      for(int i=1; i<n; i++)
        {
         if(r[i].time < dayStart) break;
         double tp = (r[i].high + r[i].low + r[i].close) / 3.0;   // typical price
         tpv += tp * (double)v[i];
         vv  += (double)v[i];
        }
      vwap = (vv > 0 ? tpv/vv : c1);

      //--- trend line text
      string dirTxt = (tDir>0 ? "UP" : (tDir<0 ? "DOWN" : "SIDEWAYS"));
      string confTxt = (tConf==TC_STRONG ? "strong" : (tConf==TC_MOD ? "moderate" : "weak"));
      string ageTxt  = (tAge==TA_YOUNG ? "young" : (tAge==TA_MATURE ? "mature" : "old"));
      string regTxt  = (tRegime==TRG_TREND ? "trending" : (tRegime==TRG_BOX ? "box" : "transition"));
      string hlTxt   = (tHealth==TH_SHALLOW ? "pullback shallow" :
                        (tHealth==TH_NORMAL ? "pullback normal" : "pullback deep - watch"));
      trendLine = dirTxt + " " + confTxt + " " + ageTxt + " | " + regTxt +
                  " (chop " + DoubleToString(chop,1) + ") | " + hlTxt;
     }

   //------------------------------------------------------------------
   // Step 2: precision map
   //------------------------------------------------------------------
   void ZoneTagsText(int tags, string &txt)
     {
      txt = "";
      if((tags & ZG_SWING)  != 0) txt += "swing ";
      if((tags & ZG_LIFE)   != 0) txt += "lifeline ";
      if((tags & ZG_SESS)   != 0) txt += "session ";
      if((tags & ZG_ROUND)  != 0) txt += "round ";
      if((tags & ZG_FIB)    != 0) txt += "fib ";
      if((tags & ZG_VWAP)   != 0) txt += "vwap ";
      if((tags & ZG_BROKEN) != 0) txt += "flipped ";
      StringTrimRight(txt);
     }

   void AddCandidate(double price, int tag, double &cp[], int &ct[], int &cn)
     {
      if(price <= 0) return;
      for(int i=0; i<cn; i++)
        {
         if(MathAbs(cp[i] - price) < _Point*0.5)   // same price, merge tags
           { ct[i] |= tag; return; }
        }
      ArrayResize(cp, cn+1); ArrayResize(ct, cn+1);
      cp[cn]=price; ct[cn]=tag; cn++;
     }

   void BuildMap()
     {
      double thick = g_pr.zoneATR * atr[1];
      if(thick <= 0) thick = _Point*10;
      double c1 = r[1].close;
      double buf = g_pr.breakBuf * atr[1];

      //--- gather candidates
      double cp[]; int ct[]; int cn=0;
      ArrayResize(cp,0); ArrayResize(ct,0);

      for(int i=0; i<nHi && i<5; i++) AddCandidate(swHiP[i], ZG_SWING, cp, ct, cn);
      for(int i=0; i<nLo && i<5; i++) AddCandidate(swLoP[i], ZG_SWING, cp, ct, cn);

      // lifeline: last HL in up-trend / last LH in down-trend
      double lifePrice = 0;
      if(tDir > 0 && nLo>=1) { lifePrice = swLoP[0]; AddCandidate(lifePrice, ZG_LIFE, cp, ct, cn); }
      if(tDir < 0 && nHi>=1) { lifePrice = swHiP[0]; AddCandidate(lifePrice, ZG_LIFE, cp, ct, cn); }

      // session extremes (today, server time)
      datetime now = TimeCurrent();
      datetime dayStart = (datetime)((long)now - ((long)now % 86400));
      double dHi=0, dLo=0; bool hasDay=false;
      for(int i=1; i<n; i++)
        {
         if(r[i].time < dayStart) break;
         if(!hasDay) { dHi=r[i].high; dLo=r[i].low; hasDay=true; }
         if(r[i].high > dHi) dHi = r[i].high;
         if(r[i].low  < dLo) dLo = r[i].low;
        }
      if(hasDay)
        {
         if(MathAbs(dHi - c1) < 6*atr[1]) AddCandidate(dHi, ZG_SESS, cp, ct, cn);
         if(MathAbs(dLo - c1) < 6*atr[1]) AddCandidate(dLo, ZG_SESS, cp, ct, cn);
        }
      // Asian range (forex profile only)
      if(g_pr.asianRange)
        {
         datetime aEnd = (datetime)((long)dayStart + (long)g_pr.asianEndHour*3600);
         if(now > aEnd)
           {
            double aHi=0, aLo=0; bool hasA=false;
            for(int i=1; i<n; i++)
              {
               if(r[i].time < dayStart) break;
               if(r[i].time >= aEnd) continue;
               if(!hasA) { aHi=r[i].high; aLo=r[i].low; hasA=true; }
               if(r[i].high > aHi) aHi = r[i].high;
               if(r[i].low  < aLo) aLo = r[i].low;
              }
            if(hasA)
              {
               if(MathAbs(aHi - c1) < 4*atr[1]) AddCandidate(aHi, ZG_SESS, cp, ct, cn);
               if(MathAbs(aLo - c1) < 4*atr[1]) AddCandidate(aLo, ZG_SESS, cp, ct, cn);
              }
           }
        }

      // round numbers (per symbol type grid)
      if(g_pr.roundGrid > 0)
        {
         double g = g_pr.roundGrid;
         double above = (MathFloor(c1/g)+1.0)*g;
         double below = (MathFloor(c1/g))*g;
         if(MathAbs(above - c1) < 4*atr[1]) AddCandidate(above, ZG_ROUND, cp, ct, cn);
         if(MathAbs(below - c1) < 4*atr[1]) AddCandidate(below, ZG_ROUND, cp, ct, cn);
        }
      if(g_pr.roundGrid2 > 0)
        {
         double g2 = g_pr.roundGrid2;
         double above2 = (MathFloor(c1/g2)+1.0)*g2;
         double below2 = (MathFloor(c1/g2))*g2;
         if(MathAbs(above2 - c1) < 3*atr[1]) AddCandidate(above2, ZG_ROUND, cp, ct, cn);
         if(MathAbs(below2 - c1) < 3*atr[1]) AddCandidate(below2, ZG_ROUND, cp, ct, cn);
        }

      // fib pause-zones of the last completed leg (measured, with structure)
      if(legDir != 0 && legHigh > legLow)
        {
         double size = legHigh - legLow;
         if(legDir > 0)
           {
            AddCandidate(legHigh - FIB_R1*size, ZG_FIB, cp, ct, cn);
            AddCandidate(legHigh - FIB_R2*size, ZG_FIB, cp, ct, cn);
            AddCandidate(legHigh - FIB_R3*size, ZG_FIB, cp, ct, cn);
           }
         else
           {
            AddCandidate(legLow + FIB_R1*size, ZG_FIB, cp, ct, cn);
            AddCandidate(legLow + FIB_R2*size, ZG_FIB, cp, ct, cn);
            AddCandidate(legLow + FIB_R3*size, ZG_FIB, cp, ct, cn);
           }
        }

      //--- cluster candidates into zones
      double clusterDist = 0.6*thick;
      SZone tmp[];
      int nz=0;
      ArrayResize(tmp, 0);
      // sort candidates by price (insertion sort, small n)
      for(int i=1; i<cn; i++)
        {
         double kp=cp[i]; int kt=ct[i];
         int j=i-1;
         while(j>=0 && cp[j]>kp) { cp[j+1]=cp[j]; ct[j+1]=ct[j]; j--; }
         cp[j+1]=kp; ct[j+1]=kt;
        }
      for(int i=0; i<cn; i++)
        {
         if(nz>0 && MathAbs(tmp[nz-1].price - cp[i]) <= clusterDist)
           {
            // merge into previous zone
            tmp[nz-1].price = (tmp[nz-1].price + cp[i])*0.5;
            tmp[nz-1].tags |= ct[i];
           }
         else
           {
            ArrayResize(tmp, nz+1);
            tmp[nz].price = cp[i];
            tmp[nz].thick = thick;
            tmp[nz].tags  = ct[i];
            tmp[nz].touches=0; tmp[nz].drama=0; tmp[nz].recencyF=0.3;
            tmp[nz].strength=0; tmp[nz].slForBuy=0; tmp[nz].slForSell=0;
            tmp[nz].isLifeline=false; tmp[nz].brokenDir=0;
            nz++;
           }
        }

      //--- grade zones: touches, drama, recency, vwap/stack, flip rule
      for(int z=0; z<nz; z++)
        {
         double zLo = tmp[z].price - thick;
         double zHi = tmp[z].price + thick;
         int touches=0; double drama=0; int newestTouch=0;
         // swing pivots touching the zone
         for(int i=0; i<nHi; i++)
            if(swHiP[i] >= zLo && swHiP[i] <= zHi)
              {
               touches++;
               double ratio = (volAvg>0 ? (double)v[swHiB[i]]/volAvg : 1);
               drama += MathMin(ratio, 3.0);
               if(swHiB[i] > newestTouch) newestTouch = swHiB[i];
              }
         for(int i=0; i<nLo; i++)
            if(swLoP[i] >= zLo && swLoP[i] <= zHi)
              {
               touches++;
               double ratio = (volAvg>0 ? (double)v[swLoB[i]]/volAvg : 1);
               drama += MathMin(ratio, 3.0);
               if(swLoB[i] > newestTouch) newestTouch = swLoB[i];
              }
         tmp[z].touches = touches;
         tmp[z].drama   = (touches>0 ? drama/touches : 0);
         tmp[z].recencyF= (touches>0 ? MathMax(0.1, 1.0 - (double)newestTouch/300.0) : 0.2);
         if(MathAbs(vwap - tmp[z].price) <= thick) tmp[z].tags |= ZG_VWAP;

         // flip rule: decisively closed beyond within last 10 bars?
         tmp[z].brokenDir = 0;
         for(int j=1; j<=10 && j<n-1; j++)
           {
            if(r[j].close > zHi) { tmp[z].brokenDir = 1; break; }
            if(r[j].close < zLo) { tmp[z].brokenDir = -1; break; }
           }
         if(tmp[z].brokenDir != 0) tmp[z].tags |= ZG_BROKEN;

         // lifeline flag
         tmp[z].isLifeline = ((tmp[z].tags & ZG_LIFE) != 0);

         // strength = touches x drama x recency + stack-bonus
         int stack = 0;
         int t = tmp[z].tags;
         if((t & ZG_SWING) != 0) stack++;
         if((t & ZG_LIFE)  != 0) stack++;
         if((t & ZG_SESS)  != 0) stack++;
         if((t & ZG_ROUND) != 0) stack++;
         if((t & ZG_FIB)   != 0) stack++;
         if((t & ZG_VWAP)  != 0) stack++;
         double s = 40.0*MathMin(touches,4)/4.0
                  + 25.0*MathMin(tmp[z].drama,2.0)/2.0
                  + 20.0*tmp[z].recencyF
                  + 15.0*MathMin(stack-1, 3)/3.0;
         tmp[z].strength = s;

         // risk lines ("where am I wrong")
         tmp[z].slForBuy  = tmp[z].price - thick - buf;
         tmp[z].slForSell = tmp[z].price + thick + buf;

         ZoneTagsText(tmp[z].tags, tmp[z].tagStr);
        }

      //--- keep strongest maxZones with at least one meaningful tag
      //    (drop naked low-strength candidates)
      int keep = 0;
      for(int z=0; z<nz; z++)
         if(tmp[z].strength >= 25.0 || tmp[z].isLifeline)
           {
            if(keep != z) tmp[keep] = tmp[z];
            keep++;
           }
      nz = keep;
      // selection sort by strength desc, keep top maxZones
      for(int i=0; i<nz-1; i++)
        {
         int best=i;
         for(int j=i+1; j<nz; j++) if(tmp[j].strength > tmp[best].strength) best=j;
         if(best!=i) { SZone tz=tmp[i]; tmp[i]=tmp[best]; tmp[best]=tz; }
        }
      nZones = MathMin(nz, g_pr.maxZones);
      ArrayResize(zones, nZones);
      for(int z=0; z<nZones; z++) zones[z] = tmp[z];

      //--- price location (the primary gate)
      atZone = -1;
      for(int z=0; z<nZones; z++)
         if(MathAbs(c1 - zones[z].price) <= thick) { atZone = z; break; }

      int resIdx=-1, supIdx=-1;
      double dRes=0, dSup=0;
      for(int z=0; z<nZones; z++)
        {
         if(zones[z].price > c1 + thick && (resIdx<0 || zones[z].price < dRes))
           { resIdx=z; dRes=zones[z].price; }
         if(zones[z].price < c1 - thick && (supIdx<0 || zones[z].price > dSup))
           { supIdx=z; dSup=zones[z].price; }
        }
      if(atZone >= 0)
         locLine = "price AT zone " + DoubleToString(zones[atZone].price, _Digits) +
                   " [" + zones[atZone].tagStr + "]";
      else if(resIdx>=0 && supIdx>=0)
         locLine = "between zones: res " + DoubleToString(dRes,_Digits) + " / sup " +
                   DoubleToString(dSup,_Digits);
      else
         locLine = "no zones nearby - standing aside";
     }

   //------------------------------------------------------------------
   // Step 3: the verdict - living scenario tree
   //------------------------------------------------------------------
   int EstBars(double dist)
     {
      double sp = (speed > 0 ? speed : atr[1]*0.25);
      int b = (int)MathCeil(dist / MathMax(sp, _Point));
      int cap = 3*StallBars();
      if(b < 2)   b = 2;
      if(b > cap) b = cap;
      return(b);
     }

   int StallBars()
     {
      return(tf==PERIOD_M5 ? g_pr.stallM5 : g_pr.stallM15);
     }

   void SetBranch(int idx, string name, int dir, double t1, double t2, double inv, int bars)
     {
      br[idx].used    = true;
      br[idx].name    = name;
      br[idx].dir     = dir;
      br[idx].target1 = t1;
      br[idx].target2 = t2;
      br[idx].invalid = inv;
      br[idx].bars    = bars;
      br[idx].status  = BR_WAIT;
     }

   void BuildTree()
     {
      double c1 = r[1].close;
      double a  = atr[1];
      double buf = g_pr.breakBuf * a;

      // nearest zones around price
      int resIdx=-1, supIdx=-1, res2Idx=-1, sup2Idx=-1;
      for(int z=0; z<nZones; z++)
        {
         if(zones[z].price > c1 + zones[z].thick)
           {
            if(resIdx<0 || zones[z].price < zones[resIdx].price)
              { res2Idx=resIdx; resIdx=z; }
            else if(res2Idx<0 || zones[z].price < zones[res2Idx].price)
              res2Idx=z;
           }
         if(zones[z].price < c1 - zones[z].thick)
           {
            if(supIdx<0 || zones[z].price > zones[supIdx].price)
              { sup2Idx=supIdx; supIdx=z; }
            else if(sup2Idx<0 || zones[z].price > zones[sup2Idx].price)
              sup2Idx=z;
           }
        }

      double ext1=0, ext2=0;
      if(legDir != 0 && legHigh > legLow)
        {
         double size = legHigh - legLow;
         if(legDir > 0) { ext1 = legLow + FIB_E1*size; ext2 = legLow + FIB_E2*size; }
         else           { ext1 = legHigh - FIB_E1*size; ext2 = legHigh - FIB_E2*size; }
        }

      if(tDir > 0)
        {
         double t1 = (resIdx>=0 ? zones[resIdx].price : (ext1>0 ? ext1 : c1 + 2*a));
         double t2 = (ext1>0 && ext1>t1 ? ext1 : (ext2>0 ? ext2 : t1 + (t1-c1)));
         if(resIdx>=0 && ext1>0 && ext1>t1) t2 = ext1;
         double inv = (supIdx>=0 ? zones[supIdx].slForBuy : c1 - 2.5*a);
         SetBranch(0, "base: UP continuation", 1, t1, t2, inv, EstBars(t1-c1));
         double a1 = (supIdx>=0 ? zones[supIdx].price : c1 - 1.5*a);
         double a2 = (sup2Idx>=0 ? zones[sup2Idx].price : a1 - (t1-c1)*0.8);
         double aInv = (resIdx>=0 ? zones[resIdx].slForSell : c1 + 2.5*a);
         SetBranch(1, "alt: reversal at resistance", -1, a1, a2, aInv, EstBars(c1-a1));
        }
      else if(tDir < 0)
        {
         double t1 = (supIdx>=0 ? zones[supIdx].price : (ext1>0 ? ext1 : c1 - 2*a));
         double t2 = (ext1>0 && ext1<t1 ? ext1 : (ext2>0 ? ext2 : t1 - (c1-t1)));
         if(supIdx>=0 && ext1>0 && ext1<t1) t2 = ext1;
         double inv = (resIdx>=0 ? zones[resIdx].slForSell : c1 + 2.5*a);
         SetBranch(0, "base: DOWN continuation", -1, t1, t2, inv, EstBars(c1-t1));
         double a1 = (resIdx>=0 ? zones[resIdx].price : c1 + 1.5*a);
         double a2 = (res2Idx>=0 ? zones[res2Idx].price : a1 + (c1-t1)*0.8);
         double aInv = (supIdx>=0 ? zones[supIdx].slForBuy : c1 - 2.5*a);
         SetBranch(1, "alt: reversal at support", 1, a1, a2, aInv, EstBars(a1-c1));
        }
      else
        {
         // sideways: fade toward the opposite edge / break beyond nearer edge
         int nearIdx=-1; double nearD=0;
         for(int z=0; z<nZones; z++)
           {
            double d = MathAbs(zones[z].price - c1);
            if(nearIdx<0 || d<nearD) { nearIdx=z; nearD=d; }
           }
         if(nearIdx>=0)
           {
            bool nearAbove = zones[nearIdx].price > c1;
            int fdir = (nearAbove ? -1 : 1);
            double far = c1; bool haveFar = false;
            for(int z=0; z<nZones; z++)
               if(z!=nearIdx && ((fdir>0 && zones[z].price>c1) || (fdir<0 && zones[z].price<c1)))
                  if(!haveFar || MathAbs(zones[z].price-c1) < MathAbs(far-c1))
                    { far = zones[z].price; haveFar = true; }
            if(!haveFar) far = c1 + fdir*2*a;
            SetBranch(0, "base: range fade at zone edge", fdir, far, far + fdir*(far-c1)*0.5,
                      zones[nearIdx].price + (nearAbove ? zones[nearIdx].thick + buf : -(zones[nearIdx].thick + buf)),
                      EstBars(MathAbs(far-c1)));
            SetBranch(1, "alt: break of range edge", (nearAbove ? 1 : -1),
                      zones[nearIdx].price + (nearAbove ? 1 : -1)*(zones[nearIdx].thick + buf),
                      zones[nearIdx].price + (nearAbove ? 1 : -1)*(2*zones[nearIdx].thick + 2*buf),
                      zones[nearIdx].price - (nearAbove ? 1 : -1)*(zones[nearIdx].thick),
                      EstBars(zones[nearIdx].thick));
           }
         else
           {
            SetBranch(0, "base: no map - drift", 0, c1, c1, c1, StallBars());
            SetBranch(1, "alt: none", 0, c1, c1, c1, StallBars());
           }
        }

      // stall branch always last
      SetBranch(2, "stall: no significant move - tree rebuilt", 0, c1, c1, 0, StallBars());

      // tracking marker: which branch price currently behaves like
      double m = r[1].close - r[3].close;
      trackLine = "tracking: stall";
      if(MathAbs(m) >= 0.15*a)
        {
         int md = (m>0 ? 1 : -1);
         for(int b=0; b<2; b++)
            if(br[b].used && br[b].dir == md)
              { trackLine = "tracking: " + br[b].name; break; }
        }
     }

   //------------------------------------------------------------------
   // Step 4a: track the active declaration (outcome bookkeeping)
   //------------------------------------------------------------------
   //--- living-target helpers ----------------------------------------
   // nearest minor swing (natural pause) between 'from' and 'limit'
   double NearestShelf(int dir, double from, double limit)
     {
      double best = 0;
      if(dir > 0)
        {
         for(int i=0; i<nHi; i++)
           {
            double p = swHiP[i];
            if(p > from && (limit == 0 || p < limit))
               if(best == 0 || p < best) best = p;
           }
        }
      else
        {
         for(int i=0; i<nLo; i++)
           {
            double p = swLoP[i];
            if(p < from && (limit == 0 || p > limit))
               if(best == 0 || p > best) best = p;
           }
        }
      return(best);
     }

   // next natural pause beyond the current target
   double NextShelfBeyond(int dir, double tp)
     {
      double a = (atr[1] > 0 ? atr[1] : _Point);
      double best = 0;
      if(dir > 0)
        {
         for(int i=0; i<nHi; i++)
            if(swHiP[i] > tp + 0.3*a && (best == 0 || swHiP[i] < best)) best = swHiP[i];
        }
      else
        {
         for(int i=0; i<nLo; i++)
            if(swLoP[i] < tp - 0.3*a && (best == 0 || swLoP[i] > best)) best = swLoP[i];
        }
      return(best);
     }

   // road check: cap a target just before a strong zone sitting beyond it
   double RoadCapped(int dir, double target)
     {
      double a = (atr[1] > 0 ? atr[1] : _Point);
      double cap = target;
      for(int z=0; z<nZones; z++)
        {
         if(zones[z].strength < 55) continue;
         if(dir > 0 && zones[z].price > target && zones[z].price < cap + 2*zones[z].thick)
            cap = MathMin(cap, zones[z].price - 0.2*a);
         if(dir < 0 && zones[z].price < target && zones[z].price > cap - 2*zones[z].thick)
            cap = MathMax(cap, zones[z].price + 0.2*a);
        }
      return(cap);
     }

   //------------------------------------------------------------------
   // Step 4a: track the active declaration - outcomes + LIVING TARGET
   //------------------------------------------------------------------
   // The human's way: keep watching every candle. If the move is healthy,
   // extend the target to the next natural pause; if the candles start
   // disagreeing, tighten the target (take what the market gives).
   void TrackDecl(int otherDir, int otherRegime)
     {
      if(!decl.active) return;
      decl.barsAge++;
      double a = (atr[1] > 0 ? atr[1] : _Point);
      double slDist = (decl.risk0 > 0 ? decl.risk0 : MathAbs(decl.entry - decl.sl));

      // best favorable excursion since entry
      if(decl.dir > 0 && r[1].high > decl.bestFav) decl.bestFav = r[1].high;
      if(decl.dir < 0 && r[1].low  < decl.bestFav) decl.bestFav = r[1].low;

      // SL / target outcome (after +1R the plan's stop lives at breakeven)
      double effSL = decl.sl;    // the stop line: original SL -> lock line at +1R -> trailed
      if(decl.dir > 0)
        {
         if(r[1].low <= effSL)
           {
            if(decl.beArmed)
              {
               double favR = (effSL - decl.entry)/slDist;
               if(favR > 0.1)
                 { FinishDecl(DO_TRAIL, "trailed out +" + DoubleToString(favR,1) + "R" +
                              (decl.remLots < decl.lots ? " - half was banked" : " (min lot - no split)")); return; }
               FinishDecl(DO_BE, (decl.remLots < decl.lots ? "stopped at BE+ - half was banked"
                                                           : "stopped at BE+ (min lot - no split)")); return;
              }
            FinishDecl(DO_SL, "invalidated"); return;
           }
         if(r[1].high >= decl.tp1) { FinishDecl(DO_TP1, "target hit");  return; }
        }
      else
        {
         if(r[1].high >= effSL)
           {
            if(decl.beArmed)
              {
               double favR = (decl.entry - effSL)/slDist;
               if(favR > 0.1)
                 { FinishDecl(DO_TRAIL, "trailed out +" + DoubleToString(favR,1) + "R" +
                              (decl.remLots < decl.lots ? " - half was banked" : " (min lot - no split)")); return; }
               FinishDecl(DO_BE, (decl.remLots < decl.lots ? "stopped at BE+ - half was banked"
                                                           : "stopped at BE+ (min lot - no split)")); return;
              }
            FinishDecl(DO_SL, "invalidated"); return;
           }
         if(r[1].low  <= decl.tp1) { FinishDecl(DO_TP1, "target hit");  return; }
        }
      if(decl.barsAge >= decl.durBars)   // time-left 0: the estimate is spent
        { FinishDecl(DO_TIMEOUT, "timed out - time-left spent"); return; }

      // management: at +1R bank half, stop to breakeven, remainder rides
      double fav = (decl.dir > 0 ? decl.bestFav - decl.entry : decl.entry - decl.bestFav);
      if(!decl.beArmed && slDist > 0 && fav >= slDist)
        {
         decl.beArmed = true;
         double lstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double lmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double half  = decl.lots/2.0;
         if(lstep > 0) half = MathFloor(half/lstep)*lstep;
         bool split = (half >= lmin && half > 0 && half < decl.lots);
         decl.remLots = (split ? half : decl.lots);   // min lot -> no split, whole trails
         // lock line: entry + 5% of the RISK distance into profit (covers
         // spread/costs) when price still leaves room, else plain entry
         double lock = (decl.dir > 0 ? decl.entry + 0.05*slDist
                                     : decl.entry - 0.05*slDist);
         bool room = (decl.dir > 0 ? r[1].close > lock + 0.1*slDist
                                   : r[1].close < lock - 0.1*slDist);
         decl.beLevel = (room ? lock : decl.entry);
         decl.sl = decl.beLevel;               // the stop line IS the lock from now on
         AddEvent("[" + tfName + "] +1R reached - " +
                  (split ? "half banked (" + DoubleToString(decl.remLots,2) + " of " +
                           DoubleToString(decl.lots,2) + "), stop to BE+"
                         : "min lot, no split - stop to BE+, whole rides"));
        }

      //--- Option A ladder: trail the stop under the newest rest step
      //    (structure trail; ratchet - never moves backward, ever)
      if(decl.beArmed && slDist > 0)
        {
         double cand = 0;
         if(decl.dir > 0)
           {
            if(nLo > 0 && swLoP[0] < r[1].close) cand = swLoP[0] - 0.1*slDist;   // pad under the shelf
           }
         else
           {
            if(nHi > 0 && swHiP[0] > r[1].close) cand = swHiP[0] + 0.1*slDist;
           }
         if(cand != 0)
           {
            bool safer = (decl.dir > 0 ? cand > decl.sl + 0.3*slDist    // >=0.3R improvement gate
                                       : cand < decl.sl - 0.3*slDist);
            if(safer)
              {
               double lockR = MathAbs(cand - decl.entry)/slDist;
               decl.sl = cand;
               AddEvent("[" + tfName + "] SL trailed to " + DoubleToString(decl.sl,_Digits) +
                        " (under the newest rest step, +" + DoubleToString(lockR,1) + "R locked)");
              }
           }
        }

      //--- move health (the human's "is it going as expected?")
      bool dirOK = (decl.dir > 0 ? (r[1].close >= r[1].open || Body(1) <= 0.5*a)
                                 : (r[1].close <= r[1].open || Body(1) <= 0.5*a));
      double move = (decl.dir > 0 ? decl.bestFav - decl.entry : decl.entry - decl.bestFav);
      double retrFrac = 0;
      if(move > 0)
        {
         double give = (decl.dir > 0 ? decl.bestFav - r[1].close : r[1].close - decl.bestFav);
         retrFrac = give/move;
        }
      bool regimeAgainst = false;
      if(slot == 0 && otherDir != 0 && otherDir != decl.dir && otherRegime == TRG_TREND)
         regimeAgainst = true;                       // M5 idea vs a trending M15 the other way
      if(slot == 1 && tRegime == TRG_BOX && tDir != 0 && tDir != decl.dir)
         regimeAgainst = true;                       // M15 idea while own TF turned to a box

      int warnings = 0;
      if(!dirOK)          warnings++;
      if(retrFrac >= 0.5) warnings++;
      if(regimeAgainst)   warnings++;
      bool red = (retrFrac >= 0.618) || (regimeAgainst && retrFrac >= 0.3);

      double distTP = (decl.dir > 0 ? decl.tp1 - r[1].close : r[1].close - decl.tp1);

      //--- RED: candles disagree -> tighten the target
      // arms only once the move has substance (>=0.5R): before that the SL
      // protects, and early jitter must not chase the target around
      if(red)
        {
         if(move < 0.5*slDist) return;
         double newTP = NearestShelf(decl.dir, r[1].close, decl.tp1);
         if(newTP == 0) newTP = (decl.dir > 0 ? r[1].close + 0.4*a : r[1].close - 0.4*a);
         // a target never crosses back through the entry: a BUY's TP stays
         // ABOVE entry, a SELL's BELOW. No natural pause left past the entry
         // -> the move has failed: close the forecast honestly
         double tpFloor = (decl.dir > 0 ? decl.entry + 0.2*slDist : decl.entry - 0.2*slDist);
         bool pastFloor = (decl.dir > 0 ? newTP >= tpFloor : newTP <= tpFloor);
         if(!pastFloor)
           {
            FinishDecl(DO_CLOSED, "closed early - move failed (no pause past entry)");
            return;
           }
         bool tighter = (decl.dir > 0 ? newTP < decl.tp1 : newTP > decl.tp1);
         if(tighter)
           {
            decl.tp1 = newTP; decl.tpUpdates++;
            int run = EstBars(MathAbs(decl.tp1 - decl.entry));
            decl.durBars  = decl.barsAge + run;            // runway follows the living TP
            OnDeclared("[" + tfName + "] TP tightened to " + DoubleToString(decl.tp1,_Digits) + " (weakening)");
           }
         return;
        }

      //--- GREEN: move healthy and near the target -> extend to next pause
      if(warnings == 0 && distTP > 0 && distTP < 0.5*a)
        {
         double cand = NextShelfBeyond(decl.dir, decl.tp1);
         double cap  = (legDir != 0 && legHigh > legLow ?
                        (decl.dir > 0 ? legLow + FIB_E2*(legHigh-legLow)
                                      : legHigh - FIB_E2*(legHigh-legLow)) : 0);
         if(cand > 0) cand = RoadCapped(decl.dir, cand);
         bool farther = (decl.dir > 0 ? cand > decl.tp1 : cand < decl.tp1);
         bool withinCap = (cap == 0 || (decl.dir > 0 ? cand <= cap : cand >= cap));
         if(cand > 0 && farther && withinCap)
           {
            decl.tp1 = cand; decl.tpUpdates++;
            int run = EstBars(MathAbs(decl.tp1 - decl.entry));
            decl.durBars  = decl.barsAge + run;            // runway follows the living TP
            OnDeclared("[" + tfName + "] TP extended to " + DoubleToString(decl.tp1,_Digits) + " (move healthy)");
           }
        }
     }

   void FinishDecl(int outcome, string note)
     {
      decl.outcome = outcome;
      decl.active  = false;
      PushMemory(decl, note + " (" + tfName + " " + TimeToString(TimeCurrent(), TIME_MINUTES) + ")");
      OnDeclared("declaration " + note);
     }

   //------------------------------------------------------------------
   // Step 4b: detect the selector candle at a zone -> declare
   //------------------------------------------------------------------
   void DetectAndDeclare()
     {
      double a = atr[1];
      if(a <= 0) return;
      double body1 = Body(1), body2 = Body(2);

      int bestZone=-1; double bestScore=0; int bestEvent=0; // 1 rej 2 flip 3 decisive 4 false
      int bestDir=0;

      for(int z=0; z<nZones; z++)
        {
         if(zones[z].strength < 30.0) continue;          // faded zone - not trusted
         double zp = zones[z].price, tk = zones[z].thick;
         bool touch = (r[1].high >= zp - tk) && (r[1].low <= zp + tk);
         if(!touch) continue;

         bool aboveZone = r[1].close > zp + tk;
         bool belowZone = r[1].close < zp - tk;

         // --- false break (trap): poked through, closed back inside
         if(r[1].high > zp + tk && r[1].close < zp + tk && UpW(1) >= 0.4*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=4; bestDir=-1; } continue; }
         if(r[1].low < zp - tk && r[1].close > zp - tk && LoW(1) >= 0.4*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=4; bestDir=1; } continue; }

         // --- decisive break: full close beyond the zone
         if(aboveZone && Body(1) >= 0.5*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=3; bestDir=1; } continue; }
         if(belowZone && Body(1) >= 0.5*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=3; bestDir=-1; } continue; }

         // --- rejection: pierced, closed back with dominant wick
         if(r[1].low <= zp && r[1].close > zp && LoW(1) >= 1.2*MathMax(body1,_Point) && LoW(1) >= 0.3*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=1; bestDir=1; } continue; }
         if(r[1].high >= zp && r[1].close < zp && UpW(1) >= 1.2*MathMax(body1,_Point) && UpW(1) >= 0.3*a)
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=1; bestDir=-1; } continue; }

         // --- dominance flip: body engulfs previous opposite body at the zone
         if(body1 > body2 && body1 >= 0.4*a &&
            ((r[1].close > r[1].open && r[2].close < r[2].open &&
              r[1].close >= r[2].open && r[1].open <= r[2].close) ||
             (r[1].close < r[1].open && r[2].close > r[2].open &&
              r[1].close <= r[2].open && r[1].open >= r[2].close)))
           { if(zones[z].strength > bestScore){ bestScore=zones[z].strength; bestZone=z; bestEvent=2;
                bestDir = (r[1].close > r[1].open ? 1 : -1); } continue; }
        }

      if(bestZone < 0) return;                          // noise filter: nothing declared

      // one idea at a time per timeframe
      if(decl.active)
        {
         if(decl.dir == bestDir)
            return;                     // same idea still playing - nothing new to say
         decl.outcome = DO_SUPERSEDE;
         decl.active = false;
         PushMemory(decl, "superseded by new selector (" + tfName + " " +
                    TimeToString(TimeCurrent(), TIME_MINUTES) + ")");
         AddEvent("[" + tfName + "] old plan superseded - a new selector took over");
        }

      SZone z = zones[bestZone];
      int d = bestDir;
      double entry = r[1].close;
      double sl = (d > 0 ? z.slForBuy : z.slForSell);
      if(d > 0 && r[1].low - 0.1*a < sl) sl = r[1].low - 0.1*a;      // never inside the trigger bar
      if(d < 0 && r[1].high + 0.1*a > sl) sl = r[1].high + 0.1*a;
      double slDist = MathAbs(entry - sl);
      if(slDist < 2.0 * (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point)
        { OnDeclared("selector rejected: stop tighter than 2x spread"); return; }

      //--- single LIVING target, planned the HUMAN WAY.
      //    At planning a trader states the PORTION the move should travel -
      //    where this move naturally ENDS:
      //      fading / reversing the last leg -> its FAR END (full retrace =
      //          the opposite edge the move is travelling toward)
      //      riding the last leg             -> its 1.272 EXTENSION (the
      //          measured portion the structure promises)
      //    only when no leg is on the map: nearest swing shelf / ATR view.
      //    The target must still pay for the risk (minR) and fit on the road.
      double minR = (tRegime == TRG_TREND ? 0.8 : 0.6);   // choppy regime: accept quick pauses
      double tp = 0;
      if(legDir != 0 && legHigh > legLow)
        {
         double size = legHigh - legLow;
         double dest = (d > 0 ? (legDir < 0 ? legHigh : legLow + FIB_E1*size)
                              : (legDir > 0 ? legLow  : legHigh - FIB_E1*size));
         if(d > 0 && dest > entry + 0.2*a && dest - entry >= minR*slDist) tp = dest;
         if(d < 0 && dest < entry - 0.2*a && entry - dest >= minR*slDist) tp = dest;
        }
      if(tp == 0)                                          // fallback: nearest paying shelf
        {
         if(d > 0)
           {
            for(int i=0; i<nHi; i++)
              {
               double p = swHiP[i];
               if(p > entry + 0.2*a && p - entry >= minR*slDist && (tp == 0 || p < tp)) tp = p;
              }
            if(tp == 0) tp = entry + 1.2*a;                // no level on the map: ATR projection
           }
         else
           {
            for(int i=0; i<nLo; i++)
              {
               double p = swLoP[i];
               if(p < entry - 0.2*a && entry - p >= minR*slDist && (tp == 0 || p > tp)) tp = p;
              }
            if(tp == 0) tp = entry - 1.2*a;
           }
        }

      // never aim beyond the nearest zone in the direction (any strength)
      double nextZone = 0;
      for(int zz=0; zz<nZones; zz++)
         if(((d > 0 && zones[zz].price > entry) || (d < 0 && zones[zz].price < entry)) &&
            (nextZone == 0 || MathAbs(zones[zz].price - entry) < MathAbs(nextZone - entry)))
            nextZone = zones[zz].price;
      if(nextZone != 0)
        {
         if(d > 0 && tp > nextZone - 0.2*a) tp = nextZone - 0.2*a;
         if(d < 0 && tp < nextZone + 0.2*a) tp = nextZone + 0.2*a;
        }

      // reward floor; if the road has no room for it, PASS the setup
      if(MathAbs(tp - entry) < 0.8*slDist)
        {
         bool blocked = (nextZone != 0 && MathAbs(nextZone - entry) < 0.8*slDist);
         if(blocked)
           {
            AddEvent("[" + tfName + "] selector passed: no room to the next zone (" +
                     DoubleToString(MathAbs(nextZone - entry)/_Point, 0) +
                     " pts) - not every setup deserves a trade");
            return;
           }
         tp = (d > 0 ? entry + 0.8*slDist : entry - 0.8*slDist);
        }

      // duration (the only clock - retires at time-left 0)
      int dur = EstBars(MathAbs(tp - entry));

      // suggested lot from risk (F5 computation, no user tuning)
      double lot = SuggestLot(slDist);
      if(lot <= 0)
        { OnDeclared("selector rejected: lot could not be computed"); return; }

      // branch linkage for naming
      string bname = "event-driven";
      for(int b=0; b<3; b++)
         if(br[b].used && br[b].dir == d && br[b].status != BR_DEAD)
           { br[b].status = BR_EXEC; bname = br[b].name; break; }

      decl.active = true;
      decl.tfSlot = slot;
      decl.dir = d;
      decl.tDeclare = r[1].time;
      decl.branch = bname;
      decl.entry = entry;
      decl.sl = sl;
      decl.risk0 = slDist;             // original risk: lock/trail/R math never drifts
      decl.tp1 = tp;
      decl.lots = lot;
      decl.remLots = lot;
      decl.bestFav = entry;
      decl.tpUpdates = 0;
      decl.durBars = dur;
      decl.outcome = DO_ACTIVE;
      decl.barsAge = 0;
      decl.beArmed = false;

      string evTxt = (bestEvent==1 ? "rejection" : (bestEvent==2 ? "dominance flip" :
                     (bestEvent==3 ? "decisive break" : "false break (trap)")));
      OnDeclared("DECLARED " + (d>0?"BUY":"SELL") + " [" + tfName + "] " + bname +
                 " - " + evTxt + " at zone " + DoubleToString(z.price, _Digits) +
                 " [" + z.tagStr + " s" + DoubleToString(z.strength,0) + "]" +
                 " | entry " + DoubleToString(decl.entry,_Digits) +
                 " SL " + DoubleToString(decl.sl,_Digits) +
                 " TP " + DoubleToString(decl.tp1,_Digits) + " (living)" +
                 " lot " + DoubleToString(decl.lots,2) +
                 " ~" + IntegerToString(decl.durBars) + " bars");
     }

   double SuggestLot(double slDist)   { return(SuggestLotG(slDist)); }

   //------------------------------------------------------------------
   // per-new-bar pipeline
   //------------------------------------------------------------------
   void OnNewBar()
     {
      datetime t = iTime(_Symbol, tf, 0);
      if(t == 0 || t == lastBar) return;
      lastBar = t;
      if(!Load()) return;
      DetectSwings();
      ComputeTrend();
      BuildMap();
      BuildTree();
     }

   // called after BOTH brains refreshed (living TP needs the other TF's read)
   // closed-candle cadence; a brain whose history is still loading just waits
   // (never touches empty arrays - that was the silent freeze)
   void ManageAndDetect(int otherDir, int otherRegime)
     {
      if(!ready || n < 3) return;          // history not loaded yet - wait, don't crash
      if(lastThink == r[1].time) return;   // think once per CLOSED candle
      lastThink = r[1].time;
      TrackDecl(otherDir, otherRegime);
      DetectAndDeclare();
     }
  };

//====================================================================//
//  GLOBALS                                                           //
//====================================================================//

CTFBrain g_tf[2];                 // 0 = M5, 1 = M15 (both always computed, F2)
bool     g_tfOK = true;           // F1: chart TF inside M5/M15 range

string   g_events[8];             // rolling event log, newest first
int      g_eventN = 0;

SDecl    g_mem[6];                // declaration memory (both TFs)
string   g_memNote[6];
int      g_memN = 0;

void AddEvent(string s)
  {
   for(int i=MathMin(g_eventN,7); i>0; i--) g_events[i] = g_events[i-1];
   g_events[0] = TimeToString(TimeCurrent(), TIME_MINUTES) + "  " + s;
   if(g_eventN < 8) g_eventN++;
   Print("SmartTrader: ", s);
  }

void OnDeclared(string s)          { AddEvent(s); if(InpAlertPopup) Alert("SmartTrader: ", s); }

void PushMemory(const SDecl &d, string note)
  {
   for(int i=MathMin(g_memN,5); i>0; i--) { g_mem[i]=g_mem[i-1]; g_memNote[i]=g_memNote[i-1]; }
   g_mem[0]=d; g_memNote[0]=note;
   if(g_memN < 6) g_memN++;
  }

string OutcomeText(int o)
  {
   if(o==DO_TP1) return("target hit");
   if(o==DO_TP2) return("target hit");
   if(o==DO_SL)  return("invalidated");
   if(o==DO_TIMEOUT) return("timed out");
   if(o==DO_SUPERSEDE) return("superseded");
   if(o==DO_CLOSED)    return("closed early");
   if(o==DO_BE)        return("stopped at BE");
   if(o==DO_TRAIL)     return("trailed out");
   return("active");
  }

//====================================================================//
//  Mi2: THE HANDS - autotrading translator (never a thinker)         //
//====================================================================//

struct SHand
  {
   datetime          planTime;      // tDeclare of the plan this hand is linked to
   datetime          lastBarC;      // caretaker cadence (one action pass per candle)
   datetime          birthBar;      // market-chase allowed only in the plan's birth bar
   bool              linked;        // a real order/position exists for this plan
   bool              wasLinked;     // a placement was made for this plan
   bool              partialDone;   // +1R bank-half executed for real
   bool              userClosed;    // position closed externally - bot stands down
   bool              userOverride;      // user changed SL/TP - one captain per ship
   bool              suspended;     // broker refused repeatedly - placement paused
   int               tries;         // consecutive broker refusals
   int               replaces;      // re-placements after external vanish
   ulong             orderTicket;   // resting order ticket (0 = none)
   ulong             posTicket;     // position ticket (0 = none)
   double            sentSL;        // last SL sent to the broker
   double            sentTP;        // last TP sent to the broker
   double            sentLot;       // lot of the placed order/position
  };

SHand    g_hand[2];
CTrade   g_trade;
bool     g_hedging = true;
string   g_accCur  = "";

void HandsResetSlot(int s)
  {
   g_hand[s].planTime=0;    g_hand[s].lastBarC=0;  g_hand[s].birthBar=0;
   g_hand[s].linked=false;  g_hand[s].wasLinked=false;
   g_hand[s].partialDone=false; g_hand[s].userClosed=false;
   g_hand[s].userOverride=false;    g_hand[s].suspended=false;
   g_hand[s].tries=0;       g_hand[s].replaces=0;
   g_hand[s].orderTicket=0; g_hand[s].posTicket=0;
   g_hand[s].sentSL=0;      g_hand[s].sentTP=0;   g_hand[s].sentLot=0;
  }

bool ModeAllows(int s)
  {
   if(InpAutoMode == AUTO_M5_ONLY)  return(s == 0);
   if(InpAutoMode == AUTO_M15_ONLY) return(s == 1);
   return(true);
  }

long SlotMagic(int s)      { return(MAGIC_BASE + 1 + s); }

bool TradeAllowed()
  {
   return(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) != 0);
  }

bool AnyBotPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(m == SlotMagic(0) || m == SlotMagic(1)) return(true);
     }
   return(false);
  }

ulong FindBotPosition(int s)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != SlotMagic(s)) continue;
      return(tk);                          // position stays selected for the caller
     }
   return(0);
  }

ulong FindBotOrder(int s)
  {
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != SlotMagic(s)) continue;
      return(tk);                          // order stays selected
     }
   return(0);
  }

string MSM(double m)   { return((m >= 0 ? "+" : "") + DoubleToString(m, 2)); }

double MoneyFor(double dist, double lot)   // signed price distance -> account money
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0) return(0);
   return(dist / ts * tv * lot);
  }

//--------------------------------------------------------------------
// Part 1: place the plan's order (entry following, protected from birth)
//--------------------------------------------------------------------
void HandsPlace(int s)
  {
   if(!g_tf[s].decl.active || g_tf[s].decl.dir == 0) return;
   if(g_hand[s].wasLinked || g_hand[s].linked) return;      // one placement per plan

   if(!TradeAllowed()) return;                              // panel shows BLOCKED
   if(!g_hedging && AnyBotPosition())
     {
      g_hand[s].tries++;
      if(g_hand[s].tries == 1)
         AddEvent("[" + g_tf[s].tfName + "] netting account - one bot position at a time: order skipped");
      return;
     }

   double entry = g_tf[s].decl.entry;
   double sl    = g_tf[s].decl.sl;
   double tp    = g_tf[s].decl.tp1;
   double slDist= (g_tf[s].decl.risk0 > 0 ? g_tf[s].decl.risk0 : MathAbs(entry - sl));
   int    dir   = g_tf[s].decl.dir;
   double lot   = g_tf[s].decl.lots;

   if(g_hand[s].birthBar == 0)
      g_hand[s].birthBar = iTime(_Symbol, g_tf[s].tf, 0);   // chase window opens

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = (dir > 0 ? ask : bid);
   bool crossed = (dir > 0 ? px > entry : px < entry);
   bool birthOK = (iTime(_Symbol, g_tf[s].tf, 0) == g_hand[s].birthBar);
   bool inBand  = (MathAbs(px - entry) <= 0.25*slDist);
   // broker minimum distance for stop/limit orders: when price HUGS the
   // declared entry (the natural straddle), a resting order AT the entry is
   // invalid - and an instant market fill IS the plan price (UK100 live case)
   double minDist = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), 10) * _Point;
   bool atEntry = (MathAbs(px - entry) < minDist);
   bool chase = (crossed && birthOK && inBand) || atEntry;

   g_trade.SetExpertMagicNumber(SlotMagic(s));
   string cmt = "ST-" + (s==0 ? "M5" : "M15");
   bool ok = false;
   double useLot = lot;

   if(chase)
     {
      double realDist = MathAbs(px - sl);                  // risk at the REAL price
      double rl = SuggestLotG(realDist);
      if(rl > 0) useLot = rl;                              // same money risk, smaller lot
      ok = (dir > 0 ? g_trade.Buy(useLot, _Symbol, 0.0, sl, tp, cmt)
                    : g_trade.Sell(useLot, _Symbol, 0.0, sl, tp, cmt));
      uint rc = g_trade.ResultRetcode();
      ok = (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
      if(ok)
         OnDeclared("[" + g_tf[s].tfName + "] order placed: MARKET " + (dir>0?"BUY ":"SELL ") +
                    DoubleToString(useLot,2) +
                    (atEntry ? " (price at plan entry - broker min distance)"
                             : " (chase in the 25% band)") +
                    " - SL/TP attached from birth");
     }
   else
     {
      if(dir > 0)
         ok = (px <= entry ? g_trade.BuyStop(useLot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt)
                           : g_trade.BuyLimit(useLot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt));
      else
         ok = (px >= entry ? g_trade.SellStop(useLot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt)
                           : g_trade.SellLimit(useLot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt));
      uint rc = g_trade.ResultRetcode();
      ok = (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
      if(ok)
         OnDeclared("[" + g_tf[s].tfName + "] order placed: " +
                    (dir>0 ? (px<=entry ? "BUY STOP " : "BUY LIMIT ") : (px>=entry ? "SELL STOP " : "SELL LIMIT ")) +
                    DoubleToString(useLot,2) + " @ " + DoubleToString(entry,_Digits) +
                    " - SL/TP attached (waiting)");
     }

   if(ok)
     {
      g_hand[s].linked    = true;
      g_hand[s].wasLinked = true;
      g_hand[s].planTime  = g_tf[s].decl.tDeclare;
      g_hand[s].sentSL    = sl;
      g_hand[s].sentTP    = tp;
      g_hand[s].sentLot   = useLot;
      g_hand[s].tries     = 0;
      if(!chase) g_hand[s].orderTicket = g_trade.ResultOrder();
      SavePlans();
     }
   else
     {
      g_hand[s].tries++;
      if(g_hand[s].tries == 1 || g_hand[s].tries % 5 == 0)
         AddEvent("[" + g_tf[s].tfName + "] broker refused placement (" +
                  g_trade.ResultRetcodeDescription() + ") - retrying");
      if(g_hand[s].tries >= 20)
        {
         g_hand[s].suspended = true;
         OnDeclared("[" + g_tf[s].tfName + "] placement suspended - broker refused repeatedly");
        }
     }
  }

//--------------------------------------------------------------------
// resting order gone: filled (late handover) or vanished (external cancel)
//--------------------------------------------------------------------
void CheckPending(int s)
  {
   bool stillThere = false;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == g_hand[s].orderTicket) { stillThere = true; break; }
     }
   if(stillThere) return;

   ulong pt = FindBotPosition(s);
   if(pt > 0)                                               // LATE FILL - edge 2
     {
      g_hand[s].posTicket   = pt;
      g_hand[s].orderTicket = 0;
      g_hand[s].sentSL      = PositionGetDouble(POSITION_SL);
      g_hand[s].sentTP      = PositionGetDouble(POSITION_TP);
      g_hand[s].sentLot     = PositionGetDouble(POSITION_VOLUME);
      OnDeclared("[" + g_tf[s].tfName + "] entry order FILLED - caretaker took over (SL/TP rode on it from birth)");
      SavePlans();
     }
   else
     {
      g_hand[s].orderTicket = 0;
      g_hand[s].linked      = false;
      if(g_tf[s].decl.active && g_hand[s].replaces < 2)
        {
         g_hand[s].replaces++;
         g_hand[s].wasLinked = false;                       // allow re-placement
         AddEvent("[" + g_tf[s].tfName + "] resting order vanished (external cancel?) - re-placing");
        }
      else
        {
         g_hand[s].userClosed = true;
         if(g_tf[s].decl.active)
            OnDeclared("[" + g_tf[s].tfName + "] resting order gone without fill - bot stands aside");
        }
      SavePlans();
     }
  }

//--------------------------------------------------------------------
// the bridge for a RESTING order: SL/TP follow the living plan
// (Part 2 b.1). The lot is fixed at placement (the plan's lot cannot
// change before the fill), so only the two lines are mirrored.
//--------------------------------------------------------------------
void HandsBridgePending(int s)
  {
   if(!OrderSelect(g_hand[s].orderTicket)) return;
   double tol  = 5*_Point;
   double osl  = OrderGetDouble(ORDER_SL);
   double otp  = OrderGetDouble(ORDER_TP);
   double wantSL = g_tf[s].decl.sl;
   double wantTP = g_tf[s].decl.tp1;
   if(MathAbs(osl - wantSL) <= tol && MathAbs(otp - wantTP) <= tol) return;
   bool ok = g_trade.OrderModify(g_hand[s].orderTicket,
                                 OrderGetDouble(ORDER_PRICE_OPEN),
                                 wantSL, wantTP, ORDER_TIME_GTC, 0);
   if(ok)
     {
      g_hand[s].sentSL = wantSL;
      g_hand[s].sentTP = wantTP;
      g_hand[s].tries  = 0;
      SavePlans();
     }
   else
     {
      g_hand[s].tries++;
      if(g_hand[s].tries % 5 == 1)
         AddEvent("[" + g_tf[s].tfName + "] order modify refused (" +
                  g_trade.ResultRetcodeDescription() + ") - retrying next candle");
     }
  }

//--------------------------------------------------------------------
// position gone: broker line fired, or the user closed it (one captain)
//--------------------------------------------------------------------
void CheckPosition(int s)
  {
   if(PositionSelectByTicket(g_hand[s].posTicket)) return;
   ulong pt = FindBotPosition(s);
   if(pt > 0) { g_hand[s].posTicket = pt; return; }         // ticket morph (netting)
   g_hand[s].posTicket = 0;
   g_hand[s].linked    = false;
   if(g_tf[s].decl.active)
     {
      g_hand[s].userClosed = true;                          // brain still records the ending
      OnDeclared("[" + g_tf[s].tfName + "] bot position closed externally (SL/TP line or by user) - bot stands down");
      SavePlans();
     }
  }

//--------------------------------------------------------------------
// the caretaker: candle-cadenced bridge (partial, lock, trail, living TP)
//--------------------------------------------------------------------
void Caretake(int s)
  {
   datetime cb = iTime(_Symbol, g_tf[s].tf, 0);
   if(cb == g_hand[s].lastBarC) return;                     // one pass per candle
   g_hand[s].lastBarC = cb;

   if(!PositionSelectByTicket(g_hand[s].posTicket)) return;
   double curSL  = PositionGetDouble(POSITION_SL);
   double curTP  = PositionGetDouble(POSITION_TP);
   double tol    = 5*_Point;

   // one captain per ship: user touched the lines -> bot watches only
   if(!g_hand[s].userOverride && g_hand[s].sentSL > 0 &&
      (MathAbs(curSL - g_hand[s].sentSL) > tol || MathAbs(curTP - g_hand[s].sentTP) > tol))
     {
      g_hand[s].userOverride = true;
      OnDeclared("[" + g_tf[s].tfName + "] manual override - SL/TP changed by user, bot steps aside (watches only)");
      SavePlans();
      return;
     }
   if(g_hand[s].userOverride) return;

   // Option A step 2: +1R -> bank half for real (min lot: nothing to bank)
   // volumes from the REAL position (a chase fill may hold a smaller lot)
   SDecl d = g_tf[s].decl;
   if(d.beArmed && !g_hand[s].partialDone)
     {
      double vol     = PositionGetDouble(POSITION_VOLUME);
      double lstep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lmin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double bankVol = (lstep > 0 ? MathFloor(vol/2.0/lstep)*lstep : vol/2.0);
      if(bankVol >= lmin && bankVol > 0 && bankVol < vol)
        {
         bool ok = g_trade.PositionClosePartial(g_hand[s].posTicket, bankVol);
         uint rc = g_trade.ResultRetcode();
         if(ok || rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL)
           {
            g_hand[s].partialDone = true;
            g_hand[s].sentLot     = vol - bankVol;
            OnDeclared("[" + g_tf[s].tfName + "] +1R banked for real: " + DoubleToString(bankVol,2) +
                       " lot closed, stop at the lock line");
            SavePlans();
           }
         else
            AddEvent("[" + g_tf[s].tfName + "] partial close refused (" +
                     g_trade.ResultRetcodeDescription() + ") - will retry next candle");
         return;                                           // bridge continues next candle
        }
      g_hand[s].partialDone = true;                        // min lot: nothing to split - whole rides
     }

   // the bridge: SL ratchet (lock + trail, never backward) + living TP
   double wantSL = g_tf[s].decl.sl;
   double wantTP = g_tf[s].decl.tp1;
   if(MathAbs(wantSL - curSL) > tol || MathAbs(wantTP - curTP) > tol)
     {
      bool ok = g_trade.PositionModify(g_hand[s].posTicket, wantSL, wantTP);
      if(ok)
        {
         g_hand[s].sentSL = wantSL;
         g_hand[s].sentTP = wantTP;
         g_hand[s].tries   = 0;
         SavePlans();
        }
      else
        {
         g_hand[s].tries++;
         if(g_hand[s].tries % 5 == 1)
            AddEvent("[" + g_tf[s].tfName + "] modify refused (" +
                     g_trade.ResultRetcodeDescription() + ") - retrying next candle");
        }
     }
  }

//--------------------------------------------------------------------
// Part 3: the plan retired -> the real order obeys (same reason, same second)
//--------------------------------------------------------------------
void HandsOnPlanEnd(int s, string reason)
  {
   bool done = true;
   if(g_hand[s].orderTicket > 0)
     {
      if(OrderSelect(g_hand[s].orderTicket))
        {
         if(g_trade.OrderDelete(g_hand[s].orderTicket))
            OnDeclared("[" + g_tf[s].tfName + "] resting order cancelled - plan " + reason);
         else
           {
            AddEvent("[" + g_tf[s].tfName + "] order cancel refused (" +
                     g_trade.ResultRetcodeDescription() + ") - will retry");
            done = false;                                  // keep the hand, retry next tick
           }
        }
      else
         OnDeclared("[" + g_tf[s].tfName + "] resting order already gone - plan " + reason);
     }
   if(done && g_hand[s].posTicket > 0 && !g_hand[s].userOverride && !g_hand[s].userClosed)
     {
      if(PositionSelectByTicket(g_hand[s].posTicket))
        {
         if(g_trade.PositionClose(g_hand[s].posTicket))
            OnDeclared("[" + g_tf[s].tfName + "] position closed at market - plan " + reason);
         else
           {
            AddEvent("[" + g_tf[s].tfName + "] close refused (" +
                     g_trade.ResultRetcodeDescription() + ") - will retry");
            return;                                        // keep the hand for the retry
           }
        }
      else
         OnDeclared("[" + g_tf[s].tfName + "] position already gone - plan " + reason);
     }
   if(done)
     {
      HandsResetSlot(s);
      SavePlans();
     }
  }

//--------------------------------------------------------------------
// restart recovery: broker holds the truth, the file holds the plans
//--------------------------------------------------------------------
void HandsReconcile()
  {
   for(int s=0; s<2; s++)
     {
      if(!g_tf[s].decl.active)
        {
         if(!g_hand[s].linked) HandsResetSlot(s);
         continue;
        }
      ulong pt = FindBotPosition(s);
      ulong ot = FindBotOrder(s);
      if(pt > 0)
        {
         g_hand[s].posTicket   = pt;
         g_hand[s].linked      = true;
         g_hand[s].wasLinked   = true;
         g_hand[s].planTime    = g_tf[s].decl.tDeclare;
         g_hand[s].sentSL      = PositionGetDouble(POSITION_SL);
         g_hand[s].sentTP      = PositionGetDouble(POSITION_TP);
         g_hand[s].sentLot     = PositionGetDouble(POSITION_VOLUME);
         g_hand[s].partialDone = g_tf[s].decl.beArmed;
         AddEvent("[" + g_tf[s].tfName + "] restored: position re-linked to the saved plan - caretaking resumed");
        }
      else if(ot > 0)
        {
         g_hand[s].orderTicket = ot;
         g_hand[s].linked      = true;
         g_hand[s].wasLinked   = true;
         g_hand[s].planTime    = g_tf[s].decl.tDeclare;
         g_hand[s].sentSL      = OrderGetDouble(ORDER_SL);
         g_hand[s].sentTP      = OrderGetDouble(ORDER_TP);
         g_hand[s].sentLot     = OrderGetDouble(ORDER_VOLUME_CURRENT);
         AddEvent("[" + g_tf[s].tfName + "] restored: resting order re-linked to the saved plan");
        }
      else if(g_hand[s].wasLinked)
        {
         g_hand[s].userClosed = true;
         AddEvent("[" + g_tf[s].tfName + "] saved plan's order/position not found at restart - bot stands aside");
        }
     }
  }

//--------------------------------------------------------------------
// plan persistence (small binary file, terminal Files folder)
//--------------------------------------------------------------------
void SavePlans()
  {
   int f = FileOpen(TRADES_FILE, FILE_WRITE|FILE_BIN);
   if(f == INVALID_HANDLE) return;
   FileWriteInteger(f, 2);                                  // layout version
   for(int s=0; s<2; s++)
     {
      SDecl d = g_tf[s].decl;
      FileWriteInteger(f, d.active ? 1 : 0);
      FileWriteInteger(f, d.tfSlot);
      FileWriteInteger(f, d.dir);
      FileWriteLong(f, (long)d.tDeclare);
      FileWriteDouble(f, d.entry);   FileWriteDouble(f, d.sl);    FileWriteDouble(f, d.tp1);
      FileWriteDouble(f, d.lots);    FileWriteDouble(f, d.remLots); FileWriteDouble(f, d.bestFav);
      FileWriteDouble(f, d.beLevel); FileWriteDouble(f, d.risk0);
      FileWriteInteger(f, d.tpUpdates);
      FileWriteInteger(f, d.durBars);
      FileWriteInteger(f, d.barsAge);
      FileWriteInteger(f, d.beArmed ? 1 : 0);
      FileWriteInteger(f, d.outcome);
      FileWriteLong(f, (long)g_hand[s].orderTicket);
      FileWriteLong(f, (long)g_hand[s].posTicket);
      FileWriteInteger(f, g_hand[s].linked ? 1 : 0);
      FileWriteInteger(f, g_hand[s].wasLinked ? 1 : 0);
      FileWriteInteger(f, g_hand[s].partialDone ? 1 : 0);
      FileWriteInteger(f, g_hand[s].userClosed ? 1 : 0);
      FileWriteInteger(f, g_hand[s].userOverride ? 1 : 0);
      FileWriteDouble(f, g_hand[s].sentSL);
      FileWriteDouble(f, g_hand[s].sentTP);
      FileWriteDouble(f, g_hand[s].sentLot);
     }
   FileClose(f);
  }

void LoadPlans()
  {
   if(!FileIsExist(TRADES_FILE)) return;
   int f = FileOpen(TRADES_FILE, FILE_READ|FILE_BIN);
   if(f == INVALID_HANDLE) return;
   if(FileReadInteger(f) != 2) { FileClose(f); return; }    // unknown layout: start clean
   for(int s=0; s<2; s++)
     {
      SDecl d;
      d.active    = (FileReadInteger(f) != 0);
      d.tfSlot    = FileReadInteger(f);
      d.dir       = FileReadInteger(f);
      d.tDeclare  = (datetime)FileReadLong(f);
      d.entry     = FileReadDouble(f);
      d.sl        = FileReadDouble(f);
      d.tp1       = FileReadDouble(f);
      d.lots      = FileReadDouble(f);
      d.remLots   = FileReadDouble(f);
      d.bestFav   = FileReadDouble(f);
      d.beLevel   = FileReadDouble(f);
      d.risk0     = FileReadDouble(f);
      d.tpUpdates = FileReadInteger(f);
      d.durBars   = FileReadInteger(f);
      d.barsAge   = FileReadInteger(f);
      d.beArmed   = (FileReadInteger(f) != 0);
      d.outcome   = FileReadInteger(f);
      d.branch    = "(restored)";
      g_tf[s].decl = d;
      g_hand[s].orderTicket = (ulong)FileReadLong(f);
      g_hand[s].posTicket   = (ulong)FileReadLong(f);
      g_hand[s].linked      = (FileReadInteger(f) != 0);
      g_hand[s].wasLinked   = (FileReadInteger(f) != 0);
      g_hand[s].partialDone = (FileReadInteger(f) != 0);
      g_hand[s].userClosed  = (FileReadInteger(f) != 0);
      g_hand[s].userOverride    = (FileReadInteger(f) != 0);
      g_hand[s].sentSL      = FileReadDouble(f);
      g_hand[s].sentTP      = FileReadDouble(f);
      g_hand[s].sentLot     = FileReadDouble(f);
      if(d.active)
         AddEvent("[" + g_tf[s].tfName + "] plan restored from disk" +
                  (d.beArmed ? " (+1R armed)" : ""));
     }
   FileClose(f);
  }

//--------------------------------------------------------------------
// the hands' master pass (every tick; actions on transitions only)
//--------------------------------------------------------------------
void HandsThink()
  {
   if(!g_tfOK) return;
   for(int s=0; s<2; s++)
     {
      if(g_hand[s].orderTicket > 0) CheckPending(s);
      if(g_hand[s].posTicket  > 0) CheckPosition(s);

      bool active = g_tf[s].decl.active;
      if(!active)
        {
         if(g_hand[s].linked || g_hand[s].orderTicket > 0 || g_hand[s].posTicket > 0)
            HandsOnPlanEnd(s, OutcomeText(g_tf[s].decl.outcome));
         else if(g_hand[s].planTime != 0)
            HandsResetSlot(s);
         continue;
        }
      // a NEW plan inherited an old hand (supersede path): retire the old order first
      if(g_hand[s].planTime != g_tf[s].decl.tDeclare &&
         (g_hand[s].linked || g_hand[s].wasLinked))
        {
         HandsOnPlanEnd(s, "superseded");
         continue;                                          // new plan placed next tick, clean hand
        }
      // the master switch gates NEW placements only - an already-linked
      // order/position keeps obeying its plan (the LAW: same ending, same second)
      if(!g_hand[s].linked)
        {
         if(InpAutoTrade && ModeAllows(s) && g_msState == MS_OPEN &&
            !g_hand[s].userClosed && !g_hand[s].suspended && !g_hand[s].wasLinked)
            HandsPlace(s);
         continue;
        }
      if(g_hand[s].orderTicket > 0) HandsBridgePending(s);  // resting order follows the plan
      if(g_hand[s].posTicket == 0 && g_hand[s].orderTicket == 0)
        {
         ulong pt = FindBotPosition(s);                     // market fill linkage
         if(pt > 0)
           {
            g_hand[s].posTicket = pt;
            g_hand[s].sentSL   = PositionGetDouble(POSITION_SL);
            g_hand[s].sentTP   = PositionGetDouble(POSITION_TP);
            g_hand[s].sentLot  = PositionGetDouble(POSITION_VOLUME);
           }
        }
      if(g_hand[s].posTicket > 0) Caretake(s);
     }
  }

//====================================================================//
//  PANELS                                                            //
//====================================================================//

void AddRow(string &rows[], color &cols[], int &n, string s, color c)
  {
   int cap = ArraySize(rows);
   if(n >= cap) return;
   rows[n] = s; cols[n] = c; n++;
  }

void PaintPanel(string pfx, int x0, int y0, int width, string &rows[], color &cols[], int n)
  {
   int rowH = PANEL_FONT + 7;
   int height = n*rowH + 14;
   string bg = pfx + "BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, CLR_BG);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, CLR_BORDER);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, x0);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, y0);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, height);

   for(int i=0; i<64; i++)
     {
      string nm = pfx + "R" + IntegerToString(i);
      if(i >= n)
        {
         if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
         continue;
        }
      if(ObjectFind(0, nm) < 0)
        {
         ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
         ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, PANEL_FONT);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
        }
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x0 + 10);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y0 + 8 + i*rowH);
      ObjectSetString(0, nm, OBJPROP_TEXT, rows[i]);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, cols[i]);
     }
   ChartRedraw(0);
  }

string MarketStateText()
  {
   if(g_msState==MS_OPEN)   return("OPEN" + (g_msNote!="" ? "  (" + g_msNote + ")" : ""));
   if(g_msState==MS_CLOSED) return("CLOSED");
   return("HOLD");
  }

string DeclLine(const SDecl &d, bool compact)
  {
   string dir = (d.dir>0 ? "BUY" : "SELL");
   string base = "[" + (d.tfSlot==0 ? "M5" : "M15") + "] " + dir + "  " + d.branch +
                 "  @ " + TimeToString(d.tDeclare, TIME_MINUTES);
   if(compact) return(base);
   return(base +
          "\nentry " + DoubleToString(d.entry,_Digits) +
          "   SL " + DoubleToString(d.sl,_Digits) +
          "\nTP " + DoubleToString(d.tp1,_Digits) +
          (d.tpUpdates > 0 ? "  (updated " + IntegerToString(d.tpUpdates) + "x by candles)" : "") +
          "\nlot " + DoubleToString(d.remLots,2) +
          (d.remLots < d.lots ? " of " + DoubleToString(d.lots,2) : "") +
          "\ntime-left " +
          IntegerToString((d.durBars - d.barsAge > 0 ? d.durBars - d.barsAge : 0)) +
          " of " + IntegerToString(d.durBars) + " bars" +
          "\nmgmt: partial@+1R, BE, TP follows the candles");
  }

void CleanupDetails()
  {
   if(ObjectFind(0, OBJ_P+"D_BG") >= 0) ObjectDelete(0, OBJ_P+"D_BG");
   for(int i=0; i<64; i++)
     {
      string nm = OBJ_P+"D_R"+IntegerToString(i);
      if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
     }
  }

void RenderAll()
  {
   string mr[]; color mc[]; int mn=0;
   ArrayResize(mr, 48); ArrayResize(mc, 48);

   AddRow(mr, mc, mn, "SmartTrader Mi1 - the brain (no orders)", CLR_HEAD);

   bool connOK = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   string symType = g_pr.typeName;
   AddRow(mr, mc, mn,
          _Symbol + " [" + symType + "]  " + MarketStateText() +
          (connOK ? "" : "  NO CONNECTION") +
          "  spread " + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts",
          (g_msState==MS_OPEN ? (connOK ? CLR_NEUT : CLR_DN) : CLR_ATT));

   if(g_msState != MS_OPEN)
     {
      if(g_msState==MS_CLOSED && g_msNote != "")
         AddRow(mr, mc, mn, g_msNote, CLR_ATT);
      if(g_msState==MS_HOLD && g_msNote != "")
         AddRow(mr, mc, mn, g_msNote, CLR_ATT);
      AddRow(mr, mc, mn, "forecasting paused - market not open", CLR_DIM);
      PaintPanel(OBJ_P+"M_", 8, 8, MAIN_W, mr, mc, mn);
      CleanupDetails();
      return;
     }

   // countdown (chart timeframe)
   datetime cb = iTime(_Symbol, _Period, 0);
   long left = (long)(cb + PeriodSeconds(_Period) - TimeCurrent());
   if(left < 0) left = 0;
   AddRow(mr, mc, mn, "chart TF " + StringSubstr(EnumToString(_Period),7) +
          "  |  bar closes in " + IntegerToString((int)(left/60)) + ":" +
          (left%60<10 ? "0" : "") + IntegerToString((int)(left%60)) +
          "  |  risk " + DoubleToString(InpRiskPercent,1) + "%/trade", CLR_DIM);

   // trend read (both timeframes, F2)
   for(int s=0; s<2; s++)
     {
      string ln = g_tf[s].tfName + ": " + (g_tf[s].ready ? g_tf[s].trendLine : "warming up...");
      color lc = (g_tf[s].tDir>0 ? CLR_UP : (g_tf[s].tDir<0 ? CLR_DN : CLR_NEUT));
      AddRow(mr, mc, mn, ln, lc);
     }

   // declaration (most recent active, else none) - section 5
   AddRow(mr, mc, mn, "DECLARATION", CLR_HEAD);
   int showSlot=-1;
   for(int s=0; s<2; s++)
      if(g_tf[s].decl.active) { showSlot = s; break; }
   if(showSlot < 0)
     {
      // most recent resolved?
      if(g_memN > 0)
         AddRow(mr, mc, mn, "no active declaration - last: " +
                (g_mem[0].dir>0?"BUY ":"SELL ") + g_mem[0].branch + " -> " + g_memNote[0], CLR_DIM);
      else
         AddRow(mr, mc, mn, "no active declaration - waiting for a branch execution", CLR_DIM);
     }
   else
     {
      string dl = DeclLine(g_tf[showSlot].decl, false);
      bool firstLine = true;
      int start=0;
      while(start < StringLen(dl))
        {
         int p = StringFind(dl, "\n", start);
         string part = (p<0 ? StringSubstr(dl, start) : StringSubstr(dl, start, p-start));
         AddRow(mr, mc, mn, part, (firstLine ? CLR_ENTRY : CLR_NEUT));
         firstLine = false;
         if(p<0) break;
         start = p+1;
        }
     }

   // memory line (compact)
   if(g_memN > 0)
     {
      string mem = "memory: ";
      for(int i=0; i<MathMin(g_memN,3); i++)
        {
         if(i>0) mem += " | ";
         mem += (g_mem[i].dir>0?"BUY ":"SELL ") + OutcomeText(g_mem[i].outcome);
        }
      AddRow(mr, mc, mn, mem, CLR_DIM);
     }

   // event line (section 6)
   AddRow(mr, mc, mn, "event: " + (g_eventN>0 ? g_events[0] : "none yet"), CLR_ATT);

   //--- autotrading section (Mi2 panel contract: below the event line)
   {
    string modeTxt = (InpAutoMode==AUTO_BOTH ? "both" :
                      (InpAutoMode==AUTO_M5_ONLY ? "M5 only" : "M15 only"));
    string hdr = (!InpAutoTrade ? "AUTOTRADING OFF - forecast only"
                 : "AUTOTRADING ON (" + modeTxt + ") [" + (g_hedging ? "hedging" : "netting") + "] " +
                   g_accCur + (TradeAllowed() ? "" : "  BLOCKED - enable Algo Trading"));
    AddRow(mr, mc, mn, hdr, CLR_ATT);
    for(int s=0; s<2; s++)
      {
       SDecl d = g_tf[s].decl;
       string tf = g_tf[s].tfName;
       if(!d.active || (!g_hand[s].linked && !g_hand[s].wasLinked))
         {
          AddRow(mr, mc, mn, tf + "  -- entry --   lot --", CLR_DIM);
          AddRow(mr, mc, mn, "     sl --   tp --   p/l --", CLR_DIM);
          continue;
         }
       bool havePos = (g_hand[s].posTicket > 0 && PositionSelectByTicket(g_hand[s].posTicket));
       bool pend    = (g_hand[s].orderTicket > 0);
       if(pend && !havePos)
         {
          double msm = MoneyFor(d.sl    - d.entry, d.remLots)*d.dir;
          double mtp = MoneyFor(d.tp1   - d.entry, d.remLots)*d.dir;
          AddRow(mr, mc, mn, tf + "  LIMIT " + (d.dir>0?"BUY ":"SELL ") +
                 DoubleToString(d.remLots,2) + " @ " + DoubleToString(d.entry,_Digits) + " (waiting)", CLR_ATT);
          AddRow(mr, mc, mn, "     SL " + DoubleToString(d.sl,_Digits) + " (" + MSM(msm) + ")  TP " +
                 DoubleToString(d.tp1,_Digits) + " (" + MSM(mtp) + ")  P/L --", CLR_NEUT);
         }
       else if(havePos)
         {
          double vol = PositionGetDouble(POSITION_VOLUME);
          double op  = PositionGetDouble(POSITION_PRICE_OPEN);
          double slp = PositionGetDouble(POSITION_SL);
          double tpp = PositionGetDouble(POSITION_TP);
          double pl  = PositionGetDouble(POSITION_PROFIT);
          AddRow(mr, mc, mn, tf + "  " + (d.dir>0?"BUY ":"SELL ") + DoubleToString(vol,2) +
                 "  entry " + DoubleToString(op,_Digits), (pl>=0 ? CLR_UP : CLR_DN));
          double msm = MoneyFor(slp - op, vol)*d.dir;
          double mtp = MoneyFor(tpp - op, vol)*d.dir;
          AddRow(mr, mc, mn, "     SL " + DoubleToString(slp,_Digits) + " (" + MSM(msm) + ")  TP " +
                 DoubleToString(tpp,_Digits) + " (" + MSM(mtp) + ")  P/L " + MSM(pl), CLR_NEUT);
         }
       else
         {
          AddRow(mr, mc, mn, tf + "  (bot stood aside - order/position closed externally)", CLR_DIM);
          AddRow(mr, mc, mn, "     sl --   tp --   p/l --", CLR_DIM);
         }
      }
   }

   PaintPanel(OBJ_P+"M_", 8, 8, MAIN_W, mr, mc, mn);

   //--- details panel (right of main panel)
   if(!InpShowDetails)
     {
      CleanupDetails();
      return;
     }

   string dr[]; color dc[]; int dn=0;
   int capD = 60;
   ArrayResize(dr, capD); ArrayResize(dc, capD);

   AddRow(dr, dc, dn, "DETAILS - analyst view", CLR_HEAD);
   for(int s=0; s<2; s++)
     {
      AddRow(dr, dc, dn, "[" + g_tf[s].tfName + "] trend: " +
             (g_tf[s].ready ? g_tf[s].trendLine : "warming up..."), CLR_NEUT);
      if(!g_tf[s].ready) continue;
      AddRow(dr, dc, dn, "[" + g_tf[s].tfName + "] vwap " + DoubleToString(g_tf[s].vwap,_Digits) +
             "  speed " + DoubleToString(g_tf[s].speed/_Point,1) + " pts/bar", CLR_DIM);
      AddRow(dr, dc, dn, "[" + g_tf[s].tfName + "] MAP " + IntegerToString(g_tf[s].nZones) +
             " zones  -  " + g_tf[s].locLine, CLR_HEAD);
      for(int z=0; z<g_tf[s].nZones; z++)
        {
         string role = (g_tf[s].zones[z].price > g_tf[s].r[1].close ? "RES" : "SUP");
         if(g_tf[s].zones[z].brokenDir != 0) role += "(flipped)";
         if(g_tf[s].zones[z].isLifeline)     role += "(LIFE)";
         AddRow(dr, dc, dn,
                " " + role + " " + DoubleToString(g_tf[s].zones[z].price,_Digits) +
                "  s" + DoubleToString(g_tf[s].zones[z].strength,0) +
                "  t" + IntegerToString(g_tf[s].zones[z].touches) + "x" +
                "  [" + g_tf[s].zones[z].tagStr + "]" +
                "  slB " + DoubleToString(g_tf[s].zones[z].slForBuy,_Digits) +
                " slS " + DoubleToString(g_tf[s].zones[z].slForSell,_Digits),
                (g_tf[s].zones[z].strength>=60 ? CLR_ATT : CLR_NEUT));
        }
      AddRow(dr, dc, dn, "[" + g_tf[s].tfName + "] VERDICT", CLR_HEAD);
      for(int b=0; b<3; b++)
        {
         if(!g_tf[s].br[b].used) continue;
         string bl = " " + g_tf[s].br[b].name +
                     " -> " + DoubleToString(g_tf[s].br[b].target1,_Digits) +
                     " (~" + IntegerToString(g_tf[s].br[b].bars) + " bars)" +
                     " inv " + DoubleToString(g_tf[s].br[b].invalid,_Digits);
         color bc = CLR_NEUT;
         if(StringFind(g_tf[s].trackLine, g_tf[s].br[b].name) >= 0) { bl += "  <== tracking"; bc = CLR_ATT; }
         if(g_tf[s].br[b].status == BR_EXEC) { bl += "  [EXECUTED]"; bc = CLR_UP; }
         AddRow(dr, dc, dn, bl, bc);
        }
      AddRow(dr, dc, dn, "[" + g_tf[s].tfName + "] DECLARATION", CLR_HEAD);
      if(g_tf[s].decl.active)
        {
         string dl = DeclLine(g_tf[s].decl, false);
         int start=0;
         while(start < StringLen(dl))
           {
            int p = StringFind(dl, "\n", start);
            string part = (p<0 ? StringSubstr(dl,start) : StringSubstr(dl,start,p-start));
            AddRow(dr, dc, dn, " " + part, CLR_ENTRY);
            if(p<0) break;
            start = p+1;
           }
        }
      else
         AddRow(dr, dc, dn, " none active", CLR_DIM);
      AddRow(dr, dc, dn, "", CLR_NEUT);
     }
   AddRow(dr, dc, dn, "EVENTS", CLR_HEAD);
   for(int i=0; i<MathMin(g_eventN,6); i++)
      AddRow(dr, dc, dn, " " + g_events[i], CLR_DIM);

   // geometry: right of main panel, same top line
   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
   int dW = 470;
   if(chartW > 100) dW = (int)MathMin(470.0, MathMax(300.0, chartW*0.55));
   PaintPanel(OBJ_P+"D_", 8 + MAIN_W + 12, 8, dW, dr, dc, dn);
  }

//====================================================================//
//  EVENT HANDLERS                                                    //
//====================================================================//

//+------------------------------------------------------------------+
//  F1: out-of-range notice - the EA STAYS on the chart and says why
//+------------------------------------------------------------------+
void PaintOutOfRange()
  {
   string rows[4]; color cols[4]; int n = 0;
   AddRow(rows, cols, n, "SmartTrader", CLR_HEAD);
   AddRow(rows, cols, n, "OUT OF RANGE - chart TF is " +
          StringSubstr(EnumToString(_Period), 7), CLR_ATT);
   AddRow(rows, cols, n, "return to M5 or M15", CLR_ATT);
   AddRow(rows, cols, n, "the panel returns on its own when you switch back", CLR_DIM);
   PaintPanel(OBJ_P+"M_", 8, 8, MAIN_W, rows, cols, n);
  }

int OnInit()
  {
   //--- F1: timeframe guard - stay attached, show the message (never unload)
   g_tfOK = (_Period == PERIOD_M5 || _Period == PERIOD_M15);
   if(!g_tfOK)
     {
      Print("SmartTrader: chart TF ", EnumToString(_Period),
            " out of range - return to M5/M15; the panel returns on its own.");
      EventSetTimer(1);
      PaintOutOfRange();
      return(INIT_SUCCEEDED);
     }

   //--- F4: symbol type + F5 profile
   InitProfile(ClassifySymbol(_Symbol));

   //--- F2: both timeframe brains
   g_tf[0].Configure(PERIOD_M5,  "M5",  0);
   g_tf[1].Configure(PERIOD_M15, "M15", 1);

   //--- F3: market state first
   UpdateMarketState();

   //--- Mi2: the hands (account facts, trade engine, restore + reconcile)
   g_hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_accCur  = AccountInfoString(ACCOUNT_CURRENCY);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(20);
   LoadPlans();
   HandsReconcile();

   EventSetTimer(1);
   Print("SmartTrader Mi1 started on ", _Symbol, " [", g_pr.typeName, "] chart ",
         EnumToString(_Period), " - brain only: trend, map, verdict, declarations. No orders.");
   RenderAll();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   SavePlans();                              // persist before unload (restart recovery)
   EventKillTimer();
   ObjectsDeleteAll(0, OBJ_P);
   ChartRedraw(0);
   Print("SmartTrader Mi1 stopped (reason ", reason, ").");
  }

void OnTick()
  {
   if(!g_tfOK) { PaintOutOfRange(); return; }
   UpdateMarketState();                    // F3: state first, every tick
   if(g_msState == MS_OPEN)
     {
      g_tf[0].OnNewBar();                  // F2: both TFs, each on own nature
      g_tf[1].OnNewBar();
      g_tf[0].ManageAndDetect(g_tf[1].tDir, g_tf[1].tRegime);
      g_tf[1].ManageAndDetect(g_tf[0].tDir, g_tf[0].tRegime);
     }
   HandsThink();                            // Mi2: the hands (internally gated)
   RenderAll();
  }

void OnTimer()
  {
   if(!g_tfOK) { PaintOutOfRange(); return; }
   UpdateMarketState();
   RenderAll();
  }
//+------------------------------------------------------------------+

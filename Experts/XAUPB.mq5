//+------------------------------------------------------------------+
//|                                                       XAUPB.mq5 |
//|                                          Copyright 2024, Geraked |
//|                                       https://github.com/geraked |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2024, Geraked"
#property link        "https://github.com/geraked"
#property version     "1.0"
#property description "XAUUSD pullback-window strategy (EMA cross -> pullback -> breakout)"
#property description "with ADX/EMA trend filter, session, ATR volatility, ATR SL/TP,"
#property description "breakeven/trailing, cooldown and daily loss guard. Grid is OFF by default."
#property description "Designed for XAUUSD M5 - must be optimized/validated by the user."

#include <EAGuards.mqh>

input group "Indicator Parameters"
input int EmaFastLen = 14; // EMA Fast
input int EmaMedLen = 18; // EMA Medium
input int EmaSlowLen = 24; // EMA Slow
input int AtrLen = 14; // ATR Period
input double MinAngle = 10; // Min EMA Angle (Degrees, 0: Disable)
input int AngleBars = 3; // EMA Angle Lookback (Bars)

input group "Pullback Window"
input int PbMinCandles = 1; // Min Pullback Candles
input int PbMaxCandles = 3; // Max Pullback Candles
input int WindowBars = 2; // Entry Window (Bars)
input double BreakoutOffsetATR = 0.1; // Breakout Offset (x ATR)
input bool UseLong = true; // Allow Long
input bool UseShort = true; // Allow Short

input group "SL / TP"
input double SLATR = 2.5; // SL (x ATR)
input double TPATR = 6.0; // TP (x ATR)
input double BEFrac = 0.5; // Breakeven at Fraction of TP Distance (0: Disable)
input int BEBuffer = 20; // Breakeven Buffer (Points)
input double TrailStartATR = 0; // Trail Start (x ATR) (0: Disable)
input double TrailATR = 2.0; // Trail Distance (x ATR)

input group "Filters"
input int AdxLen = 14; // ADX Period
input double AdxMin = 25; // Min ADX (0: Disable)
input int TrendEmaLen = 100; // Trend EMA (0: Disable)
input int SessionStart = 7; // Session Start Hour, Server Time (Start==End: Disable)
input int SessionEnd = 20; // Session End Hour, Server Time
input bool NoFridayLate = true; // No New Trades Late Friday
input int FridayCutoff = 18; // Friday Cutoff Hour
input double AtrMinRatio = 0.7; // Min ATR / Avg ATR (0: Disable)
input double AtrMaxRatio = 2.5; // Max ATR / Avg ATR (0: Disable)
input int CooldownBars = 36; // Cooldown After SL (Bars) (0: Disable)

input group "Risk Management"
input double Risk = 1.0; // Risk (%)
input ENUM_RISK RiskMode = RISK_DEFAULT; // Risk Mode
input double DailyLossLimit = 3.0; // Daily Loss Limit (%) (0: Disable)
input double EquityDrawdownLimit = 0; // Equity Drawdown Limit (%) (0: Disable)
input double MaxTotalLots = 0; // Max Total Lots (0: Disable)

input group "Strategy: Grid (high risk, off by default)"
input bool Grid = false; // Grid Enable
input double GridVolMult = 1.0; // Grid Volume Multiplier
input double GridTrailingStopLevel = 0; // Grid Trailing Stop Level (%) (0: Disable)
input int GridMaxLvl = 4; // Grid Max Levels
input double BasketLossLimit = 8.0; // Basket Loss Limit (% of Equity) (0: Disable)

input group "News"
input bool News = true; // News Enable
input ENUM_NEWS_IMPORTANCE NewsImportance = NEWS_IMPORTANCE_HIGH; // News Importance
input int NewsMinsBefore = 60; // News Minutes Before
input int NewsMinsAfter = 60; // News Minutes After
input int NewsStartYear = 0; // News Start Year to Fetch for Backtesting (0: Disable)

input group "Open Position Limit"
input bool OpenNewPos = true; // Allow Opening New Position
input double MarginLimit = 300; // Margin Limit (%) (0: Disable)
input int SpreadLimit = 60; // Spread Limit (Points) (-1: Disable)

input group "Auxiliary"
input int Slippage = 30; // Slippage (Points)
input int TimerInterval = 30; // Timer Interval (Seconds)
input ulong MagicNumber = 2000; // Magic Number
input ENUM_FILLING Filling = FILLING_DEFAULT; // Order Filling

enum PBState { PB_SCANNING, PB_ARMED, PB_WINDOW };

GerEA ea;
datetime lastCandle;
datetime tc;
datetime lastSlTime;
int hFast, hMed, hSlow, hTrend, hAtr, hAdx;
double eFast[], eMed[], eSlow[], eTrend[], atrBuf[];

// state machine (one direction at a time; dir: 1 long, -1 short)
PBState state = PB_SCANNING;
int dir = 0;
int pbCount = 0;
int windowLeft = 0;
double breakout = 0;
double pbExtreme = 0;
double stateAtr = 0;

//+------------------------------------------------------------------+
//| EMA slope normalized by ATR, in degrees                          |
//+------------------------------------------------------------------+
double EmaAngle(const double &ema[], double atr) {
    if (atr <= 0) return 0;
    double slope = (ema[1] - ema[1 + AngleBars]) / AngleBars;
    return MathArctan(slope / atr) * 180.0 / M_PI;
}

//+------------------------------------------------------------------+
//| Global filters shared by both directions                         |
//+------------------------------------------------------------------+
bool FiltersOk() {
    if (!InSession(SessionStart, SessionEnd)) return false;
    if (!TradingDayOk(NoFridayLate, FridayCutoff)) return false;
    if (!AtrRatioOk(hAtr, 50, AtrMinRatio, AtrMaxRatio)) return false;
    if (SpreadLimit != -1 && Spread() > SpreadLimit) return false;
    if (CooldownBars > 0 && lastSlTime > 0 && TimeCurrent() - lastSlTime < CooldownBars * PeriodSeconds()) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Direction filter: ADX + trend EMA                                |
//+------------------------------------------------------------------+
bool TrendOk(int d) {
    if (AdxMin > 0 && !RegimeOk(hAdx, 1, AdxMin)) return false;
    if (TrendEmaLen > 0) {
        if (d > 0 && Close(1) <= eTrend[1]) return false;
        if (d < 0 && Close(1) >= eTrend[1]) return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Cross of price over fast EMA with stacked EMAs and angle         |
//+------------------------------------------------------------------+
int ScanSignal() {
    double atr = atrBuf[1];
    bool up = Close(2) <= eFast[2] && Close(1) > eFast[1] && eFast[1] > eMed[1] && eMed[1] > eSlow[1];
    bool dn = Close(2) >= eFast[2] && Close(1) < eFast[1] && eFast[1] < eMed[1] && eMed[1] < eSlow[1];
    if (up && UseLong && TrendOk(1) && (MinAngle <= 0 || EmaAngle(eFast, atr) >= MinAngle)) return 1;
    if (dn && UseShort && TrendOk(-1) && (MinAngle <= 0 || -EmaAngle(eFast, atr) >= MinAngle)) return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| State transitions on every new closed candle                     |
//+------------------------------------------------------------------+
void AdvanceState() {
    int sig = ScanSignal();

    // global invalidation: opposite signal resets setup
    if (state != PB_SCANNING && sig != 0 && sig != dir) {
        state = PB_SCANNING;
    }

    if (state == PB_SCANNING) {
        if (sig != 0) {
            state = PB_ARMED;
            dir = sig;
            pbCount = 0;
            pbExtreme = dir > 0 ? High(1) : Low(1);
            stateAtr = atrBuf[1];
        }
        return;
    }

    bool against = dir > 0 ? Close(1) < Open(1) : Close(1) > Open(1);
    bool along = dir > 0 ? Close(1) > Open(1) : Close(1) < Open(1);

    if (state == PB_ARMED) {
        // trend broke: price closed beyond the slow EMA
        if ((dir > 0 && Close(1) < eSlow[1]) || (dir < 0 && Close(1) > eSlow[1])) {
            state = PB_SCANNING;
            return;
        }
        if (against) {
            pbCount++;
            if (pbCount > PbMaxCandles) {
                state = PB_SCANNING;
                return;
            }
            pbExtreme = dir > 0 ? MathMax(pbExtreme, High(1)) : MathMin(pbExtreme, Low(1));
        } else if (along && pbCount >= PbMinCandles) {
            state = PB_WINDOW;
            windowLeft = WindowBars;
            stateAtr = atrBuf[1];
            double off = BreakoutOffsetATR * stateAtr;
            breakout = dir > 0 ? MathMax(pbExtreme, High(1)) + off : MathMin(pbExtreme, Low(1)) - off;
        }
        return;
    }

    if (state == PB_WINDOW) {
        windowLeft--;
        if (windowLeft <= 0) state = PB_SCANNING;
    }
}

//+------------------------------------------------------------------+
//| Tick-level breakout check while the entry window is open         |
//+------------------------------------------------------------------+
bool TryEntry() {
    if (state != PB_WINDOW) return false;
    if (!OpenNewPos) return false;
    if (!FiltersOk()) return false;
    if (MarginLimit && PositionsTotal() > 0 && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < MarginLimit) return false;
    if (ea.OPTotal() > 0) return false;
    if (MaxTotalLots > 0 && TotalVolume(ea.GetMagic()) >= MaxTotalLots) return false;
    if (DailyLossExceeded(ea.GetMagic(), DailyLossLimit * 0.01)) return false;

    double atr = stateAtr;
    if (atr <= 0) return false;

    if (dir > 0 && Ask() >= breakout) {
        double in = Ask();
        double sl = in - SLATR * atr;
        double tp = in + TPATR * atr;
        if (ea.BuyOpen(in, sl, tp, false, false)) { state = PB_SCANNING; return true; }
    } else if (dir < 0 && Bid() <= breakout) {
        double in = Bid();
        double sl = in + SLATR * atr;
        double tp = in - TPATR * atr;
        if (ea.SellOpen(in, sl, tp, false, false)) { state = PB_SCANNING; return true; }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Record time of the latest stop-loss exit for the cooldown        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    ulong d = trans.deal;
    if (!HistoryDealSelect(d)) return;
    if (HistoryDealGetInteger(d, DEAL_MAGIC) != (long) ea.GetMagic()) return;
    if (HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
    if (HistoryDealGetInteger(d, DEAL_REASON) == DEAL_REASON_SL && HistoryDealGetDouble(d, DEAL_PROFIT) < 0)
        lastSlTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    ea.Init();
    ea.SetMagic(MagicNumber);
    ea.risk = Risk * 0.01;
    ea.reverse = false;
    ea.trailingStopLevel = 0;
    ea.grid = Grid;
    ea.gridVolMult = GridVolMult;
    ea.gridTrailingStopLevel = GridTrailingStopLevel * 0.01;
    ea.gridMaxLvl = GridMaxLvl;
    ea.equityDrawdownLimit = EquityDrawdownLimit * 0.01;
    ea.slippage = Slippage;
    ea.news = News;
    ea.newsImportance = NewsImportance;
    ea.newsMinsBefore = NewsMinsBefore;
    ea.newsMinsAfter = NewsMinsAfter;
    ea.filling = Filling;
    ea.riskMode = RiskMode;

    if (RiskMode == RISK_FIXED_VOL || RiskMode == RISK_MIN_AMOUNT) ea.risk = Risk;
    if (News) fetchCalendarFromYear(NewsStartYear);

    if (EmaFastLen >= EmaMedLen || EmaMedLen >= EmaSlowLen || PbMinCandles > PbMaxCandles || AngleBars < 1) {
        Print("Invalid parameters: require Fast < Medium < Slow and PbMin <= PbMax");
        return INIT_PARAMETERS_INCORRECT;
    }

    hFast = iMA(NULL, 0, EmaFastLen, 0, MODE_EMA, PRICE_CLOSE);
    hMed = iMA(NULL, 0, EmaMedLen, 0, MODE_EMA, PRICE_CLOSE);
    hSlow = iMA(NULL, 0, EmaSlowLen, 0, MODE_EMA, PRICE_CLOSE);
    hTrend = TrendEmaLen > 0 ? iMA(NULL, 0, TrendEmaLen, 0, MODE_EMA, PRICE_CLOSE) : 0;
    hAtr = iATR(NULL, 0, AtrLen);
    hAdx = iADX(NULL, 0, AdxLen);

    if (hFast == INVALID_HANDLE || hMed == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE || hAdx == INVALID_HANDLE ||
        (TrendEmaLen > 0 && hTrend == INVALID_HANDLE)) {
        Print("Runtime error = ", GetLastError());
        return INIT_FAILED;
    }

    ArraySetAsSeries(eFast, true);
    ArraySetAsSeries(eMed, true);
    ArraySetAsSeries(eSlow, true);
    ArraySetAsSeries(eTrend, true);
    ArraySetAsSeries(atrBuf, true);

    EventSetTimer(TimerInterval);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    datetime oldTc = tc;
    tc = TimeCurrent();
    if (tc == oldTc) return;

    if (EquityDrawdownLimit) ea.CheckForEquity();
    if (Grid) ea.CheckForGrid();

    // hard guards: close everything on daily-loss / basket-loss breach
    if (DailyLossExceeded(ea.GetMagic(), DailyLossLimit * 0.01) || (Grid && BasketLossExceeded(ea.GetMagic(), BasketLossLimit * 0.01, _Symbol))) {
        ea.BuyClose();
        ea.SellClose();
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if (ea.OPTotal() > 0 && (BEFrac > 0 || TrailStartATR > 0)) {
        double a = Ind(hAtr, 1);
        if (a > 0) ManageAtrStops(ea.GetMagic(), _Symbol, a, BEFrac, BEBuffer, TrailStartATR, TrailATR);
    }

    if (lastCandle != Time(0)) {
        lastCandle = Time(0);

        int need = MathMax(AngleBars + 2, 3);
        if (CopyBuffer(hFast, 0, 0, need, eFast) < need) return;
        if (CopyBuffer(hMed, 0, 0, need, eMed) < need) return;
        if (CopyBuffer(hSlow, 0, 0, need, eSlow) < need) return;
        if (CopyBuffer(hAtr, 0, 0, 3, atrBuf) < 3) return;
        if (TrendEmaLen > 0 && CopyBuffer(hTrend, 0, 0, 3, eTrend) < 3) return;

        AdvanceState();
    }

    TryEntry();
}
//+------------------------------------------------------------------+

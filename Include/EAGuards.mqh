//+------------------------------------------------------------------+
//|                                                    EAGuards.mqh |
//| Reusable entry filters and risk guards (session, regime, ATR     |
//| breakeven/trailing, daily loss limit, basket loss limit).        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Geraked"
#property link      "https://github.com/geraked"

#include <EAUtils.mqh>

//+------------------------------------------------------------------+
//| Session filter (server time). Supports overnight ranges, e.g.    |
//| start=22, end=6. start==end disables the filter.                 |
//+------------------------------------------------------------------+
bool InSession(int startHour, int endHour, datetime t = 0) {
    if (startHour == endHour) return true;
    if (t == 0) t = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(t, dt);
    if (startHour < endHour) return dt.hour >= startHour && dt.hour < endHour;
    return dt.hour >= startHour || dt.hour < endHour;
}

//+------------------------------------------------------------------+
//| Day of week filter: false on Friday late hours / Sunday-Monday   |
//| early hours when requested.                                      |
//+------------------------------------------------------------------+
bool TradingDayOk(bool noFridayLate, int fridayCutoffHour, datetime t = 0) {
    if (t == 0) t = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(t, dt);
    if (noFridayLate && dt.day_of_week == 5 && dt.hour >= fridayCutoffHour) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Regime filter. mode: 0=off, 1=trend only (ADX >= level),         |
//| 2=range only (ADX < level). adxHandle is an iADX handle.         |
//+------------------------------------------------------------------+
bool RegimeOk(int adxHandle, int mode, double level, int shift = 1) {
    if (mode == 0) return true;
    double adx = Ind(adxHandle, shift, 0);
    if (adx < 0) return false;
    return mode == 1 ? adx >= level : adx < level;
}

//+------------------------------------------------------------------+
//| Volatility filter: current ATR must be within [minRatio,maxRatio]|
//| of its average over avgBars. 0 disables a bound.                 |
//+------------------------------------------------------------------+
bool AtrRatioOk(int atrHandle, int avgBars, double minRatio, double maxRatio, int shift = 1) {
    if (minRatio <= 0 && maxRatio <= 0) return true;
    double B[];
    if (CopyBuffer(atrHandle, 0, shift, avgBars, B) != avgBars) return false;
    double sum = 0;
    for (int i = 0; i < avgBars; i++) sum += B[i];
    double avg = sum / avgBars;
    if (avg <= 0) return false;
    double cur = B[avgBars - 1]; // CopyBuffer is oldest-first when not series
    double r = cur / avg;
    if (minRatio > 0 && r < minRatio) return false;
    if (maxRatio > 0 && r > maxRatio) return false;
    return true;
}

//+------------------------------------------------------------------+
//| ATR based breakeven + trailing for all positions of a magic.     |
//| beFrac:  move SL to entry once price covered this fraction of    |
//|          the distance to TP (0 = off, e.g. 0.5).                 |
//| trailStartATR / trailATR: start trailing after profit exceeds    |
//| trailStartATR*ATR and keep SL trailATR*ATR behind (0 = off).     |
//+------------------------------------------------------------------+
void ManageAtrStops(ulong magic, string symbol, double atr, double beFrac, double beBufferPoints, double trailStartATR, double trailATR) {
    if (atr <= 0) return;
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    int digits = (int) SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    long stopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minDist = (stopLevel + 5) * point;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!ticket) continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long) magic) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE) PositionGetInteger(POSITION_TYPE);
        double in = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double tp = PositionGetDouble(POSITION_TP);
        double price = type == POSITION_TYPE_BUY ? Bid(symbol) : Ask(symbol);
        double dir = type == POSITION_TYPE_BUY ? 1.0 : -1.0;
        double moved = (price - in) * dir;
        double newSL = sl;

        // Breakeven
        if (beFrac > 0 && tp > 0) {
            double full = MathAbs(tp - in);
            double be = in + dir * beBufferPoints * point;
            bool notYet = (sl == 0) || ((sl - be) * dir < 0);
            if (full > 0 && moved >= beFrac * full && notYet) newSL = be;
        }

        // ATR trailing
        if (trailATR > 0 && moved >= trailStartATR * atr) {
            double t = price - dir * trailATR * atr;
            if (newSL == 0 || (t - newSL) * dir > 0) newSL = t;
        }

        newSL = NormalizeDouble(newSL, digits);
        if (newSL == 0 || newSL == sl) continue;
        if ((newSL - sl) * dir <= 0 && sl != 0) continue;     // never loosen
        if ((price - newSL) * dir < minDist) continue;        // too close to market

        MqlTradeRequest req;
        MqlTradeResult res;
        ZeroMemory(req);
        ZeroMemory(res);
        req.action = TRADE_ACTION_SLTP;
        req.position = ticket;
        req.symbol = symbol;
        req.magic = magic;
        req.sl = newSL;
        req.tp = tp;
        if (!OrderSend(req, res))
            PrintFormat("%s error #%d : %s", __FUNCTION__, GetLastError(), ErrorDescription(GetLastError()));
    }
}

//+------------------------------------------------------------------+
//| Daily loss guard. Returns true while trading is blocked.         |
//| Counts closed deals of this magic since server-day start plus    |
//| floating P/L. When the loss exceeds limitPct of the day-start    |
//| balance, caller should close positions and stop opening.         |
//+------------------------------------------------------------------+
bool DailyLossExceeded(ulong magic, double limitPct) {
    if (limitPct <= 0) return false;
    datetime now = TimeCurrent();
    datetime dayStart = now - (now % 86400);
    if (!HistorySelect(dayStart, now + 60)) return false;

    double closed = 0;
    for (int i = HistoryDealsTotal() - 1; i >= 0; i--) {
        ulong d = HistoryDealGetTicket(i);
        if (!d) continue;
        if (HistoryDealGetInteger(d, DEAL_MAGIC) != (long) magic) continue;
        long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
        if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
        closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
    }

    double floating = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long) magic) continue;
        floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }

    double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
    if (startBalance <= 0) return true;
    return (closed + floating) <= -limitPct * startBalance;
}

//+------------------------------------------------------------------+
//| Basket guard for grid: true when the floating loss of all        |
//| positions of this magic on symbol exceeds limitPct of equity.    |
//+------------------------------------------------------------------+
bool BasketLossExceeded(ulong magic, double limitPct, string symbol = NULL) {
    if (limitPct <= 0) return false;
    double floating = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long) magic) continue;
        if (symbol != NULL && PositionGetString(POSITION_SYMBOL) != symbol) continue;
        floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    if (eq <= 0) return true;
    return floating <= -limitPct * eq;
}

//+------------------------------------------------------------------+
//| Total open volume of this magic (use as a hard grid lot cap).    |
//+------------------------------------------------------------------+
double TotalVolume(ulong magic, string symbol = NULL) {
    double v = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (!t) continue;
        if (PositionGetInteger(POSITION_MAGIC) != (long) magic) continue;
        if (symbol != NULL && PositionGetString(POSITION_SYMBOL) != symbol) continue;
        v += PositionGetDouble(POSITION_VOLUME);
    }
    return v;
}
//+------------------------------------------------------------------+

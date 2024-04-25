-- Strategy profile initialization routine
-- Defines Strategy profile properties and Strategy parameters
function Init()
    strategy:name("min1 Strategy");
    strategy:description("min1 Strategy");
	strategy:setTag("group", "Oscillators");
	strategy:setTag("NonOptimizableParameters", "Version,isNeedLogOrders");
    strategy:type(core.Both);

    strategy.parameters:addGroup("Price Parameters");
    strategy.parameters:addString("TF", "Time frame ('t1', 'm1', 'm5', etc.)", "", "H1");
    strategy.parameters:setFlag("TF", core.FLAG_PERIODS);
	strategy.parameters:addString("Type", "Price Type", "", "Bid");
    strategy.parameters:addStringAlternative("Type", "Bid", "", "Bid");
    strategy.parameters:addStringAlternative("Type", "Ask", "", "Ask");
	
    strategy.parameters:addGroup("Indicator Parameters");
	strategy.parameters:addInteger("Period", "Period", "Period of the moving average", 10, 1, 300);
	strategy.parameters:addDouble("Slope", "Slope", "Slope", 0.01, 0, 100);
	
    strategy.parameters:addGroup("Trading Parameters");
    strategy.parameters:addBoolean("AllowTrade", "Allow strategy to trade", "", false);
    strategy.parameters:setFlag("AllowTrade", core.FLAG_ALLOW_TRADE);
    strategy.parameters:addString("Account", "Account to trade on", "", "");
    strategy.parameters:setFlag("Account", core.FLAG_ACCOUNT);
	
	strategy.parameters:addGroup("")
    strategy.parameters:addDouble("Amount", "Trade Amount in Lots", "", 1, 0.01, 100);
    strategy.parameters:addBoolean("SetLimit", "Set Limit Orders", "", false);
    strategy.parameters:addInteger("Limit", "Limit Order in pips", "", 30, 1, 10000);
    strategy.parameters:addBoolean("SetStop", "Set Stop Orders", "", false);
    strategy.parameters:addInteger("Stop", "Stop Order in pips", "", 30, 1, 10000);
    strategy.parameters:addBoolean("TrailingStop", "Trailing stop order", "", false);
end

-- strategy instance initialization routine
-- Processes strategy parameters and creates output streams
-- Parameters block
local Period;
local Slope;
local openCounter;
local closeCounter;
------------
local MA;
local RSI;
local gSource = nil; -- the source stream
local AllowTrade;
local Account;
local Amount;
local BaseSize;
local SetLimit;
local Limit;
local SetStop;
local Stop;
local TrailingStop;
local Offer;
local CanClose;
--TODO: Add variable(s) for your indicator(s) if needed


-- Routine
function Prepare(nameOnly)
	Period = instance.parameters.Period;
	Slope = instance.parameters.Slope;
	
    local name = profile:id() .. "(" .. instance.bid:instrument() .. ", " .. tostring(MAPeriod) .. ", " .. tostring(Slope) .. ")";
    instance:name(name);

    if nameOnly then
        return ;
    end

    AllowTrade = instance.parameters.AllowTrade;
    if AllowTrade then
        Account = instance.parameters.Account;
        Amount = instance.parameters.Amount;
        BaseSize = core.host:execute("getTradingProperty", "baseUnitSize", instance.bid:instrument(), Account);
        Offer = core.host:findTable("offers"):find("Instrument", instance.bid:instrument()).OfferID;
        CanClose = core.host:execute("getTradingProperty", "canCreateMarketClose", instance.bid:instrument(), Account);
        SetLimit = instance.parameters.SetLimit;
        Limit = instance.parameters.Limit * instance.bid:pipSize();
        SetStop = instance.parameters.SetStop;
        Stop = instance.parameters.Stop * instance.bid:pipSize();
        TrailingStop = instance.parameters.TrailingStop;
    end

    gSource = ExtSubscribe(1, nil, instance.parameters.TF, instance.parameters.Type == "Bid", "bar");
	
    --TODO: Find indicator's profile, intialize parameters, and create indicator's instance (if needed)
	
	MA = core.indicators:create("KAMA", gSource, Period)
	RSI = core.indicators:create("RSI", gSource, Period)
end


-- strategy calculation routine
function ExtUpdate(id, source, period)
	
	MA:update(core.UpdateLast)
	RSI:update(core.UpdateLast)
	
	if RSI.DATA[period-1] < 30 and RSI.DATA[period] > 30 then
		openCounter = 2
	end
	
	if not haveTrades("S") then
		if openCounter == 2 and RSI.DATA[period] > 50 and MA.DATA[period] - MA.DATA[period-1] > Slope then
			if not haveTrades("B") then
				enter("B")
			end
		end
	end
	
	if haveTrades("B") and RSI.DATA[period-1] > 70 and RSI.DATA[period] < 70 then
		exit("B")
	end
	

	if RSI.DATA[period-1] > 70 and RSI.DATA[period] < 70 then
		openCounter = -2
	end
	
	if not haveTrades("B") then
		if openCounter == -2 and RSI.DATA[period] < 50 and MA.DATA[period] - MA.DATA[period-1] < (-Slope) then
			if not haveTrades("S") then
				enter("S")
			end
		end
	end
	
	if haveTrades("S") and RSI.DATA[period-1] < 30 and RSI.DATA[period] > 30 then
		exit("S")
	end
	
end


-- open positions in direction BuySell
function enter(BuySell)

    local valuemap, success, msg;
    valuemap = core.valuemap();

    valuemap.OrderType = "OM";
    valuemap.OfferID = Offer;
    valuemap.AcctID = Account;
    valuemap.Quantity = Amount * BaseSize;
    valuemap.BuySell = BuySell;
    valuemap.GTC = "GTC";

    if SetLimit then
        -- set limit order
        valuemap.PegTypeLimit = "O";
        if BuySell == "B" then
           valuemap.PegPriceOffsetPipsLimit = Limit/instance.bid:pipSize();
        else
           valuemap.PegPriceOffsetPipsLimit = -Limit/instance.bid:pipSize();
        end
    end

    if SetStop then
        -- set stop order
        valuemap.PegTypeStop = "O";
        if BuySell == "B" then
           valuemap.PegPriceOffsetPipsStop = -Stop/instance.bid:pipSize();
        else
           valuemap.PegPriceOffsetPipsStop = Stop/instance.bid:pipSize();
        end
		
		if TrailingStop then
            valuemap.TrailStepStop = 1;
        end
    end

    if (not CanClose) and (StopLoss > 0 or TakeProfit > 0) then
        valuemap.EntryLimitStop = "Y"
    end
    
    success, msg = terminal:execute(100, valuemap);

    if not(success) then
        terminal:alertMessage(instance.bid:instrument(), instance.bid[instance.bid:size() - 1], "open order failure: " .. msg, instance.bid:date(instance.bid:size() - 1));
        return false;
    end

    return true;
end


-- return true if trade is found (can check single side as well)
function haveTrades(BuySell)
    local enum, row;
    local found = false;
    enum = core.host:findTable("trades"):enumerator();
    row = enum:next();
    while (not found) and (row ~= nil) do
        if row.AccountID == Account and
           row.OfferID == Offer and
           (row.BS == BuySell or BuySell == nil) then
           found = true;
        end
        row = enum:next();
    end

    return found;
end


-- closes positions in direction BuySell
function exit(BuySell)
	enum = core.host:findTable("trades"):enumerator();
	row = enum:next();

	while row ~= nil do
		if row.OfferID == Offer and
		   row.AccountID == Account and
		   (row.BS == BuySell or BuySell == nil) then
		   
			-- close trade
			local valuemap = core.valuemap();
			valuemap.Command = "CreateOrder";
			valuemap.OrderType = "CM";
			valuemap.OfferID = Offer;
			valuemap.AcctID = Account;
			valuemap.Quantity = row.Lot;
			valuemap.TradeID = row.TradeID;
			if row.BS == "B" then
                valuemap.BuySell = "S";
			else
                valuemap.BuySell = "B";
			end
			local success, msg = terminal:execute(200, valuemap);
			if not (success) then
                terminal:alertMessage(instance.bid:instrument(), instance.bid[NOW], "close order failure:" .. msg, instance.bid:date(NOW));
			end

		end
		row = enum:next();
	end
end


dofile(core.app_path() .. "\\strategies\\standard\\include\\helper.lua");

local powerToWeight = require('overhaul/lib/vehicles/powerToWeight')
local M = {}
local defaults={minCashWagerMoney=250,maxCashWagerMoney=2000,cashWagerStepMoney=250,
  maxCashIncreaseMoney=250,maxCashDiscountMoney=500,counterConcessionFraction=0.5,
  patienceCount=3,refusalPatienceCostCount=1,repeatedRefusalPatienceCostCount=2}
local function copy(t) local result={};for k,v in pairs(t) do result[k]=v end;return result end
function M.fromConfig(data)
  if type(data)~='table' then return copy(defaults) end
  for k in pairs(defaults) do
    local value=data[k]
    if type(value)~='number' or value~=value or value<0 or value==math.huge
      or (k~='counterConcessionFraction' and value%1~=0) then return copy(defaults) end
  end
  local step=data.cashWagerStepMoney
  if step<1 or data.minCashWagerMoney<step or data.maxCashWagerMoney<data.minCashWagerMoney
    or data.minCashWagerMoney%step~=0 or data.maxCashWagerMoney%step~=0
    or data.maxCashIncreaseMoney%step~=0 or data.maxCashDiscountMoney%step~=0
    or data.refusalPatienceCostCount<1 or data.patienceCount<=data.refusalPatienceCostCount
    or data.repeatedRefusalPatienceCostCount<data.refusalPatienceCostCount
    or data.counterConcessionFraction<=0 or data.counterConcessionFraction>1 then return copy(defaults) end
  local result={};for k in pairs(defaults) do result[k]=data[k] end;return result
end
local ok,data=false,nil
if type(jsonReadFile)=='function' then ok,data=pcall(jsonReadFile,'/gameplay/overhaul/streetChallenges/negotiation.json') end
M.tuning=M.fromConfig(ok and data or nil)
local function finite(n) return type(n)=='number' and n==n and n>0 and n<math.huge end
M.ratio = powerToWeight.ratio
M.confidence = powerToWeight.confidence
function M.wager(player, opponent, random)
  local p,o=M.ratio(player),M.ratio(opponent)
  if not p or not o then return nil,'Power and weight could not be measured for both cars.' end
  local confidence=M.confidence(p,o)
  local t=M.tuning
  local amount=math.max(t.minCashWagerMoney,math.min(t.maxCashWagerMoney,t.cashWagerStepMoney*(1+math.floor(confidence*5)+random(0,2))))
  return {kind=random()<0.03+confidence*0.17 and 'boss' or 'cash',amount=amount,confidence=confidence}
end
function M.negotiate(preference,kind,amount,venueId,random)
  if kind~='cash' and kind~='boss' then return nil,'Choose cash or pink slips.' end
  local t=M.tuning
  if kind=='cash' and (not finite(amount) or amount<t.minCashWagerMoney or amount>t.maxCashWagerMoney or amount%t.cashWagerStepMoney~=0) then
    return nil,string.format('Choose a cash wager from $%d to $%d in $%d steps.',t.minCashWagerMoney,t.maxCashWagerMoney,t.cashWagerStepMoney)
  end
  local pink=preference.kind=='boss' or preference.confidence>=0.37012987012987 -- Allow a 10% player power-to-weight advantage.
  local ceiling=math.min(t.maxCashWagerMoney,preference.amount+t.maxCashIncreaseMoney)
  local agreedKind=kind=='boss' and pink and 'boss' or 'cash'
  local agreedAmount=kind=='cash' and math.min(amount,ceiling) or preference.amount
  local agreedVenue=venueId==preference.venueId or random()<0.65
  local accepted=agreedKind==kind and (kind=='boss' or agreedAmount==amount) and agreedVenue
  return {kind=agreedKind,amount=agreedAmount,venueId=agreedVenue and venueId or preference.venueId,accepted=accepted}
end
local function say(state,line,status)
  state.history[#state.history+1]={theirOffer=state.kind=='boss' and 0 or state.amount,negotiationStatus=status,line=line}
end
function M.openNegotiation(preference)
  local state={kind=preference.kind,amount=preference.amount,venueId=preference.venueId,
    status='initial',patience=M.tuning.patienceCount,history={}}
  say(state,state.kind=='boss' and {text="I'll run you for pink slips."} or {pre="I'll run you for ",post='.'},'initial')
  return state
end
function M.counterOffer(state,preference,kind,amount,venueId,random)
  if state.status=='accepted' or state.status=='failed' then return nil,'This discussion has ended.' end
  if state.status=='counterOfferLastChance' then return nil,'Accept the final terms or walk away.' end
  local terms,err=M.negotiate(preference,kind,amount,venueId,random)
  if not terms then return nil,err end
  local t=M.tuning
  local minimum=math.max(t.minCashWagerMoney,preference.amount-t.maxCashDiscountMoney)
  if kind=='cash' and terms.accepted and amount<minimum then terms.accepted=false;terms.amount=minimum end
  local repeated=state.lastKind==kind and (kind=='boss' or state.lastAmount==amount)
  state.lastKind=kind;state.lastAmount=amount
  state.history[#state.history+1]={myOffer=kind=='boss' and 0 or amount,
    line={text=kind=='boss' and 'How about pink slips? My car against yours.' or 'How about $'..amount..' each?'}}
  if terms.accepted then
    state.kind=terms.kind;state.amount=terms.amount;state.venueId=terms.venueId;state.status='accepted'
    say(state,{text="Alright, let's do it."},'accepted')
  else
    state.patience=math.max(0,state.patience-(repeated and t.repeatedRefusalPatienceCostCount or t.refusalPatienceCostCount))
    if state.patience==0 then
      state.status='failed'
      state.history[#state.history+1]={theirOffer=0,negotiationStatus='failed',line={text="Nah, I'll pass."}}
    else
      local previousKind,previousAmount=state.kind,state.amount
      if state.kind=='cash' and terms.kind=='cash' then
        local change=terms.amount-state.amount
        local step=math.ceil(math.abs(change)/t.cashWagerStepMoney*t.counterConcessionFraction)*t.cashWagerStepMoney
        state.amount=state.amount+(change<0 and -step or step)
      else state.amount=terms.amount end
      state.kind=terms.kind;state.venueId=terms.venueId
      state.status=state.patience<=t.refusalPatienceCostCount and 'counterOfferLastChance' or 'counterOffer'
      local line
      if state.kind=='boss' then
        line={text=state.status=='counterOfferLastChance' and 'Pink slips. Take it or leave it.' or "I'll run you for pink slips."}
      elseif state.status=='counterOfferLastChance' then
        line={pre='',post='. Take it or leave it.'}
      else
        line={text="It's not worth it.",pre=state.kind==previousKind and state.amount==previousAmount and "I'm sticking with " or "I'd do ",post='.'}
      end
      say(state,line,state.status)
    end
  end
  return state
end
function M.publicNegotiation(state)
  local t=M.tuning
  return {status=state.status,patience=state.patience,maxPatience=t.patienceCount,history=state.history,
    minCashWagerMoney=t.minCashWagerMoney,maxCashWagerMoney=t.maxCashWagerMoney,cashWagerStepMoney=t.cashWagerStepMoney}
end
return M

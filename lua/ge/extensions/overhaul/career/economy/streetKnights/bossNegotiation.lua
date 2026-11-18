-- Boss pink-slip negotiation: the boss weighs both cars' worth and who should win, then names the cash it wants on top of your car.
-- Pure rules with no scene, UI or save access. Cash is whole dollars and is only paid if the player loses.
-- The talk is kept in the shared negotiation chat's history format, so NegotiationChatWindow can show it as is.
local rules=require('overhaul/career/economy/streetKnights/rules')
local powerToWeight=require('overhaul/lib/vehicles/powerToWeight')
local M={}

-- Tuning lives in gameplay/overhaul/streetKnights/bossNegotiation.json; these defaults match it and are used when it is missing or invalid.
local defaults={
  fairCarValueFraction=0.5,        -- at even odds the boss takes a car worth half of theirs with no cash
  minBossWinChance=0.2,            -- odds are clamped so a mismatch never asks for an unbounded amount
  maxBossWinChance=0.8,
  quickerTrustFraction=0.5,        -- the boss only half believes you are quicker: its odds drop half as far below even
  maxCashBossValueFraction=0.25,   -- the real price never asks for more than this share of the boss car's value in cash
  openingMarkupMinFactor=1.15,     -- the boss opens this far above the price it would really take (rolled each night)
  openingMarkupMaxFactor=1.45,
  minOpeningMarginMoney=500,       -- and always at least this many dollars above it
  nightlyMoodFraction=0.15,        -- each night the cash part of the price moves by up to this share either way
  generousChance=0.15,             -- some nights the boss is in a good mood
  generousDiscountMinFraction=0.3, -- and knocks this share off the cash it wants
  generousDiscountMaxFraction=0.6,
  straightMaxChance=0.5,           -- the boss may take your straight pink-slip challenge with no cash on top,
  straightGapBossValueFraction=0.15, -- more likely the smaller the cash it wants; none once that is this share of its car's value
  luckyFloorPriceFraction=0.75,    -- an offer at this share of the real price or more might just be taken
  luckyMaxChance=0.5,              -- with a chance that rises to this just under the price
  patienceCount=3,                 -- offers below the price the boss hears before walking for the night
  lowballPriceFraction=0.5,        -- an offer under this share of the price costs two patience
  concessionMinFraction=0.3,       -- each counter moves this share of the way from the ask toward your offer (rolled per counter)
  concessionMaxFraction=0.6,
  priceStepMoney=100,
}
local function number(v) return type(v)=='number' and v==v and v>=0 and v<math.huge end
local function ordered(t,lo,hi) return t[lo]<=t[hi] end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end return r end
-- Every value must be a non-negative number with ordered min/max pairs, or the defaults are used as a whole.
function M.fromConfig(data)
  if type(data)~='table' then return copy(defaults) end
  for k in pairs(defaults) do if not number(data[k]) then return copy(defaults) end end
  if not (ordered(data,'minBossWinChance','maxBossWinChance') and ordered(data,'openingMarkupMinFactor','openingMarkupMaxFactor')
    and ordered(data,'generousDiscountMinFraction','generousDiscountMaxFraction') and ordered(data,'concessionMinFraction','concessionMaxFraction'))
    or data.minBossWinChance<=0 or data.maxBossWinChance>=1 or data.priceStepMoney<1 or data.patienceCount<1 or data.luckyFloorPriceFraction>=1 then
    return copy(defaults)
  end
  local t={};for k in pairs(defaults) do t[k]=data[k] end
  return t
end
local ok,data=false,nil
if type(jsonReadFile)=='function' then ok,data=pcall(jsonReadFile,'/gameplay/overhaul/streetKnights/bossNegotiation.json') end
M.tuning=M.fromConfig(ok and data or nil)

-- {ask} marks where the chat shows the boss's current ask; lines without it are said before the price.
local lines={
  greet={"So you're the one who's been winning out here.","Heard you've been making noise at my meet.","You want my keys? Let's hear it."},
  challenge={"Pink slips. Your car against mine, straight up."},
  straight={"Pink slips, straight up? You're on.","No cash? Fine. Keys for keys. Let's go."},
  trash={"Your car's trash. I'm not parking my keys next to that.","That's not a car, that's a parts donor. Come back with something real.","I don't race scrap. Bring a real car."},
  short={"That thing's not worth enough. Not even close to mine.","Your keys don't cover mine. Sweeten it.","Cute car. Not worth my slip, though."},
  faster={"You roll up in that and want me to race for free? Put some cash on it.","I've heard about your car. You're quicker, and that costs you.","Faster car, same stakes? Nah. Make it worth my while."},
  table={"You need to put something on the table.","Keys alone won't do it. Add some cash.","I'm risking my car here. What are you risking?"},
  counter={"Not enough. Make it {ask} and we'll talk.","Getting warmer. {ask} and it's a race.","Meet me at {ask}."},
  final={"{ask}. That's my final number.","I'm not going under {ask}. Take it or leave it."},
  lowball={"Are you serious? Don't waste my time. {ask}, or walk.","That's an insult. {ask}, or walk."},
  broke={"You don't have that kind of money. I'm still at {ask}.","Show me the cash first. You can't cover that. {ask}."},
  generous={"I'm in a good mood tonight. Don't make me regret it.","Lucky you. I'm feeling generous."},
  agreed={"Deal. Keys and cash on the line. Don't be late to the tree.","You've got yourself a race."},
  lucky={"Ah, what the hell. You've got a deal.","You know what? Fine. Let's run it."},
  resume={"Back again? I'm still at {ask}.","You again. {ask}, same as before."},
  enough={"Your car's worth it. Keys for keys, let's run it.","Fair trade. No cash needed. Let's go."},
  walked={"I'm done talking. Come back next meet.","Forget it. You're not serious. Maybe next meet."},
}
M.lines=lines

-- The chat's status names for each stage of the talk.
local chatStatus={open='',countered='',final='counterOfferLastChance',agreed='accepted',walked='failed',refused='failed'}

local function ceilStep(n) return math.ceil(n/M.tuning.priceStepMoney-1e-9)*M.tuning.priceStepMoney end
local function clamp(n,lo,hi) return math.max(lo,math.min(hi,n)) end
local function roll(lo,hi,random) return lo+random()*(hi-lo) end
-- One boss turn. Priced turns show `amount` in the chat's money style, either where {ask} sits or after the line.
local function say(state,kind,random,amount)
  local pool=lines[kind];local text=pool[math.floor(random()*#pool)+1]
  local line
  local pre,post=text:match('^(.-){ask}(.*)$')
  if pre then line={pre=pre,post=post}
  elseif amount and amount>0 then line={text=text,pre=(kind=='agreed' or kind=='lucky') and 'Deal at ' or 'I want ',post=' on top of your car.'}
  else line={text=text} end
  state.history[#state.history+1]={theirOffer=amount or state.ask,negotiationStatus=chatStatus[state.status] or '',line=line}
  state.mood=kind
end
local function offered(state,amount,accepted,text) state.history[#state.history+1]={myOffer=amount,negotiationStatus=accepted and 'accepted' or nil,line=text and {text=text} or nil} end

-- Who should win, read from both cars' power-to-weight with the same formula car-meet challengers use.
-- Without both measurements the boss calls it even.
function M.odds(playerStats,bossStats)
  local p,o=powerToWeight.ratio(playerStats),powerToWeight.ratio(bossStats)
  if not p or not o then return {known=false,bossWinChance=0.5,playerAdvantage=0} end
  local t=M.tuning
  local chance=clamp(powerToWeight.confidence(p,o),t.minBossWinChance,t.maxBossWinChance)
  if chance<0.5 then chance=0.5-(0.5-chance)*t.quickerTrustFraction end
  return {known=true,bossWinChance=chance,playerAdvantage=p/o-1}
end

-- The least cash the boss accepts: your car plus cash must cover their car, scaled by how likely they are to lose it,
-- and never more than a set share of their car's value.
function M.price(carValue,bossValue,odds,mood)
  local t,chance=M.tuning,odds.bossWinChance
  local wanted=bossValue*t.fairCarValueFraction*(1-chance)/chance
  return clamp(ceilStep((wanted-carValue)*(mood or 1)),0,ceilStep(bossValue*t.maxCashBossValueFraction))
end

-- args: carValue (what the boss counts your car as), bossValue, odds (from M.odds), random (0..1 generator, seeded per meet night).
function M.open(args)
  local t,random=M.tuning,args.random
  local state={carValue=args.carValue,bossValue=args.bossValue,odds=args.odds,patience=t.patienceCount,cash=0,ask=0,startingPrice=0,history={}}
  -- The boss greets you and you open with a straight pink-slip challenge: your car, no cash.
  state.quote=lines.greet[math.floor(random()*#lines.greet)+1]
  offered(state,0,false,lines.challenge[1]);state.lastOffer=0
  if not args.carValue or not args.bossValue or args.carValue<args.bossValue*rules.bossFloorFraction then
    state.status='refused';say(state,'trash',random,0);return state
  end
  local mood=1+(random()*2-1)*t.nightlyMoodFraction
  state.generous=random()<t.generousChance
  if state.generous then mood=mood*(1-roll(t.generousDiscountMinFraction,t.generousDiscountMaxFraction,random)) end
  state.reservation=M.price(args.carValue,args.bossValue,args.odds,mood)
  if state.reservation==0 then state.status='agreed';say(state,'enough',random,0);return state end
  -- Close enough and the boss may just take the straight race; otherwise it counters with cash.
  local gap=state.reservation/args.bossValue
  if random()<t.straightMaxChance*math.max(0,1-gap/t.straightGapBossValueFraction) then state.status='agreed';say(state,'straight',random,0);return state end
  state.ask=math.max(ceilStep(state.reservation*roll(t.openingMarkupMinFactor,t.openingMarkupMaxFactor,random)),state.reservation+t.minOpeningMarginMoney)
  state.startingPrice=state.ask
  state.status='open'
  local opener=state.generous and 'generous' or args.odds.known and args.odds.playerAdvantage>0.05 and 'faster'
    or args.carValue<args.bossValue*t.fairCarValueFraction and 'short' or 'table'
  say(state,opener,random,state.ask)
  return state
end

local function talking(state) return state.status=='open' or state.status=='countered' or state.status=='final' end

-- Talking again the same night picks up where you left off: the boss keeps its patience, its lower ask and a final price.
-- saved: {patience, ask, final}; ask and final are only passed when it is the same pair of cars.
function M.resume(state,saved,random)
  if type(saved)~='table' then return state end
  if type(saved.patience)=='number' then state.patience=math.min(state.patience,saved.patience) end
  if not talking(state) then return state end
  local ask=state.ask
  if saved.final then ask=state.reservation
  elseif type(saved.ask)=='number' and saved.ask<ask then ask=math.max(state.reservation,saved.ask) end
  if ask==state.ask and not saved.final then return state end
  state.ask=ask
  state.status=ask==state.reservation and 'final' or 'countered'
  say(state,state.status=='final' and 'final' or 'resume',random)
  return state
end

-- The player puts `amount` on top of their car. Returns true, or nil and the reason the offer cannot be made.
function M.offer(state,amount,balance,random)
  if not talking(state) then return nil,'The boss is not taking offers.' end
  if state.status=='final' then return nil,'That was their final offer. Take it or walk away.' end
  if type(amount)~='number' or amount~=math.floor(amount) or amount<0 then return nil,'Offer a whole dollar amount.' end
  offered(state,amount)
  -- Money you do not have costs no patience: the boss just calls it out.
  if amount>balance then say(state,'broke',random);return true end
  state.lastOffer=amount
  if amount>=state.reservation then
    state.cash=math.min(amount,state.ask);state.status='agreed';say(state,'agreed',random,state.cash);return true
  end
  -- A close offer can land a good deal: the nearer the real price, the better the chance the boss just takes it.
  local t=M.tuning
  local closeness=(amount/state.reservation-t.luckyFloorPriceFraction)/(1-t.luckyFloorPriceFraction)
  if closeness>0 and random()<t.luckyMaxChance*closeness then
    state.cash=amount;state.status='agreed';say(state,'lucky',random,state.cash);return true
  end
  local lowball=amount<state.reservation*t.lowballPriceFraction
  state.patience=state.patience-(lowball and 2 or 1)
  if state.patience<=0 then state.status='walked';say(state,'walked',random);return true end
  -- On its last bit of patience the boss names its real price, so you always see it before it walks.
  state.ask=state.patience==1 and state.reservation or math.max(state.reservation,ceilStep(state.ask-(state.ask-amount)*roll(t.concessionMinFraction,t.concessionMaxFraction,random)))
  state.status=state.ask==state.reservation and 'final' or 'countered'
  say(state,lowball and 'lowball' or state.status=='final' and 'final' or 'counter',random)
  return true
end

-- The player takes the boss's current ask.
function M.acceptAsk(state,balance,random)
  if not talking(state) then return nil,'The boss is not taking offers.' end
  if state.ask>balance then offered(state,state.ask);say(state,'broke',random);return true end
  offered(state,state.ask,true)
  state.cash=state.ask;state.status='agreed';say(state,'agreed',random,state.cash);return true
end

-- What the UI may see, in NegotiationChatWindow's terms: never the boss's real price.
function M.public(state)
  if not state then return nil end
  local history={}
  for i,h in ipairs(state.history) do history[i]={myOffer=h.myOffer,theirOffer=h.theirOffer,negotiationStatus=h.negotiationStatus,line=h.line and {text=h.line.text,pre=h.line.pre,post=h.line.post}} end
  return {status=state.status,chatStatus=chatStatus[state.status] or '',quote=state.quote,ask=state.ask,startingPrice=state.startingPrice,cash=state.cash,lastOffer=state.lastOffer,
    patience=state.patience,maxPatience=M.tuning.patienceCount,mood=state.mood,history=history,
    carValue=state.carValue,bossValue=state.bossValue,step=M.tuning.priceStepMoney}
end
return M

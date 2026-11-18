-- Owns spectator markets, commitments and settlement; motorsportEvents supplies official results.
-- Parts: bettingRules prices qualifying evidence; lib/finance/wagerJournal persists revisions;
-- payment mutates money/XP; save/store captures receipts with the wallet in one snapshot.
-- Contract: one debit and settlement per ticket; only recorded results pay; failed writes retry.
local M = {}
local rules = require('overhaul/events/motorsportEvents/drag/bettingRules')
local reasons = require('overhaul/events/motorsportEvents/drag/bettingReasons')
local gambling = require('overhaul/lib/progression/gambling')
local journalFactory = require('overhaul/lib/finance/wagerJournal')
local saveStore = require('overhaul/lib/save/store')
local metadata = require('overhaul/lib/finance/metadata')
local session
-- The window counts real time while the heat runs in sim time, so opening the bet slip pauses the
-- simulation and freezes the window until the player bets or hides it. The open slip repeats openSlip
-- about once a second as a heartbeat; a slip that falls silent (failed hide, UI reload, overlay gone)
-- counts as hidden so the game is never left paused. Each slip names itself, so a close from an older,
-- unmounted slip cannot release the one that replaced it; the owner's own closes name nobody.
local PAUSE_REQUEST = 'motorsportBetting'
local SLIP_HEARTBEAT_TIMEOUT_SECONDS = 5
local function closeSlip(slipName)
  if not (session and session.slipOpen) then return end
  if slipName ~= nil and slipName ~= session.slipHolder then return end
  session.slipOpen, session.slipSilentSeconds, session.slipHolder = false, 0, nil
  if simTimeAuthority then simTimeAuthority.popPauseRequest(PAUSE_REQUEST) end
end
-- The window waits only while the heat really is paused; a player who unpauses with the open slip
-- gets the countdown back, and the slip stops saying the race is paused.
local function slipHoldsHeat()
  return session.slipOpen == true and (not simTimeAuthority or simTimeAuthority.getPause() == true)
end
local function slipAllowed()
  local market = session.market
  return market ~= nil and market.open == true and not session.fault
    and session.journal ~= nil and not session.journal.records[market.id]
end
local function resetSession(currentIdentity, slot, savedReceipts)
  closeSlip()
  session = {identity = currentIdentity, profile = slot, receipts = savedReceipts or {}, now = 0, busy = false}
end
resetSession()
local function clearHeat(event)
  closeSlip()
  session.market, session.heatId, session.reasonCode = nil, nil, nil
  session.eventId, session.classId = event and event.id, event and event.activeClassId
end
local function attrs() return overhaul_career_economy_playerAttributes end
local function wallet() return attrs() and attrs().getAttributeValue('money') or 0 end
local function xp() return attrs() and attrs().getAttributeValue(gambling.attribute) or 0 end
-- Retry only refusals made before the durable commitment can create a ticket.
local function failed(error, retryable) return {ok = false, error = error, retryable = retryable == true} end
local function apply(record)
  local receipt = session.receipts[record.id] or {}
  session.receipts[record.id] = receipt
  local race = record.race
  if not receipt.charged then
    -- Durable commitment owns this debit, including recovery from an older save.
    local accepted = overhaul_career_economy_payment.pay({money = {amount = race.stake, canBeNegative = true}},
      metadata.tag({label = 'Drag spectator bet', tags = {'gambling', 'spectatorBet'}}, 'gambling'), nil,
      function() receipt.charged = true end)
    if not accepted or not receipt.charged then return false, 'Bet payment could not be recorded.' end
  end
  if record.state ~= 'locked' or receipt.settled then return true end
  local returned = record.outcome == 'win' and race.total or record.outcome == 'void' and race.stake or 0
  local earned = record.outcome ~= 'void' and record.reason ~= 'Interrupted bet' and gambling.xp(returned - race.stake) or 0
  local change = {[gambling.attribute] = {amount = earned}}
  if returned > 0 then change.money = {amount = returned} end
  -- Money and XP are one attribute mutation. Receipt is set before attribute hooks
  -- can trigger another settlement/save. The capture includes both owners together.
  overhaul_career_economy_payment.reward(change, metadata.tag({label = 'Drag bet ' .. record.outcome,
    tags = {'gambling', 'spectatorBet'}}, record.outcome == 'void' and 'refund' or 'gambling'), true, nil,
    function() receipt.settled = true end)
  if not receipt.settled then return false, 'Bet result could not be recorded.' end
  session.lastResult = {id = record.id, outcome = record.outcome, reason = record.reason, car = race.car,
    stake = race.stake, returned = returned, net = returned - race.stake, xp = earned}
  return true
end
local function transaction(fn)
  if session.busy then return false, 'Bet transaction in progress.' end
  session.busy = true
  local hold = saveStore.hold(M, 'Settling spectator bet', {stage = 'beforeRoute'})
  local ok, result, problem = pcall(fn)
  hold.release()
  session.busy = false
  if not ok then session.fault = tostring(result); return false, session.fault end
  if not result then session.fault = problem; return false, problem end
  session.fault = nil
  saveStore.request('motorsport:betChanged')
  return result
end

function M.load(state)
  rules.configure(jsonReadFile('/gameplay/overhaul/motorsportBetting.json'))
  local system = overhaul_career_saveSystem
  if not system or not attrs() then return end
  local slot = system.getCurrentProfile()
  if not slot then return end
  -- A Lua reload shares the live wallet; do not replay receipts from its older disk snapshot.
  local currentIdentity = attrs().getAllAttributes()
  if session.identity == currentIdentity and session.profile == slot and session.journal then
    state.betReceipts = session.receipts
    return
  end
  resetSession(currentIdentity, slot, state.betReceipts)
  state.betReceipts = session.receipts
  local dir = system.getSaveRootDirectory() .. slot .. '/motorsportBetLedger/'
  system.getSaveWriter().mkdir(dir)
  session.journal = journalFactory.new({readAll = function()
    local records = {}
    for _, file in ipairs(FS:findFiles(dir, '*.json', 0, false, false) or {}) do
      if file:match('/%d+%.json$') then
        local record = jsonReadFile(file)
        if not record then return nil, 'Unreadable spectator bet ledger.' end
        records[#records + 1] = record
      end
    end
    return records
  end, write = function(record)
    local file = dir .. string.format('%010d', record.sequence) .. '.json'
    system.jsonWriteFileSafe(file, record, true)
    local check = jsonReadFile(file)
    return check and check.id == record.id and check.sequence == record.sequence and check.state == record.state
      and check.outcome == record.outcome and check.decidedOutcome == record.decidedOutcome
  end})
  local ok, error = session.journal:load()
  if not ok then session.fault = error; return end
  M.interrupt()
end

local function carView(entrant)
  local config = type(entrant.config) == 'string' and entrant.config or ''
  local image = config:match('^/vehicles/') and config:gsub('%.pc$', '.jpg')
    or '/vehicles/' .. entrant.model .. '/' .. config:gsub('%.pc$', '') .. '.jpg'
  if not FS:fileExists(image) then image = '/vehicles/' .. entrant.model .. '/default.jpg' end
  if not FS:fileExists(image) then image = nil end
  local details = core_vehicles and core_vehicles.getModel(entrant.model) or {}
  local model = details and details.model or {}
  local function displayText(value)
    return value and core_locales and core_locales.translateWithOrWithoutContext(value) or value
  end
  local brand, name = displayText(model.Brand), displayText(model.Name)
  name = entrant.vehicleName or (name and brand and brand ~= '' and (brand .. ' ' .. name) or name) or entrant.model
  return {id = entrant.id, name = name, driver = entrant.name, image = image,
    average = rules.average(entrant)}
end
-- Every successful dispatch reaches this owner, including heats that cannot open a market.
function M.open(event, match, entrants, watching)
  local pending = M.pending()
  clearHeat(event)
  session.heatId = match and rules.key(event, match) or nil
  session.reasonCode = 'qualifying'
  if not match or event.phase == 'qualifying' or event.phase == 'playerQualifying' then return end
  session.reasonCode = 'bye'
  if match.bye or #entrants ~= 2 then return end
  for _, entrant in ipairs(entrants) do
    if entrant.player then session.reasonCode = 'player_car'; return end
  end
  for _, entrant in ipairs(entrants) do
    if entrant.inventoryId or entrant.teamId then session.reasonCode = 'team_car'; return end
  end
  session.reasonCode = 'unavailable'
  if pending or not session.journal or session.fault or not rules.window then return end
  local key = rules.key(event, match)
  if session.journal.records[key] then session.reasonCode = 'already_placed'; return end
  local a, b = carView(entrants[1]), carView(entrants[2])
  session.reasonCode = 'qualifying_times'
  if not a.average or not b.average then return end
  a.odds, b.odds = rules.prices(a.average, b.average)
  session.reasonCode = 'one_sided'
  if not a.odds then return end
  session.reasonCode = 'late_entry'
  if watching == false then return end
  session.reasonCode = nil
  session.market = {id = key, matchId = match.id, cars = {a, b}, deadline = session.now + rules.window, open = true}
end
function M.isOpen() return session.market ~= nil and session.market.open == true end
function M.update(dt, runtime)
  -- A watchdog release earlier in this frame must not charge the paused frame to the window.
  if not (slipHoldsHeat() or session.frameStartedHeld) then session.now = session.now + math.max(0, dt or 0) end
  if not session.market or not session.market.open then return end
  if session.fault or not session.journal or not rules.window then
    session.market.open = false
    session.reasonCode = 'unavailable'
  elseif rules.closed(runtime) then
    session.market.open = false
    session.reasonCode = 'staging'
  elseif session.now >= session.market.deadline then
    session.market.open = false
    session.reasonCode = 'timeout'
  end
  if not slipAllowed() then closeSlip() end
end
-- Only an open market the player can still bet on pauses the heat. Repeating it is the heartbeat, and it
-- takes the pause back if the watchdog dropped it.
function M.openSlip(id, runtime, watching, slipName)
  M.update(0, runtime)
  if not watching or not session.market or session.market.id ~= id or not slipAllowed() then return failed('Bets closed.') end
  session.slipOpen, session.slipSilentSeconds, session.slipHolder = true, 0, slipName
  if simTimeAuthority then simTimeAuthority.pushPauseRequest(PAUSE_REQUEST) end
  return {ok = true}
end
M.closeSlip = closeSlip
-- Runs first every frame, paused or not, so a silent slip is released even while the game is paused.
function M.watchSlip(dtReal, watching)
  session.frameStartedHeld = slipHoldsHeat()
  if not session.slipOpen then return end
  session.slipSilentSeconds = session.slipSilentSeconds + math.max(0, dtReal or 0)
  if not watching or session.slipSilentSeconds >= SLIP_HEARTBEAT_TIMEOUT_SECONDS then closeSlip() end
end
function M.pending()
  if session.recovering then M.interrupt() else M.retrySettlement() end
  if not session.journal then return false end
  for _, record in pairs(session.journal.records) do
    if record.state == 'committed' or not (session.receipts[record.id] and session.receipts[record.id].settled) then return true end
  end
  return false
end
function M.place(id, entrantId, stake, runtime, watching)
  M.update(0, runtime)
  if session.fault then return failed(session.fault) end
  if not session.journal or not watching or not session.market or session.market.id ~= id or not session.market.open then return failed('Bets closed.') end
  if session.journal.records[id] then return failed('Bet already placed.') end
  if not rules.validStake(stake, wallet(), xp()) then return failed('Check your stake and balance.', true) end
  local system = overhaul_career_saveSystem
  if system.isSaveInFlight and system.isSaveInFlight() then return failed('Wait for the save to finish.', true) end
  local selected
  for _, car in ipairs(session.market.cars) do if car.id == entrantId then selected = car end end
  if not selected then return failed('Choose a car.', true) end
  local ok, error = transaction(function()
    local record, problem = session.journal:commit({id = id, order = session.journal.sequence + 1, car = selected,
      matchId = session.market.matchId, stake = stake, total = math.floor(stake * selected.odds)})
    if not record then return false, problem end
    return apply(record)
  end)
  if not slipAllowed() then closeSlip() end
  return ok and {ok = true} or failed(error)
end
-- Retry only a known official decision, never infer a new result from a later heat.
function M.retrySettlement()
  if not session.retry or session.busy then return end
  local decision = session.retry
  transaction(function()
    local record, error = session.journal.records[decision.id]
    if record.state == 'committed' then
      if not record.decidedOutcome then
        record, error = session.journal:decide(decision.id, decision.outcome, decision.reason)
        if not record then return false, error end
      end
      record, error = session.journal:lock(decision.id, record.decidedOutcome, record.decidedReason)
      if not record then return false, error end
    end
    local ok, problem = apply(record)
    if ok then session.retry = nil end
    return ok, problem
  end)
end
function M.finish(event, match, result, recorded)
  if not session.journal or not match then return end
  local id = rules.key(event, match)
  local record = session.journal.records[id]
  if session.heatId == id then
    if session.market then session.market.open = false end
    session.reasonCode = 'next_heat'
    closeSlip()
  end
  if not record or (session.receipts[id] and session.receipts[id].settled) then return end
  session.retry = session.retry or {id = id,
    outcome = record.decidedOutcome or (result.error and 'void' or recorded and (result.winnerId == record.race.car.id and 'win' or 'loss') or 'void'),
    reason = record.decidedReason or result.error or 'Official result'}
  M.retrySettlement()
end
function M.interrupt()
  clearHeat()
  if not session.journal then return end
  session.recovering = true
  M.retrySettlement()
  if session.retry then return end
  for _, record in ipairs(session.journal:ordered()) do
    if not (session.receipts[record.id] and session.receipts[record.id].settled) then
      session.retry = {id = record.id, outcome = record.decidedOutcome or record.outcome or 'loss',
        reason = record.decidedReason or record.reason or 'Interrupted bet'}
      M.retrySettlement()
      if session.retry then return end
    end
  end
  session.recovering = false
end
function M.view(runtime, event)
  if session.recovering then M.interrupt() else M.retrySettlement() end
  if event and (event.id ~= session.eventId or event.activeClassId ~= session.classId) then clearHeat(event) end
  M.update(0, runtime)
  local record = session.journal and session.heatId and session.journal.records[session.heatId]
  local reasonCode = session.reasonCode
  local qualifying = event and (event.phase == 'qualifying' or event.phase == 'playerQualifying')
  if not session.heatId and qualifying then
    reasonCode = 'qualifying'
  elseif not runtime or runtime.phase == 'idle' or runtime.phase == 'cooldown' then
    reasonCode = qualifying and 'qualifying' or 'next_heat'
  end
  if session.fault or not session.journal or not rules.window then reasonCode = 'unavailable'
  elseif record then reasonCode = 'already_placed' end
  reasonCode = reasonCode or (not session.market and 'next_heat' or nil)
  local cars = {}
  for _, car in ipairs(session.market and session.market.cars or {}) do
    local row = {}
    for key, value in pairs(car) do row[key] = value end
    row.lane = require('overhaul/events/motorsportEvents/drag/parking').getSide(car.id)
    cars[#cars + 1] = row
  end
  return {reasonCode = reasonCode, reason = reasons[reasonCode],
    market = session.market and {id = session.market.id, cars = cars, open = session.market.open and not session.fault,
      paused = slipHoldsHeat(), seconds = math.max(0, math.ceil(session.market.deadline - session.now))},
    ticket = record and {id = record.id, car = record.race.car, stake = record.race.stake, total = record.race.total,
      settled = session.receipts[record.id] and session.receipts[record.id].settled == true},
    result = session.lastResult, maxBet = gambling.maxBet(xp()), balance = wallet(), minimum = gambling.minimum, error = session.fault}
end
return M

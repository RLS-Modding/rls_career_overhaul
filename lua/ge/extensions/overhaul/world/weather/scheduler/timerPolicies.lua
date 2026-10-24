-- Timer policy records: how today's Overhaul timers count time, written down rather than changed.
-- Wall timers stay on the wall clock and sim timers keep their phase. timer_policies_test checks every anchor, so update this file with any timer change.

local M = {}

local Timer = {}
Timer.__index = Timer

local function createTimer(policy)
  policy = policy or {}
  local comparator = policy.comparator or ">="
  local mode = policy.mode or "subtract"
  assert(comparator == ">=" or comparator == ">", "legacyTimer: comparator must be >= or >")
  assert(mode == "subtract" or mode == "modulo" or mode == "reset", "legacyTimer: unknown mode " .. tostring(mode))
  local initial = policy.initial or 0
  return setmetatable({
    period = policy.period or 1,
    strict = comparator == ">",
    mode = mode,
    initial = initial,
    value = initial,
  }, Timer)
end

-- No clamping: the caller's amount is added as given.
function Timer:add(amount)
  self.value = self.value + amount
  return self.value
end

function Timer:due()
  if self.strict then return self.value > self.period end
  return self.value >= self.period
end

function Timer:take()
  local value = self.value
  if self.strict then
    if not (value > self.period) then return false end
  elseif not (value >= self.period) then
    return false
  end
  local mode = self.mode
  if mode == "subtract" then
    self.value = value - self.period
    return true, self.period
  elseif mode == "modulo" then
    self.value = value % self.period
    return true, self.period
  end
  self.value = 0
  return true, value
end

-- add() then take(), for timers whose module checked right after accumulating.
function Timer:step(amount)
  self.value = self.value + amount
  return self:take()
end

function Timer:get() return self.value end
function Timer:set(value) self.value = value end

-- Back to `value`, or to the policy's initial phase.
function Timer:reset(value)
  if value == nil then value = self.initial end
  self.value = value
end


local OVERHAUL_DIR = "lua/ge/extensions/overhaul/"

M.periodic = {
  {
    id = "weather.state", file = OVERHAUL_DIR .. "world/weather.lua", clock = "sim", add = "math.max(0, tonumber(dtSim) or 0)",
    period = 1, comparator = ">=", mode = "subtract", initial = 0, elapsed = "none (advances 1 s of the day cycle)",
    order = "after the real-time wet-material tick, before the per-frame visual transition and audio",
    pause = "dtSim 0: no advance; travel journal, editor and editor saves skip the hook",
    anchors = {"stateTimer:add(math.max(0, dt))", "if stateTimer:take() then"},
  },
  {
    id = "weather.visual", file = OVERHAUL_DIR .. "world/weather.lua", clock = "sim", add = "math.max(0, tonumber(dtSim) or 0)",
    period = 0.2, comparator = ">=", mode = "reset", initial = 0, elapsed = "none",
    order = "checked inside the transition, also forced when the transition completes",
    pause = "dtSim 0: no advance",
    anchors = {"visualTimer:add(math.max(0, dt))", "if visualTimer:due() or p >= 1 then"},
  },
  {
    id = "weather.wetMaterial", file = OVERHAUL_DIR .. "world/weather/environment.lua", clock = "real", add = "math.max(0, tonumber(dtReal) or 0)",
    period = 0.1, comparator = ">=", mode = "subtract", initial = 0, elapsed = "none (one material per tick)",
    order = "first in the weather hook; only accumulates while materials are queued",
    pause = "keeps running while paused (real time)",
    anchors = {"timer:add(math.max(0, tonumber(dt) or 0))", "if not timer:take() then return end"},
  },
  {
    id = "logistics.generation", file = OVERHAUL_DIR .. "career/logistics/general.lua", clock = "sim", add = "dtSim (unclamped)",
    period = 1, comparator = ">", mode = "subtract", initial = 0, elapsed = "none",
    order = "background generation receives (tickTimer > 1) before discovery; independent of discovery resets",
    pause = "dtSim 0: no advance",
    anchors = {"tickTimer = tickTimer + dtSim", "deliveryServices.generator.updateBackgroundGeneration(tickTimer > 1)",
      "if tickTimer > 1 then", "tickTimer = tickTimer - 1"},
  },
  {
    id = "logistics.poiScan", file = OVERHAUL_DIR .. "career/logistics/general.lua", clock = "real", add = "dtReal or 0",
    period = "config.poiScanIntervalSec", comparator = ">=", mode = "reset", initial = 0, elapsed = "none",
    order = "dirty POIs coalesce after generation; a container discovery pass also refreshes them",
    pause = "dirty POIs may refresh while paused; clean POIs do not poll",
    anchors = {"discovery.poiElapsed = discovery.poiElapsed + (dtReal or 0)",
      "discovery.poiDirty and discovery.poiElapsed >= config.poiScanIntervalSec",
      "discovery.poiDirty, discovery.poiElapsed = false, 0"},
  },
  {
    id = "logistics.discovery", file = OVERHAUL_DIR .. "career/logistics/general.lua", clock = "sim", add = "dtSim or 0",
    period = "5 idle / 1 active", comparator = ">=", mode = "reset", initial = 0, elapsed = "none",
    order = "bounded container and POI fallback after generation; nearby events may reset it earlier",
    pause = "fallback stops while paused; nearby events coalesce on real time",
    anchors = {"idleRefreshIntervalSec = 5", "activeRefreshIntervalSec = 1",
      "discovery.elapsed = discovery.elapsed + (dtSim or 0)",
      "local interval = runtime.deliveryModeActive and config.activeRefreshIntervalSec or config.idleRefreshIntervalSec",
      "local fallbackDue = discovery.elapsed >= interval",
      "discovery.dirty, discovery.elapsed, discovery.eventElapsed = false, 0, 0"},
  },
  {
    id = "economy.tick", file = OVERHAUL_DIR .. "career/economy/globalEconomy.lua", clock = "sim", add = "dtSim",
    period = 300, comparator = ">=", mode = "reset", initial = "saved timeSinceLastUpdate", elapsed = "accumulated sim seconds",
    order = "only while career is active and economy data is loaded",
    pause = "dtSim 0: no advance; the phase is saved and restored",
    anchors = {"timeSinceLastUpdate = timeSinceLastUpdate + dtSim", "if timeSinceLastUpdate >= UPDATE_INTERVAL_SIM then",
      "local elapsed = timeSinceLastUpdate", "timeSinceLastUpdate = 0", "runEconomyTickCore(elapsed, false)",
      "local UPDATE_INTERVAL_SIM = 300"},
  },
  {
    id = "tires.context", file = OVERHAUL_DIR .. "career/maintenance/tireSystem.lua", clock = "sim, real fallback",
    add = "tonumber(dtSim) or tonumber(dtReal) or 0", period = 1, comparator = ">=", mode = "modulo", initial = 0.5,
    elapsed = "none", order = "whole hook", pause = "dtSim 0: no advance",
    anchors = {"local CONTEXT_PHASE = 0.5", "local contextTimer = CONTEXT_PHASE",
      "contextTimer = contextTimer + (tonumber(dtSim) or tonumber(dtReal) or 0)", "if contextTimer < 1 then return end",
      "contextTimer = contextTimer % 1"},
  },
  {
    id = "bank.savings", file = OVERHAUL_DIR .. "career/economy/bank.lua", clock = "sim", add = "dtSim or 0", period = 1,
    comparator = ">=", mode = "reset", initial = 0, elapsed = "accumulated sim seconds (applySavingsDtSim)",
    order = "before the pending-transfer check", pause = "dtSim 0: no interest accrues",
    anchors = {"savingsUpdateTimer = savingsUpdateTimer + dtSim", "if savingsUpdateTimer >= SAVINGS_UPDATE_INTERVAL_S then",
      "local elapsed = savingsUpdateTimer", "savingsUpdateTimer = 0", "applySavingsDtSim(elapsed)"},
  },
  {
    id = "bank.transferPoll", file = OVERHAUL_DIR .. "career/economy/bank.lua", clock = "real", add = "dtReal or 0", period = 5,
    comparator = ">=", mode = "reset", initial = 0, elapsed = "none (polls wall-clock deadlines)",
    order = "after savings", pause = "keeps polling while paused",
    anchors = {"updateTimer = updateTimer + dtReal", "if updateTimer >= UPDATE_INTERVAL_S then", "processPendingTransfers()"},
  },
  {
    id = "marketplace.offers", file = OVERHAUL_DIR .. "career/market/marketplace.lua", clock = "sim", add = "dtSim", period = 10,
    comparator = ">=", mode = "reset", initial = 0, elapsed = "none (compares calendar timestamps)",
    order = "after the offer pass step, only with listed vehicles", pause = "dtSim 0: no dispatch; deadlines are calendar time",
    anchors = {"timeSinceUpdate = timeSinceUpdate + dtSim", "if timeSinceUpdate < 10 then return end", "timeSinceUpdate = 0"},
  },
}

-- Stamps are deadlines or durations on wall, process, or simulation clocks.
M.stamps = {
  {id = "taxi.fareTiming", file = OVERHAUL_DIR .. "jobs/taxi/taxi.lua", clock = "simulation (dtSimSeconds)",
    effect = "speed factor and tip from accumulated passenger-leg rideElapsed",
    pause = "paused frames add no ride time",
    anchors = {"local elapsedTime = currentFare.rideElapsed or 0", "currentFare.rideElapsed = 0", "currentFare.rideElapsed = (currentFare.rideElapsed or 0) + dtSimSeconds"}},
  {id = "repo.reward", file = OVERHAUL_DIR .. "jobs/repo.lua", clock = "wall (os.time)",
    effect = "time multiplier in calculateReward, at least 1 s",
    pause = "pause time counts toward elapsed seconds",
    anchors = {"local elapsedSeconds = math.max(1, os.time() - (self.jobStartTime or os.time()))", "self.jobStartTime = os.time()"}},
  {id = "quarry.contractStart", file = OVERHAUL_DIR .. "jobs/quarry/contracts.lua", clock = "process (os.clock)",
    effect = "recorded only; nothing reads contractProgress.startTime", pause = "n/a",
    anchors = {"startTime = os.clock(),"}},
  {id = "bank.delayedTransfer", file = OVERHAUL_DIR .. "career/economy/bank.lua", clock = "calendar (os.time)",
    effect = "transfer completes when os.time() >= completesAt; closed-game time counts",
    pause = "pause and closed-game time count", anchors = {"local currentTime = os.time()", "elseif currentTime >= transfer.completesAt then"}},
  {id = "marketplace.calendar", file = OVERHAUL_DIR .. "career/market/marketplace.lua", clock = "calendar (os.time)",
    effect = "offer schedule and listing expiry against os.time()", pause = "pause and closed-game time count",
    anchors = {"scheduleNextOffer(listing, os.time())", "pass.timeNow = os.time()"}},
  {id = "carmeets.invites", file = OVERHAUL_DIR .. "career/carmeets/carmeets/flow.lua", facade = OVERHAUL_DIR .. "career/carmeets/carmeets.lua", clock = "calendar (os.time)",
    effect = "invite generation every generationInterval wall seconds; expiry at expiresAt",
    pause = "pause and closed-game time count",
    anchors = {"return (currentTime - carMeetState.lastGenerationTime) >= carMeetState.generationInterval and #carMeetState.pendingInvites < parts.sales.getPendingInviteCap()",
      "if invite.expiresAt and now >= invite.expiresAt then"}},
  {id = "racingTeam.postRaceCooldown", file = OVERHAUL_DIR .. "career/business/racingTeam/racingTeam/results.lua", facade = OVERHAUL_DIR .. "career/business/racingTeam/racingTeam.lua",
    clock = "career sim time or wall epoch, whichever ends first",
    effect = "racingCooldownUntilSimTime plus postRaceCooldownReadyWallEpoch", pause = "wall deadline keeps counting while paused or closed",
    anchors = {"tech.racingCooldownUntilSimTime = nowSim + cdSec", "tech.postRaceCooldownReadyWallEpoch = os.time() + cdSec",
      "if wallEpoch and wallEpoch > 0 and os.time() >= wallEpoch then"}},
}

-- Named random streams would change every later math.random draw that follows these reseeds.
M.reseeds = {
  {id = "world.routes", file = OVERHAUL_DIR .. "world/dynamicRoutes.lua", anchor = "math.randomseed(os.time())"},
  {id = "miningHaul", file = OVERHAUL_DIR .. "jobs/miningHaul.lua", anchor = "math.randomseed(os.time())"},
  {id = "recovery", file = OVERHAUL_DIR .. "jobs/recovery.lua", anchor = "math.randomseed(os.time())"},
  {id = "vehicleShopping", file = OVERHAUL_DIR .. "career/market/vehicleShopping/catalog.lua", facade = OVERHAUL_DIR .. "career/market/vehicleShopping.lua", anchor = "math.randomseed(os.time() + os.clock() * 10000)"},
  {id = "parcelMods", file = OVERHAUL_DIR .. "lib/logistics/parcelMods.lua", anchor = "math.randomseed(item.groupSeed)"},
}

local byId = {}
for _, policy in ipairs(M.periodic) do byId[policy.id] = policy end

function M.get(id) return byId[id] end

-- A legacyTimer configured exactly like the recorded periodic timer (numeric policies only).
function M.timer(id)
  local policy = assert(byId[id], "timerPolicies: unknown timer " .. tostring(id))
  assert(type(policy.period) == "number" and type(policy.initial) == "number", "timerPolicies: " .. id .. " has no fixed period/phase")
  return createTimer({period = policy.period, comparator = policy.comparator, mode = policy.mode, initial = policy.initial})
end

return M

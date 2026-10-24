-- Runs ordered step sequences (fades, spawns, level loads, messages) one frame at a time.
-- A frame owns its current batch while callbacks may queue the next batch.
local M = {}

M.dependencies = { "util_stepHandler" }

-- Step factories re-exported from util_stepHandler; the lookup happens at call time.
local STEP_FACTORY_NAMES = {
  "makeStepWait", "makeStepWaitFrames", "makeStepReturnTrueFunction",
  "makeStepFadeToBlack", "makeStepFadeFromBlack", "makeStepSpawnVehicle", "makeStepSpawnVehicleSimple",
  "makeStepSpawnTrafficSimple", "makeLoadLevelStep", "makeUiMessageStep",
}

for _, name in ipairs(STEP_FACTORY_NAMES) do
  M[name] = function(...) return util_stepHandler[name](...) end
end

local sequences = {}
local current
local updatingSequences

-- Runs one frame of a step; a thrown error or a timeout completes it so the sequence can move on.
local function advanceStep(step, dt)
  step._startingTime = step._startingTime or os.clockhp()
  local ok, err = xpcall(function() step.processTask(step, dt) end, debug.traceback)
  if not ok then
    log("E", "deliveryStepHandler", tostring(err))
    step.complete = true
  end
  if not step.complete and os.clockhp() - step._startingTime > (step.timeout or 120) then
    log("E", "deliveryStepHandler", "Step timed out: " .. tostring(step.name))
    step.complete = true
  end
end

-- Returns the step still waiting, or nil when the sequence has no steps left.
local function runSequenceSteps(sequence, dt)
  local step = sequence.steps[sequence.index]
  while step do
    advanceStep(step, dt)
    if not step.complete then break end
    sequence.index = sequence.nextIndex or sequence.index + 1
    sequence.nextIndex = nil
    step = sequence.steps[sequence.index]
  end
  return step
end

local function finishSequence(sequence)
  if not sequence.callback then return end
  local ok, err = xpcall(sequence.callback, debug.traceback)
  if not ok then log("E", "deliveryStepHandler", tostring(err)) end
end

-- Covers sequences started this frame as well as the batch being run, so events reach both.
local function forActiveSteps(callback)
  for _, list in ipairs({ sequences, updatingSequences or {} }) do
    for _, sequence in ipairs(list) do
      local step = sequence.steps[sequence.index]
      if step then callback(step) end
    end
  end
end

-- Steps are copied, so the caller's table can be reused.
function M.startStepSequence(steps, callback)
  local copy = {}
  for index, step in ipairs(steps) do
    copy[index] = {}
    for key, value in pairs(step) do copy[index][key] = value end
  end
  sequences[#sequences + 1] = { steps = copy, index = 1, callback = callback }
end

function M.skipToLastStepOrCallback()
  if not current then return end
  local step = current.steps[current.index]
  if step then step.complete = true end
  current.nextIndex = current.index < #current.steps and #current.steps or #current.steps + 1
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not next(sequences) then return end
  local active = sequences
  updatingSequences = active
  sequences = {}
  local dt = { dtReal = dtReal, dtSim = dtSim, dtRaw = dtRaw }
  for _, sequence in ipairs(active) do
    current = sequence
    if runSequenceSteps(sequence, dt) then
      sequences[#sequences + 1] = sequence
    else
      finishSequence(sequence)
    end
  end
  current = nil
  updatingSequences = nil
end

function M.onScreenFadeState(state)
  forActiveSteps(function(step)
    if step.waitForFade then step["fadeState" .. state] = true end
  end)
end

function M.onVehicleGroupSpawned(vehIds, groupId)
  forActiveSteps(function(step)
    if step.waitForVehicleGroup and step.groupId == groupId then
      step.state, step.vehIds = 2, vehIds
    end
  end)
end

function M.onClientStartMission()
  forActiveSteps(function(step)
    if step.waitForClientStartMission then step.complete = true end
  end)
end

function M.onClientEndMission()
  sequences = {}
  current = nil
  updatingSequences = nil
end

M.onExtensionUnloaded = M.onClientEndMission
return M

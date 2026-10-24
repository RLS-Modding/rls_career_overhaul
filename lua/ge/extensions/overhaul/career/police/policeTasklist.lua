-- Session police HUD in the career task list (on-duty only).
-- Arrests + suspect BOLO reset with the career session; not saved.
local M = {}

local jobSkillRewards = require("overhaul/lib/jobs/skillRewards")

-- Config ------------------------------------------------------------------------------------------

local POLICE_SKILL_ATTRIBUTE_KEY = "careerSkills-emergency"
local POLICE_SKILL_PATH_IDS = {"careerSkills-emergency", "emergency"}
local COP_PROXIMITY_DISTANCE = 15

local TASK_ARRESTS_ID = "police_tasklist_arrests"
local TASK_SUSPECT_ID = "police_tasklist_suspect"
local REFRESH_INTERVAL = 0.5

-- State -------------------------------------------------------------------------------------------

local sessionArrests = 0
local suspectLabel = nil
local suspectVehId = nil
local visible = false
local lastPushed = nil
local refreshTimer = 0

-- Helpers -----------------------------------------------------------------------------------------

local function isCareerActive()
  return overhaul_career_career and overhaul_career_career.isActive()
end

local function isOnDuty()
  if not isCareerActive() then return false end
  if overhaul_career_police_enforcement then
    local disabled = overhaul_career_police_enforcement.isPoliceDisabled()
    if disabled then return false end
  end
  if not overhaul_career_police_playerDriving then
    return false
  end
  return overhaul_career_police_playerDriving.getPlayerIsCop() == true
end

local function getPoliceSkillLevel()
  return jobSkillRewards.getSkillLevel(POLICE_SKILL_ATTRIBUTE_KEY, POLICE_SKILL_PATH_IDS) or 1
end

local function colorDistanceSq(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return math.huge end
  local dr = (tonumber(a[1]) or 0) - (tonumber(b[1]) or 0)
  local dg = (tonumber(a[2]) or 0) - (tonumber(b[2]) or 0)
  local db = (tonumber(a[3]) or 0) - (tonumber(b[3]) or 0)
  return dr * dr + dg * dg + db * db
end

-- Names the live paint only when it matches a catalogue paint; custom colors return nil rather than a misleading BOLO.
local function getPaintColorName(vehId)
  local obj = getObjectByID(vehId)
  if not obj or not obj.color then return nil end
  local color = obj.color
  local live = {color.x, color.y, color.z}
  if live[1] == nil or live[2] == nil or live[3] == nil then return nil end

  local modelData = core_vehicles.getModel(obj.jbeam)
  local paints = modelData and modelData.model and modelData.model.paints
  if type(paints) ~= "table" then return nil end

  -- Traffic repaints live objects without touching the spawn config, so compare in linear color space.
  local function distance(paint)
    local base = type(paint) == "table" and paint.baseColor
    if type(base) ~= "table" or not base[1] or not base[2] or not base[3] then return math.huge end
    local linear = ColorF(base[1], base[2], base[3], base[4] or 1):asLinear4F()
    return colorDistanceSq(live, {linear.x, linear.y, linear.z})
  end
  local tolerance = 0.0001
  local vehicleData = core_vehicle_manager.getVehicleData(vehId)
  local config = vehicleData and vehicleData.config
  if type(config) == "table" then
    local named = config.paintName
    if type(named) == "string" and paints[named] and distance(paints[named]) <= tolerance then
      return named
    end
    local paint = type(config.paints) == "table" and config.paints[1]
    if type(paint) == "table" and paints[paint.name] and distance(paints[paint.name]) <= tolerance then
      return paint.name
    end
  end

  -- Sorted names make duplicate RGB values resolve the same way every time.
  local names = {}
  for name in pairs(paints) do table.insert(names, name) end
  table.sort(names)
  local bestName, bestDist = nil, tolerance
  for _, name in ipairs(names) do
    local paint = paints[name]
    if type(paint) == "table" then
      local dist = distance(paint)
      if dist < bestDist then
        bestDist = dist
        bestName = paint.name or name
      end
    end
  end
  return bestName
end

local function buildSuspectLabel(vehId)
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  local veh = traffic and traffic[vehId]
  local modelName = veh and veh.modelName
  if not modelName or modelName == "" then
    local obj = getObjectByID(vehId)
    modelName = (obj and obj.jbeam) or "Unknown vehicle"
  end

  local colorName = getPaintColorName(vehId)
  if colorName and colorName ~= "" then
    return string.format("%s %s", colorName, modelName)
  end
  return modelName
end

local function clearSuspect()
  suspectVehId = nil
  suspectLabel = nil
end

local function setSuspect(vehId)
  if not vehId then
    clearSuspect()
    return
  end
  suspectVehId = vehId
  suspectLabel = buildSuspectLabel(vehId)
end

local function clearSuspectIfMatch(vehId)
  if suspectVehId and vehId and suspectVehId == vehId then
    clearSuspect()
  elseif not vehId then
    clearSuspect()
  end
end

-- Picks the highest-scoring suspect that is still pursuing; nil when none is.
local function findActiveSuspectId()
  local traffic = gameplay_traffic and gameplay_traffic.getTrafficData()
  if not traffic then return nil end

  local playerId = be:getPlayerVehicleID(0)
  local bestId, bestScore = nil, -1
  for id, veh in pairs(traffic) do
    if id ~= playerId and veh.role and veh.role.name == "suspect" and veh.pursuit and (veh.pursuit.mode or 0) >= 1 then
      local score = tonumber(veh.pursuit.score) or 0
      if score > bestScore then
        bestScore = score
        bestId = id
      end
    end
  end
  return bestId
end

local function playerNearSuspect(suspectId)
  local playerVeh = getPlayerVehicle(0)
  local suspectObj = suspectId and getObjectByID(suspectId)
  if not playerVeh or not suspectObj then return false end
  return playerVeh:getPosition():distance(suspectObj:getPosition()) <= COP_PROXIMITY_DISTANCE
end

local function buildState()
  return {
    skill = getPoliceSkillLevel(),
    arrests = sessionArrests,
    suspect = suspectLabel,
  }
end

local function stateChanged(state)
  if not lastPushed then return true end
  return lastPushed.skill ~= state.skill
      or lastPushed.arrests ~= state.arrests
      or lastPushed.suspect ~= state.suspect
end

-- Task list HUD -----------------------------------------------------------------------------------

local function hideTasklist()
  if not visible and not lastPushed then return end
  guihooks.trigger("DiscardTasklistItem", TASK_ARRESTS_ID)
  guihooks.trigger("DiscardTasklistItem", TASK_SUSPECT_ID)
  guihooks.trigger("SetTasklistHeader", nil)
  visible = false
  lastPushed = nil
end

local function pushTasklist(force)
  if not isOnDuty() then
    hideTasklist()
    return
  end

  -- Refresh BOLO from live chase if we do not have one yet, or vehicle still exists.
  local activeId = findActiveSuspectId()
  if activeId and (activeId ~= suspectVehId or not suspectLabel) then
    setSuspect(activeId)
  end

  local state = buildState()
  if not force and not stateChanged(state) and visible then
    return
  end

  guihooks.trigger("SetTasklistHeader", {
    label = "Police",
    subtext = string.format("Skill %d", state.skill),
  })
  guihooks.trigger("SetTasklistTask", {
    id = TASK_ARRESTS_ID,
    label = string.format("Arrests: %d", state.arrests),
    active = true,
    type = "message",
  })
  guihooks.trigger("SetTasklistTask", {
    id = TASK_SUSPECT_ID,
    label = state.suspect and string.format("Suspect: %s", state.suspect) or "No active suspect",
    active = true,
    type = "message",
  })

  visible = true
  lastPushed = state
end

local function resetSession()
  sessionArrests = 0
  clearSuspect()
  lastPushed = nil
  hideTasklist()
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  if not isCareerActive() then
    if visible then hideTasklist() end
    return
  end

  refreshTimer = refreshTimer + (dtReal or 0)
  if refreshTimer < REFRESH_INTERVAL then return end
  refreshTimer = 0

  local onDuty = isOnDuty()
  if onDuty then
    pushTasklist(false)
  elseif visible then
    hideTasklist()
  end
end

-- Public API: test and debug views ----------------------------------------------------------------

function M.getSessionArrests() return sessionArrests end
function M.getSuspectLabel() return suspectLabel end
function M.refresh() pushTasklist(true) end

-- Game hooks --------------------------------------------------------------------------------------

local function onPursuitAction(vehId, action, data)
  if not isCareerActive() then return end
  if not overhaul_career_police_playerDriving.getPlayerIsCop() then return end

  if action == "start" then
    if vehId and vehId ~= be:getPlayerVehicleID(0) then
      setSuspect(vehId)
      pushTasklist(true)
    end
  elseif action == "arrest" then
    if vehId and playerNearSuspect(vehId) then
      sessionArrests = sessionArrests + 1
      clearSuspectIfMatch(vehId)
      pushTasklist(true)
    end
  elseif action == "evade" or action == "release" or action == "reset" then
    clearSuspectIfMatch(vehId)
    if not findActiveSuspectId() then
      clearSuspect()
    end
    pushTasklist(true)
  end
end

local function onPursuitModeUpdate(vehId, info)
  if not isOnDuty() then return end
  local mode = info and info.mode or 0
  if mode >= 1 and vehId and vehId ~= be:getPlayerVehicleID(0) then
    setSuspect(vehId)
    pushTasklist(true)
  elseif mode <= 0 and suspectVehId == vehId then
    if not findActiveSuspectId() then
      clearSuspect()
      pushTasklist(true)
    end
  end
end

-- Duty can change with the vehicle, so the HUD refreshes straight away.
local function onVehicleSwitched(oldId, newId)
  if not isCareerActive() then return end
  pushTasklist(true)
end

local function onOverhaulPlayerAttributesChanged()
  if visible or isOnDuty() then
    pushTasklist(true)
  end
end

local function onCareerActivated()
  resetSession()
  pushTasklist(true)
end

local function onOverhaulActive()
  resetSession()
end

local function onClientEndMission()
  hideTasklist()
end

M.onPursuitAction = onPursuitAction
M.onPursuitModeUpdate = onPursuitModeUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onOverhaulPlayerAttributesChanged = onOverhaulPlayerAttributesChanged
M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onClientEndMission = onClientEndMission

return M

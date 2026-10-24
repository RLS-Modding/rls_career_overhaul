-- Minimap app: sends the road graph, terrain tile and tracked vehicles to the phone map.
-- Only the player's vehicle is tracked while ONLY_SHOW_PLAYER is set.
local M = {}
local mapData = require("overhaul/lib/phone/minimapData")
local MARKER_INTERVAL_S = 0.08
local ONLY_SHOW_PLAYER = true
local AXIS_X = vec3(1, 0, 0)
local AXIS_NEG_Y = vec3(0, -1, 0)
local markerElapsedS = MARKER_INTERVAL_S
local currentLevel = nil

local function addTrackedObject(objects, id, obj, controlId)
  if not obj or not obj.pos or not obj.dirVec then return end
  objects[id] = {
    posX = -obj.pos.x,
    posY = obj.pos.y,
    rot = math.floor(-math.deg(math.atan2(obj.dirVec:dot(AXIS_X), obj.dirVec:dot(AXIS_NEG_Y)))),
    speed = obj.speed or 0,
    isPlayer = id == controlId,
  }
end

local function collectTrackedObjects(tracked, controlId)
  local objects = {}
  if not tracked then return objects end
  if ONLY_SHOW_PLAYER then
    addTrackedObject(objects, controlId, tracked[controlId], controlId)
  else
    for id, obj in pairs(tracked) do
      addTrackedObject(objects, id, obj, controlId)
    end
  end
  return objects
end

local function onGuiUpdate()
  if markerElapsedS < MARKER_INTERVAL_S then return end
  markerElapsedS = markerElapsedS % MARKER_INTERVAL_S
  local controlId = be:getPlayerVehicleID(0)
  if not controlId then return end

  local isFreeCam = commands.isFreeCamera() or (gameplay_walk and gameplay_walk.isWalking())
  local camPos = core_camera.getPosition() or vec3()
  local camForward = core_camera.getForward() or vec3()

  guihooks.queueStream("phoneMinimap", {
    controlID = controlId,
    isFreeCam = isFreeCam,
    camPosition = { x = camPos.x, y = camPos.y },
    camRotationZ = math.atan2(camForward.x, -camForward.y) * 180 / math.pi,
    objects = collectTrackedObjects(map.getTrackedObjects(), controlId),
  })
end

local function requestPhoneMap(knownLevel, knownRevision)
  currentLevel = getCurrentLevelIdentifier()
  if not currentLevel then
    guihooks.trigger("PhoneMinimapData", {level = "", revision = 0, nodes = {}, terrainTiles = {}})
    return
  end
  local data = mapData.get(currentLevel)
  local payload = data
  if knownLevel == data.level and knownRevision == data.revision then
    payload = {level = data.level, revision = data.revision}
  end
  guihooks.trigger("PhoneMinimapData", payload)
end

-- onGuiUpdate only runs when CEF is ready, but receives a simulation frame's
-- dt. Accumulate time on every update so slower UI frames do not slow the clock.
function M.onUpdate(dtReal)
  markerElapsedS = math.min(markerElapsedS + dtReal, MARKER_INTERVAL_S * 2)
end

M.onGuiUpdate = onGuiUpdate
M.requestPhoneMap = requestPhoneMap

function M.onClientStartMission()
  markerElapsedS = MARKER_INTERVAL_S
end

function M.onClientEndMission()
  mapData.invalidate(currentLevel)
  currentLevel = nil
  guihooks.trigger("PhoneMinimapData", {level = "", revision = 0, nodes = {}, terrainTiles = {}})
end

return M

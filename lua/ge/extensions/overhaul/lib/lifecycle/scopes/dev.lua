-- Dev scope: the gates that tell a dev checkout (valid devkey.txt) from a release install: key, console and cheats.
-- Predicates resolve extension globals when they run, never at require time, so loading this file reads no game state.
local M = {}
local capabilities = require('overhaul/lib/platform/capabilities')
local platformManifests = require('overhaul/lib/platform/manifests')
-- The dev policy is data: it declares the debug folder and the console setting. Read it lazily.
local POLICY_PATH = '/gameplay/overhaul/dev/policy.json'
local policy

-- Session policy is immutable; all gates share the same lazy snapshot.
local function getPolicy()
  if policy == nil then policy = jsonReadFile(POLICY_PATH) or {} end
  return policy
end

local function declarations()
  return platformManifests.scan({dir = '/gameplay/overhaul/career/owners/', tag = 'overhaul.dev.policy',
    validate = function(data) return data end})
end

-- Resolved lazily so mounted add-ons take part without extending a roster.
setmetatable(M, {__index = function(_, key)
  if key ~= 'debugModulePrefix' and key ~= 'keyedExtensions' then return nil end
  if key == 'debugModulePrefix' then
    return getPolicy().debugModulePrefix
  end
  local keyed = {}
  for _, owner in ipairs((declarations())) do
    if owner.devKey then keyed[#keyed + 1] = owner.id end
  end
  return keyed
end})

function M.isDebugModule(path)
  local prefix = M.debugModulePrefix
  return prefix ~= nil and path:find(prefix, 1, true) == 1
end

-- Retained owners may use their own key checker instead of a replacement's.
function M.isKeyValid(keyCheck)
  if keyCheck then return keyCheck() and true or false end
  local extensionManager = capabilities.get('devKey')
  return extensionManager and extensionManager.isDevKeyValid and extensionManager.isDevKeyValid() and true or false
end

-- Debug panels load with the key.
function M.debugPanelsEnabled()
  return M.isKeyValid()
end

-- Dev tools (the dev console module, the phone tutorial replay) need the key.
function M.devToolsEnabled()
  return M.isKeyValid()
end

-- Console policy stays closed until both the creator key and its declared setting pass.
function M.consoleEnabled()
  if not M.isKeyValid() then
    return false
  end
  local settings = capabilities.get('developerSettings')
  if not (settings and settings.getSetting) then
    return false
  end
  local settingName = getPolicy().consoleSetting
  if type(settingName) ~= 'string' then
    return false
  end
  return settings.getSetting(settingName) == true
end

-- Evaluate a lazy cheats predicate only when it can change the gate.
local function cheatsOn(cheatsMode)
  if type(cheatsMode) == 'function' then
    return cheatsMode()
  end
  return cheatsMode
end

function M.keyOrCheats(cheatsMode)
  return M.isKeyValid() or (cheatsOn(cheatsMode) and true or false)
end

-- The editor input actions are blocked in a career unless the key is valid or cheats mode is on.
function M.editorBlocked(careerActive, cheatsMode)
  return not M.isKeyValid() and (careerActive and true or false) and not cheatsOn(cheatsMode)
end

-- Time-of-day cycling: free outside a career, inside one only with cheats mode or the key.
function M.canCycleTimeOfDay(careerActive, cheatsMode)
  if not careerActive then return true end
  if cheatsOn(cheatsMode) then return true end
  return M.isKeyValid()
end

return M

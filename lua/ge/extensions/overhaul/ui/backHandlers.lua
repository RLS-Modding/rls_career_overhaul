-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Back handlers for Overhaul's screens, resolved by the UI router while Overhaul runs.
-- Fork of stock lua/ge/extensions/ui/router/routeHandlers/careerExitHandlers.lua (BeamNG 0.40).
local M = {}
local modIdentity = require("overhaul/lib/platform/modIdentity")
local optional = require("overhaul/lib/platform/optional")

M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "backHandlers"

-- The router's navigation state is resolved at invocation, after the router has initialized.
local function navigationState() return require("ge/extensions/ui/router/navigationState") end

local function careerProfilesExitHandler()
  local career = optional("overhaul_career_career")
  if career and career.isActive() then
    ui_router.navigate("pause")
  else
    ui_router.navigate("menu")
  end
end

local function careerBranchPageBackHandler()
  local currentEntry = navigationState().getCurrentEntry()
  local params = currentEntry and currentEntry.request and currentEntry.request.params or {}
  local returnRoute = params.returnRoute
  local pathId = params.pathId
  local branch = overhaul_career_progression_skills and pathId and overhaul_career_progression_skills.getBranchById(pathId) or nil
  local parentId = branch and not branch.missing and branch.parentId or nil

  if parentId then
    local targetParams = {
      pathId = parentId,
      focusPathId = pathId,
    }
    if returnRoute then
      targetParams.returnRoute = returnRoute
    end
    return ui_router.navigate("overhaul.branchPage", targetParams)
  end

  if returnRoute == "overhaul.computer" then
    return ui_router.navigate("overhaul.computer")
  end

  return ui_router.navigate("overhaul.domainSelection", {focusPathId = pathId})
end

local function negotiationExitHandler()
  extensions.overhaul_career_market_marketplace.finalizeNegotiationExit()

  local prevEntry = navigationState().getPreviousEntry()
  if prevEntry and prevEntry.request and prevEntry.request.name then
    return ui_router.navigate(prevEntry.request.name, prevEntry.request.params or {}, { restoreLastScope = true })
  end

  return { success = false, reason = "no_previous_entry" }
end

M.careerProfilesExitHandler = careerProfilesExitHandler
M.careerBranchPageBackHandler = careerBranchPageBackHandler
M.negotiationExitHandler = negotiationExitHandler

local ownerCatalog = require("overhaul/lib/ui/ownerCatalog")
local handlers
local handlerDeclarations = {}
local patchOwned = false

local function refreshDeclarations()
  local declarations = ownerCatalog.scan()
  local replacement = {}
  for id, row in pairs(declarations.handlers) do
    local owner, method = row.owner, row.method
    local previous = handlerDeclarations[id]
    if previous and previous.owner == owner and previous.method == method then
      replacement[id] = handlers[id]
    else
      local handler
      handler = function(...)
        if handlers[id] ~= handler then return end
        local target = extensions[owner]
        return target[method](...)
      end
      replacement[id] = handler
    end
  end
  handlers = replacement
  handlerDeclarations = declarations.handlers
end

M.getHandler = function(name)
  if not handlers then refreshDeclarations() end
  return handlers[name]
end

M.onExtensionLoaded = function()
  refreshDeclarations()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return require("ge/extensions/ui/router/routeHandlers") end, {
    getHandler = function(original)
      return function(name)
        return handlers[name] or original(name)
      end
    end,
  })
  patchOwned = true
end

M.onExtensionUnloaded = function()
  handlers = {}
  handlerDeclarations = {}
  if patchOwned and overhaul_shell_patches then
    patchOwned = false
    overhaul_shell_patches.unregister(PATCH_ID)
  end
end

M.onModActivated = refreshDeclarations
M.onModDeactivated = function(modData)
  if modIdentity.isOwnMod(modData) then return end
  return refreshDeclarations()
end

return M

-- While Overhaul runs, Ctrl+L is overhaulLuaReload, so the game's lua_reload action is blocked.
-- The patch follows level reloads and releases the input block when Overhaul stops.
local M = {}
local devPolicy = require("overhaul/lib/lifecycle/devConsolePolicy")
local wrapperLifetime = require("overhaul/lib/shell/wrapperLifetime")

M.dependencies = { "overhaul_shell_patches" }

local PATCH_ID = "luaReloadKey"
local FILTER_GROUP = "overhaul_shell_luaReload"

-- Stock 0.40 hides debug categories with simplemenu=false, but desktop
-- Controls publishes every active action. Filter that shared UI snapshot so
-- Options and the phone agree, including conflicts. Engine bindings stay live.
local function isPrivate(action)
  return action and action.overhaulDevOnly == true
end

local function publicBindings(devices, actions)
  local result = deepcopy(devices)
  for _, device in ipairs(result or {}) do
    local kept = {}
    for _, binding in ipairs(device.contents.bindings or {}) do
      if not isPrivate(actions[binding.action]) then kept[#kept + 1] = binding end
    end
    device.contents.bindings = kept
  end
  return result
end

local installVisibility, uninstallVisibility, refreshVisibility = wrapperLifetime.create(
  function() return guihooks end, {
    trigger = function(original)
      return function(name, data, ...)
        if name == "InputBindingsChanged" and not devPolicy.isDevToolsEnabled() then
          local published = deepcopy(data)
          for key, action in pairs(data.actions or {}) do
            if isPrivate(action) then published.actions[key] = nil end
          end
          published.bindings = publicBindings(data.bindings, data.actions)
          published.defaultBindings = publicBindings(data.defaultBindings, data.actions)
          data = published
        end
        return original(name, data, ...)
      end
    end,
  })

-- Stock saves a whole device, so putting a filtered UI snapshot back must
-- retain the hidden bindings rather than write their removal into its diff.
local installSave, uninstallSave, refreshSave = wrapperLifetime.create(
  function() return core_input_bindings end, {
    saveBindingsToDisk = function(original, bindings)
      return function(data, ...)
        if not devPolicy.isDevToolsEnabled() then
          data = deepcopy(data)
          local actions = core_input_actions.getActiveActions()
          local kept = {}
          for _, binding in ipairs(data.bindings or {}) do
            if not isPrivate(actions[binding.action]) then kept[#kept + 1] = binding end
          end
          for _, device in ipairs(bindings.bindings or {}) do
            local contents = device.contents
            if contents.devicetype == data.devicetype and contents.vidpid == data.vidpid
                and contents.guid == data.guid and contents.name == data.name then
              for _, binding in ipairs(contents.bindings or {}) do
                if isPrivate(actions[binding.action]) then kept[#kept + 1] = deepcopy(binding) end
              end
              break
            end
          end
          data.bindings = kept
        end
        return original(data, ...)
      end
    end,
  })

local function setBlocked(blocked)
  local filter = core_input_actionFilter
  if not (filter and filter.setGroup and filter.addAction) then return end
  filter.setGroup(FILTER_GROUP, { "lua_reload" })
  filter.addAction(0, FILTER_GROUP, blocked)
end

-- Re-blocking rebuilds every filter and fires onActionFilterUpdated, so only do it when the block is gone.
local function isBlocked()
  local filter = core_input_actionFilter
  if not (filter and filter.getGroup and filter.getBlockedActions) then return false end
  local group = filter.getGroup(FILTER_GROUP)
  local blocked = filter.getBlockedActions()[0]
  return type(group) == "table" and group[1] == "lua_reload" and blocked ~= nil and blocked.lua_reload == true
end

local function install() setBlocked(true) end
local function uninstall() setBlocked(false) end

local function refresh()
  if not isBlocked() then install() end
end

M.onExtensionLoaded = function()
  installVisibility()
  installSave()
  -- Level loads clear the action filter, so refresh blocks the action again.
  overhaul_shell_patches.register(PATCH_ID, install, uninstall, refresh)
end

M.onExtensionUnloaded = function()
  uninstallSave()
  uninstallVisibility()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

-- Visibility also applies in Options outside an active career. Reattach if
-- stock reloads the bindings module; retired wrappers safely pass through.
M.onUpdate = function()
  refreshVisibility()
  refreshSave()
end

return M

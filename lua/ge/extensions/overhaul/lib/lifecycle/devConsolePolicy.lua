-- Dev console gates: who may open the dev tools and the dev console, and the refusals they return.
-- Stateless policy shared by the console owner and business callers; the dev scope resolves live providers.
local M = {}

local devScope = require("overhaul/lib/lifecycle/scopes/dev")

local DEV_TOOLS_MESSAGE = "Dev tools require a valid dev key."

function M.isDevToolsEnabled()
  return devScope.devToolsEnabled()
end

function M.isEnabled()
  return devScope.consoleEnabled()
end

function M.requireDevTools()
  if not M.isDevToolsEnabled() then return false, "dev_tools_disabled" end
  return true
end

function M.requireEnabled()
  if not M.isEnabled() then return false, "dev_console_disabled" end
  return true
end

function M.devToolsDisabledResult()
  return { success = false, message = DEV_TOOLS_MESSAGE }
end

function M.devToolsDisabledInvariantResult()
  return { success = false, failures = { DEV_TOOLS_MESSAGE }, checks = 0 }
end

return M

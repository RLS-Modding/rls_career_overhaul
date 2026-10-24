-- Public dev-console gates and refusal results for extension callers.
-- The shared policy resolves live dev scope state on each call.
local M = {}
local policy = require("overhaul/lib/lifecycle/devConsolePolicy")

M.isDevToolsEnabled = policy.isDevToolsEnabled
M.isEnabled = policy.isEnabled
M.requireDevTools = policy.requireDevTools
M.requireEnabled = policy.requireEnabled
M.devToolsDisabledResult = policy.devToolsDisabledResult
M.devToolsDisabledInvariantResult = policy.devToolsDisabledInvariantResult
return M

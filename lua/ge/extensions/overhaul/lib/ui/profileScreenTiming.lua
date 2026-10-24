-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Opt-in timing of the profile screen's Lua work, for in-game measurement only.
-- Off unless OVERHAUL_DEBUG_PROFILE_TIMING is true; then each finished span logs one D-level "profileTiming" line.
local M = {}

local FLAG = 'OVERHAUL_DEBUG_PROFILE_TIMING'

-- hptimer is a callable class table, not a function, so look it up the way stock luaProfiler does.
local function timerClass()
  return rawget(_G, 'HighPerfTimer') or rawget(_G, 'hptimer')
end

local function enabled()
  return rawget(_G, FLAG) == true and timerClass() ~= nil
end

-- Returns nil when timing is off, so step and finish do nothing with a nil span.
function M.start(label)
  if not enabled() then return nil end
  local timer = timerClass()()
  return {label = label, timer = timer, lap = timer:stop(), steps = {}}
end

function M.step(span, name)
  if not span then return end
  local now = span.timer:stop()
  span.steps[#span.steps + 1] = string.format('%s=%.1fms', name, now - span.lap)
  span.lap = now
end

function M.finish(span, detail)
  if not span then return end
  log('D', 'profileTiming', string.format('%s total=%.1fms %s%s', span.label, span.timer:stop(),
    table.concat(span.steps, ' '), detail and (' ' .. detail) or ''))
end

return M

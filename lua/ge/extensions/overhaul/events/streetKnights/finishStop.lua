-- How a drag race brings the opponent to rest after the finish, and when a won car is handed over.
-- Shared by the race runner, the native driver's cleanup and the race controls (GE and vehicle side),
-- so braking, parking and the prize hand-over agree on when the car has stopped.
local M={}

-- Tuning lives in gameplay/overhaul/streetKnights/finishStop.json; these defaults match it and are used when it is missing or invalid.
local defaults={
  stoppedSpeedMps=1,       -- below this the car counts as stopped: it is frozen, parked at cleanup and handed over
  brakeRampPerSec=1.5,     -- the post-finish brake rises by this much per second, reaching full braking in 1/rate seconds
  handoverTimeoutSec=15,   -- game time; a won car that never settles is handed over after this anyway
}
local function positive(v) return type(v)=='number' and v==v and v>0 and v<math.huge end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end return r end
-- Every value must be a positive number, or the defaults are used as a whole.
function M.fromConfig(data)
  if type(data)~='table' then return copy(defaults) end
  local t={}
  for k in pairs(defaults) do
    if not positive(data[k]) then return copy(defaults) end
    t[k]=data[k]
  end
  return t
end
local ok,data=false,nil
if type(jsonReadFile)=='function' then ok,data=pcall(jsonReadFile,'/gameplay/overhaul/streetKnights/finishStop.json') end
M.tuning=M.fromConfig(ok and data or nil)
return M

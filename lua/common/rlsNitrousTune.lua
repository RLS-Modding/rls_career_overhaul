-- Optional activation window. Absent/original retains the installed controller.
local M={}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function M.validate(t)
  if t==nil then return true end
  if type(t)~='table' then return false,'Invalid nitrous settings' end
  if t.mode=='original' then return true end
  if t.mode~='speed' and t.mode~='rpmGear' then return false,'Choose one nitrous mode' end
  local fields=t.mode=='speed' and {{'minSpeed','maxSpeed',0,1000}} or {{'minRPM','maxRPM',0,50000},{'minGear','maxGear',1,64}}
  for _,f in ipairs(fields) do
    local lo,hi=t[f[1]],t[f[2]]
    if not finite(lo) or not finite(hi) or lo<f[3] or hi>f[4] or (f[1]~='minGear' and lo==hi) or lo>hi then return false,'Invalid nitrous activation window' end
    if f[1]=='minGear' and (lo%1~=0 or hi%1~=0) then return false,'Nitrous gears must be whole numbers' end
  end
  return true
end
function M.allows(t,rpm,speed,gear)
  if not t or t.mode=='original' then return true end
  if not M.validate(t) or not finite(gear) or gear<=0 then return false end
  if t.mode=='speed' then return finite(speed) and speed>=t.minSpeed and speed<=t.maxSpeed end
  return finite(rpm) and rpm>=t.minRPM and rpm<=t.maxRPM and gear>=t.minGear and gear<=t.maxGear
end
return M

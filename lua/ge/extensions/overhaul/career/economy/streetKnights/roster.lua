-- Authoring guide: docs/street-knights.md#map-owned-bosses; example: levels/rls_west_coast/streetKnights/bosses.json.
local M={}
function M.load(level,read,fs)
  local shared=(read('/gameplay/overhaul/streetKnights/roster.json') or {}).entries or {}
  if not level then return shared end
  local path='/levels/'..level..'/streetKnights/bosses.json'
  local data=read(path)
  if not data and not (fs and fs.fileExists and fs:fileExists(path)) then return shared end
  local entries,ids,tiers={},{},{}
  for _,entry in ipairs(shared) do
    if entry.role~='boss' then entries[#entries+1]=entry;ids[entry.id]=true end
  end
  local function invalid(reason) return entries,'Invalid No Prep Knights bosses in '..path..': '..reason end
  if type(data)~='table' or data.version~=1 or type(data.entries)~='table' or #data.entries~=5 then
    return invalid('expected five boss entries (version 1).')
  end
  local bosses={}
  for _,entry in ipairs(data.entries) do
    if type(entry)~='table' or type(entry.tier)~='number' or entry.tier%1~=0 or entry.tier<1 or entry.tier>5 or tiers[entry.tier] then
      return invalid('each tier from 1 to 5 must appear once.')
    end
    local model,configKey
    if type(entry.config)=='string' then model,configKey=entry.config:match('^/vehicles/([%w_%-]+)/([%w_%-]+)%.pc$') end
    if not model or entry.model~=model or type(entry.name)~='string' or not entry.name:find('%S') then
      return invalid('each boss needs a name, model, and matching /vehicles/<model>/<config>.pc path.')
    end
    local id=entry.id or level..'_boss_'..entry.tier
    if type(id)~='string' or not id:match('^[%w_%-]+$') or ids[id] then return invalid('boss IDs must be unique within the roster.') end
    local boss={}
    for key,value in pairs(entry) do boss[key]=value end
    boss.id=id;boss.role='boss';boss.configKey=configKey
    bosses[#bosses+1]=boss;ids[id]=true;tiers[entry.tier]=true
  end
  for _,boss in ipairs(bosses) do entries[#entries+1]=boss end
  return entries
end
return M

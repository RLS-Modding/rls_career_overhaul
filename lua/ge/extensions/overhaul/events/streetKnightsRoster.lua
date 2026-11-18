local M={}
M.dependencies={'util_configListGenerator','overhaul_shell_patches'}
local byConfig={}
local roster=require('overhaul/career/economy/streetKnights/roster')
local function key(config,model)
  if type(config)=='table' then
    model=config.model_key or config.model or model
    config=config.partConfigFilename or config.key or config.config
  end
  if type(config)~='string' then return end
  config=config:gsub('\\','/')
  model=config:match('^/?vehicles/([^/]+)/') or model
  if type(model)~='string' then return end
  return model..'/'..(config:match('([^/]+)%.pc$') or config)
end
function M.isEventConfig(config,model)
  local id=key(config,model)
  return id~=nil and byConfig[id]~=nil
end
function M.allowListing(info)
  return not(type(info)=='table' and (M.isEventConfig(info) or M.isEventConfig(info.config,info.model_key or info.model) or info['Config Type']=='StreetKnights'))
end
function M.onExtensionLoaded()
  byConfig={}
  local function register(entries)
    for _,entry in ipairs(entries) do
      local id=key(entry.config,entry.model)
      if id then byConfig[id]=true end
    end
  end
  register(roster.load(nil,jsonReadFile))
  if FS and FS.findFiles then
    for _,path in ipairs(FS:findFiles('/levels/','bosses.json',-1,true,false) or {}) do
      local level=path:match('^/levels/([%w_%-]+)/streetKnights/bosses%.json$')
      if level then register(roster.load(level,jsonReadFile,FS)) end
    end
  end
  overhaul_shell_patches.registerFields('streetKnightsEligibleConfigs',function()return rawget(_G,'util_configListGenerator')end,{
    getEligibleVehicles=function(original)
      return function(...)
        local result={}
        for _,info in ipairs(original(...)or{})do if M.allowListing(info)then result[#result+1]=info end end
        return result
      end
    end,
  })
end
function M.onExtensionUnloaded() overhaul_shell_patches.unregister('streetKnightsEligibleConfigs') end
return M

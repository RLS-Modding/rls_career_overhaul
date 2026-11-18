local M={}
M.dependencies={'overhaul_shell_patches'}
local saveStore=require('overhaul/lib/save/store')
local forwarding=require('overhaul/lib/shell/wrapperLifetime').forwarding
local hold
local ids={'streetKnightsReset','streetKnightsExit','streetKnightsQuit','streetKnightsTravel',
  'streetKnightsRecovery','streetKnightsInventory','streetKnightsCommit','streetKnightsChallengeCommit',
  'streetKnightsOtherRaces','streetKnightsGarageTravel'}
local function owner() return rawget(_G,'overhaul_career_economy_streetKnights') end
local function pack(...) return {n=select('#',...),...} end
function M.sync()
  local current=owner()
  if current and current.blocksSave() then
    if not hold then hold=saveStore.hold('noPrepKnights','Unsettled wager or prize capture',{stage='beforeRecovery'}) end
  elseif hold then hold.release();hold=nil end
end
local function guard(label)
  return forwarding(function(original)
    if type(original)~='function' then return end
    return function(...)
      local current=owner()
      if current and current.isCommitted() then
        local args=pack(...)
        return current.requestAction(label,function() original(unpack(args,1,args.n)) end)
      end
      return original(...)
    end
  end)
end
local function commitment(original)
  if type(original)~='function' then return end
  return function(...)
    if not hold then hold=saveStore.hold('noPrepKnights','Committing a wager',{stage='beforeRecovery'}) end
    local result=pack(pcall(original,...))
    M.sync()
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
  end
end
local function register(id,name,fields)
  overhaul_shell_patches.registerFields(id,function() return name=='_G' and _G or rawget(_G,name) end,fields)
end
function M.onExtensionLoaded()
  M.clear()
  register(ids[1],'_G',{resetGameplay=guard('reset your car')})
  register(ids[2],'_G',{returnToMainMenu=guard('leave your career'),quit=guard('leave your career')})
  register(ids[3],'TorqueScript',{eval=forwarding(function(original)
    if type(original)~='function' then return end
    local quit=guard('leave your career')(original)
    return function(command,...)
      if type(command)=='string' and command:match('^%s*quit%(%s*%)%s*;?%s*$') then return quit(command,...) end
      return original(command,...)
    end
  end)})
  register(ids[4],'freeroam_freeroam',{startFreeroam=guard('leave this map')})
  register(ids[5],'overhaul_ui_recoveryPrompt',{buttonPressed=guard('recover or tow your car')})
  register(ids[6],'overhaul_career_garage_inventory',{enterVehicle=guard('switch cars')})
  register(ids[7],'overhaul_career_economy_streetKnights',{commit=forwarding(commitment)})
  register(ids[8],'overhaul_career_economy_streetChallenges',{startRace=forwarding(commitment)})
  local function otherRace(original)
    if type(original)~='function' then return end
    return function(...)
      local current=owner()
      if current and current.blocksOtherRaces() then return false,'Finish your No Prep Knights race first.' end
      return original(...)
    end
  end
  register(ids[9],'overhaul_events_host',{beginFreeroamRace=forwarding(otherRace),startSanctionedRaceDispatch=forwarding(otherRace)})
  register(ids[10],'overhaul_career_garage_quickTravel',{quickTravelToPos=guard('travel to your garage')})
  M.sync()
end
function M.clear()
  for _,id in ipairs(ids)do overhaul_shell_patches.unregister(id) end
  if hold then hold.release();hold=nil end
end
M.onUpdate=M.sync
M.onClientEndMission=function()if hold then hold.release();hold=nil end end
M.onExtensionUnloaded=M.clear
return M

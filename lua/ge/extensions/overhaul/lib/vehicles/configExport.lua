-- Export payload rules, shared by the service and its offline tests.
-- Copyright (C) RLS Modding; SPDX-License-Identifier: AGPL-3.0-only
local M = {}
local copy = require('common/rlsFuelModel').copy
local portable = require('common/rlsFuelConfig')
local configKeys = {'parts','partsTree','vars','paints','paintName','paintName2','paintName3',
  'licenseName','licenseText','mainPartName','mainPartPath','rlsPearlescent'}
local identityKeys = {'Brand','Name','Country','Years','Type','Body Style','Config Type','Derby Class','Region'}

function M.name(value)
  if type(value) ~= 'string' then return nil, 'Give the export a name.' end
  value = value:match('^%s*(.-)%s*$')
  if #value == 0 or #value > 80 then return nil, 'Use a name between 1 and 80 characters.' end
  if value:find('[<>:"/\\|?*%c]') or value:sub(-1) == '.' or value == '.' or value == '..' then return nil, 'Names cannot use < > : " / \\ | ? or *, or end with a period.' end
  local stem = value:match('^([^.]*)'):lower()
  if stem == 'con' or stem == 'prn' or stem == 'aux' or stem == 'nul' or stem:match('^com[1-9]$') or stem:match('^lpt[1-9]$') then return nil, 'Windows reserves this name. Pick another one.' end
  return value
end
function M.slug(name) return 'rls_shared_' .. name:lower():gsub('[^%w_%-]', '_') end
function M.model(value) return type(value) == 'string' and #value <= 100 and value:match('^[%w_%-]+$') ~= nil end
function M.partNames(config)
  local names,seen={},{}
  local function add(name) if type(name)=='string' and name~='' and #name<=160 then names[name]=true end end
  local function visit(node,depth)
    if type(node)~='table' or seen[node] or depth>64 then return end
    seen[node]=true;add(node.chosenPartName)
    for _,child in pairs(node.children or {}) do visit(child,depth+1) end
  end
  for _,name in pairs(config.parts or {}) do add(name) end
  visit(config.partsTree,0);add(config.mainPartName)
  return names
end

function M.build(record, runtimeConfig, sourceInfo, request, fuel)
  local name, err = M.name(request.name)
  if not name then return nil, err end
  if not record or not M.model(record.model) then return nil, 'The mod for this vehicle is missing or broken.' end
  local source = runtimeConfig or record.config
  if type(source) ~= 'table' or (type(source.parts) ~= 'table' and type(source.partsTree) ~= 'table') then return nil, 'The parts on this vehicle could not be read.' end
  local pc = {format = source.format or 2, model = record.model}
  for _, key in ipairs(configKeys) do if source[key] ~= nil then pc[key] = copy(source[key]) end end
  if request.includeFuel then
    pc.rlsFuel, err = portable.pack(fuel)
    if not pc.rlsFuel then return nil, err end
  end
  local info = {}
  for _, key in ipairs(identityKeys) do if sourceInfo and sourceInfo[key] ~= nil then info[key] = copy(sourceInfo[key]) end end
  if type(info.Region)=='table' then
    local regions={}
    for key,value in pairs(info.Region) do
      if type(key)=='string' and value==true then regions[#regions+1]=key
      elseif type(value)=='string' then regions[#regions+1]=value end
    end
    table.sort(regions);info.Region=#regions==1 and regions[1] or (#regions>1 and regions or nil)
  end
  for _, key in ipairs({'Config Type','Body Style'}) do
    local value = request.metadata and request.metadata[key]
    if value ~= nil then
      if value ~= false and (type(value) ~= 'string' or #value > 80 or value:find('%c')) then return nil, 'Choose a build type and body type from the lists.' end
      info[key] = value ~= false and value ~= '' and value or nil
    end
  end
  info.Configuration, info.Description = name, type(request.description) == 'string' and request.description:sub(1,320) or ''
  info.Population = 0 -- sharing a build must not populate traffic or dealership stock
  info.rlsExport = {version=1, fuelActivation=pc.rlsFuel and 'career' or nil}
  local slug = M.slug(name)
  return {pc=pc,info=info,name=name,slug=slug,model=record.model,
    relative='vehicles/' .. record.model .. '/',
    files={slug..'.pc','info_'..slug..'.json'}}
end
function M.applyPartValues(payload, stats, catalogValue)
  if type(stats)~='table' or type(stats.total)~='number' or stats.total~=stats.total or stats.total<=0 or stats.total==math.huge
    or type(stats.count)~='number' or stats.count<=0 or type(catalogValue)~='number' or catalogValue~=catalogValue or catalogValue<=0 or catalogValue==math.huge then
    return nil,'The installed part prices could not be read. Check this vehicle\'s mods, then try again.'
  end
  -- Use Career's undepreciated assembled value, never its owned resale quote.
  payload.info.Value = catalogValue
  payload.info.rlsExport.catalogValueBasis = 'installed-parts'
  payload.info.rlsExport.partsRetailValue = stats.total
  payload.info.rlsExport.valuedPartCount = stats.count
  return true
end
function M.applyMeasurements(payload, measurements, context)
  local allowed={'Power','Torque','Weight','Weight/Power','Drivetrain','Transmission','Fuel Type','Off-Road Score',
    'Top Speed','0-60 mph','0-100 km/h','0-200 km/h','60-100 mph','100-200 km/h','60-0 mph','100-0 km/h','Braking G'}
  for _, key in ipairs(allowed) do
    local value = measurements and measurements[key]
    if (type(value)=='number' and value==value and value>0 and value<math.huge) or (type(value)=='string' and #value<80) then payload.info[key]=value end
  end
  payload.info.rlsExport.measurementContext=context
end

-- A successful archive is not evidence that all requested driving tests finished.
function M.testReport(measurements, issues)
  local report={status='complete',items={}}
  for _,entry in ipairs({{'acceleration','0-60 mph','0–60 mph'},{'topSpeed','Top Speed','Top speed'},{'braking','60-0 mph','Braking from 60 mph'},{'offroad','Off-Road Score','Off-road score'}}) do
    local value=measurements and measurements[entry[2]]
    local valid=type(value)=='number' and value==value and value>0 and value<math.huge
    local reason=type(issues)=='table' and issues[entry[1]] or nil
    if not valid or reason then report.status='incomplete' end
    report.items[#report.items+1]={key=entry[1],label=entry[3],status=valid and not reason and 'measured' or 'unavailable',
      message=reason or (not valid and 'Check that the build starts and drives.' or nil)}
  end
  return report
end

local function numberLabel(value)
  local whole,fraction=string.format('%.2f',value):match('^(%-?%d+)(%.%d+)$')
  whole=whole:reverse():gsub('(%d%d%d)','%1,'):reverse():gsub('^,','')
  return whole..fraction:gsub('0+$',''):gsub('%.$','')
end
function M.fuelSummary(setup,engineNames)
  local summary={}
  if not setup then return summary end
  local hardware=require('common/rlsFuelHardware')
  local conversions={gasoline='Gasoline',diesel='Diesel',flexfuel='Flex-fuel',methanol='Methanol',nitromethane='Nitromethane'}
  local engineOrder={};for name in pairs(setup.engines or {}) do engineOrder[#engineOrder+1]=name end;table.sort(engineOrder)
  for index,name in ipairs(engineOrder) do
    local state=setup.engines[name]
    -- With more than one engine, each label says which one it is about: "Injectors, engine 2".
    local which=#engineOrder>1 and (', engine '..index) or ''
    local group='engine'..index
    -- The label already says Engine: "2.5L Turbocharged H4 Engine" reads as "2.5L Turbocharged H4".
    -- An engine without a known name has no row: "Standard" would say nothing about it.
    local engineName=engineNames and engineNames[state.partOrigin]
    if engineName then summary[#summary+1]={group=group,label=#engineOrder>1 and ('Engine '..index) or 'Engine',value=engineName:gsub('%s+[Ee]ngine$','')} end
    summary[#summary+1]={group=group,label='Fuel system'..which,value=conversions[state.conversionKind] or 'Standard'}
    for _,entry in ipairs({{'injector','Injectors'},{'pump','Fuel pump'}}) do
      local kind,label=entry[1],entry[2]..which
      local id=state.hardware and state.hardware[kind]
      local option=id and hardware.option(state,{fuelType=state.tune.fuelType,deliveryLps=state.baseDeliveryLps},kind,id)
      local value=(not option or id=='equipped') and 'Standard' or option.label
      if option and id~='equipped' and id~='legacy' and not id:match('^over') then
        value=numberLabel(option.flowLps*(kind=='injector' and 60000 or 3600))..(kind=='injector' and ' cc/min total' or ' L/h')
      end
      summary[#summary+1]={group=group,label=label,value=value}
    end
  end
  local tanks={};for name in pairs(setup.tanks or {}) do tanks[#tanks+1]=name end;table.sort(tanks)
  for index,name in ipairs(tanks) do
    local b=setup.tanks[name].blend
    local which=#tanks>1 and (', tank '..index) or ''
    local group='tank'..index
    -- The tank is named after what it mostly holds; the shares follow as their own values.
    local ethanol,methanol=b.ethanol or 0,b.methanol or 0
    local fuelName=b.diesel and 'Diesel' or (ethanol>=.5 and 'Ethanol blend') or (methanol>=.5 and 'Methanol blend')
      or ((ethanol>0 or methanol>0) and 'Gasoline blend') or 'Gasoline'
    summary[#summary+1]={group=group,label=#tanks>1 and ('Fuel in tank '..index) or 'Fuel in tank',value=fuelName}
    if not b.diesel then
      summary[#summary+1]={group=group,label='Octane'..which,value=string.format('%.0f AKI',b.aki or 87)}
      summary[#summary+1]={group=group,label='Ethanol share'..which,value=string.format('%.0f%%',(b.ethanol or 0)*100)}
      if (b.methanol or 0)>0 then summary[#summary+1]={group=group,label='Methanol share'..which,value=string.format('%.0f%%',b.methanol*100)} end
    end
  end
  return summary
end
return M

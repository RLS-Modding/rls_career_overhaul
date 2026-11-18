-- Drive the complete native thumbnail job on an owned, uniquely named fixture.
-- Supports the shipped monolithic creator and the split creator without depending on it.
local M = {}
local previous
local function set(pointer,value) if pointer then pointer[0]=value end end
local function keepDarkBackdrop()
  -- The world-ready capture transition owns this setup; the stopped showroom
  -- graph cannot replace it while the native offscreen render is in flight.
  for name,hidden in pairs({backdrop_white=false,backdrop_dark=true}) do
    local backdrop=scenetree.findObject(name)
    if backdrop then
      backdrop.hidden=hidden
      backdrop:setHidden(hidden)
      backdrop:setRenderEnabled(not hidden)
      -- New native captures use render-view mask 63; its visibility can differ
      -- from the main view's hidden/render flags.
      if hidden and backdrop.hideInRenderView then backdrop:hideInRenderView(63)
      elseif not hidden and backdrop.unhideInRenderView then backdrop:unhideInRenderView(63) end
    end
  end
end
local function jpegSize(data)
  if type(data)~='string' or data:sub(1,2)~='\255\216' or data:sub(-2)~='\255\217' then return nil end
  local i=3
  while i+8<=#data do
    if data:byte(i)~=255 then return nil end
    local marker=data:byte(i+1);i=i+2
    if marker==216 or marker==1 then -- no length
    elseif marker==218 or marker==217 then return nil
    else
      local length=data:byte(i)*256+data:byte(i+1)
      if length<2 or i+length-1>#data then return nil end
      if marker>=192 and marker<=195 then
        return data:byte(i+5)*256+data:byte(i+6),data:byte(i+3)*256+data:byte(i+4)
      end
      i=i+length
    end
  end
end
M.jpegSize=jpegSize
function M.start(job,vehicle)
  assert(getCurrentLevelIdentifier()==jsonReadFile('/gameplay/overhaul/vehicles/configExport.json').maps.thumbnail,'The showroom is not ready')
  previous={}
  if core_flowgraphManager then
    for _,manager in pairs(core_flowgraphManager.getAllManagers()) do
      if manager.name=='Showroom V2 Tools' then
        previous.flowgraph=manager;previous.flowgraphRunning=manager.runningState
        manager:setRunning(false)
      end
    end
  end
  local white,dark=scenetree.findObject('backdrop_white'),scenetree.findObject('backdrop_dark')
  assert(white and dark,'The dark showroom backdrop is unavailable')
  previous.whiteHidden,previous.darkHidden=white:isHidden(),dark:isHidden()
  previous.whiteRender,previous.darkRender=white:isRenderEnabled(),dark:isRenderEnabled()
  -- The native offscreen view can retain the white instance's visibility. Use
  -- that same instance with the showroom's dark mesh, then restore it on exit.
  previous.whiteShape=white:getField('shapeName',0)
  white:setField('shapeName',0,dark:getField('shapeName',0))
  white:postApply()
  keepDarkBackdrop()
  local material=scenetree.findObject('backdrop_a')
  if material then previous.backdropColor=material:getField('diffuseColor',0);material:setField('diffuseColor',0,'0.18 0.18 0.205 1');material:reload() end
  local exposure=scenetree.findObject('PostEffectLocalExposureObject')
  if exposure then
    previous.exposure={auto=exposure.autoExposure,manual=exposure.manualEV}
    exposure.autoExposure=true;exposure.manualEV=10.5;exposure.autoExposure=false
  end
  extensions.load('util_screenshotCreator')
  local settings=rawget(_G,'util_screenshotCreator_settings')
  if settings then
    local c=settings.getControls()
    for _,key in ipairs({'autoExposure','manualExposure','cameraOverlayEnabled','compositionOverlayEnabled','includeMarginInScreenshot','outputDestination','resolution','lightingRigEnabled','parkingMarkup'}) do
      if c[key] then previous[key]=c[key][0] end
    end
    previous.imageWidth,previous.imageHeight=c.imageResolution[0],c.imageResolution[1]
    previous.framingMode=util_screenshotCreator.getFramingMode and util_screenshotCreator.getFramingMode()
    set(c.outputDestination,0)
    set(c.autoExposure,false);set(c.manualExposure,10.5);set(c.cameraOverlayEnabled,false)
    set(c.compositionOverlayEnabled,false);set(c.includeMarginInScreenshot,false)
    set(c.lightingRigEnabled,false);set(c.parkingMarkup,false)
    settings.setImageResolution(800,448)
  end
  if util_screenshotCreator.setFramingMode then util_screenshotCreator.setFramingMode('legacy') end
  -- selection is the shipped API. targets adds an exact target for newer creators.
  local ok,err=util_screenshotCreator.startWork({selection=job.tempName,
    targets={{model=job.payload.model,config=job.tempName}},vehicleId=vehicle:getID(),
    shippedConfigsOnly=false,onlyMissingThumbnails=false,framingModeId='legacy'})
  if ok==false then error(err or 'The native thumbnail job was refused') end
end
function M.poll(job)
  if previous and previous.finishedAt then return os.time()-previous.finishedAt>=2 end
  local nativeJob=rawget(_G,'util_screenshotCreator_job')
  if nativeJob and nativeJob.isRunning and nativeJob.isRunning() then return false end
  -- The shipped monolithic job ends by setting speed to zero after its 0.75s
  -- render wait. A readable JPEG alone does not prove that workflow has ended.
  if not nativeJob and be:getPhysicsSpeedFactor()~=0 then return false end
  if not FS:fileExists(job.tempImage) then return false end
  local width,height=jpegSize(readFile(job.tempImage))
  if not width then return false end -- wait until native writer finishes
  if width~=800 or height~=448 then return false,'The native thumbnail has unexpected dimensions.' end
  if previous and not previous.finishedAt then previous.finishedAt=os.time();return false end
  return true
end
function M.cancel()
  if not previous then return true end
  local nativeJob=rawget(_G,'util_screenshotCreator_job')
  if nativeJob and nativeJob.stop then
    nativeJob.stop()
    return not nativeJob.isRunning or not nativeJob.isRunning()
  elseif rawget(_G,'util_screenshotCreator') then extensions.unload('util_screenshotCreator') end
  return true
end
function M.restore()
  local settings=rawget(_G,'util_screenshotCreator_settings')
  if previous and settings then for key,value in pairs(previous) do set(settings.getControls()[key],value) end end
  if previous and settings then
    local c=settings.getControls()
    if previous.imageWidth then c.imageResolution[0]=previous.imageWidth;c.imageResolution[1]=previous.imageHeight end
  end
  if previous and previous.framingMode and util_screenshotCreator and util_screenshotCreator.setFramingMode then util_screenshotCreator.setFramingMode(previous.framingMode) end
  local material=scenetree.findObject('backdrop_a')
  if previous and material and previous.backdropColor then material:setField('diffuseColor',0,previous.backdropColor);material:reload() end
  local exposure=scenetree.findObject('PostEffectLocalExposureObject')
  if previous and previous.exposure and exposure then
    exposure.manualEV=previous.exposure.manual;exposure.autoExposure=previous.exposure.auto
  end
  for name,key in pairs({backdrop_white='whiteHidden',backdrop_dark='darkHidden'}) do
    local backdrop=scenetree.findObject(name)
    if previous and backdrop and previous[key]~=nil then
      if name=='backdrop_white' and previous.whiteShape then backdrop:setField('shapeName',0,previous.whiteShape);backdrop:postApply() end
      backdrop.hidden=previous[key];backdrop:setHidden(previous[key])
      backdrop:setRenderEnabled(previous[name=='backdrop_white' and 'whiteRender' or 'darkRender'])
      if backdrop.unhideInRenderView then backdrop:unhideInRenderView(63) end
    end
  end
  -- This helper always leaves the temporary showroom immediately. Restarting its
  -- scene graph during teardown can run hide nodes against deleted scene objects.
  previous=nil
end
return M

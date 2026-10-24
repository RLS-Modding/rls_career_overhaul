-- Offscreen save thumbnails must not hide CEF or change global graphics settings.
-- The stock renderViews screenshot job does both, which rebuilds the visible UI
-- and graphics pipeline during a transaction save.
local M = {}

function M.capture(filename, camera, callback)
  local view
  local finished = false
  local function warn(problem)
    pcall(function() log('W', 'inventory.thumbnail', tostring(problem)) end)
  end
  local function finish(success)
    if finished then return end
    finished = true
    if view then
      local capturedView = view
      view = nil
      local released, problem = pcall(function() RenderViewManagerInstance:destroyView(capturedView) end)
      if not released then success = false; warn(problem) end
    end
    if callback then callback(success) end
  end
  local ok, problem = pcall(function()
    view = RenderViewManagerInstance:getOrCreateView('overhaulVehicleThumbnail')
    view.luaOwned = true
    view:maskSet(63)
    local matrix = QuatF(camera.rot.x, camera.rot.y, camera.rot.z, camera.rot.w):getMatrix()
    matrix:setPosition(camera.pos)
    view.cameraMatrix = matrix
    view.renderCubemap = false
    local width, height = camera.width or 500, camera.height or 281
    view.resolution = Point2I(width, height)
    view.viewPort = RectI(0, 0, width, height)
    view.namedTexTargetColor = 'overhaulVehicleThumbnail'
    view.frustum = Frustum.construct(false, math.rad(camera.fov), width / height, camera.nearPlane, 2000)
    view.fov = camera.fov
    view.renderEditorIcons = false
    local exposure = scenetree.findObject('PostEffectLocalExposureObject')
    local main = RenderViewManagerInstance:getView('main')
    view.useManualEV = exposure and exposure.autoExposure ~= true or false
    if view.useManualEV then view.manualEV = exposure.manualEV
    elseif main and main.currentExposure then view.currentExposure = main.currentExposure end
    local temporary = filename .. '.tmp.png'
    core_jobsystem.create(function(job)
      local captured, result = pcall(function()
        job.sleep(camera.screenshotDelay or 0.5)
        if not view:saveToDisk(temporary) then return false end
        local bitmap = GBitmap()
        if not bitmap:loadFile(temporary) then return false end
        bitmap:setFormat(10) -- GFXFormatR8G8B8, as in the stock thumbnail writer.
        return bitmap:saveFile(filename) == true
      end)
      local removed, problem = pcall(function() FS:removeFile(temporary) end)
      if not removed then warn(problem) end
      if not captured then warn(result) end
      finish(captured and result)
    end)
  end)
  if not ok then
    warn(problem)
    finish(false)
  end
end

return M

-- Phone photos, gallery and live preview for one career or freeroam session.
-- Read storage and gallery, torch/capture, preview/update, then the public API and hooks.
local M = {}

local mime = require('mime')

M.dependencies = { 'render_renderViews' }

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = 'phoneCamera'
local PHOTO_PREFIX = 'phone_'
local PREVIEW_INTERVAL = 0.1
local PREVIEW_FALLBACK_INTERVAL = 0.25
local PREVIEW_VIEW_NAME = 'phoneCameraPreview'
local PREVIEW_WARMUP_FRAMES = 2
local PREVIEW_LANDSCAPE = vec3(320, 240, 0)
local PREVIEW_PORTRAIT = vec3(240, 320, 0)
local PHOTO_LANDSCAPE = vec3(1280, 720, 0)
local PHOTO_PORTRAIT = vec3(720, 1280, 0)
local FLASH_RADIUS = 50

-- State -------------------------------------------------------------------------------------------

local previewActive = false
local previewBusy = false
local previewTimer = 0
local previewSequence = 0
local previewGeneration = 0
local previewAwaitingSequence = nil
local previewFallback = false
local previewSession = tostring(os.time()) .. '-' .. tostring(math.floor(os.clock() * 1000000))
local previewOrientation = 'landscape' -- 'landscape' | 'portrait'
local previewRenderView = nil
local previewWarmupFramesRemaining = 0
local persistentFlashLight = nil
local lastPhotoStamp = ''
local photoSeq = 0

-- Storage and files -------------------------------------------------------------------------------

local function nextPhotoStamp()
  local stamp = os.date('%Y%m%d_%H%M%S')
  if stamp == lastPhotoStamp then
    photoSeq = photoSeq + 1
  else
    lastPhotoStamp = stamp
    photoSeq = 0
  end
  return string.format('%s_%02d', stamp, photoSeq)
end

-- Photo directory with a trailing slash. In a career this is the Gallery/ folder beside the autosave
-- slots, so photos survive the slot rotation.
local function getPhotoDir()
  if overhaul_career_career.isActive() then
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if savePath and savePath ~= '' then
      local profilePath = savePath:match('^(.+)/[^/]+$')
      if profilePath and profilePath ~= '' then
        return profilePath .. '/Gallery/'
      end
      return savePath .. '/Gallery/'
    end
  end
  return 'settings/RLS/phoneCamera/'
end

-- FS calls resolve a freeroam user path with a leading slash, so both forms are tried.
local function getPhotoDirSlash()
  local dir = getPhotoDir()
  if dir:sub(1, 1) == '/' then return dir end
  return '/' .. dir
end

local function getPreviewTempPath(sequence)
  return getPhotoDir() .. '_preview_' .. tostring(sequence % 2) .. '.png'
end

local function ensurePhotoDir()
  local dir = getPhotoDir()
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
end

local function isPreviewFilename(name)
  return name == '_preview.jpg' or name == '_preview.jpeg' or name == '_preview.png'
    or name:match('^_preview_[01]%.png$') ~= nil or name:match('^_preview_[01]%.jpg$') ~= nil
end

-- Reads a file's bytes, or nil when it is missing or empty.
local function readFileBytes(relPath)
  local fullPath = FS:expandFilename(relPath)
  if not fullPath then return nil end
  local file = io.open(fullPath, 'rb')
  if not file then return nil end
  local data = file:read('*a')
  file:close()
  if not data or #data == 0 then return nil end
  return data
end

-- Finds a photo's path in the photo directory, trying the slash form when the plain one is missing.
local function findPhotoPath(filename)
  local relPath = getPhotoDir() .. filename
  if not FS:fileExists(relPath) then
    relPath = getPhotoDirSlash() .. filename
  end
  if not FS:fileExists(relPath) then return nil end
  return relPath
end

-- Gallery ----------------------------------------------------------------------------------------

local function removeWithOsFallback(relPath)
  local fullPath = FS:expandFilename(relPath)
  log('D', LOG_TAG, '[PhoneCamera] fallback: expandFilename => "' .. tostring(fullPath) .. '"')
  if not fullPath or fullPath == '' then return false end
  local suc, res = pcall(os.remove, fullPath)
  log('D', LOG_TAG, '[PhoneCamera] os.remove(fullPath) => pcall_ok=' .. tostring(suc) .. ' result=' .. tostring(res) .. ' ok=' .. tostring(suc and res))
  return suc and res
end

local function removePhotoFile(filename, photoDir, photoDirSlash)
  local relPath = photoDir .. filename
  local exists = FS:fileExists(relPath)
  if not exists then
    relPath = photoDirSlash .. filename
    exists = FS:fileExists(relPath)
  end
  log('D', LOG_TAG, '[PhoneCamera] delete file: relPath="' .. tostring(relPath) .. '" fileExists=' .. tostring(exists))
  if not exists then return false end
  local removed = FS:removeFile(relPath)
  log('D', LOG_TAG, '[PhoneCamera] FS:removeFile(relPath) => ' .. tostring(removed))
  if removed then return true end
  return removeWithOsFallback(relPath)
end

-- Photo filenames for the gallery, newest first. FS:findFiles lists files; directoryList only lists folders.
function M.getPhotoList()
  ensurePhotoDir()
  local photoDir = getPhotoDir()
  local photoDirSlash = getPhotoDirSlash()
  local list = {}
  for _, pattern in ipairs({ '*.jpg', '*.jpeg', '*.png' }) do
    local found = FS:findFiles(photoDir, pattern, 0, false, false)
    if not found or #found == 0 then
      found = FS:findFiles(photoDirSlash, pattern, 0, false, false)
    end
    for _, filepath in ipairs(found or {}) do
      local name = (type(filepath) == 'string' and filepath:match('([^/\\]+)$')) or tostring(filepath)
      if name and name ~= '' and not isPreviewFilename(name) then
        list[#list + 1] = { filename = name, name = name:gsub('%.%w+$', '') }
      end
    end
  end
  table.sort(list, function(a, b) return (a.filename or '') > (b.filename or '') end)
  return list
end

-- Deletes photos by filename and returns how many were removed.
function M.deletePhotos(filenames)
  if type(filenames) ~= 'table' then filenames = { filenames } end
  local photoDir = getPhotoDir()
  local photoDirSlash = getPhotoDirSlash()
  log('D', LOG_TAG, '[PhoneCamera] deletePhotos: photoDir="' .. tostring(photoDir) .. '" photoDirSlash="' .. tostring(photoDirSlash) .. '" count=' .. #filenames)
  local removed = 0
  for _, filename in ipairs(filenames) do
    if type(filename) == 'string' and filename ~= '' then
      filename = filename:gsub('^.*[/\\]', '')
      if filename ~= '' and not isPreviewFilename(filename) and removePhotoFile(filename, photoDir, photoDirSlash) then
        removed = removed + 1
      end
    end
  end
  log('D', LOG_TAG, '[PhoneCamera] deletePhotos done: removed=' .. removed)
  return removed
end

-- A photo as a base64 data URL for the phone UI.
function M.getPhotoAsDataUrl(filename)
  if not filename or filename == '' then return nil end
  filename = filename:gsub('^.*[/\\]', '')
  local relPath = findPhotoPath(filename)
  if not relPath then return nil end
  local data = readFileBytes(relPath)
  if not data then return nil end
  local b64 = mime.b64(data)
  if not b64 then return nil end
  local ext = filename:lower():match('%.(%w+)$') or 'jpg'
  local mimeType = (ext == 'png' or data:sub(1, 8) == '\137PNG\r\n\26\n') and 'image/png' or 'image/jpeg'
  return 'data:' .. mimeType .. ';base64,' .. b64
end

-- Torch and flash --------------------------------------------------------------------------------

local function destroyPersistentFlash()
  if persistentFlashLight then
    persistentFlashLight:delete()
    persistentFlashLight = nil
  end
end

local function updatePersistentFlash()
  if persistentFlashLight then
    local pos = core_camera.getPosition()
    if pos then
      persistentFlashLight:setPosition(pos)
    end
  end
end

local function createCameraLight(name, position, brightness)
  local light = createObject('PointLight')
  if not light then return nil end
  if position then light:setPosition(position) end
  light.radius = FLASH_RADIUS
  light.brightness = brightness
  light.color = Point4F(1, 1, 1, 1)
  light.castShadows = true
  light:registerObject(name)
  return light
end

-- A short flash for one photo; waits a moment so the light renders before the shutter.
local function createPhotoFlash(job, position)
  local flash = createCameraLight('phoneCameraFlash', position, 0.3)
  if flash then job.sleep(0.05) end
  return flash
end

-- Capture ----------------------------------------------------------------------------------------

local function announcePhotoResult(photoDir, success)
  if success == false then
    guihooks.trigger('toastrMsg', { type = 'error', title = 'Camera', msg = 'Could not take photo.' })
    return
  end
  guihooks.trigger('toastrMsg', { type = 'success', title = 'Photo saved', msg = 'Saved to ' .. photoDir })
end

-- Renders the photo through a render view so the saved image matches the chosen orientation.
local function takePhotoWithOrientationJob(job)
  local orientation = (job.args[1] == 'portrait') and 'portrait' or 'landscape'
  local useFlash = job.args[2] == true

  ensurePhotoDir()
  local photoDir = getPhotoDir()
  local position = core_camera.getPosition()
  local rotation = core_camera.getQuat()
  if not position or not rotation then
    guihooks.trigger('toastrMsg', { type = 'error', title = 'Camera', msg = 'Could not take photo.' })
    return
  end

  local tempFlash = nil
  if useFlash and not persistentFlashLight then
    tempFlash = createPhotoFlash(job, position)
  end

  local resolution = (orientation == 'portrait') and PHOTO_PORTRAIT or PHOTO_LANDSCAPE
  local pathNoExt = photoDir .. PHOTO_PREFIX .. nextPhotoStamp()
  local options = {
    pos = position,
    rot = { x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w },
    filename = pathNoExt .. '.png',
    renderViewName = 'phoneCameraPhoto',
    resolution = resolution,
    fov = core_camera.getFovDeg() or 75,
    nearPlane = 0.1,
    copyMainViewExposure = true,
    screenshotDelay = 0.2,
  }
  local function onSaved(success)
    if tempFlash then tempFlash:delete() end
    announcePhotoResult(photoDir, success)
  end
  render_renderViews.takeScreenshot(options, onSaved)
end

-- Live preview -----------------------------------------------------------------------------------

-- The normal path leaves the pixels on disk. Only CEF decode failures use
-- the smaller, slower JPEG transport, so normal frames never cross Lua as bytes.
local function sendPreviewFrameToUI(filename, sequence, fallback)
  local source
  if fallback then
    local data = readFileBytes(filename)
    if not data then return end
    local encoded = mime.b64(data)
    if not encoded then return end
    source = 'data:image/jpeg;base64,' .. encoded
  else
    source = 'local://local/' .. filename:gsub('^/', '') .. '?v=' .. previewSession .. '-' .. sequence
    previewAwaitingSequence = sequence
  end
  guihooks.trigger('PhoneCameraPreviewFrame', {src = source, sequence = sequence})
end

local function destroyPreviewRenderView()
  if RenderViewManagerInstance and previewRenderView then
    RenderViewManagerInstance:destroyView(previewRenderView)
  end
  previewRenderView = nil
end

local function finishPreviewCapture(success, filename, sequence, generation, fallback)
  previewBusy = false
  if not previewActive then destroyPreviewRenderView(); return end
  if generation ~= previewGeneration or not success then return end
  -- A new view's first frames can show an exposure flash.
  if previewWarmupFramesRemaining > 0 then
    previewWarmupFramesRemaining = previewWarmupFramesRemaining - 1
    return
  end
  sendPreviewFrameToUI(filename, sequence, fallback)
end

-- saveToDisk completes before publishing its path. The next capture writes the
-- other buffer, and cannot start until CEF acknowledges the published image.
local function previewSaveJob(job)
  local renderView, filename, sequence, generation, fallback = unpack(job.args)
  job.sleep(0.06)
  if generation ~= previewGeneration or not previewActive then
    finishPreviewCapture(false, filename, sequence, generation, fallback)
    return
  end
  local success = renderView:saveToDisk(filename)
  if success and fallback then
    local bitmap = GBitmap()
    local jpegFilename = filename:gsub('%.png$', '.jpg')
    success = bitmap:loadFile(filename)
    if success then
      bitmap:setFormat(10) -- JPEG requires RGB rather than the render view's RGBA.
      success = bitmap:saveFile(jpegFilename)
    end
    filename = jpegFilename
  end
  finishPreviewCapture(success, filename, sequence, generation, fallback)
end

local function getMainViewManualEV()
  local localExposure = scenetree.findObject('PostEffectLocalExposureObject')
  return localExposure and tonumber(localExposure.manualEV) or nil
end

-- Points the preview view at the current camera and matches the main view's exposure.
local function configurePreviewView(renderView, position, rotation, resolution)
  local matrix = QuatF(rotation.x, rotation.y, rotation.z, rotation.w):getMatrix()
  matrix:setPosition(position)
  local fov = core_camera.getFovDeg() or 75
  local manualEV = getMainViewManualEV()
  renderView.renderCubemap = false
  renderView.cameraMatrix = matrix
  renderView.resolution = Point2I(resolution.x, resolution.y)
  renderView.viewPort = RectI(0, 0, resolution.x, resolution.y)
  renderView.namedTexTargetColor = PREVIEW_VIEW_NAME
  renderView.frustum = Frustum.construct(false, math.rad(fov), resolution.x / resolution.y, 0.1, 2000)
  renderView.fov = fov
  renderView.renderEditorIcons = false
  renderView.useManualEV = manualEV ~= nil
  renderView.manualEV = manualEV or 0
end

-- One render view stays alive for the preview. Recreating it every frame resets the renderer's
-- temporal exposure and makes bright flashes in BeamNG 0.39.
local function capturePreviewFrame()
  if not previewActive or previewBusy or previewAwaitingSequence then return end
  if not RenderViewManagerInstance then return end
  local position = core_camera.getPosition()
  local rotation = core_camera.getQuat()
  if not position or not rotation then return end
  ensurePhotoDir()
  previewBusy = true
  local renderView = previewRenderView or RenderViewManagerInstance:getOrCreateView(PREVIEW_VIEW_NAME)
  if not renderView then previewBusy = false; return end
  previewRenderView = renderView
  renderView.luaOwned = true
  local resolution = (previewOrientation == 'portrait') and PREVIEW_PORTRAIT or PREVIEW_LANDSCAPE
  configurePreviewView(renderView, position, rotation, resolution)
  previewSequence = previewSequence + 1
  core_jobsystem.create(previewSaveJob, nil, renderView, getPreviewTempPath(previewSequence),
    previewSequence, previewGeneration, previewFallback)
end

-- Per-frame update -------------------------------------------------------------------------------

local function tickPreview(dt)
  previewTimer = previewTimer + dt
  local interval = previewFallback and PREVIEW_FALLBACK_INTERVAL or PREVIEW_INTERVAL
  if previewTimer >= interval then
    previewTimer = 0
    capturePreviewFrame()
  end
  updatePersistentFlash()
end

-- Public API: photos and gallery -----------------------------------------------------------------

-- Called from the phone UI when the user taps "Take Photo". orientation: 'landscape' | 'portrait'.
function M.takePhoto(orientation, useFlash)
  core_jobsystem.create(takePhotoWithOrientationJob, nil, orientation or 'landscape', useFlash)
end

-- Public API: torch and preview ------------------------------------------------------------------

function M.setTorchMode(enabled)
  if not enabled then
    destroyPersistentFlash()
    return
  end
  if persistentFlashLight then return end
  persistentFlashLight = createCameraLight('phoneCameraTorch', core_camera.getPosition(), 0.55)
end

function M.startPreview()
  previewGeneration = previewGeneration + 1
  previewAwaitingSequence = nil
  previewFallback = false
  previewActive = true
  previewTimer = 0
  previewWarmupFramesRemaining = PREVIEW_WARMUP_FRAMES
end

local function stopPreview()
  previewActive = false
  previewGeneration = previewGeneration + 1
  previewAwaitingSequence = nil
  if not previewBusy then
    destroyPreviewRenderView()
  end
  destroyPersistentFlash()
end

M.stopPreview = stopPreview

function M.onPreviewFrameLoaded(sequence)
  if previewActive and sequence == previewAwaitingSequence then
    previewAwaitingSequence = nil
  end
end

function M.onPreviewFrameFailed(sequence)
  if not previewActive or sequence ~= previewAwaitingSequence then return end
  previewAwaitingSequence = nil
  previewFallback = true
  previewTimer = 0
end

function M.setPreviewOrientation(orientation)
  if orientation == 'portrait' or orientation == 'landscape' then
    if previewActive and previewOrientation ~= orientation then
      previewWarmupFramesRemaining = math.max(previewWarmupFramesRemaining, 1)
    end
    previewOrientation = orientation
  end
end

-- Game hooks -------------------------------------------------------------------------------------

function M.onUpdate(dt)
  if not previewActive then return end
  tickPreview(dt)
end

function M.onExtensionLoaded()
  log('I', LOG_TAG, 'Camera Phone App Extension Loaded')
end

function M.onExtensionUnloaded()
  stopPreview()
end

return M

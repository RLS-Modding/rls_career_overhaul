-- Phone Camera app: take in-game photos (screenshots) from the career phone.
-- Freeroam: photos saved to screenshots/phone/
-- Career: photos saved in the save profile folder (not inside autosave slot): {profile}/Gallery/
--   so they persist when the game rotates autosave1/2/3.
-- Gallery: list photos and serve as data URLs for the phone UI.
-- Live preview: stream current camera view to the app via periodic capture.

local M = {}

M.dependencies = { 'ui_visibility', 'core_camera', 'render_renderViews' }

local PHOTO_PREFIX = 'phone_'
local PREVIEW_INTERVAL = 0.1
local PREVIEW_VIEW_NAME = 'phoneCameraPreview'
local PREVIEW_LANDSCAPE = vec3(320, 240, 0)
local PREVIEW_PORTRAIT = vec3(240, 320, 0)
local PHOTO_LANDSCAPE = vec3(1280, 720, 0)
local PHOTO_PORTRAIT = vec3(720, 1280, 0)

local previewActive = false
local previewBusy = false
local previewTimer = 0
local previewOrientation = 'landscape'  -- 'landscape' | 'portrait'

local lastPhotoStamp = ''
local photoSeq = 0
local function nextPhotoStamp()
  local ts = os.date('%Y%m%d_%H%M%S')
  if ts == lastPhotoStamp then
    photoSeq = photoSeq + 1
  else
    lastPhotoStamp = ts
    photoSeq = 0
  end
  return string.format('%s_%02d', ts, photoSeq)
end

-- Returns the directory where photos are stored (with trailing slash).
-- In career: save profile folder (parent of autosave1/2/3) + Gallery/, e.g. settings/cloud/saves/Profile/Gallery/
--   so photos persist when the active autosave slot changes.
-- In freeroam: screenshots/phone/
local function getPhotoDir()
  if career_career and career_career.isActive and career_career.isActive() and career_saveSystem and career_saveSystem.getCurrentSaveSlot then
    local _, savePath = career_saveSystem.getCurrentSaveSlot()
    if savePath and savePath ~= '' then
      -- savePath is e.g. settings/cloud/saves/Profile/autosave2; we want settings/cloud/saves/Profile/Gallery/
      local profilePath = savePath:match('^(.+)/[^/]+$')
      if profilePath and profilePath ~= '' then
        return profilePath .. '/Gallery/'
      end
      -- fallback if no slash (unusual)
      return savePath .. '/Gallery/'
    end
  end
  return 'screenshots/phone/'
end

-- Path with leading slash for FS APIs that expect user path (freeroam only; career path usually has no leading slash).
local function getPhotoDirSlash()
  local d = getPhotoDir()
  if d:sub(1, 1) == '/' then return d end
  return '/' .. d
end

local function getPreviewTempPath()
  return getPhotoDir() .. '_preview.jpg'
end

local mime = nil
local function getMime()
  if not mime then
    local ok, mod = pcall(require, 'mime')
    mime = ok and mod or nil
  end
  return mime
end

local function ensurePhotoDir()
  local dir = getPhotoDir()
  if not FS:directoryExists(dir) then
    FS:directoryCreate(dir, true)
  end
end

-- Returns list of photo filenames (newest first) for the gallery.
-- Uses FS:findFiles (lists files); directoryList only lists subdirectories.
-- Try both path forms in case FS resolves user path with leading slash.
function M.getPhotoList()
  ensurePhotoDir()
  local photoDir = getPhotoDir()
  local photoDirSlash = getPhotoDirSlash()
  local list = {}
  local patterns = { '*.jpg', '*.jpeg', '*.png' }
  for _, pat in ipairs(patterns) do
    local raw = FS:findFiles(photoDir, pat, 0, false, false)
    if not raw or #raw == 0 then
      raw = FS:findFiles(photoDirSlash, pat, 0, false, false)
    end
    if raw then
      for _, filepath in ipairs(raw) do
        local name = (type(filepath) == 'string' and filepath:match('([^/\\]+)$')) or tostring(filepath)
        if name and name ~= '' and name ~= '_preview.jpg' and name ~= '_preview.jpeg' then
          list[#list + 1] = { filename = name, name = name:gsub('%.%w+$', '') }
        end
      end
    end
  end
  table.sort(list, function(a, b) return (a.filename or '') > (b.filename or '') end)
  return list
end

-- Delete one or more photos by filename (removes files from disk in current photo dir).
-- Returns the number of files successfully removed.
-- Uses FS:removeFile(relPath); if that fails, tries os.remove(FS:expandFilename(relPath)).
function M.deletePhotos(filenames)
  if type(filenames) ~= 'table' then filenames = { filenames } end
  local photoDir = getPhotoDir()
  local photoDirSlash = getPhotoDirSlash()
  local removed = 0
  print('[PhoneCamera] deletePhotos: photoDir="' .. tostring(photoDir) .. '" photoDirSlash="' .. tostring(photoDirSlash) .. '" count=' .. #filenames)
  for _, filename in ipairs(filenames) do
    if type(filename) == 'string' and filename ~= '' then
      filename = filename:gsub('^.*[/\\]', '')
      if filename ~= '' and filename ~= '_preview.jpg' and filename ~= '_preview.jpeg' then
        local relPath = photoDir .. filename
        local exists = FS:fileExists(relPath)
        if not exists then
          relPath = photoDirSlash .. filename
          exists = FS:fileExists(relPath)
        end
        print('[PhoneCamera] delete file: relPath="' .. tostring(relPath) .. '" fileExists=' .. tostring(exists))
        if not exists then goto continue end
        local ok = FS:removeFile(relPath)
        print('[PhoneCamera] FS:removeFile(relPath) => ' .. tostring(ok))
        if not ok then
          local fullPath = FS:expandFilename(relPath)
          print('[PhoneCamera] fallback: expandFilename => "' .. tostring(fullPath) .. '"')
          if fullPath and fullPath ~= '' then
            local suc, res = pcall(os.remove, fullPath)
            ok = suc and res
            print('[PhoneCamera] os.remove(fullPath) => pcall_ok=' .. tostring(suc) .. ' result=' .. tostring(res) .. ' ok=' .. tostring(ok))
          end
        end
        if ok then removed = removed + 1 end
        ::continue::
      end
    end
  end
  print('[PhoneCamera] deletePhotos done: removed=' .. removed)
  return removed
end

-- Reads a photo file and returns a data URL for display in the UI (base64).
function M.getPhotoAsDataUrl(filename)
  if not filename or filename == '' then return nil end
  filename = filename:gsub('^.*[/\\]', '')
  local photoDir = getPhotoDir()
  local photoDirSlash = getPhotoDirSlash()
  local relPath = photoDir .. filename
  if not FS:fileExists(relPath) then
    relPath = photoDirSlash .. filename
  end
  if not FS:fileExists(relPath) then return nil end
  local fullPath = FS:expandFilename(relPath)
  if not fullPath then return nil end
  local f = io.open(fullPath, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  if not data or #data == 0 then return nil end
  local m = getMime()
  if not m or not m.b64 then return nil end
  local b64 = m.b64(data)
  if not b64 then return nil end
  local ext = filename:lower():match('%.(%w+)$') or 'jpg'
  local mimeType = (ext == 'png') and 'image/png' or 'image/jpeg'
  return 'data:' .. mimeType .. ';base64,' .. b64
end

local persistentFlashLight = nil

local function destroyPersistentFlash()
  if persistentFlashLight then
    persistentFlashLight:delete()
    persistentFlashLight = nil
  end
end

local function updatePersistentFlash()
  if persistentFlashLight and core_camera then
    local pos = core_camera.getPosition()
    if pos then
      persistentFlashLight:setPosition(pos)
    end
  end
end

function M.setTorchMode(enabled)
  if enabled then
    if not persistentFlashLight then
      persistentFlashLight = createObject('PointLight')
      if persistentFlashLight then
        local pos = core_camera.getPosition()
        if pos then persistentFlashLight:setPosition(pos) end
        persistentFlashLight.radius = 50
        persistentFlashLight.brightness = 0.55 -- Slightly dimmer for continuous torch
        persistentFlashLight.color = Point4F(1, 1, 1, 1)
        persistentFlashLight.castShadows = true
        persistentFlashLight:registerObject('phoneCameraTorch')
      end
    end
  else
    destroyPersistentFlash()
  end
end

-- Take photo using render view so saved image matches orientation (landscape or portrait).
local function takePhotoWithOrientationJob(job)
  local orientation = (job.args[1] == 'portrait') and 'portrait' or 'landscape'
  local useFlash = job.args[2] == true
  
  ensurePhotoDir()
  local photoDir = getPhotoDir()
  local pos = core_camera.getPosition()
  local q = core_camera.getQuat()
  if not pos or not q or not render_renderViews or not render_renderViews.takeScreenshot then
    guihooks.trigger('toastrMsg', { type = 'error', title = 'Camera', msg = 'Could not take photo.' })
    return
  end

  local tempFlashLight = nil
  -- Only create a temporary flash if the persistent torch isn't already on
  if useFlash and not persistentFlashLight then
    -- Create a temporary point light for the flash
    tempFlashLight = createObject('PointLight')
    if tempFlashLight then
      tempFlashLight:setPosition(pos)
      tempFlashLight.radius = 50
      tempFlashLight.brightness = 0.3
      tempFlashLight.color = Point4F(1, 1, 1, 1)
      tempFlashLight.castShadows = true
      tempFlashLight:registerObject('phoneCameraFlash')
      
      -- Wait a tiny bit for the light to render
      job.sleep(0.05)
    end
  end

  local res = (orientation == 'portrait') and PHOTO_PORTRAIT or PHOTO_LANDSCAPE
  local timestamp = nextPhotoStamp()
  local pathNoExt = photoDir .. PHOTO_PREFIX .. timestamp
  local options = {
    pos = pos,
    rot = { x = q.x, y = q.y, z = q.z, w = q.w },
    filename = pathNoExt .. '.jpg',
    renderViewName = 'phoneCameraPhoto',
    resolution = res,
    fov = (core_camera.getFovDeg and core_camera.getFovDeg()) or 75,
    nearPlane = 0.1,
    screenshotDelay = 0.2
  }
  local function onSaved()
    if tempFlashLight then
      tempFlashLight:delete()
    end
    guihooks.trigger('toastrMsg', {
      type = 'success',
      title = 'Photo saved',
      msg = 'Saved to ' .. photoDir
    })
  end
  render_renderViews.takeScreenshot(options, onSaved)
end

-- Called from the phone UI (Vue) when the user taps "Take Photo". orientation: 'landscape' | 'portrait'
function M.takePhoto(orientation, useFlash)
  core_jobsystem.create(takePhotoWithOrientationJob, nil, orientation or 'landscape', useFlash)
end

-- Live preview: capture current camera view and send as data URL to UI.
-- Use our own job so we never hide the UI (no flicker/reload).
local function sendPreviewFrameToUI()
  local relPath = getPreviewTempPath()
  if not FS:fileExists(relPath) then relPath = getPhotoDirSlash() .. '_preview.jpg' end
  if not FS:fileExists(relPath) then previewBusy = false; return end
  local fullPath = FS:expandFilename(relPath)
  if not fullPath then previewBusy = false; return end
  local f = io.open(fullPath, 'rb')
  if not f then previewBusy = false; return end
  local data = f:read('*a')
  f:close()
  if not data or #data == 0 then previewBusy = false; return end
  local m = getMime()
  if not m or not m.b64 then previewBusy = false; return end
  local b64 = m.b64(data)
  if b64 then
    guihooks.trigger('PhoneCameraPreviewFrame', 'data:image/jpeg;base64,' .. b64)
  end
  previewBusy = false
end

-- Job that only saves the view to disk (no UI hide) then calls callback.
local function previewSaveJob(job)
  local renderView = job.args[1]
  local filename = job.args[2]
  local callback = job.args[3]
  job.sleep(0.06)
  if renderView and renderView.saveToDisk then
    renderView:saveToDisk(filename)
  end
  if RenderViewManagerInstance and renderView then
    RenderViewManagerInstance:destroyView(renderView)
  end
  if callback then callback() end
end

-- Create render view from current camera and run our no-UI-hide job.
local function capturePreviewFrame()
  if not previewActive or previewBusy then return end
  if not RenderViewManagerInstance or not core_camera then return end
  local pos = core_camera.getPosition()
  local q = core_camera.getQuat()
  if not pos or not q then return end
  ensurePhotoDir()
  previewBusy = true
  local viewName = PREVIEW_VIEW_NAME
  local renderView = RenderViewManagerInstance:getOrCreateView(viewName)
  if not renderView then previewBusy = false; return end
  renderView.luaOwned = true
  local res = (previewOrientation == 'portrait') and PREVIEW_PORTRAIT or PREVIEW_LANDSCAPE
  local rot = q
  local mat = QuatF(rot.x, rot.y, rot.z, rot.w):getMatrix()
  mat:setPosition(pos)
  renderView.renderCubemap = false
  renderView.cameraMatrix = mat
  renderView.resolution = Point2I(res.x, res.y)
  renderView.viewPort = RectI(0, 0, res.x, res.y)
  renderView.namedTexTargetColor = viewName
  local aspectRatio = res.x / res.y
  local fov = (core_camera.getFovDeg and core_camera.getFovDeg()) or 75
  local nearPlane = 0.1
  local farClip = 2000
  renderView.frustum = Frustum.construct(false, math.rad(fov), aspectRatio, nearPlane, farClip)
  renderView.fov = fov
  renderView.renderEditorIcons = false
  core_jobsystem.create(previewSaveJob, nil, renderView, getPreviewTempPath(), sendPreviewFrameToUI)
end

function M.startPreview()
  previewActive = true
  previewTimer = 0
end

function M.stopPreview()
  previewActive = false
  previewBusy = false
  destroyPersistentFlash()
end

function M.setPreviewOrientation(orientation)
  if orientation == 'portrait' or orientation == 'landscape' then
    previewOrientation = orientation
  end
end

function M.onUpdate(dt)
  if not previewActive then return end
  previewTimer = previewTimer + dt
  if previewTimer >= PREVIEW_INTERVAL then
    previewTimer = 0
    capturePreviewFrame()
  end
  
  -- Keep the persistent torch attached to the camera
  updatePersistentFlash()
end

local function onExtensionLoaded()
  print("Camera Phone App Extension Loaded")
end

M.onExtensionLoaded = onExtensionLoaded

return M

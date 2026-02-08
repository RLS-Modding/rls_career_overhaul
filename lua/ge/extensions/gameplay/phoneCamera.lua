-- Phone Camera app: take in-game photos (screenshots) from the career phone.
-- Photos are saved to screenshots/phone/ and the UI is hidden briefly so the shot is clean.
-- Gallery: list photos and serve as data URLs for the phone UI.
-- Live preview: stream current camera view to the app via periodic capture.

local M = {}

M.dependencies = { 'ui_visibility', 'core_camera', 'render_renderViews' }

local PHOTO_DIR = 'screenshots/phone/'
local PHOTO_DIR_SLASH = '/screenshots/phone/'  -- leading slash for FS APIs (user path)
local PHOTO_PREFIX = 'phone_'
local PREVIEW_TEMP = PHOTO_DIR .. '_preview.jpg'
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

local mime = nil
local function getMime()
  if not mime then
    local ok, mod = pcall(require, 'mime')
    mime = ok and mod or nil
  end
  return mime
end

local function ensurePhotoDir()
  if not FS:directoryExists(PHOTO_DIR) then
    FS:directoryCreate(PHOTO_DIR, true)
  end
end

-- Returns list of photo filenames (newest first) for the gallery.
-- Uses FS:findFiles (lists files); directoryList only lists subdirectories.
-- Try both path forms in case FS resolves user path with leading slash.
function M.getPhotoList()
  ensurePhotoDir()
  local list = {}
  local patterns = { '*.jpg', '*.jpeg', '*.png' }
  for _, pat in ipairs(patterns) do
    local raw = FS:findFiles(PHOTO_DIR, pat, 0, false, false)
    if not raw or #raw == 0 then
      raw = FS:findFiles(PHOTO_DIR_SLASH, pat, 0, false, false)
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

-- Reads a photo file and returns a data URL for display in the UI (base64).
function M.getPhotoAsDataUrl(filename)
  if not filename or filename == '' then return nil end
  filename = filename:gsub('^.*[/\\]', '')
  local relPath = PHOTO_DIR .. filename
  if not FS:fileExists(relPath) then
    relPath = PHOTO_DIR_SLASH .. filename
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

-- Take photo using render view so saved image matches orientation (landscape or portrait).
local function takePhotoWithOrientationJob(job)
  local orientation = (job.args[1] == 'portrait') and 'portrait' or 'landscape'
  ensurePhotoDir()
  local pos = core_camera.getPosition()
  local q = core_camera.getQuat()
  if not pos or not q or not render_renderViews or not render_renderViews.takeScreenshot then
    guihooks.trigger('toastrMsg', { type = 'error', title = 'Camera', msg = 'Could not take photo.' })
    return
  end
  local res = (orientation == 'portrait') and PHOTO_PORTRAIT or PHOTO_LANDSCAPE
  local timestamp = os.date('%Y%m%d_%H%M%S')
  local pathNoExt = PHOTO_DIR .. PHOTO_PREFIX .. timestamp
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
    guihooks.trigger('toastrMsg', {
      type = 'success',
      title = 'Photo saved',
      msg = 'Saved to ' .. PHOTO_DIR
    })
  end
  render_renderViews.takeScreenshot(options, onSaved)
end

-- Called from the phone UI (Vue) when the user taps "Take Photo". orientation: 'landscape' | 'portrait'
function M.takePhoto(orientation)
  core_jobsystem.create(takePhotoWithOrientationJob, nil, orientation or 'landscape')
end

-- Live preview: capture current camera view and send as data URL to UI.
-- Use our own job so we never hide the UI (no flicker/reload).
local function sendPreviewFrameToUI()
  local relPath = PREVIEW_TEMP
  if not FS:fileExists(relPath) then relPath = PHOTO_DIR_SLASH .. '_preview.jpg' end
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
  core_jobsystem.create(previewSaveJob, nil, renderView, PREVIEW_TEMP, sendPreviewFrameToUI)
end

function M.startPreview()
  previewActive = true
  previewTimer = 0
end

function M.stopPreview()
  previewActive = false
  previewBusy = false
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
end

local function onExtensionLoaded()
  print("Camera Phone App Extension Loaded")
end

M.onExtensionLoaded = onExtensionLoaded

return M

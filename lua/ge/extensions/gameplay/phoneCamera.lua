-- Phone Camera app: take in-game photos (screenshots) from the career phone.
-- Photos are saved to screenshots/phone/ and the UI is hidden briefly so the shot is clean.
-- Gallery: list photos and serve as data URLs for the phone UI.

local M = {}

M.dependencies = { 'ui_visibility' }

local PHOTO_DIR = 'screenshots/phone/'
local PHOTO_DIR_SLASH = '/screenshots/phone/'  -- leading slash for FS APIs (user path)
local PHOTO_PREFIX = 'phone_'

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
        if name and name ~= '' then
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

local function takePhotoJob(job)
  -- Close phone so the next frame shows the game world
  guihooks.trigger('closePhone')
  job.sleep(0.5)

  ensurePhotoDir()

  -- Hide all UI so the screenshot is clean (no HUD/phone)
  local wasVisible = ui_visibility.get()
  ui_visibility.set(false)
  job.sleep(0.25)

  -- Use game's screenshot module (global when career is running)
  local screenshot = _G.screenshot or (function()
    local ok, mod = pcall(require, 'screenshot')
    return ok and mod or nil
  end)()
  if not screenshot or not screenshot.doScreenshot then
    ui_visibility.set(wasVisible)
    guihooks.trigger('toastrMsg', { type = 'error', title = 'Camera', msg = 'Could not take photo.' })
    return
  end

  local timestamp = os.date('%Y%m%d_%H%M%S')
  local pathNoExt = PHOTO_DIR .. PHOTO_PREFIX .. timestamp
  screenshot.doScreenshot(nil, nil, pathNoExt, 'jpg')

  ui_visibility.set(wasVisible)

  guihooks.trigger('toastrMsg', {
    type = 'success',
    title = 'Photo saved',
    msg = 'Saved to ' .. PHOTO_DIR
  })
end

-- Called from the phone UI (Vue) when the user taps "Take Photo".
function M.takePhoto()
  core_jobsystem.create(takePhotoJob)
end

local function onExtensionLoaded()
  print("Camera Phone App Extension Loaded")
end

M.onExtensionLoaded = onExtensionLoaded


return M

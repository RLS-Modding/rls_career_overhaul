-- Resolve event artwork for phone cards and host POIs; absent photos leave the UI placeholder.
-- Existing authored art takes precedence; relative paths use the map asset convention.
local M = {}
local levelData = require('overhaul/lib/world/levelData')

function M.resolve(levelId, eventId, thumbnail)
  if type(thumbnail) == 'string' and thumbnail ~= '' then
    if thumbnail:match('^%a[%w+.-]*:') then return thumbnail end
    local authoredPhoto
    if thumbnail:sub(1, 1) == '/' then
      authoredPhoto = thumbnail
    elseif levelId and levelId ~= '' then
      authoredPhoto = levelData.assetPath(levelId, thumbnail)
    end
    if authoredPhoto and FS:fileExists(authoredPhoto) then return authoredPhoto end
  end
  if levelId and levelId ~= '' and eventId then
    local photo = '/levels/' .. levelId .. '/facilities/freeroamEvents/' .. eventId .. '.jpg'
    if FS:fileExists(photo) then return photo end
  end
end

return M

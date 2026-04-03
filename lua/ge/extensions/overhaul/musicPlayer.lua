local M = {}

local DEFAULT_PLAY_MODE = 'random'

local state = {
  tracks = {},
  playlistPath = nil,
  musicLibraryRoot = nil,
  playlistsByName = nil,
  activePlaylistName = nil,
  index = 1,
  mode = DEFAULT_PLAY_MODE,
  guiSourceId = nil,
  lastEmitter = nil,
  uiEmitterName = nil,
  uiUseGui = true,
  uiChannel = 'AudioGui',
  isPlaying = false,
  playStartClock = nil,
  playDurationSec = 0,
  playbackPauseAccumSec = 0,
  playbackPauseWallStart = nil,
  uiWantsAutoAdvance = false,
  repeatMode = 'all',
  musicVolume = 1,
  shuffleOrder = nil,
  shuffleCursor = nil
}

local function invalidateShuffleOrder()
  state.shuffleOrder = nil
  state.shuffleCursor = nil
end

local musicPrefsPath = 'settings/musicPlayerPrefs.json'

local defaultTracks = {}

local function deepCopy(src)
  if type(src) ~= 'table' then
    return src
  end
  local out = {}
  for k, v in pairs(src) do
    out[k] = deepCopy(v)
  end
  return out
end

local function resolveEmitter(emitter, emitterName)
  if emitter then
    return emitter
  end
  if type(emitterName) == 'string' and emitterName ~= '' then
    return scenetree.findObject(emitterName)
  end
  return nil
end

local function stopGuiSource()
  if state.guiSourceId then
    pcall(function() Engine.Audio.deleteSource(state.guiSourceId) end)
    state.guiSourceId = nil
  end
end

local function stopEmitter(emitter)
  if emitter and emitter.stop then
    pcall(function() emitter:stop() end)
    pcall(function() emitter:stop(-1) end)
  end
end

local function simTimePaused()
  local st = extensions.simTimeAuthority
  if st and st.getPause then
    return st.getPause() == true
  end
  return false
end

local function resetPlaybackPauseTracking()
  state.playbackPauseAccumSec = 0
  state.playbackPauseWallStart = nil
end

local function syncPlaybackPauseWallClock()
  if not state.isPlaying or not state.playStartClock then
    resetPlaybackPauseTracking()
    return
  end
  if simTimePaused() then
    if not state.playbackPauseWallStart then
      state.playbackPauseWallStart = os.clock()
    end
  else
    if state.playbackPauseWallStart then
      state.playbackPauseAccumSec = (state.playbackPauseAccumSec or 0) + (os.clock() - state.playbackPauseWallStart)
      state.playbackPauseWallStart = nil
    end
  end
end

local function playbackPositionSec()
  if not state.playStartClock then
    return 0
  end
  local raw = os.clock() - state.playStartClock
  local pauseTotal = state.playbackPauseAccumSec or 0
  if state.playbackPauseWallStart then
    pauseTotal = pauseTotal + (os.clock() - state.playbackPauseWallStart)
  end
  local pos = raw - pauseTotal
  if pos < 0 then
    pos = 0
  end
  return pos
end

local function stop()
  stopGuiSource()
  stopEmitter(state.lastEmitter)
  state.lastEmitter = nil
  state.isPlaying = false
  state.playStartClock = nil
  resetPlaybackPauseTracking()
  state.uiWantsAutoAdvance = false
end

local function validateTrack(entry)
  if type(entry) ~= 'table' then
    return false
  end
  if type(entry.event) == 'string' and entry.event ~= '' then
    return true
  end
  if type(entry.filename) == 'string' and entry.filename ~= '' and type(entry.track) == 'string' and entry.track ~= '' then
    return true
  end
  if type(entry.file) == 'string' and entry.file ~= '' then
    return true
  end
  return false
end

local function applyTrackToEmitter(emitter, entry)
  if entry.event then
    pcall(function() emitter:setField('filename', 0, '') end)
    pcall(function() emitter:setField('track', 0, entry.event) end)
  elseif type(entry.file) == 'string' and entry.file ~= '' then
    pcall(function() emitter:setField('filename', 0, '') end)
    pcall(function() emitter:setField('track', 0, entry.file) end)
  else
    pcall(function() emitter:setField('filename', 0, entry.filename) end)
    pcall(function() emitter:setField('track', 0, entry.track) end)
    if entry.useTrackDescriptionOnly ~= nil then
      local v = entry.useTrackDescriptionOnly and '1' or '0'
      pcall(function() emitter:setField('useTrackDescriptionOnly', 0, v) end)
    end
  end
  local loopVal = entry.isLooping
  if loopVal == nil and type(entry.file) == 'string' and entry.file ~= '' then
    loopVal = false
  end
  if loopVal ~= nil then
    local v = loopVal and '1' or '0'
    pcall(function() emitter:setField('isLooping', 0, v) end)
  end
end

local function clamp01(x)
  local v = tonumber(x) or 0
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function applyMusicVolumeToActive()
  local v = clamp01(state.musicVolume)
  state.musicVolume = v
  if state.guiSourceId then
    local snd = scenetree.findObjectById(state.guiSourceId)
    if snd then
      pcall(function() snd:setVolume(v) end)
      pcall(function() snd:setVolumePitch(v, 1) end)
    end
  end
  local em = state.lastEmitter
  if em then
    pcall(function() em:setField('scale', 0, tostring(v)) end)
  end
end

local function loadMusicPrefs()
  local data = jsonReadFile(musicPrefsPath)
  if type(data) == 'table' and data.volume ~= nil then
    state.musicVolume = clamp01(data.volume)
  end
end

local function saveMusicPrefs()
  jsonWriteFile(musicPrefsPath, { volume = state.musicVolume }, true)
end

local function playEmitter(emitter, entry)
  stopEmitter(emitter)
  applyTrackToEmitter(emitter, entry)
  state.lastEmitter = emitter
  if emitter.play then
    local ok = pcall(function() emitter:play(-1) end)
    if not ok then
      pcall(function() emitter:play() end)
    end
  end
  applyMusicVolumeToActive()
end

local function playCreateSource(entry, channel)
  local ref = type(entry.event) == 'string' and entry.event ~= '' and entry.event or nil
  if not ref and type(entry.file) == 'string' and entry.file ~= '' then
    ref = entry.file
  end
  if not ref then
    return false
  end
  stopGuiSource()
  local ch = channel or 'AudioGui'
  local id = Engine.Audio.createSource(ch, ref)
  if not id then
    return false
  end
  state.guiSourceId = id
  local snd = scenetree.findObjectById(id)
  if snd and snd.play then
    pcall(function() snd:play(-1) end)
  end
  applyMusicVolumeToActive()
  return true
end

local function playOnce(entry, channel)
  local ref = type(entry.event) == 'string' and entry.event ~= '' and entry.event or nil
  if not ref and type(entry.file) == 'string' and entry.file ~= '' then
    ref = entry.file
  end
  if not ref then
    return false
  end
  local ch = channel or 'AudioGui'
  pcall(function() Engine.Audio.playOnce(ch, ref, {}) end)
  return true
end

local function normalizePlaylistData(data)
  if type(data) ~= 'table' then
    return nil
  end
  local tracks = data.tracks or data
  if type(tracks) ~= 'table' then
    return nil
  end
  local mode = data.mode
  if mode ~= 'random' and mode ~= 'sequential' then
    mode = 'sequential'
  end
  local out = {}
  for _, t in ipairs(tracks) do
    if validateTrack(t) then
      table.insert(out, t)
    end
  end
  if #out == 0 then
    return nil
  end
  return out, mode
end

local function loadPlaylistFromFile(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local data = jsonReadFile(path)
  local tracks, mode = normalizePlaylistData(data)
  if not tracks then
    return false
  end
  state.musicLibraryRoot = nil
  state.playlistsByName = nil
  state.activePlaylistName = nil
  state.tracks = tracks
  state.mode = mode or 'sequential'
  state.playlistPath = path
  state.index = math.min(math.max(1, state.index), #state.tracks)
  invalidateShuffleOrder()
  return true
end

local function normalizeMusicRoot(p)
  if type(p) ~= 'string' or p == '' then
    p = '/music'
  end
  p = p:gsub('\\', '/')
  if p:sub(-1) == '/' then
    p = p:sub(1, -2)
  end
  return p
end

local function playlistNameFromFile(musicRoot, filePath)
  local root = musicRoot:gsub('\\', '/'):gsub('/+$', '')
  local fp = filePath:gsub('\\', '/')
  if fp:sub(1, #root) ~= root then
    return nil
  end
  local rest = fp:sub(#root + 1)
  if rest:sub(1, 1) == '/' then
    rest = rest:sub(2)
  end
  return rest:match('^([^/]+)')
end

local function normalizeAudioVfsPath(p)
  if type(p) ~= 'string' then
    return ''
  end
  p = p:gsub('\\', '/')
  return p
end

local function fileExistsFirst(candidates)
  for _, p in ipairs(candidates) do
    if type(p) == 'string' and p ~= '' and FS:fileExists(p) then
      return p
    end
  end
  return nil
end

local function vfsPathTryList(p)
  if type(p) ~= 'string' or p == '' then
    return {}
  end
  local n = normalizeAudioVfsPath(p)
  local out = {}
  local function add(x)
    if x == '' then
      return
    end
    out[x] = true
  end
  add(p)
  add(n)
  if n ~= '' then
    if n:sub(1, 1) == '/' then
      add(n:sub(2))
    else
      add('/' .. n)
    end
  end
  local list = {}
  for s, _ in pairs(out) do
    table.insert(list, s)
  end
  return list
end

local function findFolderCover(folderPath)
  folderPath = normalizeAudioVfsPath(folderPath)
  if folderPath == '' then
    return ''
  end
  if folderPath:sub(-1) ~= '/' then
    folderPath = folderPath .. '/'
  end
  for _, name in ipairs({'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png', 'album.jpg', 'album.png'}) do
    local hit = fileExistsFirst(vfsPathTryList(folderPath .. name))
    if hit then
      return hit
    end
  end
  return ''
end

local function findSidecarCover(audioPath)
  if type(audioPath) ~= 'string' then
    return ''
  end
  local variants = {}
  local seen = {}
  for _, ap in ipairs(vfsPathTryList(audioPath)) do
    local base = ap:gsub('%.[^%.]+$', '')
    if not seen[base] then
      seen[base] = true
      table.insert(variants, base)
    end
  end
  for _, base in ipairs(variants) do
    for _, ext in ipairs({'.jpg', '.jpeg', '.png', '.webp'}) do
      local hit = fileExistsFirst(vfsPathTryList(base .. ext))
      if hit then
        return hit
      end
    end
  end
  return ''
end

local function readFileBinaryRange(vfsPath, offset0, maxLen)
  local off = tonumber(offset0) or 0
  maxLen = tonumber(maxLen) or 0
  if maxLen < 1 then
    return nil
  end
  local norm = normalizeAudioVfsPath(vfsPath)
  if norm == '' then
    return nil
  end
  local paths = vfsPathTryList(vfsPath)
  local function tryRangeOnPath(path)
    if type(path) ~= 'string' or path == '' then
      return nil
    end
    local f = io.open(path, 'rb')
    if not f then
      return nil
    end
    if off > 0 then
      f:seek('set', off)
    end
    local data = f:read(maxLen)
    f:close()
    return data
  end
  for _, try in ipairs(paths) do
    local data = tryRangeOnPath(try)
    if data then
      return data
    end
    local rp = FS:getFileRealPath(try)
    data = tryRangeOnPath(rp)
    if data then
      return data
    end
  end
  local sz = FS:fileSize(norm) or FS:fileSize(paths[#paths])
  if not sz or sz < 1 or off < 0 or off >= sz then
    return nil
  end
  if sz > 8388608 then
    return nil
  end
  for _, try in ipairs(paths) do
    local f = io.open(try, 'rb')
    if f then
      local whole = f:read(sz)
      f:close()
      if whole and #whole >= off + 1 then
        local e = math.min(off + maxLen, #whole)
        return whole:sub(off + 1, e)
      end
    end
    local rp = FS:getFileRealPath(try)
    if type(rp) == 'string' and rp ~= '' then
      local f = io.open(rp, 'rb')
      if f then
        local whole = f:read(sz)
        f:close()
        if whole and #whole >= off + 1 then
          local e = math.min(off + maxLen, #whole)
          return whole:sub(off + 1, e)
        end
      end
    end
  end
  return nil
end

local band = bit.band
local rshift = bit.rshift

local function readU32BE(s, idx)
  local a, b, c, d = string.byte(s, idx, idx + 3)
  if not d then
    return nil
  end
  return a * 16777216 + b * 65536 + c * 256 + d
end

local mp3L3BitrateMpeg1 = {
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0
}
local mp3L3BitrateMpeg2 = {
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0
}
local mp3SrMpeg1 = {44100, 48000, 32000}
local mp3SrMpeg2 = {22050, 24000, 16000}
local mp3SrMpeg25 = {11025, 12000, 8000}

local function id3v2LeadingBytes(vfsPath, fileSize)
  local sz = tonumber(fileSize) or 0
  local head = readFileBinaryRange(vfsPath, 0, 10)
  if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
    return 0
  end
  local a, b, c, d = string.byte(head, 7, 10)
  local tagLen = 10 + band(a, 127) * 2097152 + band(b, 127) * 16384 + band(c, 127) * 128 + band(d, 127)
  if tagLen < 10 or tagLen > sz then
    return 0
  end
  if tagLen > 32 * 1048576 then
    return 0
  end
  return tagLen
end

local function id3v2TlenDurationSec(vfsPath)
  local sz = FS:fileSize(vfsPath)
  if not sz then
    return 0
  end
  local head = readFileBinaryRange(vfsPath, 0, 10)
  if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
    return 0
  end
  local verMaj = string.byte(head, 4)
  if verMaj ~= 3 and verMaj ~= 4 then
    return 0
  end
  local tagLen = id3v2LeadingBytes(vfsPath, sz)
  if tagLen <= 10 then
    return 0
  end
  local bodyBytes = tagLen - 10
  local body = readFileBinaryRange(vfsPath, 10, math.min(bodyBytes, 262144))
  if not body or #body < 11 then
    return 0
  end
  local i = 1
  while i <= #body - 10 do
    local id = body:sub(i, i + 3)
    if id == '\0\0\0\0' then
      break
    end
    local a, b, c, d = string.byte(body, i + 4, i + 7)
    if not d then
      break
    end
    local frSz
    if verMaj == 4 then
      frSz = band(a, 127) * 2097152 + band(b, 127) * 16384 + band(c, 127) * 128 + band(d, 127)
    else
      frSz = a * 16777216 + b * 65536 + c * 256 + d
    end
    if frSz < 1 or frSz > bodyBytes * 2 or i + 10 + frSz - 1 > #body then
      break
    end
    if id == 'TLEN' then
      local raw = body:sub(i + 10, i + 9 + frSz)
      local ms = tonumber(raw:match('%d+'))
      if ms and ms > 0 then
        return ms / 1000
      end
    end
    i = i + 10 + frSz
  end
  return 0
end

local mp3CoverCacheDir = 'settings/musicPlayerCovers/'

local function imageExtFromMagic(img)
  if #img >= 3 and img:byte(1) == 255 and img:byte(2) == 216 and img:byte(3) == 255 then
    return 'jpg'
  end
  if #img >= 8 and img:sub(1, 8) == '\137PNG\r\n\26\n' then
    return 'png'
  end
  if #img >= 12 and img:sub(1, 4) == 'RIFF' and img:sub(9, 12) == 'WEBP' then
    return 'webp'
  end
  return 'jpg'
end

local function deunsyncBytes(data)
  if type(data) ~= 'string' or data == '' then
    return data
  end
  return (data:gsub('\255\0', '\255'))
end

local function parseApicFramePayload(payload)
  if not payload or #payload < 20 then
    return nil, nil, nil
  end
  local enc = string.byte(payload, 1)
  local pos = 2
  local z = payload:find('\0', pos, true)
  if not z then
    return nil, nil, nil
  end
  local mime = payload:sub(pos, z - 1):lower()
  pos = z + 1
  if pos > #payload then
    return nil, nil, nil
  end
  local picType = string.byte(payload, pos)
  pos = pos + 1
  if pos > #payload then
    return nil, nil, nil
  end
  if enc == 0 or enc == 3 then
    z = payload:find('\0', pos, true)
    if not z then
      return nil, nil, nil
    end
    pos = z + 1
  elseif enc == 1 or enc == 2 then
    z = pos
    local okSeek = false
    while z <= #payload - 1 do
      if payload:byte(z) == 0 and payload:byte(z + 1) == 0 then
        pos = z + 2
        okSeek = true
        break
      end
      z = z + 1
    end
    if not okSeek then
      return nil, nil, nil
    end
  else
    return nil, nil, nil
  end
  local img = payload:sub(pos)
  if #img < 32 then
    return nil, nil, nil
  end
  if mime == '-->' then
    return nil, nil, nil
  end
  local ext = 'jpg'
  if mime:find('png', 1, true) then
    ext = 'png'
  elseif mime:find('webp', 1, true) then
    ext = 'webp'
  elseif mime == '' then
    ext = imageExtFromMagic(img)
  end
  return img, ext, picType
end

local function parsePicFrameV22Payload(payload)
  if not payload or #payload < 20 then
    return nil, nil, nil
  end
  local enc = string.byte(payload, 1)
  local fmt = payload:sub(2, 4):lower()
  local picType = string.byte(payload, 5)
  local pos = 6
  local z
  if enc == 0 or enc == 3 then
    z = payload:find('\0', pos, true)
    if not z then
      return nil, nil, nil
    end
    pos = z + 1
  elseif enc == 1 or enc == 2 then
    z = pos
    local okSeek = false
    while z <= #payload - 1 do
      if payload:byte(z) == 0 and payload:byte(z + 1) == 0 then
        pos = z + 2
        okSeek = true
        break
      end
      z = z + 1
    end
    if not okSeek then
      return nil, nil, nil
    end
  else
    return nil, nil, nil
  end
  local img = payload:sub(pos)
  if #img < 32 then
    return nil, nil, nil
  end
  local ext = 'jpg'
  if fmt == 'png' then
    ext = 'png'
  elseif fmt == 'jpg' then
    ext = 'jpg'
  else
    ext = imageExtFromMagic(img)
  end
  return img, ext, picType
end

local function hashPathForCoverCache(vfsPath)
  local ok, h = pcall(function()
    return FS:hashFileSHA1(vfsPath)
  end)
  if ok and type(h) == 'string' and h ~= '' then
    return h:gsub('[^%w%._%-]', '_')
  end
  ok, h = pcall(function()
    return FS:hashFile(vfsPath)
  end)
  if ok and type(h) == 'string' and h ~= '' then
    return h:gsub('[^%w%._%-]', '_')
  end
  return tostring(#vfsPath) .. '_' .. vfsPath:gsub('[^%w%._%-]', '_')
end

local function writeBinaryFile(paths, bytes)
  if type(bytes) ~= 'string' or bytes == '' then
    return false
  end
  local candidates = type(paths) == 'table' and paths or { paths }
  for _, p in ipairs(candidates) do
    if type(p) == 'string' and p ~= '' then
      local f = io.open(p, 'wb')
      if f then
        f:write(bytes)
        f:close()
        return true
      end
    end
  end
  return false
end

local function joinPath(a, b)
  a = type(a) == 'string' and a or ''
  b = type(b) == 'string' and b or ''
  if a == '' then
    return b
  end
  if b == '' then
    return a
  end
  a = a:gsub('\\', '/')
  b = b:gsub('\\', '/')
  if a:sub(-1) ~= '/' then
    a = a .. '/'
  end
  return a .. b:gsub('^/+', '')
end

local function cacheEmbeddedCoverToSettings(audioVfsPath, img, ext)
  if not FS:directoryExists('settings') then
    FS:directoryCreate('settings')
  end
  if not FS:directoryExists(mp3CoverCacheDir) then
    FS:directoryCreate(mp3CoverCacheDir)
  end
  local base = hashPathForCoverCache(audioVfsPath)
  local rel = mp3CoverCacheDir .. base .. '.' .. ext
  if FS:fileExists(rel) then
    return rel
  end
  local userPath = FS:getUserPath() or ''
  local rp = userPath ~= '' and joinPath(userPath, rel) or FS:getFileRealPath(rel)
  if writeBinaryFile({ rel, rp }, img) then
    return rel
  end
  return nil
end

local function extractEmbeddedMp3CoverVfsPath(vfsPath)
  local norm = normalizeAudioVfsPath(vfsPath)
  if norm:lower():sub(-4) ~= '.mp3' then
    return nil
  end
  local sz = FS:fileSize(norm)
  if not sz or sz < 32 then
    return nil
  end
  local head = readFileBinaryRange(norm, 0, 10)
  if not head or #head < 10 or head:sub(1, 3) ~= 'ID3' then
    return nil
  end
  local verMaj = string.byte(head, 4)
  if verMaj ~= 2 and verMaj ~= 3 and verMaj ~= 4 then
    return nil
  end
  local hdrFlags = string.byte(head, 6) or 0
  local tagLen = id3v2LeadingBytes(norm, sz)
  if tagLen <= 10 then
    return nil
  end
  local bodyBytes = tagLen - 10
  local maxRead = math.min(bodyBytes, 8 * 1048576)
  local body = readFileBinaryRange(norm, 10, maxRead)
  if not body or #body < 20 then
    return nil
  end
  if band(hdrFlags, 128) ~= 0 then
    body = deunsyncBytes(body)
  end
  local i = 1
  local bestImg, bestExt, bestPri = nil, nil, 999
  while i <= #body - 6 do
    local id
    local frSz
    local headerLen
    if verMaj == 2 then
      id = body:sub(i, i + 2)
      if id == '\0\0\0' then
        break
      end
      local a, b, c = string.byte(body, i + 3, i + 5)
      if not c then
        break
      end
      frSz = a * 65536 + b * 256 + c
      headerLen = 6
    else
      id = body:sub(i, i + 3)
      if id == '\0\0\0\0' then
        break
      end
      local a, b, c, d = string.byte(body, i + 4, i + 7)
      if not d then
        break
      end
      if verMaj == 4 then
        frSz = band(a, 127) * 2097152 + band(b, 127) * 16384 + band(c, 127) * 128 + band(d, 127)
      else
        frSz = a * 16777216 + b * 65536 + c * 256 + d
      end
      headerLen = 10
    end
    if frSz < 1 or frSz > bodyBytes * 2 then
      break
    end
    if i + headerLen + frSz - 1 > #body then
      break
    end
    if id == 'APIC' or (verMaj == 2 and id == 'PIC') then
      local payload = body:sub(i + headerLen, i + headerLen + frSz - 1)
      local img, ext, picType
      if verMaj == 2 then
        img, ext, picType = parsePicFrameV22Payload(payload)
      else
        img, ext, picType = parseApicFramePayload(payload)
      end
      if img and ext then
        local pri = (picType == 3) and 0 or 1
        if pri < bestPri then
          bestPri = pri
          bestImg = img
          bestExt = ext
        end
      end
    end
    i = i + headerLen + frSz
  end
  if bestImg and bestExt then
    return cacheEmbeddedCoverToSettings(norm, bestImg, bestExt)
  end
  return nil
end

local function parseMp3L3FrameHeader(data, i)
  local b1, b2, b3, b4 = string.byte(data, i, i + 3)
  if not b4 or b1 ~= 0xFF or band(b2, 0xE0) ~= 0xE0 or band(b2, 0x06) == 0 then
    return nil
  end
  local verId = band(rshift(b2, 3), 3)
  local layerId = band(rshift(b2, 1), 3)
  if layerId ~= 1 then
    return nil
  end
  local sampleRates
  local bitrates
  local samplesPerFrame
  local scale
  local mpeg
  if verId == 3 then
    mpeg = '1'
    sampleRates = mp3SrMpeg1
    bitrates = mp3L3BitrateMpeg1
    samplesPerFrame = 1152
    scale = 144
  elseif verId == 2 then
    mpeg = '2'
    sampleRates = mp3SrMpeg2
    bitrates = mp3L3BitrateMpeg2
    samplesPerFrame = 576
    scale = 72
  elseif verId == 0 then
    mpeg = '25'
    sampleRates = mp3SrMpeg25
    bitrates = mp3L3BitrateMpeg2
    samplesPerFrame = 576
    scale = 72
  else
    return nil
  end
  local brIdx = band(rshift(b3, 4), 15)
  local srIdx = band(rshift(b3, 2), 3)
  local padding = band(rshift(b3, 1), 1)
  if brIdx == 0 or brIdx == 15 or srIdx == 3 then
    return nil
  end
  local bitrateKbps = bitrates[brIdx + 1]
  if not bitrateKbps or bitrateKbps <= 0 then
    return nil
  end
  local sampleRate = sampleRates[srIdx + 1]
  if not sampleRate or sampleRate <= 0 then
    return nil
  end
  local frameLen = math.floor(scale * bitrateKbps * 1000 / sampleRate + padding)
  if frameLen < 24 then
    return nil
  end
  local mode = band(rshift(b4, 6), 3)
  local sideInfo = (mpeg == '1') and ((mode == 3) and 17 or 32) or ((mode == 3) and 9 or 17)
  return {
    frameLen = frameLen,
    bitrateKbps = bitrateKbps,
    sampleRate = sampleRate,
    samplesPerFrame = samplesPerFrame,
    sideInfo = sideInfo
  }
end

local function mp3DurationSecFromFile(vfsPath)
  local fileSize = FS:fileSize(vfsPath)
  if not fileSize or fileSize < 1 then
    return 0
  end
  local tlenSec = id3v2TlenDurationSec(vfsPath)
  if tlenSec > 0 then
    return tlenSec
  end
  if fileSize < 64 then
    return 0
  end
  local id3 = id3v2LeadingBytes(vfsPath, fileSize)
  local readLen = math.min(524288, fileSize - id3)
  if readLen < 64 then
    return 0
  end
  local data = readFileBinaryRange(vfsPath, id3, readLen)
  if not data or #data < 64 then
    return 0
  end
  local lim = #data - 4
  local hdr
  local fi = 1
  for try = 1, lim do
    local b1, b2 = string.byte(data, try, try + 1)
    if b1 == 0xFF and b2 and band(b2, 0xE0) == 0xE0 and band(b2, 0x06) ~= 0 then
      local h = parseMp3L3FrameHeader(data, try)
      if h then
        local ni = try + h.frameLen
        if ni <= lim then
          local nb1, nb2 = string.byte(data, ni, ni + 1)
          if nb1 == 0xFF and nb2 and band(nb2, 0xE0) == 0xE0 then
            hdr = h
            fi = try
            break
          end
        end
      end
    end
  end
  if not hdr then
    fi = 1
    for try = 1, lim do
      local b1, b2 = string.byte(data, try, try + 1)
      if b1 == 0xFF and b2 and band(b2, 0xE0) == 0xE0 and band(b2, 0x06) ~= 0 then
        local h = parseMp3L3FrameHeader(data, try)
        if h then
          hdr = h
          fi = try
          break
        end
      end
    end
  end
  if not hdr then
    return 0
  end
  local xi = fi + 4 + hdr.sideInfo
  if xi + 11 <= #data then
    local tag = data:sub(xi, xi + 3)
    if tag == 'Xing' or tag == 'Info' then
      local flags = readU32BE(data, xi + 4) or 0
      if band(flags, 1) ~= 0 and xi + 12 <= #data then
        local fn = readU32BE(data, xi + 8)
        if fn and fn > 0 then
          return fn * hdr.samplesPerFrame / hdr.sampleRate
        end
      end
    end
  end
  local vend = math.min(fi + hdr.frameLen + 32, #data - 17)
  local vscan = fi + 1
  while vscan <= vend do
    local hit = data:find('VBRI', vscan, true)
    if not hit then
      break
    end
    if hit + 17 <= #data then
      local fn = readU32BE(data, hit + 14)
      if fn and fn > 0 then
        return fn * hdr.samplesPerFrame / hdr.sampleRate
      end
    end
    vscan = hit + 4
  end
  local id3v1 = 0
  if fileSize >= 128 then
    local tail = readFileBinaryRange(vfsPath, fileSize - 128, 128)
    if tail and #tail >= 3 and tail:sub(1, 3) == 'TAG' then
      id3v1 = 128
    end
  end
  local audioBytes = fileSize - id3 - id3v1
  if audioBytes <= 0 or hdr.bitrateKbps <= 0 then
    return 0
  end
  return audioBytes * 8 / (hdr.bitrateKbps * 1000)
end
local function wavDurationSecFromFile(vfsPath)
  local sz = FS:fileSize(vfsPath)
  if not sz or sz < 44 then
    return 0
  end
  local data = readFileBinaryRange(vfsPath, 0, math.min(65536, sz))
  if not data or #data < 44 or data:sub(1, 4) ~= 'RIFF' or data:sub(9, 12) ~= 'WAVE' then
    return 0
  end
  local i = 13
  local byteRate = nil
  while i <= #data - 8 do
    local id = data:sub(i, i + 3)
    local cs = string.byte(data, i + 4) + string.byte(data, i + 5) * 256 + string.byte(data, i + 6) * 65536 + string.byte(data, i + 7) * 16777216
    if id == 'fmt ' and cs >= 16 and i + 8 + cs <= #data then
      local ch = string.byte(data, i + 11) + string.byte(data, i + 10) * 256
      local sr = string.byte(data, i + 15) + string.byte(data, i + 14) * 256 + string.byte(data, i + 13) * 65536 + string.byte(data, i + 12) * 16777216
      local bitsPer = string.byte(data, i + 17) + string.byte(data, i + 16) * 256
      if sr > 0 and ch > 0 and bitsPer > 0 then
        byteRate = sr * ch * (bitsPer / 8)
      end
    elseif id == 'data' and byteRate and byteRate > 0 then
      return cs / byteRate
    end
    i = i + 8 + cs + (cs % 2)
  end
  return 0
end

local durationProbeCache = {}

local function durationSecFromFmodPlayOnce(vfsPath)
  if type(vfsPath) ~= 'string' or vfsPath == '' then
    return 0
  end
  local key = normalizeAudioVfsPath(vfsPath)
  if key == '' then
    return 0
  end
  local cached = durationProbeCache[key]
  if cached then
    return cached
  end
  if key:sub(1, 6) == 'event:' then
    return 0
  end
  local tryPlay = FS:fileExists(key) and key or vfsPath
  if not FS:fileExists(tryPlay) then
    return 0
  end
  local res = Engine.Audio.playOnce('AudioGui', tryPlay, { volume = 0, pitch = 1 })
  if type(res) == 'table' then
    local len = tonumber(res.len) or 0
    if len > 0 then
      durationProbeCache[key] = len
      return len
    end
  end
  return 0
end

local function estimateTrackDurationSec(vfsPath)
  if type(vfsPath) ~= 'string' then
    return 0
  end
  local norm = normalizeAudioVfsPath(vfsPath)
  local lower = norm:lower()
  if lower:sub(-4) == '.mp3' then
    local d = mp3DurationSecFromFile(norm)
    if d > 0 then
      return d
    end
    return durationSecFromFmodPlayOnce(norm)
  end
  if lower:sub(-4) == '.wav' then
    return wavDurationSecFromFile(norm)
  end
  return 0
end

local function coverPathToUiUrl(vfsPath)
  if type(vfsPath) ~= 'string' or vfsPath == '' then
    return ''
  end
  local p = normalizeAudioVfsPath(vfsPath):gsub('^/+', '')
  if p == '' then
    return ''
  end
  return 'local://local/' .. p
end

local function scanMusicLibrary(root, allowSkipIfUnchanged)
  root = normalizeMusicRoot(root)
  if allowSkipIfUnchanged and state.musicLibraryRoot == root and type(state.playlistsByName) == 'table' and
      next(state.playlistsByName) ~= nil and (state.playlistPath == nil or state.playlistPath == '') then
    return true
  end
  stop()
  state.musicLibraryRoot = root
  state.playlistPath = nil
  state.playlistsByName = {}
  local rootDir = root .. '/'
  if not FS:directoryExists(root) then
    log('W', 'musicPlayer', 'Music folder not found: ' .. root)
    state.tracks = {}
    state.activePlaylistName = nil
    invalidateShuffleOrder()
    return false
  end
  local audioGlob = '*.mp3\t*.ogg\t*.wav\t*.flac'
  local files = FS:findFiles(rootDir, audioGlob, -1, true, true)
  if type(files) ~= 'table' then
    return false
  end
  for _, fp in ipairs(files) do
    if type(fp) == 'string' then
      local plName = playlistNameFromFile(root, fp)
      if plName and plName ~= '' then
        state.playlistsByName[plName] = state.playlistsByName[plName] or {}
        local base = fp:match('([^/]+)%.[^%.]+$')
        if not base then
          base = fp:match('([^/]+)$')
        end
        local folder = root .. '/' .. plName
        local sideCover = findSidecarCover(fp)
        local folderCov = findFolderCover(folder)
        local coverPath = (sideCover ~= '' and sideCover) or (folderCov ~= '' and folderCov) or nil
        if not coverPath and fp:lower():sub(-4) == '.mp3' then
          coverPath = extractEmbeddedMp3CoverVfsPath(fp)
        end
        local dur = estimateTrackDurationSec(fp)
        table.insert(state.playlistsByName[plName], {
          file = fp,
          title = base or 'Track',
          playlist = plName,
          cover = coverPath,
          durationSec = dur > 0 and dur or 0,
          isLooping = false
        })
      end
    end
  end
  for plName, tracks in pairs(state.playlistsByName) do
    table.sort(tracks, function(a, b)
      return tostring(a.file or '') < tostring(b.file or '')
    end)
  end
  local names = {}
  for n, _ in pairs(state.playlistsByName) do
    table.insert(names, n)
  end
  table.sort(names)
  if #names == 0 then
    log('I', 'musicPlayer', 'No audio files under subfolders of ' .. root)
    state.tracks = {}
    state.activePlaylistName = nil
    invalidateShuffleOrder()
    return false
  end
  local prev = state.activePlaylistName
  local found = false
  if prev then
    for _, n in ipairs(names) do
      if n == prev then
        found = true
        break
      end
    end
  end
  if not found then
    state.activePlaylistName = names[1]
  end
  state.tracks = deepCopy(state.playlistsByName[state.activePlaylistName])
  state.mode = DEFAULT_PLAY_MODE
  state.index = 1
  if #state.tracks == 0 then
    state.index = 1
  end
  invalidateShuffleOrder()
  return true
end

local function ensurePlaylist()
  if #state.tracks > 0 then
    return
  end
  state.tracks = deepCopy(defaultTracks)
  state.mode = DEFAULT_PLAY_MODE
  state.index = 1
end

local function buildShuffleOrder()
  local n = #state.tracks
  if n < 1 then
    state.shuffleOrder = nil
    state.shuffleCursor = nil
    return
  end
  if n == 1 then
    state.shuffleOrder = {1}
    state.shuffleCursor = 1
    return
  end
  local order = {}
  for i = 1, n do
    order[i] = i
  end
  for i = n, 2, -1 do
    local j = math.random(1, i)
    order[i], order[j] = order[j], order[i]
  end
  state.shuffleOrder = order
end

local function findShuffleCursorForIndex(originalIndex)
  if not state.shuffleOrder then
    return 1
  end
  for i = 1, #state.shuffleOrder do
    if state.shuffleOrder[i] == originalIndex then
      return i
    end
  end
  return 1
end

local function ensureShuffleOrder()
  if state.mode ~= 'random' then
    return
  end
  local n = #state.tracks
  if n < 1 then
    state.shuffleOrder = nil
    state.shuffleCursor = nil
    return
  end
  if state.shuffleOrder and #state.shuffleOrder == n then
    return
  end
  buildShuffleOrder()
  state.shuffleCursor = findShuffleCursorForIndex(state.index)
  if state.shuffleCursor < 1 or state.shuffleCursor > n then
    state.shuffleCursor = 1
  end
  state.index = state.shuffleOrder[state.shuffleCursor]
end

local function syncIndexFromShuffleCursor()
  if state.mode ~= 'random' or not state.shuffleOrder then
    return
  end
  local n = #state.shuffleOrder
  if n < 1 then
    return
  end
  local c = state.shuffleCursor
  if not c or c < 1 or c > n then
    c = findShuffleCursorForIndex(state.index)
  end
  if c < 1 then
    c = 1
  end
  if c > n then
    c = n
  end
  state.shuffleCursor = c
  state.index = state.shuffleOrder[c]
end

local function pickIndexForPlay()
  ensurePlaylist()
  local n = #state.tracks
  if n < 1 then
    return 0
  end
  if state.mode == 'random' then
    ensureShuffleOrder()
    if not state.shuffleOrder or #state.shuffleOrder < 1 then
      return 1
    end
    local c = state.shuffleCursor or 1
    if c < 1 or c > #state.shuffleOrder then
      c = 1
      state.shuffleCursor = 1
    end
    return state.shuffleOrder[c]
  end
  return state.index
end

local function advanceSequential()
  if state.mode ~= 'sequential' then
    return
  end
  state.index = state.index + 1
  if state.index > #state.tracks then
    state.index = 1
  end
end

local function getEntryAt(i)
  ensurePlaylist()
  if i < 1 or i > #state.tracks then
    return nil
  end
  return state.tracks[i]
end

local function maybeAdvanceAfterPlay(options)
  if options.trackIndex then
    return
  end
  if state.mode == 'sequential' and options.advance ~= false then
    advanceSequential()
  end
end

local function loadPlaylist(path)
  if loadPlaylistFromFile(path) then
    return true
  end
  state.tracks = deepCopy(defaultTracks)
  state.mode = DEFAULT_PLAY_MODE
  state.index = 1
  state.playlistPath = nil
  state.musicLibraryRoot = nil
  state.playlistsByName = nil
  state.activePlaylistName = nil
  invalidateShuffleOrder()
  return false
end

local function loadMusicLibrary(root, preferredPlaylist, allowSkipRescan)
  if not scanMusicLibrary(root, allowSkipRescan == true) then
    return false
  end
  if type(preferredPlaylist) == 'string' and preferredPlaylist ~= '' and state.playlistsByName[preferredPlaylist] then
    state.activePlaylistName = preferredPlaylist
    state.tracks = deepCopy(state.playlistsByName[preferredPlaylist])
    state.index = 1
    invalidateShuffleOrder()
  end
  return true
end

local function getPlaylistNames()
  if type(state.playlistsByName) ~= 'table' then
    return {}
  end
  local names = {}
  for n, _ in pairs(state.playlistsByName) do
    table.insert(names, n)
  end
  table.sort(names)
  return names
end

local function getTracks()
  ensurePlaylist()
  return state.tracks
end

local function getTrackCount()
  ensurePlaylist()
  return #state.tracks
end

local function setTrackIndex(i)
  ensurePlaylist()
  local n = math.floor(tonumber(i) or 0)
  if n < 1 or n > #state.tracks then
    return false
  end
  state.index = n
  if state.mode == 'random' then
    ensureShuffleOrder()
    state.shuffleCursor = findShuffleCursorForIndex(n)
  end
  return true
end

local function getTrackIndex()
  ensurePlaylist()
  return state.index
end

local function getCurrentTrack()
  ensurePlaylist()
  return state.tracks[state.index]
end

local function getPlaylistPath()
  return state.playlistPath
end

local function trackDisplayTitle(entry, index)
  if type(entry) ~= 'table' then
    return ''
  end
  return tostring(entry.title or entry.name or ('Track ' .. tostring(index or 0)))
end

local function resolveEntryAudioPath(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  if type(entry.file) == 'string' and entry.file ~= '' then
    return normalizeAudioVfsPath(entry.file)
  end
  if type(entry.track) == 'string' and entry.track ~= '' then
    local tr = entry.track:gsub('\\', '/')
    if tr:sub(1, 1) == '/' or tr:match('^%a:') then
      return normalizeAudioVfsPath(tr)
    end
    if type(entry.filename) == 'string' and entry.filename ~= '' then
      local fn = entry.filename:gsub('\\', '/')
      if fn:sub(-1) == '/' then
        return normalizeAudioVfsPath(fn .. tr)
      end
      return normalizeAudioVfsPath(fn .. '/' .. tr)
    end
    return normalizeAudioVfsPath(tr)
  end
  return nil
end

local function entryDurationSec(entry)
  if type(entry) ~= 'table' then
    return 0
  end
  local d = tonumber(entry.durationSec) or tonumber(entry.duration) or 0
  if d > 0 then
    return d
  end
  local path = resolveEntryAudioPath(entry)
  if path then
    d = estimateTrackDurationSec(path)
    if d > 0 then
      return d
    end
  end
  return 0
end

local function getAllPlaylistSongNames()
  ensurePlaylist()
  local out = {}
  if type(state.playlistsByName) == 'table' then
    for _, plName in ipairs(getPlaylistNames()) do
      local tracks = state.playlistsByName[plName]
      local names = {}
      if type(tracks) == 'table' then
        for i, t in ipairs(tracks) do
          table.insert(names, trackDisplayTitle(t, i))
        end
      end
      out[plName] = names
    end
    return out
  end
  local names = {}
  for i, t in ipairs(state.tracks) do
    table.insert(names, trackDisplayTitle(t, i))
  end
  out.default = names
  return out
end

local function getSongDurationSec(playlistName, songTitle)
  ensurePlaylist()
  if type(songTitle) ~= 'string' or songTitle == '' then
    return 0
  end
  local pl = type(playlistName) == 'string' and playlistName ~= '' and playlistName or nil
  local function findDuration(tracks)
    if type(tracks) ~= 'table' then
      return 0
    end
    for i, t in ipairs(tracks) do
      if trackDisplayTitle(t, i) == songTitle then
        return entryDurationSec(t)
      end
    end
    return 0
  end
  if type(state.playlistsByName) == 'table' then
    if not pl then
      return 0
    end
    return findDuration(state.playlistsByName[pl])
  end
  if pl and pl ~= 'default' then
    return 0
  end
  return findDuration(state.tracks)
end

local function getCurrentSongLengthSec()
  ensurePlaylist()
  local t = state.tracks[state.index]
  if not t then
    return 0
  end
  return entryDurationSec(t)
end

local function play(options)
  options = type(options) == 'table' and options or {}
  if options.trackIndex then
    setTrackIndex(options.trackIndex)
  else
    state.index = pickIndexForPlay()
  end
  local entry = getEntryAt(state.index)
  if not entry then
    return false
  end

  local emitter = resolveEmitter(options.emitter, options.emitterName)
  if emitter then
    stopGuiSource()
    playEmitter(emitter, entry)
    maybeAdvanceAfterPlay(options)
    return true
  end

  local output = options.output
  stopEmitter(state.lastEmitter)
  state.lastEmitter = nil

  if output == 'playOnce' then
    local ok = playOnce(entry, options.channel)
    if ok then
      maybeAdvanceAfterPlay(options)
    end
    return ok
  end

  local ok = playCreateSource(entry, options.channel)
  if ok then
    maybeAdvanceAfterPlay(options)
  end
  return ok
end

local function onExtensionUnloaded()
  stop()
end

local function uiSetOutput(emitterName, useGui, channel)
  if type(emitterName) == 'string' and emitterName ~= '' then
    state.uiEmitterName = emitterName
    state.uiUseGui = false
  else
    state.uiEmitterName = nil
    state.uiUseGui = useGui ~= false
  end
  if channel ~= nil and type(channel) == 'string' and channel ~= '' then
    state.uiChannel = channel
  end
end

local function getUiState()
  syncPlaybackPauseWallClock()
  ensurePlaylist()
  local tracksOut = {}
  for i, t in ipairs(state.tracks) do
    local c = t.cover or t.coverUrl or t.albumArt
    table.insert(tracksOut, {
      title = t.title or t.name or ('Track ' .. tostring(i)),
      durationSec = tonumber(t.durationSec) or tonumber(t.duration) or 0,
      cover = type(c) == 'string' and c ~= '' and coverPathToUiUrl(c) or ''
    })
  end
  local cur = state.tracks[state.index]
  local currentTitle = ''
  local currentCover = ''
  if cur then
    currentTitle = tostring(cur.title or cur.name or '')
    local c = cur.cover or cur.coverUrl or cur.albumArt
    if type(c) == 'string' and c ~= '' then
      currentCover = coverPathToUiUrl(c)
    end
  end
  local pos = 0
  local dur = state.playDurationSec or 0
  if state.isPlaying and state.playStartClock and dur > 0 then
    pos = playbackPositionSec()
    if pos > dur then
      pos = dur
    end
  end
  return {
    tracks = tracksOut,
    index = state.index,
    count = #state.tracks,
    isPlaying = state.isPlaying,
    positionSec = pos,
    durationSec = dur,
    currentTitle = currentTitle,
    currentCover = currentCover,
    playlistNames = getPlaylistNames(),
    activePlaylist = state.activePlaylistName or '',
    shuffle = state.mode == 'random',
    repeatMode = state.repeatMode or 'all',
    musicVolume = clamp01(state.musicVolume)
  }
end

local function uiPlay()
  ensurePlaylist()
  if state.mode == 'random' then
    ensureShuffleOrder()
    syncIndexFromShuffleCursor()
  end
  local trackIndex = state.index
  if trackIndex < 1 then
    return false
  end
  local entry = getEntryAt(trackIndex)
  if not entry then
    return false
  end
  state.index = trackIndex
  local opts = { trackIndex = trackIndex, advance = false }
  if state.uiEmitterName then
    opts.emitterName = state.uiEmitterName
  elseif state.uiUseGui then
    opts.channel = state.uiChannel
  else
    return false
  end
  local dur = entryDurationSec(entry)
  local ok = play(opts)
  if ok then
    state.isPlaying = true
    state.playStartClock = os.clock()
    state.playDurationSec = dur
    resetPlaybackPauseTracking()
    if simTimePaused() then
      state.playbackPauseWallStart = os.clock()
    end
    state.uiWantsAutoAdvance = true
  end
  return ok
end

local function setActivePlaylist(name)
  if type(state.playlistsByName) ~= 'table' then
    return false
  end
  if type(name) ~= 'string' or name == '' then
    return false
  end
  local tracks = state.playlistsByName[name]
  if type(tracks) ~= 'table' or #tracks < 1 then
    return false
  end
  local wasPlaying = state.isPlaying
  stop()
  state.activePlaylistName = name
  state.tracks = deepCopy(tracks)
  state.index = 1
  invalidateShuffleOrder()
  if wasPlaying then
    uiPlay()
  end
  return true
end

local function uiStop()
  stop()
end

local function uiNext()
  ensurePlaylist()
  if #state.tracks < 1 then
    return false
  end
  stop()
  if state.mode == 'random' then
    ensureShuffleOrder()
    local n = #(state.shuffleOrder or {})
    if n < 1 then
      return false
    end
    local c = (state.shuffleCursor or 1) + 1
    if c > n then
      c = 1
    end
    state.shuffleCursor = c
    state.index = state.shuffleOrder[c]
  else
    state.index = state.index + 1
    if state.index > #state.tracks then
      state.index = 1
    end
  end
  return uiPlay()
end

local function uiPrevious()
  ensurePlaylist()
  if #state.tracks < 1 then
    return false
  end
  stop()
  if state.mode == 'random' then
    ensureShuffleOrder()
    local n = #(state.shuffleOrder or {})
    if n < 1 then
      return false
    end
    local c = (state.shuffleCursor or 1) - 1
    if c < 1 then
      c = n
    end
    state.shuffleCursor = c
    state.index = state.shuffleOrder[c]
  else
    state.index = state.index - 1
    if state.index < 1 then
      state.index = #state.tracks
    end
  end
  return uiPlay()
end

local function uiToggleShuffle()
  if state.mode == 'random' then
    state.mode = 'sequential'
    invalidateShuffleOrder()
  else
    state.mode = 'random'
    invalidateShuffleOrder()
    ensureShuffleOrder()
  end
end

local function uiToggleRepeat()
  if state.repeatMode == 'all' then
    state.repeatMode = 'one'
  elseif state.repeatMode == 'one' then
    state.repeatMode = 'off'
  else
    state.repeatMode = 'all'
  end
end

local function uiSetVolume(v)
  state.musicVolume = clamp01(v)
  saveMusicPrefs()
  applyMusicVolumeToActive()
end

local function tickPlaybackAutoAdvance(dt)
  if not state.isPlaying or not state.uiWantsAutoAdvance then
    return
  end
  local dur = tonumber(state.playDurationSec) or 0
  if dur <= 0 then
    return
  end
  if not state.playStartClock then
    return
  end
  if playbackPositionSec() < dur - 0.08 then
    return
  end
  state.isPlaying = false
  stopGuiSource()
  stopEmitter(state.lastEmitter)
  state.lastEmitter = nil
  state.playStartClock = nil
  resetPlaybackPauseTracking()
  if #state.tracks < 1 then
    return
  end
  if state.repeatMode == 'one' then
    local repeatIndex = state.index
    if repeatIndex < 1 or repeatIndex > #state.tracks then
      repeatIndex = 1
    end
    local entry = getEntryAt(repeatIndex)
    if not entry then
      state.uiWantsAutoAdvance = false
      return
    end
    local opts = { trackIndex = repeatIndex, advance = false }
    if state.uiEmitterName then
      opts.emitterName = state.uiEmitterName
    elseif state.uiUseGui then
      opts.channel = state.uiChannel
    else
      state.uiWantsAutoAdvance = false
      return
    end
    local dur = entryDurationSec(entry)
    local ok = play(opts)
    if ok then
      state.isPlaying = true
      state.playStartClock = os.clock()
      state.playDurationSec = dur
      resetPlaybackPauseTracking()
      if simTimePaused() then
        state.playbackPauseWallStart = os.clock()
      end
      state.uiWantsAutoAdvance = true
      return
    end
    if not ok then
      state.uiWantsAutoAdvance = false
    end
    return
  end
  if state.mode == 'random' then
    ensureShuffleOrder()
    local n = #(state.shuffleOrder or {})
    if n < 1 then
      state.uiWantsAutoAdvance = false
      return
    end
    local c = (state.shuffleCursor or 1) + 1
    if c > n then
      if state.repeatMode == 'off' then
        state.shuffleCursor = n
        state.index = state.shuffleOrder[n]
        state.uiWantsAutoAdvance = false
        return
      end
      c = 1
    end
    state.shuffleCursor = c
    state.index = state.shuffleOrder[c]
  else
    state.index = state.index + 1
    if state.index > #state.tracks then
      if state.repeatMode == 'off' then
        state.index = #state.tracks
        state.uiWantsAutoAdvance = false
        return
      end
      state.index = 1
    end
  end
  if not uiPlay() then
    state.uiWantsAutoAdvance = false
  end
end

local function onUpdate(dt)
  syncPlaybackPauseWallClock()
  tickPlaybackAutoAdvance(dt)
end

M.loadPlaylist = loadPlaylist
M.loadMusicLibrary = loadMusicLibrary
M.getPlaylistNames = getPlaylistNames
M.setActivePlaylist = setActivePlaylist
M.getTracks = getTracks
M.getTrackCount = getTrackCount
M.setTrackIndex = setTrackIndex
M.getTrackIndex = getTrackIndex
M.getCurrentTrack = getCurrentTrack
M.getPlaylistPath = getPlaylistPath
M.stop = stop
M.play = play
M.getUiState = getUiState
M.uiSetOutput = uiSetOutput
M.uiPlay = uiPlay
M.uiStop = uiStop
M.uiNext = uiNext
M.uiPrevious = uiPrevious
M.uiToggleShuffle = uiToggleShuffle
M.uiToggleRepeat = uiToggleRepeat
M.uiSetVolume = uiSetVolume
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.getAllPlaylistSongNames = getAllPlaylistSongNames
M.getSongDurationSec = getSongDurationSec
M.getCurrentSongLengthSec = getCurrentSongLengthSec

loadMusicPrefs()

return M

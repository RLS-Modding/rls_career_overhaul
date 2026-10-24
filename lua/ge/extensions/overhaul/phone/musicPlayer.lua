-- Music player: library discovery, playlists, output, transport and UI commands for one extension.
-- The extension owns its playback and preferences state; audioProbe owns the independent byte decoder.
local M = {}

local probeModule = require('overhaul/phone/musicPlayer/audioProbe')

-- Config -------------------------------------------------------------------------------------------

local DEFAULT_PLAY_MODE = 'random'
local BUNDLED_MUSIC_FOLDER = 'overhaul'
local musicPrefsPath = 'settings/RLS/musicPlayerPrefs.json'
local legacyMusicPrefsPath = 'settings/musicPlayerPrefs.json'
local PREFS_SAVE_DELAY_SEC = 0.5

-- State --------------------------------------------------------------------------------------------

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
  -- Session/context scale on top of the user slider (auction, etc). Does not persist.
  outputGain = 1,
  shuffleOrder = nil,
  shuffleCursor = nil
}

local playbackClock = hptimer()
local defaultTracks = {}
local prefsSaveCountdown = nil
local uiTracksRef = nil
local uiTracksOut = nil
-- Randomize versions so hot reload cannot reuse the UI cache.
local uiTracksVersion = math.random(1, 1000000)

-- Output helpers -----------------------------------------------------------------------------------

-- Any value to the unit interval; non-numbers count as 0 and NaN passes through.
local function clamp01(value)
  local v = tonumber(value) or 0
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function playbackTimeSec()
  return playbackClock:stop() / 1000
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
    Engine.Audio.deleteSource(state.guiSourceId)
    state.guiSourceId = nil
  end
end

local function stopEmitter(emitter)
  if emitter and emitter.stop then
    emitter:stop()
    emitter:stop(-1)
  end
end

local function simTimePaused()
  return simTimeAuthority.getPause() == true
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
      state.playbackPauseWallStart = playbackTimeSec()
    end
  else
    if state.playbackPauseWallStart then
      state.playbackPauseAccumSec = (state.playbackPauseAccumSec or 0) + (playbackTimeSec() - state.playbackPauseWallStart)
      state.playbackPauseWallStart = nil
    end
  end
end

local function playbackPositionSec()
  if not state.playStartClock then
    return 0
  end
  local raw = playbackTimeSec() - state.playStartClock
  local pauseTotal = state.playbackPauseAccumSec or 0
  if state.playbackPauseWallStart then
    pauseTotal = pauseTotal + (playbackTimeSec() - state.playbackPauseWallStart)
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

local function applyTrackToEmitter(emitter, entry)
  if entry.event then
    emitter:setField('filename', 0, '')
    emitter:setField('track', 0, entry.event)
  elseif type(entry.file) == 'string' and entry.file ~= '' then
    emitter:setField('filename', 0, '')
    emitter:setField('track', 0, entry.file)
  else
    emitter:setField('filename', 0, entry.filename)
    emitter:setField('track', 0, entry.track)
    if entry.useTrackDescriptionOnly ~= nil then
      local v = entry.useTrackDescriptionOnly and '1' or '0'
      emitter:setField('useTrackDescriptionOnly', 0, v)
    end
  end
  local loopVal = entry.isLooping
  if loopVal == nil and type(entry.file) == 'string' and entry.file ~= '' then
    loopVal = false
  end
  if loopVal ~= nil then
    local v = loopVal and '1' or '0'
    emitter:setField('isLooping', 0, v)
  end
end

local function effectiveMusicVolume()
  return clamp01(clamp01(state.musicVolume) * clamp01(state.outputGain))
end

local function applyMusicVolumeToActive()
  local v = effectiveMusicVolume()
  if state.guiSourceId then
    local snd = scenetree.findObjectById(state.guiSourceId)
    if snd then
      snd:setVolume(v)
    end
  end
  local em = state.lastEmitter
  if em then
    em:setField('scale', 0, tostring(v))
  end
end

local function playEmitter(emitter, entry)
  stopEmitter(emitter)
  applyTrackToEmitter(emitter, entry)
  state.lastEmitter = emitter
  if emitter.play then
    emitter:play(-1)
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
    snd:play(-1)
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
  Engine.Audio.playOnce(ch, ref, {})
  return true
end

-- Preferences --------------------------------------------------------------------------------------

local function loadMusicPrefs()
  local data = jsonReadFile(musicPrefsPath) or jsonReadFile(legacyMusicPrefsPath)
  if type(data) == 'table' and data.volume ~= nil then
    state.musicVolume = clamp01(data.volume)
  end
end

local function saveMusicPrefs()
  if not FS:directoryExists('settings/RLS/') then FS:directoryCreate('settings/RLS/', true) end
  jsonWriteFile(musicPrefsPath, { volume = state.musicVolume }, true)
end

local function schedulePrefsSave()
  prefsSaveCountdown = PREFS_SAVE_DELAY_SEC
end

local function flushPendingPrefsSave()
  if prefsSaveCountdown then
    prefsSaveCountdown = nil
    saveMusicPrefs()
  end
end

local function tickPendingPrefsSave(dt)
  if not prefsSaveCountdown then return end
  prefsSaveCountdown = prefsSaveCountdown - (tonumber(dt) or 0)
  if prefsSaveCountdown <= 0 then
    flushPendingPrefsSave()
  end
end

-- Shuffle and track selection ----------------------------------------------------------------------

local function invalidateShuffleOrder()
  state.shuffleOrder = nil
  state.shuffleCursor = nil
end

local function ensurePlaylist()
  if #state.tracks > 0 or #defaultTracks == 0 then
    return
  end
  state.tracks = deepcopy(defaultTracks)
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

-- Playlist files and paths -------------------------------------------------------------------------

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
  local bundledRest = rest:match('^' .. BUNDLED_MUSIC_FOLDER .. '/(.+)$')
  if bundledRest and bundledRest:find('/', 1, true) then
    return bundledRest:match('^([^/]+)'), true
  end
  return rest:match('^([^/]+)'), false
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

local audioProbe = probeModule.create(normalizeAudioVfsPath, vfsPathTryList)

-- Covers and library scan --------------------------------------------------------------------------

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

local function appendLibraryFile(fp, root, folderCoverByFolder)
  if type(fp) == 'string' then
    local plName, isBundled = playlistNameFromFile(root, fp)
    if plName and plName ~= '' then
      state.playlistsByName[plName] = state.playlistsByName[plName] or {}
      local base = fp:match('([^/]+)%.[^%.]+$')
      if not base then
        base = fp:match('([^/]+)$')
      end
      local folder = isBundled and (root .. '/' .. BUNDLED_MUSIC_FOLDER .. '/' .. plName) or (root .. '/' .. plName)
      local sideCover = findSidecarCover(fp)
      local folderCov = folderCoverByFolder[folder]
      if folderCov == nil then
        folderCov = findFolderCover(folder)
        folderCoverByFolder[folder] = folderCov
      end
      local coverPath = (sideCover ~= '' and sideCover) or (folderCov ~= '' and folderCov) or nil
      if not coverPath and fp:lower():sub(-4) == '.mp3' then
        coverPath = audioProbe.extractEmbeddedMp3CoverVfsPath(fp)
      end
      local dur = audioProbe.estimateTrackDurationSec(fp)
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

local function selectScannedPlaylist(names)
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
  state.tracks = deepcopy(state.playlistsByName[state.activePlaylistName])
  state.mode = DEFAULT_PLAY_MODE
  state.index = 1
  if #state.tracks == 0 then
    state.index = 1
  end
  invalidateShuffleOrder()
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
  local folderCoverByFolder = {}
  for _, fp in ipairs(files) do
    appendLibraryFile(fp, root, folderCoverByFolder)
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
  selectScannedPlaylist(names)
  return true
end

-- Playlist loading and queries ---------------------------------------------------------------------

local function loadPlaylist(path)
  if loadPlaylistFromFile(path) then
    return true
  end
  state.tracks = deepcopy(defaultTracks)
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
  if type(preferredPlaylist) == 'string' and preferredPlaylist ~= '' and state.playlistsByName[preferredPlaylist] and
      preferredPlaylist ~= state.activePlaylistName then
    stop()
    state.activePlaylistName = preferredPlaylist
    state.tracks = deepcopy(state.playlistsByName[preferredPlaylist])
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

-- Track metadata -----------------------------------------------------------------------------------

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
    d = audioProbe.estimateTrackDurationSec(path)
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

-- Transport and UI commands ------------------------------------------------------------------------

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

local function coverPathToUiUrl(vfsPath)
  if type(vfsPath) ~= 'string' or vfsPath == '' then
    return '/ui/modModules/rlsMusicPlayer/cover-placeholder.svg'
  end
  if vfsPath:match('^https?://') or vfsPath:match('^data:image/') then return vfsPath end
  vfsPath = vfsPath:gsub('^local://local/', '/')
  local p = normalizeAudioVfsPath(vfsPath):gsub('^/+', '')
  if p == '' then
    return '/ui/modModules/rlsMusicPlayer/cover-placeholder.svg'
  end
  -- Root-relative VFS URLs work in CEF and external UI clients. Escape each byte
  -- outside URL path characters (spaces, #, ?, and UTF-8 track names included).
  return '/' .. (p:gsub('([^%w%-%._~/])', function(c) return string.format('%%%02X', c:byte()) end))
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

local function getUiTracks()
  if uiTracksRef ~= state.tracks or not uiTracksOut then
    local tracksOut = {}
    for i, track in ipairs(state.tracks) do
      local c = track.cover or track.coverUrl or track.albumArt
      table.insert(tracksOut, {
        title = track.title or track.name or ('Track ' .. tostring(i)),
        durationSec = tonumber(track.durationSec) or tonumber(track.duration) or 0,
        cover = coverPathToUiUrl(c)
      })
    end
    uiTracksRef = state.tracks
    uiTracksOut = tracksOut
    uiTracksVersion = uiTracksVersion + 1
  end
  return uiTracksOut, uiTracksVersion
end

local function getUiState(knownTracksVersion)
  syncPlaybackPauseWallClock()
  ensurePlaylist()
  local tracksOut, tracksVersion = getUiTracks()
  if knownTracksVersion ~= nil and tonumber(knownTracksVersion) == tracksVersion then
    tracksOut = nil
  end
  local cur = state.tracks[state.index]
  local currentTitle = ''
  local currentCover = coverPathToUiUrl(nil)
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
    tracksVersion = tracksVersion,
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
    state.playStartClock = playbackTimeSec()
    state.playDurationSec = dur
    resetPlaybackPauseTracking()
    if simTimePaused() then
      state.playbackPauseWallStart = playbackTimeSec()
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
  state.tracks = deepcopy(tracks)
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
  schedulePrefsSave()
  applyMusicVolumeToActive()
end

-- Context attenuation (e.g. auction). Leaves the user slider / prefs alone.
local function uiSetOutputGain(g)
  if g == nil then
    state.outputGain = 1
  else
    state.outputGain = clamp01(g)
  end
  applyMusicVolumeToActive()
  return state.outputGain
end

-- Automatic advancement ----------------------------------------------------------------------------

local function finishCurrentTrack()
  state.isPlaying = false
  stopGuiSource()
  stopEmitter(state.lastEmitter)
  state.lastEmitter = nil
  state.playStartClock = nil
  resetPlaybackPauseTracking()
end

local function replayCurrentTrack()
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
    state.playStartClock = playbackTimeSec()
    state.playDurationSec = dur
    resetPlaybackPauseTracking()
    if simTimePaused() then
      state.playbackPauseWallStart = playbackTimeSec()
    end
    state.uiWantsAutoAdvance = true
    return
  end
  if not ok then
    state.uiWantsAutoAdvance = false
  end
end

local function advanceTrackIndex()
  if state.mode == 'random' then
    ensureShuffleOrder()
    local n = #(state.shuffleOrder or {})
    if n < 1 then
      state.uiWantsAutoAdvance = false
      return false
    end
    local c = (state.shuffleCursor or 1) + 1
    if c > n then
      if state.repeatMode == 'off' then
        state.shuffleCursor = n
        state.index = state.shuffleOrder[n]
        state.uiWantsAutoAdvance = false
        return false
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
        return false
      end
      state.index = 1
    end
  end
  return true
end

local function tickPlaybackAutoAdvance(dt)
  if not state.isPlaying or not state.uiWantsAutoAdvance then return end
  local durationSec = tonumber(state.playDurationSec) or 0
  if durationSec <= 0 or not state.playStartClock then return end
  if playbackPositionSec() < durationSec - 0.08 then return end
  finishCurrentTrack()
  if #state.tracks < 1 then return end
  if state.repeatMode == 'one' then
    replayCurrentTrack()
    return
  end
  if advanceTrackIndex() == false then return end
  if not uiPlay() then
    state.uiWantsAutoAdvance = false
  end
end

-- Per-frame update ---------------------------------------------------------------------------------

local function onUpdate(dt)
  tickPendingPrefsSave(dt)
  if not state.isPlaying then return end
  syncPlaybackPauseWallClock()
  tickPlaybackAutoAdvance(dt)
end

-- Lifecycle ----------------------------------------------------------------------------------------

local function onExtensionUnloaded()
  flushPendingPrefsSave()
  state.outputGain = 1
  stop()
end

-- Public API ---------------------------------------------------------------------------------------

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
M.uiSetOutputGain = uiSetOutputGain
M.getAllPlaylistSongNames = getAllPlaylistSongNames
M.getSongDurationSec = getSongDurationSec
M.getCurrentSongLengthSec = getCurrentSongLengthSec
M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded

loadMusicPrefs()

return M

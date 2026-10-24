-- Car meet save and load, shared by the owner's lifecycle and reputation updates.
-- Keep profile guards, offline invite shifts and writes at the owner's existing hooks.

local M = {}
-- SaveStore key over the file this module writes for carmeets.lua's save hook (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "carmeets.state", owner = "overhaul_career_carmeets_carmeets", files = {"career/rls_career/carmeets.json"}, phase = "profile", required = true},
})

M.SAVE_FILE = "carmeets.json"
M.RELATIVE_DIR = "career/rls_career"

local owner = nil

local function bind(ownerHooks)
  owner = ownerHooks
end

local function getRepState()
  return overhaul_career_carmeets_reputation.getPersistState()
end

local function applyRepState(repState)
  overhaul_career_carmeets_reputation.applyPersistState(repState)
end

local function getDirPath(savePath)
  return savePath .. "/" .. M.RELATIVE_DIR
end

local function ensureDir(savePath, writer)
  local dirPath = getDirPath(savePath)
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  return dirPath
end

local function buildPayload(state, repState)
  return {
    savedAt = os.time(),
    lastGenerationTime = state.lastGenerationTime,
    rsvpData = state.rsvpData,
    pendingInvites = state.pendingInvites,
    playerMeetReputation = repState.playerMeetReputation,
    nextInviteId = state.nextInviteId,
    joinedClubs = state.joinedClubs,
    attendanceHistory = repState.attendanceHistory,
    legacyCarRepMerged = repState.legacyCarRepMerged,
  }
end

local function writeToPath(savePath, state, writer)
  if not savePath then
    return false
  end
  local repState = getRepState()
  if not repState then
    return false
  end
  ensureDir(savePath, writer)
  overhaul_career_saveSystem.jsonWriteFileSafe(getDirPath(savePath) .. "/" .. M.SAVE_FILE, buildPayload(state, repState), true)
  return true
end

function M.reset()
  if not owner then
    return
  end
  owner.setState({
    lastGenerationTime = 0,
    rsvpData = nil,
    pendingInvites = {},
    nextInviteId = 1,
    joinedClubs = {},
    loadedSavePath = nil,
    sceneRepDirty = false,
  })
  applyRepState(nil)
end

function M.markDirty()
  if not owner then
    return false
  end
  local state = owner.read()
  state.sceneRepDirty = true
  owner.setState(state)
  return true
end

function M.persist()
  return M.markDirty()
end

local function restoreInviteTimes(data, now, offlineSeconds)
  for _, invite in ipairs(data.pendingInvites or {}) do
    if invite.expiresAt then
      if data.savedAt then
        invite.expiresAt = invite.expiresAt + offlineSeconds
        if invite.generatedAt then invite.generatedAt = invite.generatedAt + offlineSeconds end
      else
        invite.expiresAt = now + math.max(0, invite.expiresAt - (invite.generatedAt or invite.expiresAt))
        invite.generatedAt = now
      end
    end
  end
end

function M.load(currentSavePath, forceReload)
  if not owner then
    return
  end
  if not currentSavePath and not owner.isCareerActive() then
    return
  end
  if not currentSavePath then
    currentSavePath = owner.getActiveSavePath()
  end
  if not currentSavePath then
    return
  end

  local state = owner.read()
  if not forceReload and state.loadedSavePath then
    return
  end

  local filePath = getDirPath(currentSavePath) .. "/" .. M.SAVE_FILE
  local data = jsonReadFile(filePath)
  if data then
    local now = os.time()
    local offlineSeconds = math.max(0, now - (tonumber(data.savedAt) or now))
    restoreInviteTimes(data, now, offlineSeconds)
    owner.setState({
      lastGenerationTime = (tonumber(data.lastGenerationTime) or 0) + offlineSeconds,
      rsvpData = data.rsvpData,
      pendingInvites = data.pendingInvites or {},
      nextInviteId = data.nextInviteId or (#(data.pendingInvites or {}) + 1),
      joinedClubs = data.joinedClubs or {},
      loadedSavePath = currentSavePath,
      sceneRepDirty = false,
    })
    applyRepState({
      playerMeetReputation = data.playerMeetReputation or data.reputation,
      attendanceHistory = data.attendanceHistory,
      legacyCarRepMerged = data.legacyCarRepMerged,
    })
  else
    owner.setState({
      lastGenerationTime = 0,
      rsvpData = nil,
      pendingInvites = {},
      nextInviteId = 1,
      joinedClubs = {},
      loadedSavePath = currentSavePath,
      sceneRepDirty = false,
    })
    applyRepState(nil)
  end
end

-- A new career's active path from setProfile has no leading "/" while save targets do; both name the same folder, so compare them without it.
local function normalizeSavePath(p)
  return (tostring(p or ""):gsub("\\", "/"):gsub("/+$", ""):gsub("^/+", ""))
end

local function saveFamily(path)
  path = normalizeSavePath(path)
  return path:match("^(.*)/[^/]+$") or path
end

local function sameSaveFamily(a, b)
  if not a or not b then
    return false
  end
  return saveFamily(a) == saveFamily(b)
end

-- carmeets.lua exports this as its onOverhaulSaveCurrentProfile hook.
function M.saveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not owner or not currentSavePath then
    return
  end

  local activeSavePath = owner.getActiveSavePath()
  if not activeSavePath then
    return
  end

  local state = owner.read()
  local livePath = state.loadedSavePath or activeSavePath
  if not sameSaveFamily(livePath, currentSavePath) and not sameSaveFamily(activeSavePath, currentSavePath) then
    return
  end

  if not state.loadedSavePath then
    if not owner.isCareerActive() then
      return
    end
    M.load(activeSavePath)
    state = owner.read()
    if not state.loadedSavePath then
      return
    end
  end

  writeToPath(currentSavePath, state, writer)
  state.loadedSavePath = currentSavePath
  state.sceneRepDirty = false
  owner.setState(state)
end

M.bind = bind

return M

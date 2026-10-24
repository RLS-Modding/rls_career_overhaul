-- Career start mode: the mode a career was started in (freeroam, story, sandbox, hardcore, career or custom).
-- Stored per save in career/rls_career/careerStartMode.json; older saves are inferred from their legacy flags.
local M = {}

-- SaveStore keys for the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "options.careerStartMode", owner = "overhaul_career_guide_careerStartMode", files = {"career/rls_career/careerStartMode.json"}, phase = "profile", required = true},
})

local store = require("overhaul/lib/save/optionsStore").new("careerStartMode.json")

local VALID_MODES = {
  freeroam = true,
  story = true,
  sandbox = true,
  hardcore = true,
  career = true,
  custom = true,
}

local saveData = {}
local careerStartMode = nil

local function resolveMode(candidate)
  if type(candidate) ~= "string" then
    return nil
  end
  local normalized = string.lower(candidate)
  if VALID_MODES[normalized] then
    return normalized
  end
  return nil
end

local function inferLegacyModeFromSave(savePath)
  if not savePath then
    return nil
  end

  local cheatsData = jsonReadFile(savePath .. "/career/rls_career/cheats.json")
  if cheatsData and cheatsData.cheatsMode then
    return "freeroam"
  end

  local challengeData = jsonReadFile(savePath .. "/career/rls_career/challengeModes.json")
  if challengeData and challengeData.activeChallenge then
    return "story"
  end

  local difficultyData = jsonReadFile(savePath .. "/career/rls_career/difficultyMode.json")
  if difficultyData and difficultyData.mode == "hardcore" then
    return "hardcore"
  end

  local hardcoreData = jsonReadFile(savePath .. "/career/rls_career/hardcore.json")
  if hardcoreData and hardcoreData.hardcoreMode then
    return "hardcore"
  end

  return nil
end

local function inferLegacyMode()
  local pendingMode = resolveMode(overhaul_career_career.pendingCareerStartMode)
  if pendingMode then
    return pendingMode
  end
  if overhaul_career_career.cheatsMode then
    return "freeroam"
  end
  if overhaul_career_career.pendingChallengeId then
    return "story"
  end
  if overhaul_career_career.hardcoreMode then
    return "hardcore"
  end
  return nil
end

local function onOverhaulActive(active)
  if not active then
    careerStartMode = nil
    saveData = {}
    return false
  end

  local savePath = store.currentSavePath()
  saveData = savePath and store.read(savePath) or {}

  if not next(saveData) then
    local initialMode = resolveMode(overhaul_career_career.pendingCareerStartMode) or inferLegacyMode() or inferLegacyModeFromSave(savePath)
    if initialMode then
      saveData = {careerStartMode = initialMode}
      if savePath then
        store.ensureDirNow(savePath)
        store.write(savePath, saveData)
      end
    end
  end

  careerStartMode = resolveMode(saveData.careerStartMode)
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  if not careerStartMode then
    return
  end
  saveData.careerStartMode = careerStartMode
  store.write(currentSavePath, saveData)
end

function M.getCareerStartMode()
  return careerStartMode
end

M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M

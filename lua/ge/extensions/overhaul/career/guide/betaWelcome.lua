-- Owns the update content and one retained intro plan per career activation.
-- Guide supplies welcome eligibility; the UI supplies the existing seen preference.
-- Slides live in /ui/modules/whatsnew/<folder>/slides.json; to ship one, add a folder and update id and folder below.
local M = {}
M.dependencies = {'overhaul_career_career'}

-- A new id shows the splash again for everyone; a hotfix keeps the old id to stay silent.
local currentCycle = {
  enabled = true,
  id = "2.8.0_public",
  folder = "2.8.0_public",
}

local CONTENT_ROOT = "/ui/modules/whatsnew/"

local cachedContent = nil
local cachedFolder = nil
local requested = false
local decided = false
local currentPlan = nil
local seenCycle = nil
local uiReady = false

local function loadContent(forceReload)
  local folder = currentCycle.folder or currentCycle.id
  if cachedContent and cachedFolder == folder and not forceReload then
    return cachedContent
  end
  local base = CONTENT_ROOT .. folder
  local data = jsonReadFile(base .. "/slides.json")
  if type(data) ~= "table" or type(data.slides) ~= "table" or #data.slides == 0 then
    log("E", "betaWelcome", "What's New content missing or empty: " .. base .. "/slides.json")
    return nil
  end
  data.imageBase = base .. "/"
  cachedContent = data
  cachedFolder = folder
  return data
end

local function getSummary(force)
  local content = loadContent(force == true)
  local summary = content and deepcopy(content) or { slides = {} }
  summary.enabled = currentCycle.enabled and content ~= nil
  summary.id = currentCycle.id
  summary.label = summary.label or ("v" .. tostring(currentCycle.id))
  summary.force = force == true
  return summary
end

local function isCareerUiReady()
  if not overhaul_career_career.isActive() then
    return false
  end
  if core_gamestate.getLoadingStatus("careerLoading") then return false end
  if core_gamestate.getLoadingStatus("careerActivate") then return false end
  return true
end

local function tryShow()
  if not requested or decided or not uiReady or not isCareerUiReady() then return end
  local guide = overhaul_career_guide_guide.getIntroState()
  if not guide.ready or not guide.allowed then return end
  decided = true
  local summary = getSummary(false)
  local whatsNew = summary.enabled and seenCycle ~= summary.id and summary or nil
  if not guide.welcome and not whatsNew then return end
  currentPlan = {welcome = guide.welcome, whatsNew = whatsNew}
  guihooks.trigger("RlsCareerIntroShow", currentPlan)
  return currentPlan
end

local function requestSplash(force)
  if not overhaul_career_career.isActive() then return nil end
  requested = true
  return tryShow()
end

-- The browser retains the existing per-cycle preference; wait for that snapshot
-- before deciding, so a seen cycle never produces an empty popup.
local function resync(seenId, hasPreference)
  if hasPreference then
    seenCycle = seenId
    uiReady = true
  end
  if currentPlan then
    guihooks.trigger("RlsCareerIntroShow", currentPlan)
    return currentPlan
  end
  return tryShow()
end

local function finish(dontShowAgain)
  if not currentPlan then return end
  local plan = currentPlan
  currentPlan = nil
  if plan.preview then return end
  if plan.whatsNew then seenCycle = dontShowAgain and plan.whatsNew.id or nil end
  if plan.welcome then overhaul_career_guide_guide.onContinue() end
end

-- Dev console: overhaul_career_guide_betaWelcome.preview() shows the splash whatever the career state.
local function preview()
  local summary = getSummary(true)
  currentPlan = {welcome = true, whatsNew = summary, preview = true}
  guihooks.trigger("RlsCareerIntroShow", currentPlan)
  return currentPlan
end

local function onCareerActivated()
  decided = false
  currentPlan = nil
  requestSplash(false)
  -- The overlay can outlive this Lua owner when another career is loaded.
  -- Ask the mounted UI for its preference again; onMounted covers a new UI.
  guihooks.trigger("RlsCareerIntroResyncRequested")
end

local function onWorldReadyState(state)
  if state ~= 2 then return end
  tryShow()
end

local function onCareerDeactivated()
  requested = false
  decided = false
  currentPlan = nil
  guihooks.trigger("RlsCareerIntroHide")
end

M.getSummary = getSummary
M.isCareerUiReady = isCareerUiReady
M.requestSplash = requestSplash
M.resync = resync
M.finish = finish
M.preview = preview
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = onWorldReadyState
-- Loading flags or a profile route may clear after the world-ready hook.
M.onUpdate = tryShow
M.onCareerDeactivated = onCareerDeactivated
M.onExtensionUnloaded = onCareerDeactivated

return M

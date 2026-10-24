-- Freeroam contracts app: the phone's view of contracts, sponsors and sanctioned races.
-- Each action forwards to the events service and returns { ok, error } to the phone.
local M = {}
local context = require('overhaul/lib/career/context')

M.dependencies = {'overhaul_events_fre_host'}

local isCareerActive = context.isCareerActive

local function getState(filterDisciplineId)
  if not isCareerActive() then
    return {
      careerActive = false,
      disciplines = {},
      activeContracts = {},
      availableContracts = {},
      activeSponsors = {},
      availableSponsors = {},
      sanctionedRacing = nil,
      sanctionedRacingOfferPeriodMinutes = nil,
    }
  end

  local state = overhaul_events_fre_ui.getUiState(filterDisciplineId)
  state = type(state) == "table" and state or {}
  state.careerActive = true
  return state
end

-- A success carries no error text, so a caller never reads it as a failure.
local function actionResult(ok, err)
  if ok == true then
    return {ok = true, error = nil}
  else
    return {ok = false, error = err or "Action failed."}
  end
end

-- Calls one service method and wraps its ok/error pair for the phone.
local function runAction(service, method, ...)
  return actionResult(service[method](...))
end

local function startLiveUpdates()
  overhaul_events_fre_ui.setUiStreamingActive(true)
  return true
end

local function stopLiveUpdates()
  overhaul_events_fre_ui.setUiStreamingActive(false)
  return true
end

local function acceptContract(contractId)
  return runAction(overhaul_events_fre_actions, "acceptContract", contractId)
end

local function abandonContract(contractId)
  return runAction(overhaul_events_fre_actions, "abandonContract", contractId)
end

local function signSponsor(sponsorId)
  return runAction(overhaul_events_fre_actions, "signSponsor", sponsorId)
end

local function dropSponsor(sponsorId)
  return runAction(overhaul_events_fre_actions, "dropSponsor", sponsorId)
end

local function acknowledgeSponsorWarning(sponsorId)
  return runAction(overhaul_events_fre_actions, "acknowledgeSponsorWarning", sponsorId)
end

local function upgradeLicense(disciplineId)
  local ok, err, tier, offerGenerated, offerMessage = overhaul_events_fre_actions.upgradeLicense(disciplineId)
  local result = actionResult(ok, err)
  result.tier = tier
  result.offerGenerated = offerGenerated == true
  result.message = offerMessage
  return result
end

local function commitSanctionedRace()
  return runAction(overhaul_events_fre_sanctionedRacing, "commitSanctionedRace")
end

local function navigateSanctionedRace()
  return runAction(overhaul_events_fre_sanctionedRacing, "navigateSanctionedRace")
end

local function rescheduleSanctionedRace()
  return runAction(overhaul_events_fre_sanctionedRacing, "rescheduleSanctionedRace")
end

M.getState = getState
M.startLiveUpdates = startLiveUpdates
M.stopLiveUpdates = stopLiveUpdates
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning
M.upgradeLicense = upgradeLicense
M.commitSanctionedRace = commitSanctionedRace
M.navigateSanctionedRace = navigateSanctionedRace
M.rescheduleSanctionedRace = rescheduleSanctionedRace

return M

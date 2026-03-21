local M = {}

M.dependencies = {'gameplay_events_freContracts'}

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

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

  local state = gameplay_events_freContracts_ui.getUiState(filterDisciplineId)
  state = type(state) == "table" and state or {}
  state.careerActive = true
  return state
end

local function actionResult(ok, err)
  return {
    ok = ok == true,
    error = ok and nil or (err or "Action failed.")
  }
end

local function startLiveUpdates()
  gameplay_events_freContracts_ui.setUiStreamingActive(true)
  return true
end

local function stopLiveUpdates()
  gameplay_events_freContracts_ui.setUiStreamingActive(false)
  return true
end

local function acceptContract(contractId)
  local ok, err = gameplay_events_freContracts_actions.acceptContract(contractId)
  return actionResult(ok, err)
end

local function abandonContract(contractId)
  local ok, err = gameplay_events_freContracts_actions.abandonContract(contractId)
  return actionResult(ok, err)
end

local function signSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.signSponsor(sponsorId)
  return actionResult(ok, err)
end

local function dropSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.dropSponsor(sponsorId)
  return actionResult(ok, err)
end

local function acknowledgeSponsorWarning(sponsorId)
  local ok, err = gameplay_events_freContracts_actions.acknowledgeSponsorWarning(sponsorId)
  return actionResult(ok, err)
end

local function commitSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.commitSanctionedRace()
  return actionResult(ok, err)
end

local function navigateSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.navigateSanctionedRace()
  return actionResult(ok, err)
end

function rescheduleSanctionedRace()
  local ok, err = gameplay_events_freContracts_sanctionedRacing.rescheduleSanctionedRace()
  return actionResult(ok, err)
end

M.getState = getState
M.startLiveUpdates = startLiveUpdates
M.stopLiveUpdates = stopLiveUpdates
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning
M.commitSanctionedRace = commitSanctionedRace
M.navigateSanctionedRace = navigateSanctionedRace
M.rescheduleSanctionedRace = rescheduleSanctionedRace

return M

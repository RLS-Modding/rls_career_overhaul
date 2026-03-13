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
      availableSponsors = {}
    }
  end

  local state = gameplay_events_freContracts.getUiState(filterDisciplineId)
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
  gameplay_events_freContracts.setUiStreamingActive(true)
  return true
end

local function stopLiveUpdates()
  gameplay_events_freContracts.setUiStreamingActive(false)
  return true
end

local function acceptContract(contractId)
  local ok, err = gameplay_events_freContracts.acceptContract(contractId)
  return actionResult(ok, err)
end

local function abandonContract(contractId)
  local ok, err = gameplay_events_freContracts.abandonContract(contractId)
  return actionResult(ok, err)
end

local function signSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts.signSponsor(sponsorId)
  return actionResult(ok, err)
end

local function dropSponsor(sponsorId)
  local ok, err = gameplay_events_freContracts.dropSponsor(sponsorId)
  return actionResult(ok, err)
end

local function acknowledgeSponsorWarning(sponsorId)
  local ok = gameplay_events_freContracts.acknowledgeSponsorWarning(sponsorId)
  return actionResult(ok, ok and nil or "Sponsor not found.")
end

M.getState = getState
M.startLiveUpdates = startLiveUpdates
M.stopLiveUpdates = stopLiveUpdates
M.acceptContract = acceptContract
M.abandonContract = abandonContract
M.signSponsor = signSponsor
M.dropSponsor = dropSponsor
M.acknowledgeSponsorWarning = acknowledgeSponsorWarning

return M

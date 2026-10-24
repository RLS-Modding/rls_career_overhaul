-- Business computer actions for the racing team: each callable forwards to the team's owner table.
-- Offer actions that succeed push the refreshed race offer list back to the computer screen.
return function(owner, raceFlowModule)

  local function notifyRaceOffersUpdated(businessId, uid)
    guihooks.trigger("businessComputer:onRaceOffersUpdated", {
      businessId = businessId,
      raceOffers = uid and uid.raceOffers or {},
      raceOffersLevelId = uid and uid.raceOffersLevelId,
      raceOffersNextRefreshAt = uid and uid.raceOffersNextRefreshAt,
      raceOffersMessage = uid and uid.raceOffersMessage,
      racingTeamProxyArmed = uid and uid.racingTeamProxyArmed,
    })
  end

  -- A UI snapshot that fails to read must not undo an accepted offer, so it falls back to an empty one.
  local function readOfferUiSafely(businessId)
    local uid = {}
    do
      local ok, data = pcall(owner.getUIData, businessId)
      if ok and type(data) == "table" then
        uid = data
      end
    end
    return uid
  end

  local function acceptRacingTeamRaceOffer(businessId, offerId, techId)
    local success = owner.acceptRacingTeamRaceOffer(businessId, offerId, techId)
    if success == true then
      notifyRaceOffersUpdated(businessId, owner.getUIData(businessId))
    end
    return success
  end

  local function acceptRacingTeamRaceOfferAsPlayer(businessId, offerId, fleetVehicleId)
    local success = owner.acceptRacingTeamRaceOfferAsPlayer(businessId, offerId, fleetVehicleId)
    if success == true then
      notifyRaceOffersUpdated(businessId, owner.getUIData(businessId))
    end
    return success
  end

  local function acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(businessId, offerId, fleetVehicleId)
    local success = owner.acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(businessId, offerId, fleetVehicleId)
    if success == true then
      notifyRaceOffersUpdated(businessId, readOfferUiSafely(businessId))
    end
    return success
  end

  local function declineRacingTeamRaceOffer(businessId, offerId)
    local success = owner.declineRacingTeamRaceOffer(businessId, offerId)
    if success then
      notifyRaceOffersUpdated(businessId, owner.getUIData(businessId))
    end
    return success
  end

  local function listLeague1FleetVehiclesForSanctionedOffer(businessId, offerId)
    return owner.listLeague1FleetVehiclesForSanctionedOffer(businessId, offerId) or {}
  end

  local function listLeague2FleetVehiclesForSanctionedOffer(businessId, offerId)
    return owner.listLeague2FleetVehiclesForSanctionedOffer(businessId, offerId) or {}
  end


  -- The race flow module answers for proxy requests when it is loaded; the owner is the fallback.
  local function requestProxyDriverRace(opts)
    if type(opts) ~= "table" then
      return { ok = false, err = "invalid_opts" }
    end
    local rtFlow = raceFlowModule()
    if rtFlow and rtFlow.requestProxyDriverRace then
      return rtFlow.requestProxyDriverRace(opts)
    end
    return owner.requestProxyDriverRace(opts)
  end

  local function clearProxyDriverRaceRequest(businessId)
    local rtFlow = raceFlowModule()
    if rtFlow and rtFlow.clearProxyDriverRaceRequest then
      return rtFlow.clearProxyDriverRaceRequest(businessId)
    end
    owner.clearProxyDriverRaceRequest(businessId)
  end

  local function getProxyDriverRaceRequest(businessId)
    local rtFlow = raceFlowModule()
    if rtFlow and rtFlow.getProxyDriverRaceRequest then
      return rtFlow.getProxyDriverRaceRequest(businessId)
    end
    return owner.getProxyDriverRaceRequest(businessId)
  end

  local function assignRolledProxyRaceToDriver(businessId, techId)
    return owner.assignRolledProxyRaceToDriver(businessId, techId)
  end

  local function acceptLeague2Invite(businessId)
    return owner.acceptLeague2Invite(businessId)
  end

  local function declineLeague2Invite(businessId)
    return owner.declineLeague2Invite(businessId)
  end

  local function racingTeamMilestoneLeague2Later(businessId)
    return owner.racingTeamMilestoneLeague2Later(businessId)
  end

  local function racingTeamMilestoneLeague2Accept(businessId)
    return owner.racingTeamMilestoneLeague2Accept(businessId)
  end

  local function racingTeamMilestoneLeague2WelcomeContinue(businessId)
    return owner.racingTeamMilestoneLeague2WelcomeContinue(businessId)
  end

  local function racingTeamMilestonePurchaseContinue(businessId)
    return owner.racingTeamMilestonePurchaseContinue(businessId)
  end

  local function racingTeamMilestoneCareerFinaleContinue(businessId)
    return owner.racingTeamMilestoneCareerFinaleContinue(businessId)
  end

  local function acceptRacingTeamSponsorOffer(businessId, offerId)
    return owner.acceptRacingTeamSponsorOffer(businessId, offerId)
  end

  local function declineRacingTeamSponsorOffer(businessId, offerId)
    return owner.declineRacingTeamSponsorOffer(businessId, offerId)
  end

  local function dropRacingTeamSponsorActive(businessId, offerId)
    return owner.dropRacingTeamSponsorActive(businessId, offerId)
  end

  return {
    acceptRacingTeamRaceOffer = function(instance, payload) return acceptRacingTeamRaceOffer(instance.id, payload.offerId, payload.techId) end,
    listLeague1FleetVehiclesForSanctionedOffer = function(instance, payload) return listLeague1FleetVehiclesForSanctionedOffer(instance.id, payload.offerId) end,
    listLeague2FleetVehiclesForSanctionedOffer = function(instance, payload) return listLeague2FleetVehiclesForSanctionedOffer(instance.id, payload.offerId) end,
    acceptRacingTeamRaceOfferAsPlayer = function(instance, payload) return acceptRacingTeamRaceOfferAsPlayer(instance.id, payload.offerId, payload.fleetVehicleId) end,
    acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = function(instance, payload) return acceptRacingTeamRaceOfferAsPlayerAlongsideProxy(instance.id, payload.offerId, payload.fleetVehicleId) end,
    declineRacingTeamRaceOffer = function(instance, payload) return declineRacingTeamRaceOffer(instance.id, payload.offerId) end,
    requestProxyDriverRace = function(instance, payload)
      if type(payload) ~= "table" then return {ok = false, err = "invalid_opts"} end
      local opts = {}
      for key, value in pairs(payload) do opts[key] = value end
      opts.businessId = instance.id
      return requestProxyDriverRace(opts)
    end,
    clearProxyDriverRaceRequest = function(instance, payload) return clearProxyDriverRaceRequest(instance.id) end,
    getProxyDriverRaceRequest = function(instance, payload) return getProxyDriverRaceRequest(instance.id) end,
    acceptLeague2Invite = function(instance, payload) return acceptLeague2Invite(instance.id) end,
    declineLeague2Invite = function(instance, payload) return declineLeague2Invite(instance.id) end,
    racingTeamMilestoneLeague2Later = function(instance, payload) return racingTeamMilestoneLeague2Later(instance.id) end,
    racingTeamMilestoneLeague2Accept = function(instance, payload) return racingTeamMilestoneLeague2Accept(instance.id) end,
    racingTeamMilestoneLeague2WelcomeContinue = function(instance, payload) return racingTeamMilestoneLeague2WelcomeContinue(instance.id) end,
    racingTeamMilestonePurchaseContinue = function(instance, payload) return racingTeamMilestonePurchaseContinue(instance.id) end,
    racingTeamMilestoneCareerFinaleContinue = function(instance, payload) return racingTeamMilestoneCareerFinaleContinue(instance.id) end,
    assignRolledProxyRaceToDriver = function(instance, payload) return assignRolledProxyRaceToDriver(instance.id, payload.techId) end,
    acceptRacingTeamSponsorOffer = function(instance, payload) return acceptRacingTeamSponsorOffer(instance.id, payload.offerId) end,
    declineRacingTeamSponsorOffer = function(instance, payload) return declineRacingTeamSponsorOffer(instance.id, payload.offerId) end,
    dropRacingTeamSponsorActive = function(instance, payload) return dropRacingTeamSponsorActive(instance.id, payload.offerId) end,
  }
end

-- Sanctioned offer display bands, UI snapshots and commit/navigation operations.
-- Read the per-load display, dispatch, commit and cancellation services.
local lib = {}
local optional = require("overhaul/lib/platform/optional")

function lib.create(ownerServices)
  local M = ownerServices.M
  local runtime = ownerServices.runtime

  local function getCompetitiveTrackFlow()
    return optional("overhaul_events_competitiveTrackFlow")
  end

  --- Reference curb weight (kg) for converting sanctioned P/W bracket → HP numbers on the phone / UI.
  local function playerRefWeightKgForOfferDisplay()
    local ar = overhaul_events_aiRacers
    if ar and type(ar.getPlayerVehicleWeightKg) == "function" then
      local w = ar.getPlayerVehicleWeightKg()
      if type(w) == "number" and w > 0 then return w end
    end
    return nil
  end

  --- Player HP for offer/staging readouts: live dyno-style sample when trusted, else sync (matches competitiveTrackFlow staging payload).
  local function playerCatalogHpForOfferDisplay()
    local ar = overhaul_events_aiRacers
    if ar and type(ar.getPlayerVehiclePowerForStagingUi) == "function" then
      local hp = select(1, ar.getPlayerVehiclePowerForStagingUi())
      if type(hp) == "number" and hp > 0 then return math.floor(hp + 0.5) end
    end
    if ar and type(ar.getPlayerVehiclePower) == "function" then
      local hp = ar.getPlayerVehiclePower()
      if type(hp) == "number" and hp > 0 then return math.floor(hp + 0.5) end
    end
    return nil
  end

  --- HP range implied by hp/kg class limits at the given curb weight (display only; bracket logic stays P/W).
  local function displayHpBandFromPwBracket(pwMin, pwMax, wkg)
    if not wkg or wkg <= 0 then return nil, nil, nil end
    local lo = tonumber(pwMin)
    local hi = tonumber(pwMax)
    if not lo or not hi then return nil, nil, nil end
    return math.floor(lo * wkg + 0.5), math.floor(hi * wkg + 0.5), wkg
  end

  --- Mutates offer table in-place with displayClassHpMin/Max for business board payloads (optional).
  function M.attachSanctionedOfferDisplayHp(offer)
    if type(offer) ~= "table" then return end
    local wkg = playerRefWeightKgForOfferDisplay()
    local dmin, dmax, dbg = displayHpBandFromPwBracket(offer.classPwMin, offer.classPwMax, wkg)
    offer.displayClassHpMin = dmin
    offer.displayClassHpMax = dmax
    offer.displayHpBasisWeightKg = dbg
  end

  function M.getOfferUiSnapshot(now)
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local n = tonumber(now) or state.simTime or 0
    local offer = sr.offer
    if not offer then return nil end
    local useAlt = string.lower(tostring(offer.raceRouteType or "main")) == "alt"
    local dispatchActive = false
    if offer.phase == "committed" then
      if runtime.dispatchUiActive == true then dispatchActive = true end
      local ctf = getCompetitiveTrackFlow()
      if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then
        dispatchActive = true
      end
    end
    local wkg = playerRefWeightKgForOfferDisplay()
    local dmin, dmax, dbg = displayHpBandFromPwBracket(offer.classPwMin, offer.classPwMax, wkg)
    local playerHp = playerCatalogHpForOfferDisplay()
    return {
      id = offer.id,
      disciplineId = offer.disciplineId,
      raceName = offer.raceName,
      raceLabel = offer.raceLabel,
      stageNumber = tonumber(offer.stageNumber) or 1,
      raceRouteType = offer.raceRouteType,
      useAltRoute = useAlt,
      hpBracketId = offer.hpBracketId,
      hpBracketBranch = offer.hpBracketBranch,
      hpBracketLabel = offer.hpBracketLabel,
      hpBracketPayoutMult = offer.hpBracketPayoutMult,
      classPwMin = offer.classPwMin,
      classPwMax = offer.classPwMax,
      displayClassHpMin = dmin,
      displayClassHpMax = dmax,
      displayHpBasisWeightKg = dbg,
      playerCatalogHp = playerHp,
      lapCount = tonumber(offer.lapCount) or 3,
      payoutFirst = offer.payoutFirst,
      payoutSecond = offer.payoutSecond,
      payoutThird = offer.payoutThird,
      xpFirst = offer.xpFirst,
      xpSecond = offer.xpSecond,
      xpThird = offer.xpThird,
      phase = offer.phase,
      minutesUntilRefresh = math.max(0, (tonumber(offer.visibleExpiresAt) or n) - n),
      minutesUntilStartDeadline = (offer.phase == "committed" and offer.startDeadlineAt)
          and math.max(0, offer.startDeadlineAt - n)
        or nil,
      dispatchActive = dispatchActive,
    }
  end

  function M.isSanctionedRescheduleActionActive()
    if not (overhaul_career_career and overhaul_career_career.isActive()) then return false end
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local o = sr.offer
    if not o or o.phase ~= "committed" then return false end
    if runtime.dispatchUiActive == true then return true end
    local ctf = getCompetitiveTrackFlow()
    if ctf and ctf.isSanctionedCareerGoToRaceActive and ctf.isSanctionedCareerGoToRaceActive() then return true end
    return false
  end

  function M.isSanctionedRaceDispatchActive()
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local o = sr.offer
    return o and (o.phase == "committed" or o.phase == "racing") or false
  end

  local function poolRefPwFromOffer(offer)
    if not offer then return nil end
    local hi = tonumber(offer.classPwMax)
    if type(hi) ~= "number" or hi <= 0 then return nil end
    return hi
  end

  local function pushDispatchForOffer(offer)
    if not offer then return false, "Missing offer." end
    -- Committing an offer acquires its flow; status snapshots only inspect it.
    local ctf = extensions["overhaul_events_competitiveTrackFlow"]
    if not ctf or not ctf.setCompetitiveRace then return false, "Competitive race flow unavailable." end
    local ok, reason = ctf.setCompetitiveRace(offer.raceName,
      string.lower(tostring(offer.raceRouteType or "main")) == "alt")
    if not ok then return false, reason end
    local fe = overhaul_events_host
    if fe and fe.startSanctionedRaceDispatch then
      local dispatched, dispatchReason = fe.startSanctionedRaceDispatch(
        string.lower(tostring(offer.raceRouteType or "main")) == "alt",
        poolRefPwFromOffer(offer),
        offer.raceName
      )
      if dispatched == false then return false, dispatchReason end
      return true
    end
    return false, "Race dispatch unavailable."
  end

  local function validateSanctionedOfferAvailable(offer)
    if not offer or offer.phase ~= "available" then return false, "No open offer to commit to." end
    if type(offer.raceName) ~= "string" or not ownerServices.isSanctionedRaceNameConfigured(offer.raceName) then
      return false, "Unsupported sanctioned race."
    end
    return true, nil
  end

  function M.commitSanctionedRace()
    if not (overhaul_career_career and overhaul_career_career.isActive()) then return false, "Career not active." end
    if not ownerServices.skillOk(ownerServices.DISCIPLINE_ROAD) then
      return false, "Road Racing level 15 and an Easy license are required."
    end
    if not ownerServices.hasSanctionedForRoadRacing() then return false, "No sanctioned racing on this map." end
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local offer = sr.offer
    local ok, err = validateSanctionedOfferAvailable(offer)
    if not ok then return false, err end
    local n = state.simTime or 0
    local cfg = ownerServices.loadCfg()
    local deadlineMin =
      math.max(1, tonumber(offer.startDeadlineMinutes) or tonumber(cfg.defaultStartDeadlineMinutes) or 60)
    offer.phase = "committed"
    offer.committedAt = n
    offer.startDeadlineAt = n + deadlineMin
    sr.nextGenAt = offer.startDeadlineAt
    runtime.dispatchUiActive = false
    overhaul_events_fre_state.refreshMaintenanceSchedule(n)
    overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_commit")
    require("overhaul/lib/save/store").request("sanctionedRacing:commitSanctionedRace")
    return true, nil
  end

  function M.navigateSanctionedRace()
    if not (overhaul_career_career and overhaul_career_career.isActive()) then return false, "Career not active." end
    if not ownerServices.skillOk(ownerServices.DISCIPLINE_ROAD) then
      return false, "Road Racing level 15 and an Easy license are required."
    end
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local offer = sr.offer
    if not offer or (offer.phase ~= "committed" and offer.phase ~= "racing") then
      return false, "Commit to a race first."
    end
    if type(offer.raceName) ~= "string" or not ownerServices.isSanctionedRaceNameConfigured(offer.raceName) then
      return false, "Unsupported sanctioned race."
    end
    local ok, reason = pushDispatchForOffer(offer)
    if not ok then return false, reason end
    runtime.dispatchUiActive = true
    overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_navigate")
    return true, nil
  end

  --- Inject and start a sanctioned-style race from an external offer source (e.g. racing team league1).
  --- opts: { bypassSkillGate = true|false }
  local function prepareExternalOfferCommit(offerIn, state, sr)
    local n = state.simTime or 0
    local cfg = ownerServices.loadCfg()
    local out = {}
    for k, v in pairs(offerIn) do
      out[k] = v
    end
    out.disciplineId = out.disciplineId or ownerServices.DISCIPLINE_ROAD
    out.phase = "committed"
    out.committedAt = n
    local deadlineMin =
      math.max(1, tonumber(out.startDeadlineMinutes) or tonumber(cfg.defaultStartDeadlineMinutes) or 60)
    -- Board offers can carry small startDeadlineMinutes; simTime is coarse (see freContracts state.updateSimTime).
    if out.racingTeamBusinessOffer == true then deadlineMin = math.max(60, deadlineMin) end
    out.startDeadlineAt = n + deadlineMin
    sr.offer = out
    sr.nextGenAt = out.startDeadlineAt

    return out, n
  end

  local function validateExternalOfferAdmission(offerIn, opts)
    if not (overhaul_career_career and overhaul_career_career.isActive()) then
      return false, "Career not active."
    end
    if type(offerIn) ~= "table" then return false, "Missing offer." end
    local bypassSkillGate = type(opts) == "table" and opts.bypassSkillGate == true
    if not bypassSkillGate and not ownerServices.skillOk(ownerServices.DISCIPLINE_ROAD) then
      return false, "Road Racing level 15 and an Easy license are required."
    end
    if not ownerServices.hasSanctionedForRoadRacing() then
      return false, "No sanctioned racing on this map."
    end
    if type(offerIn.raceName) ~= "string" or not ownerServices.isSanctionedRaceNameConfigured(offerIn.raceName) then
      return false, "Unsupported sanctioned race."
    end

    return true, nil
  end

  function M.commitAndNavigateExternalOffer(offerIn, opts)
    local admitted, admissionReason = validateExternalOfferAdmission(offerIn, opts)
    if not admitted then return ownerServices.commitExternalFail(admissionReason) end

    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local existing = sr.offer
    if existing and existing.phase == "racing" then
      return ownerServices.commitExternalFail("Finish or abort the race first.")
    end
    if existing and existing.phase == "committed" then
      return ownerServices.commitExternalFail("A sanctioned race is already committed.")
    end

    -- Player-alongside races must respect fleet cooldown without clearing the pending proxy request.
    if
      offerIn.playerProxyAlongsideRace == true
      and offerIn.businessId ~= nil
      and (overhaul_career_career and overhaul_career_career.isActive())
    then
      local rem = tonumber(
        overhaul_career_business_racingTeam_racingTeam.getPlayerPostRaceCooldownRemainingSec(offerIn.businessId)
      ) or 0
      if rem > 0 then
        local mins = math.ceil(rem / 60)
        return ownerServices.commitExternalFail(string.format("Player cooldown active (%d min remaining).", mins))
      end
    end

    local previousNextGenAt = sr.nextGenAt
    local out, n = prepareExternalOfferCommit(offerIn, state, sr)
    local ok, reason = pushDispatchForOffer(out)
    if not ok then
      sr.offer, sr.nextGenAt = existing, previousNextGenAt
      return ownerServices.commitExternalFail(reason)
    end

    runtime.dispatchUiActive = true
    overhaul_events_fre_state.refreshMaintenanceSchedule(n)
    overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_commit_external")
    require("overhaul/lib/save/store").request("sanctionedRacing:commitAndNavigateExternalOffer")

    overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_navigate_external")
    ownerServices.srTrace(
      string.format(
        "commitAndNavigateExternalOffer OK id=%s raceName=%s teamOffer=%s lapCount=%s",
        tostring(out.id),
        tostring(out.raceName),
        tostring(out.racingTeamBusinessOffer == true),
        tostring(out.lapCount)
      )
    )
    return true, nil
  end

  function M.rescheduleSanctionedRace()
    if not (overhaul_career_career and overhaul_career_career.isActive()) then return false, "Career not active." end
    if not ownerServices.skillOk(ownerServices.DISCIPLINE_ROAD) then
      return false, "Road Racing level 15 and an Easy license are required."
    end
    local state = overhaul_events_fre_state.getState()
    local sr = ownerServices.ensureSrState(state)
    local offer = sr.offer
    if not offer or type(offer.raceName) ~= "string"
      or not ownerServices.isSanctionedRaceNameConfigured(offer.raceName) then
      return false, "No sanctioned race."
    end
    if offer.phase == "racing" then return false, "Finish or abort the race first." end
    if offer.phase ~= "committed" then return false, "Commit to a race first." end
    local ctf = overhaul_events_competitiveTrackFlow
    if ctf then
      if ctf.clearSanctionedParkingStagingUi then ctf.clearSanctionedParkingStagingUi() end
      if ctf.cancelCompetitiveGridFlow then ctf.cancelCompetitiveGridFlow() end
      if ctf.leaveTrackFlowAfterRace then ctf.leaveTrackFlowAfterRace() end
    end
    local aiRacers = overhaul_events_aiRacers
    if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
    local fe = overhaul_events_host
    if fe and fe.clearSanctionedDispatchStaging then fe.clearSanctionedDispatchStaging() end
    runtime.dispatchUiActive = false
    overhaul_events_fre_ui.emitUiStateUpdate("sanctioned_reschedule")
    return true, nil
  end

  return {}
end

return lib

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, onScopeDispose, ref } from "vue"
import { defineStore, storeToRefs } from "pinia"
import { lua } from "@/bridge"
import { showErrorMessage } from "./businessBridge.js"
import { useBusinessSessionStore } from "./businessSessionStore.js"

// Racing team tab: league, sponsors, race offers, proxy-driver races and the career-sim clock poll. Calls go through
// the manager `perform` endpoint. The store is built from groups that share the session refs: derived league values,
// the sim clock poll, offer actions, proxy race actions, driver assignments, invites and sponsors, and listeners.

/** League, invite and sponsor values read from the business data; each is a computed and is only read when used. */
function createRacingTeamDerivedState({ businessData }) {
  const league2Invite = computed(() => {
    const w = businessData.value?.league2Invite ?? businessData.value?.wcaraInvite
    if (!w || typeof w !== "object") {
      return {
        visible: false,
        acronym: "ARA",
        orgName: "Amateur Racing Association",
        fee: 1500,
        feeEarly: 1500,
        feeLate: 2500
      }
    }
    return w
  })

  const racingTeamLeagueDisplayNames = computed(() => {
    const m = businessData.value?.racingTeamLeagueDisplayNames
    return m && typeof m === "object" && !Array.isArray(m) ? m : {}
  })

  const racingTeamSponsors = computed(() => {
    const s = businessData.value?.racingTeamSponsors
    if (!s || typeof s !== "object") {
      return {
        available: [],
        active: [],
        sponsorSlots: 2,
        sponsorSlotsUsed: 0,
        bonusMoneyTotal: 0,
        bonusXpTotal: 0
      }
    }
    return s
  })

  const currentLeague = computed(() => businessData.value?.currentLeague || "league1")

  const currentLeagueRank = computed(() => {
    const m = String(currentLeague.value).match(/^league(\d+)$/)
    return m ? Number(m[1]) : 1
  })

  const isRacingTeamLeague2Plus = computed(() => currentLeagueRank.value >= 2)
  return { league2Invite, racingTeamLeagueDisplayNames, racingTeamSponsors, currentLeague, currentLeagueRank, isRacingTeamLeague2Plus }
}

/** Owns the poll timer; the clock ref itself is created by the store so its creation order does not change. */
function createRacingTeamSimPoll({ businessData, isMenuActive, hasCapability, racingTeamCareerSimTime }) {
  let racingTeamSimPollId = null
  let pollGeneration = 0
  let inFlight = false

  /** Poll career sim time while scheduled races or post-race driver cooldowns need a live clock. */
  const racingTeamNeedsCareerSimPoll = () => {
    if (!hasCapability("careerSimTime")) return false
    const techs = businessData.value?.techs
    if (!Array.isArray(techs)) return false
    const now = Number(racingTeamCareerSimTime.value)
    for (const t of techs) {
      if (!t || t.fired) continue
      if (t.pendingRaceOffer) {
        const st = t.pendingRaceOffer.scheduledRaceSimTime
        if (st !== undefined && st !== null && st !== "") return true
      }
      const cd = Number(t.racingCooldownUntilSimTime)
      if (Number.isFinite(cd)) {
        if (!Number.isFinite(now)) return true
        if (cd > now) return true
      }
      const wallCd = Number(t.postRaceCooldownReadyWallEpoch)
      if (Number.isFinite(wallCd) && wallCd > Math.floor(Date.now() / 1000)) {
        return true
      }
    }
    return false
  }

  const stopRacingTeamSimPoll = () => {
    pollGeneration++
    if (racingTeamSimPollId != null) {
      clearInterval(racingTeamSimPollId)
      racingTeamSimPollId = null
    }
    racingTeamCareerSimTime.value = null
  }

  const syncRacingTeamSimPoll = () => {
    const shouldRun =
      isMenuActive.value && hasCapability("careerSimTime") && racingTeamNeedsCareerSimPoll()

    if (!shouldRun) {
      stopRacingTeamSimPoll()
      return
    }

    if (racingTeamSimPollId != null) {
      return
    }

    const generation = ++pollGeneration
    const tick = async () => {
      if (inFlight) return
      if (!isMenuActive.value || !racingTeamNeedsCareerSimPoll()) { stopRacingTeamSimPoll(); return }
      inFlight = true
      try {
        const t = await lua.overhaul_career_business_computer.getRacingTeamCareerSimTime()
        const n = Number(t)
        if (generation === pollGeneration && isMenuActive.value && Number.isFinite(n) && racingTeamCareerSimTime.value !== n) {
          racingTeamCareerSimTime.value = n
        }
      } catch (e) {
      } finally {
        inFlight = false
      }
    }
    void tick()
    racingTeamSimPollId = window.setInterval(() => {
      void tick()
    }, 5000)
  }
  return { stopRacingTeamSimPoll, syncRacingTeamSimPoll }
}

function createRacingTeamOfferActions({ businessType, luaBusinessId }) {
  const acceptRacingTeamRaceOffer = async (offerId, techId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    if (techId === undefined || techId === null || techId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "acceptRacingTeamRaceOffer", {offerId: offerId, techId: techId})
      if (typeof success === "string") return success
      return !!success
    } catch (error) {
      console.error("[acceptRacingTeamRaceOffer]", error)
      showErrorMessage("Could not reach the racing team service (Lua/bridge error). Check the log.")
      return false
    }
  }

  const listLeague1FleetVehiclesForSanctionedOffer = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return []
    try {
      const rows =
        await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "listLeague1FleetVehiclesForSanctionedOffer", {offerId: offerId})
      return Array.isArray(rows) ? rows : []
    } catch (error) {
      console.error("[listLeague1FleetVehiclesForSanctionedOffer]", error)
      return []
    }
  }

  const listLeague2FleetVehiclesForSanctionedOffer = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return []
    try {
      const rows =
        await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "listLeague2FleetVehiclesForSanctionedOffer", {offerId: offerId})
      return Array.isArray(rows) ? rows : []
    } catch (error) {
      console.error("[listLeague2FleetVehiclesForSanctionedOffer]", error)
      return []
    }
  }

  const acceptRacingTeamRaceOfferAsPlayer = async (offerId, fleetVehicleId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    if (fleetVehicleId === undefined || fleetVehicleId === null || fleetVehicleId === "") {
      showErrorMessage("Pick a fleet car before racing (fleet vehicle id missing).")
      return false
    }
    try {
      // eslint-disable-next-line no-console
      console.warn("[L1PLAYER] bridge acceptRacingTeamRaceOfferAsPlayer", { bid, offerId, fleetVehicleId })
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "acceptRacingTeamRaceOfferAsPlayer", {offerId: offerId, fleetVehicleId: fleetVehicleId})
      // eslint-disable-next-line no-console
      console.warn("[L1PLAYER] bridge raw success", success, typeof success)
      if (typeof success === "string") return success
      return !!success
    } catch (error) {
      console.error("[acceptRacingTeamRaceOfferAsPlayer]", error)
      showErrorMessage("Could not reach the racing team service (Lua/bridge error). Check the log.")
      return false
    }
  }

  const acceptRacingTeamRaceOfferAsPlayerAlongsideProxy = async (offerId, fleetVehicleId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    if (fleetVehicleId === undefined || fleetVehicleId === null || fleetVehicleId === "") {
      showErrorMessage("Pick a fleet car before racing (fleet vehicle id missing).")
      return false
    }
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "acceptRacingTeamRaceOfferAsPlayerAlongsideProxy", {offerId: offerId, fleetVehicleId: fleetVehicleId})
      if (typeof success === "string") return success
      return !!success
    } catch (error) {
      console.error("[acceptRacingTeamRaceOfferAsPlayerAlongsideProxy]", error)
      showErrorMessage("Could not reach the racing team service (Lua/bridge error). Check the log.")
      return false
    }
  }

  const declineRacingTeamRaceOffer = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "declineRacingTeamRaceOffer", {offerId: offerId})
      return !!success
    } catch (error) {
      console.error("[declineRacingTeamRaceOffer]", error)
      return false
    }
  }
  return {
    acceptRacingTeamRaceOffer,
    listLeague1FleetVehiclesForSanctionedOffer,
    listLeague2FleetVehiclesForSanctionedOffer,
    acceptRacingTeamRaceOfferAsPlayer,
    acceptRacingTeamRaceOfferAsPlayerAlongsideProxy,
    declineRacingTeamRaceOffer
  }
}

function createRacingTeamProxyRaceActions({ businessId, businessType, luaBusinessId }) {
  const requestProxyDriverRace = async (opts) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) {
      console.warn("[businessComputerStore] requestProxyDriverRace: missing businessId")
      return { ok: false, err: "no_business" }
    }

    const driverId = opts && opts.driverId
    if (driverId === undefined || driverId === null || driverId === "") {
      console.warn("[businessComputerStore] requestProxyDriverRace: missing driverId", { businessId: bid, opts })
      return { ok: false, err: "missing_driver_id" }
    }
    try {
      const o = { ...(opts || {}), businessId: bid }
      const res = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: o.businessId}, "requestProxyDriverRace", o)
      console.info("[businessComputerStore] requestProxyDriverRace response", { businessId: bid, driverId, res })
      return res
    } catch (error) {
      console.error("[businessComputerStore] requestProxyDriverRace: lua bridge error", error)
      return { ok: false, err: "lua_error" }
    }
  }

  const clearProxyDriverRaceRequest = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return
    try {
      await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "clearProxyDriverRaceRequest", {})
    } catch (error) {
    }
  }

  const getProxyDriverRaceRequest = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return null
    try {
      return await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "getProxyDriverRaceRequest", {})
    } catch (error) {
      return null
    }
  }

  const beginRacingTeamProxyRaceFromBusinessComputer = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return { ok: false, err: "no_business" }
    try {
      // Show team loading overlay BEFORE the Lua bridge call. The Lua side does teleport +
      // enterVehicle synchronously on a single tick; without painting the overlay first the
      // player sees the world transform before the loading screen appears.
      // Use enterRacingTeamProxyStagingLoadingEarly (loading overlay only) rather than
      // preflightRacingTeamProxySpectateUi (which also applies spectator-minimal UI) — this
      // path is "I'm actually driving", not spectate.
      try {
        await lua.overhaul_career_business_computer.enterRacingTeamProxyStagingLoadingEarly()
      } catch (_e) {
        /* optional on older builds */
      }
      await yieldForProxyTeamLoadingPaint()
      return await lua.overhaul_career_business_computer.beginRacingTeamProxyRaceFromBusinessComputer(
        bid
      )
    } catch (error) {
      return { ok: false, err: "lua_error" }
    }
  }

  /** Lets Vue composite the team loading overlay before arm+begin (same Lua call stack otherwise never paints). */
  const yieldForProxyTeamLoadingPaint = () =>
    new Promise((resolve) => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => resolve())
      })
    })

  const simulateRacingTeamProxyRace = async (opts) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) {
      return { ok: false, err: "no_business" }
    }
    const o = { ...(opts || {}), businessId: bid }
    try {
      try {
        await lua.overhaul_career_business_computer.preflightRacingTeamProxySpectateUi(bid)
      } catch (_e) {
        /* optional on older builds */
      }
      await yieldForProxyTeamLoadingPaint()
      return await lua.overhaul_career_business_computer.simulateRacingTeamProxyRace(o)
    } catch (error) {
      return { ok: false, err: "lua_error" }
    }
  }

  const isProxyScheduledDriverFleetOverpowered = async (driverId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return { overpowered: false }
    const tid = Number(driverId)
    if (!Number.isFinite(tid)) return { overpowered: false }
    try {
      return await lua.overhaul_career_business_computer.isProxyScheduledDriverFleetOverpowered(
        String(bid),
        tid
      )
    } catch (_e) {
      return { overpowered: false }
    }
  }

  const isArmedProxyFleetOverpoweredForRequest = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return { overpowered: false }
    try {
      return await lua.overhaul_career_business_computer.isArmedProxyFleetOverpoweredForRequest(
        String(bid)
      )
    } catch (_e) {
      return { overpowered: false }
    }
  }

  const cancelRacingTeamProxySession = async (bid) => {
    const id = bid != null && bid !== "" ? bid : businessId.value
    if (!id) return { ok: false, err: "no_business" }
    try {
      return await lua.overhaul_career_business_computer.cancelRacingTeamProxySession(String(id))
    } catch (error) {
      return { ok: false, err: "lua_error" }
    }
  }

  const cancelRacingTeamProxyScheduledRace = async (driverId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return { ok: false, err: "no_business" }
    const tid = Number(driverId)
    if (!Number.isFinite(tid)) return { ok: false, err: "missing_business_or_driver" }
    try {
      return await lua.overhaul_career_business_computer.cancelRacingTeamProxyScheduledRace(
        String(bid),
        tid
      )
    } catch (error) {
      return { ok: false, err: "lua_error" }
    }
  }
  return {
    requestProxyDriverRace,
    clearProxyDriverRaceRequest,
    getProxyDriverRaceRequest,
    beginRacingTeamProxyRaceFromBusinessComputer,
    simulateRacingTeamProxyRace,
    isProxyScheduledDriverFleetOverpowered,
    isArmedProxyFleetOverpoweredForRequest,
    cancelRacingTeamProxySession,
    cancelRacingTeamProxyScheduledRace
  }
}

function createRacingTeamDriverActions({ businessId, businessType, luaBusinessId, hasCapability, ownerModule, loadBusinessData }) {
  const assignFleetVehicleToDriver = async (techId, vehicleId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || !hasCapability('driverAssignments')) return false
    try {
      return await ownerModule().assignFleetVehicleToDriver(
        bid,
        techId,
        vehicleId
      )
    } catch (error) {
      return false
    }
  }

  const assignRolledProxyRaceToDriver = async (techId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || techId === undefined || techId === null || techId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "assignRolledProxyRaceToDriver", {techId: techId})
      const ok = !!success
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      } else {
        showErrorMessage(
          "Could not roll a proxy race. Assign a fleet car, finish other work first, or drive on a map with sanctioned races in aiRacingConfig."
        )
      }
      return ok
    } catch (error) {
      return false
    }
  }
  return { assignFleetVehicleToDriver, assignRolledProxyRaceToDriver }
}

function createRacingTeamInviteAndSponsorActions({ businessId, businessType, luaBusinessId, loadBusinessData }) {
  const acceptLeague2Invite = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return false
    try {
      const result = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "acceptLeague2Invite", {})
      let ok = false
      if (Array.isArray(result)) {
        ok = result[0] === true || result[0] === "true" || result[0] === 1
        if (!ok && result[1] === "insufficient_funds") {
          showErrorMessage("Insufficient funds in the business account.")
        }
      } else {
        ok = !!result
      }
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return ok
    } catch (error) {
      return false
    }
  }

  const declineLeague2Invite = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "declineLeague2Invite", {})
      const ok = !!success
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return ok
    } catch (error) {
      return false
    }
  }

  /** "Later" on league-2 invite: move promo to Goals tab without declining (Lua pushes goals payload). */
  const racingTeamLeague2InviteLater = async () => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined) return false
    try {
      await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "racingTeamMilestoneLeague2Later", {})
      await loadBusinessData(businessType.value, businessId.value)
      return true
    } catch (error) {
      return false
    }
  }

  const acceptRacingTeamSponsorOffer = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "acceptRacingTeamSponsorOffer", {offerId: offerId})
      const ok = !!success
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return ok
    } catch (error) {
      return false
    }
  }

  const declineRacingTeamSponsorOffer = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "declineRacingTeamSponsorOffer", {offerId: offerId})
      const ok = !!success
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return ok
    } catch (error) {
      return false
    }
  }

  const dropRacingTeamSponsorActive = async (offerId) => {
    const bid = luaBusinessId()
    if (bid === null || bid === undefined || offerId === undefined || offerId === null || offerId === "") return false
    try {
      const success = await lua.overhaul_career_business_manager.perform({type: businessType.value, id: bid}, "dropRacingTeamSponsorActive", {offerId: offerId})
      const ok = !!success
      if (ok) {
        await loadBusinessData(businessType.value, businessId.value)
      }
      return ok
    } catch (error) {
      return false
    }
  }
  return {
    acceptLeague2Invite,
    declineLeague2Invite,
    racingTeamLeague2InviteLater,
    acceptRacingTeamSponsorOffer,
    declineRacingTeamSponsorOffer,
    dropRacingTeamSponsorActive
  }
}

function createRacingTeamListeners({ businessId, businessData, isMenuActive, hasCapability }) {
  const handleRaceOffersUpdated = (data) => {
    if (!isMenuActive.value) return
    if (String(data.businessId) !== String(businessId.value)) return
    businessData.value = {
      ...businessData.value,
      raceOffers: Array.isArray(data.raceOffers) ? data.raceOffers : businessData.value.raceOffers,
      raceOffersLevelId: data.raceOffersLevelId ?? businessData.value.raceOffersLevelId,
      raceOffersNextRefreshAt: data.raceOffersNextRefreshAt ?? businessData.value.raceOffersNextRefreshAt,
      raceOffersMessage: data.raceOffersMessage ?? businessData.value.raceOffersMessage,
      racingTeamProxyArmed:
        data.racingTeamProxyArmed !== undefined ? data.racingTeamProxyArmed : businessData.value.racingTeamProxyArmed,
    }
  }

  const handleRacingTeamGoalsUpdated = (data) => {
    if (!isMenuActive.value) return
    if (!data || String(data.businessId) !== String(businessId.value)) return
    if (!hasCapability("goals")) return
    const next = { ...businessData.value }
    if (data.currentGoal !== undefined) next.currentGoal = data.currentGoal
    if (data.currentLeague !== undefined) next.currentLeague = data.currentLeague
    if (data.completedGoals !== undefined) next.completedGoals = data.completedGoals
    if (data.league2Invite !== undefined) next.league2Invite = data.league2Invite
    if (data.vehicles !== undefined) next.vehicles = Array.isArray(data.vehicles) ? data.vehicles : []
    businessData.value = next
  }
  return { handleRaceOffersUpdated, handleRacingTeamGoalsUpdated }
}

export const useBusinessRacingTeamStore = defineStore("overhaulBusinessRacingTeam", () => {
  const sessionStore = useBusinessSessionStore()
  const { businessData, isMenuActive, businessId, businessType } = storeToRefs(sessionStore)
  const { luaBusinessId, hasCapability, ownerModule, loadBusinessData, onBusinessDataLoaded } = sessionStore

  /** Career sim clock (seconds) for racing team scheduled races — matches Lua getCareerSimTime, not wall clock. */
  const racingTeamCareerSimTime = ref(null)

  const racing = { businessId, businessType, businessData, isMenuActive, luaBusinessId, hasCapability, ownerModule, loadBusinessData }
  const { league2Invite, racingTeamLeagueDisplayNames, racingTeamSponsors, currentLeague, currentLeagueRank, isRacingTeamLeague2Plus } = createRacingTeamDerivedState(racing)
  const { stopRacingTeamSimPoll, syncRacingTeamSimPoll } = createRacingTeamSimPoll({ ...racing, racingTeamCareerSimTime })
  onScopeDispose(stopRacingTeamSimPoll)
  const { acceptRacingTeamRaceOffer, listLeague1FleetVehiclesForSanctionedOffer, listLeague2FleetVehiclesForSanctionedOffer, acceptRacingTeamRaceOfferAsPlayer, acceptRacingTeamRaceOfferAsPlayerAlongsideProxy, declineRacingTeamRaceOffer } = createRacingTeamOfferActions(racing)
  const { requestProxyDriverRace, clearProxyDriverRaceRequest, getProxyDriverRaceRequest, beginRacingTeamProxyRaceFromBusinessComputer, simulateRacingTeamProxyRace, isProxyScheduledDriverFleetOverpowered, isArmedProxyFleetOverpoweredForRequest, cancelRacingTeamProxySession, cancelRacingTeamProxyScheduledRace } = createRacingTeamProxyRaceActions(racing)
  const { assignFleetVehicleToDriver, assignRolledProxyRaceToDriver } = createRacingTeamDriverActions(racing)
  const { acceptLeague2Invite, declineLeague2Invite, racingTeamLeague2InviteLater, acceptRacingTeamSponsorOffer, declineRacingTeamSponsorOffer, dropRacingTeamSponsorActive } = createRacingTeamInviteAndSponsorActions(racing)
  const { handleRaceOffersUpdated, handleRacingTeamGoalsUpdated } = createRacingTeamListeners(racing)

  onBusinessDataLoaded(() => {
    if (hasCapability("careerSimTime")) {
      syncRacingTeamSimPoll()
    }
  })

  return {
    racingTeamCareerSimTime,
    league2Invite,
    racingTeamLeagueDisplayNames,
    racingTeamSponsors,
    currentLeague,
    currentLeagueRank,
    isRacingTeamLeague2Plus,
    stopRacingTeamSimPoll,
    syncRacingTeamSimPoll,
    acceptRacingTeamRaceOffer,
    listLeague1FleetVehiclesForSanctionedOffer,
    listLeague2FleetVehiclesForSanctionedOffer,
    acceptRacingTeamRaceOfferAsPlayer,
    acceptRacingTeamRaceOfferAsPlayerAlongsideProxy,
    declineRacingTeamRaceOffer,
    requestProxyDriverRace,
    clearProxyDriverRaceRequest,
    getProxyDriverRaceRequest,
    beginRacingTeamProxyRaceFromBusinessComputer,
    simulateRacingTeamProxyRace,
    isProxyScheduledDriverFleetOverpowered,
    isArmedProxyFleetOverpoweredForRequest,
    cancelRacingTeamProxySession,
    cancelRacingTeamProxyScheduledRace,
    assignFleetVehicleToDriver,
    acceptLeague2Invite,
    declineLeague2Invite,
    racingTeamLeague2InviteLater,
    assignRolledProxyRaceToDriver,
    acceptRacingTeamSponsorOffer,
    declineRacingTeamSponsorOffer,
    dropRacingTeamSponsorActive,
    handleRaceOffersUpdated,
    handleRacingTeamGoalsUpdated
  }
})

// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services"
import { showToast } from "@/services/toast"
import { clearPhoneLayoutCache } from "../utils/phoneLayoutCache"
import { resetSeenMarketplaceOffers } from "../composables/usePhoneMarketplaceListings"
import { resetPhoneSettings } from "../composables/usePhoneSettings"

export const PROFILE_NAME_MAX_LENGTH = 100
export const PROFILE_NAME_PATTERN = /^[a-zA-Z0-9_]+$/
export const SAVE_NAME_MAX_LENGTH = 100
export const INVALID_SAVE_NAME_CHARS = /[<>:"/\\|?*\u0000-\u001F]/

function showProfileToast(kind) {
  showToast({
    type: "info",
    message: $translate.contextTranslate(`ui.career.notification.${kind}`),
    timeout: 5,
  })
}

/* Phone caches belong to the previous career until Lua sends fresh state. */
function clearPhoneCareerCaches() {
  try { clearPhoneLayoutCache() } catch (_) {}
  try { resetSeenMarketplaceOffers() } catch (_) {}
  try { resetPhoneSettings() } catch (_) {}
  try { sessionStorage.removeItem("phone_last_money") } catch (_) {}
}

/** Dropping the loading screen at the main menu sends the UI back there, so say why out loud. */
function showErrorToast(message) {
  showToast({
    type: "error",
    message,
    timeout: 10,
  })
}

/**
 * Waits until the game's loading screen has actually faded in over everything else.
 * Its fade is a full second, and Lua work started before that finishes freezes the game
 * mid-fade, so the screen looks like it arrived *after* whatever it was meant to cover.
 */
function waitForLoadingScreenCover(timeoutMs = 1800) {
  return new Promise(resolve => {
    if (typeof requestAnimationFrame !== "function" || typeof document === "undefined") {
      setTimeout(() => resolve(false), 1100)
      return
    }
    const startedAt = Date.now()
    const check = () => {
      const screen = document.querySelector("dialog.loading-screen")
      if (screen) {
        const opacity = Number(window.getComputedStyle(screen).opacity)
        if (!Number.isFinite(opacity) || opacity >= 0.99) return resolve(true)
      }
      if (Date.now() - startedAt >= timeoutMs) return resolve(false)
      requestAnimationFrame(check)
    }
    requestAnimationFrame(check)
  })
}

export const useProfilesStore = defineStore("overhaulProfiles", () => {
  const bridge = useBridge()

  async function loadProfile(
    profileName,
    tutorialEnabled,
    isAdd = false,
    difficultyMode = null,
    challengeSelection = null,
    cheatsMode = false,
    startingMap = null,
    experimentalMaintenanceEnabled = false,
    startingGarageMode = "default",
    startingGarageId = null,
    policeEnabled = true,
    xpMultiplier = null,
    economyMultiplier = null,
    startingCash = null,
    careerStartMode = null,
    sandboxEconomyProfile = null,
    sandboxXpProfile = null,
    employmentApprenticeship = true
  ) {
    if (!profileName) {
      return false
    }

    if (profileName.length > PROFILE_NAME_MAX_LENGTH && isAdd) {
      return false
    }

    const isGarageActive = await lua.overhaul_integration_services_garageMode.isActive()
    if (isGarageActive) {
      await lua.overhaul_integration_services_garageMode.stop()
    }

    if (/^ +| +$/.test(profileName)) profileName = profileName.replace(/^ +| +$/g, "")
    const hardcoreMode = difficultyMode === "hardcore" ? true : null
    const mapForStart = difficultyMode === "hardcore" ? null : startingMap
    // BeamNG 0.39 bridge signature is (name, autosave, startingOptions: Object).
    // Positional legacy args after the 3rd were dropped / mistyped (boolean as Object).
    clearPhoneCareerCaches()
    const loaded = await lua.overhaul_career_career.createOrLoadCareerAndStart(profileName, null, {
      hardcoreMode: hardcoreMode === true,
      challengeId: challengeSelection,
      cheatsMode: !!cheatsMode,
      startingMap: mapForStart,
      difficultyMode,
      experimentalMaintenanceEnabled: !!experimentalMaintenanceEnabled,
      startingGarageMode,
      startingGarageId,
      policeEnabled,
      xpMultiplier,
      economyMultiplier,
      startingCash,
      careerStartMode,
      // Vanilla .39 starting-mode key; keep both so Lua/overlay paths agree.
      startMode: careerStartMode || undefined,
      sandboxEconomyProfile,
      sandboxXpProfile,
      employmentApprenticeship: employmentApprenticeship !== false,
    })
    if (loaded === false) return false

    showProfileToast(isAdd ? "added" : "loaded")
    return true
  }

  async function getSaveFolders(profileId) {
    if (!profileId) return []
    const folders = await lua.overhaul_career_career.getSaveFoldersForProfile(profileId)
    return Array.isArray(folders) ? folders : []
  }

  async function loadExistingProfile(profileId, saveFolderName = null, employmentApprenticeship = null) {
    if (!profileId) return false

    const isGarageActive = await lua.overhaul_integration_services_garageMode.isActive()
    if (isGarageActive) {
      await lua.overhaul_integration_services_garageMode.stop()
    }

    const options = {}
    if (employmentApprenticeship !== null && employmentApprenticeship !== undefined) {
      options.employmentApprenticeship = employmentApprenticeship === true
    }

    clearPhoneCareerCaches()
    const loaded = await lua.overhaul_career_career.createOrLoadCareerAndStart(profileId, saveFolderName, options)
    if (loaded === false) return false
    showProfileToast("loaded")
    return true
  }

  async function loadProfileSave(profileId, saveFolderName, employmentApprenticeship = null) {
    if (!profileId || !saveFolderName) return false
    return loadExistingProfile(profileId, saveFolderName, employmentApprenticeship)
  }

  /**
   * Raises the real loading screen before the migrated copy is written, so pressing the
   * button loads instead of freezing the modal.
   *
   * The screen lives in this same Vue app, so it is raised locally first — waiting on the
   * Lua round-trip would cost frames before anything appears. The Lua request follows to
   * take ownership: it is ref-counted per tag, so the career load that comes next keeps
   * the screen up without it dropping in between. Only once the screen is opaque does the
   * caller get to run the copy, which blocks the game for a while.
   */
  async function startMigrationLoadingScreen() {
    showLoadingScreenLocally(true)
    let held = false
    try {
      held = (await lua.overhaul_career_career.beginLegacySaveMigrationLoading()) !== false
    } catch (_) {}
    await waitForLoadingScreenCover()
    return held
  }

  async function stopMigrationLoadingScreen() {
    let exited = false
    try {
      exited = (await lua.overhaul_career_career.endLegacySaveMigrationLoading()) === true
    } catch (_) {}
    // Lua never took ownership, so nothing else is going to take the local raise back down.
    if (!exited) showLoadingScreenLocally(false)
  }

  /** No gotoMainMenu key: hiding it locally must never navigate on its own. */
  function showLoadingScreenLocally(active) {
    const bus = bridge?.events || (typeof window !== "undefined" ? window.vueEventBus : null)
    try {
      bus?.emit("LoadingScreen", { active: !!active })
    } catch (_) {}
  }

  async function loadPreparedMigration(profileId, saveFolderName = null) {
    if (!profileId) return false

    const isGarageActive = await lua.overhaul_integration_services_garageMode.isActive()
    if (isGarageActive) {
      await lua.overhaul_integration_services_garageMode.stop()
    }

    clearPhoneCareerCaches()
    const loaded = await lua.overhaul_career_career.createOrLoadCareerAndStart(profileId, saveFolderName, {
      legacyMigrationApproved: true,
    })
    if (loaded === false) return false
    showProfileToast("loaded")
    return true
  }

  async function saveCurrentAs(saveFolderName) {
    const trimmed = (saveFolderName || "").trim()
    if (!trimmed) return false
    await lua.overhaul_career_saveSystem.saveCurrent(false, true, trimmed)
    return true
  }

  async function removeSaveFolder(profileId, saveFolderName) {
    if (!profileId || !saveFolderName) return false
    return !!(await lua.overhaul_career_saveSystem.removeSaveFolder(profileId, saveFolderName))
  }

  return {
    loadProfile,
    loadExistingProfile,
    getSaveFolders,
    loadProfileSave,
    loadPreparedMigration,
    startMigrationLoadingScreen,
    stopMigrationLoadingScreen,
    showMigrationError: showErrorToast,
    saveCurrentAs,
    removeSaveFolder,
  }
})

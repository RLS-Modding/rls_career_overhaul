import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { $translate } from "@/services"

export const PROFILE_NAME_MAX_LENGTH = 100
export const PROFILE_NAME_PATTERN = /^[a-zA-Z0-9_]+$/

export const useProfilesStore = defineStore("profiles", () => {
  async function loadProfile(profileName, tutorialEnabled, isAdd = false, hardcoreMode = false, challengeSelection = null) {
    console.log("profileStore.loadProfile", profileName, tutorialEnabled, isAdd, hardcoreMode, challengeSelection)
    if (!profileName) {
      console.warn("profileStore.loadProfile: profileName is required. Not loading profile.")
      return false
    }

    if (profileName.length > PROFILE_NAME_MAX_LENGTH && isAdd) {
      console.warn("profileStore.loadProfile: profileName is too long. Not loading profile.")
      return false
    }

    const isGarageActive = await lua.extensions.gameplay_garageMode.isActive()
    if (isGarageActive) {
      console.log("profileStore.loadProfile: garage mode is active, stopping")
      await lua.extensions.gameplay_garageMode.stop()
      console.log("profileStore.loadProfile: garage mode is stopped")
    }

    console.log("profileStore.loadProfile: enabling tutorial", tutorialEnabled)
    const enableTutorialResult = await lua.career_career.enableTutorial(tutorialEnabled)
    const enableHardcoreModeResult = await lua.career_career.enableHardcoreMode(hardcoreMode)
    console.log("profileStore.loadProfile: enableTutorialResult", enableTutorialResult)
    console.log("profileStore.loadProfile: enableHardcoreModeResult", enableHardcoreModeResult)

    // Enable challenge for later start (like tutorial and hardcore mode)
    if (typeof challengeSelection === 'string' && challengeSelection.length > 0) {
      try {
        // Ensure challenges are discovered before enabling
        await lua.career_challengeModes.discoverChallenges()
        console.log("profileStore.loadProfile: enabling challenge", challengeSelection)
        const enableChallengeResult = await lua.career_career.enableChallenge(challengeSelection)
        console.log("profileStore.loadProfile: enableChallengeResult", enableChallengeResult)
      } catch (e) {
        console.warn("profileStore.loadProfile: enableChallenge failed", e)
      }
    }

    console.log("profileStore.loadProfile: creating or loading career and starting", profileName)
    if (/^ +| +$/.test(profileName)) profileName = profileName.replace(/^ +| +$/g, "")
    const createOrLoadCareerAndStartResult = await lua.career_career.createOrLoadCareerAndStart(profileName)
    console.log("profileStore.loadProfile: createOrLoadCareerAndStartResult", createOrLoadCareerAndStartResult)

    const toastrMessage = isAdd ? "added" : "loaded"

    window.globalAngularRootScope.$broadcast("toastrMsg", {
      type: "info",
      msg: $translate.contextTranslate(`ui.career.notification.${toastrMessage}`),
      config: {
        positionClass: "toast-top-right",
        toastClass: "beamng-message-toast",
        timeOut: 5000,
        extendedTimeOut: 1000,
      },
    })
  }

  return { loadProfile }
})

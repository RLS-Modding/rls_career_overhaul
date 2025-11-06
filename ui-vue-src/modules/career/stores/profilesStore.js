import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { $translate } from "@/services"

export const PROFILE_NAME_MAX_LENGTH = 100
export const PROFILE_NAME_PATTERN = /^[a-zA-Z0-9_]+$/

export const useProfilesStore = defineStore("profiles", () => {
  async function loadProfile(profileName, tutorialEnabled, isAdd = false, hardcoreMode = false, challengeSelection = null, cheatsMode = false, startingMap = null) {
    if (!profileName) {
      return false
    }

    if (profileName.length > PROFILE_NAME_MAX_LENGTH && isAdd) {
      return false
    }

    const isGarageActive = await lua.extensions.gameplay_garageMode.isActive()
    if (isGarageActive) {
      await lua.extensions.gameplay_garageMode.stop()
    }

    if (/^ +| +$/.test(profileName)) profileName = profileName.replace(/^ +| +$/g, "")
    await lua.career_career.createOrLoadCareerAndStart(profileName, null, tutorialEnabled, hardcoreMode, challengeSelection, cheatsMode, startingMap)

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

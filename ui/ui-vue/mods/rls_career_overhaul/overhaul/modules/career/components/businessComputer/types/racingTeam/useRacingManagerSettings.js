// Private manager settings; countdowns read the shared subscribed clock.
// Register both watchers here at the original setup position to preserve initialization and rollback order.
import { computed, ref, watch } from "vue"
import { lua } from "@/bridge"
import { safeLua } from "../../../../utils/safeLua.js"

export function useRacingManagerSettings({ sessionStore, racingTeamStore, scheduleUiSecondTick }) {
  const showManagerAutomationPanel = computed(() => {
    if (!sessionStore.hasCapability('raceOffers')) return false
    const lv = Number(sessionStore.businessData?.racingTeamManagerSkillLevel ?? 0)
    if (lv <= 0) return false
    return racingTeamStore.isRacingTeamLeague2Plus
  })

  const managerSkillLevel = computed(() => Number(sessionStore.businessData?.racingTeamManagerSkillLevel ?? 0))

  const managerAutoAssign = computed(() => sessionStore.businessData?.racingTeamManagerAutoAssign === true)

  const DEFAULT_MANAGER_INTERVAL_SEC = 1800

  const MANAGER_INTERVAL_SHORT = {
    600: "10m",
    1200: "20m",
    1800: "30m",
    2700: "45m",
    3600: "60m",
  }

  function managerIntervalShortLabel (sec, fullLabel) {
    const n = Number(sec)
    if (MANAGER_INTERVAL_SHORT[n]) return MANAGER_INTERVAL_SHORT[n]
    const m = Math.round(n / 60)
    if (Number.isFinite(m) && m > 0) return `${m}m`
    return String(fullLabel || sec)
  }

  const managerIntervalOptions = computed(() => {
    const opts = sessionStore.businessData?.racingTeamManagerAssignIntervalOptions
    const list = Array.isArray(opts) && opts.length
      ? opts
      : [
          { sec: 600, label: "10 minutes" },
          { sec: 1200, label: "20 minutes" },
          { sec: 1800, label: "30 minutes" },
          { sec: 2700, label: "45 minutes" },
          { sec: 3600, label: "60 minutes" },
        ]
    return list.map((o) => {
      const value = Number(o.sec)
      const label = String(o.label || o.sec)
      return {
        value,
        label,
        shortLabel: managerIntervalShortLabel(value, label),
      }
    })
  })

  const managerIntervalModel = ref(DEFAULT_MANAGER_INTERVAL_SEC)

  watch(
    () => sessionStore.businessData?.racingTeamManagerAssignIntervalSec,
    (sec) => {
      const n = Number(sec)
      if (!Number.isFinite(n) || n <= 0) return
      if (managerIntervalOptions.value.some((o) => o.value === n)) {
        managerIntervalModel.value = n
      }
    },
    { immediate: true }
  )

  function formatManagerCountdown (seconds) {
    const s = Math.max(0, Math.floor(Number(seconds) || 0))
    const m = Math.floor(s / 60)
    const r = s % 60
    if (m <= 0) return `${r}s`
    return r > 0 ? `${m}m ${r}s` : `${m}m`
  }

  const managerIntervalCountdownSec = computed(() => {
    void scheduleUiSecondTick.value
    if (!managerAutoAssign.value) return null
    const due = Number(sessionStore.businessData?.racingTeamManagerNextAssignWallEpoch)
    if (Number.isFinite(due) && due > 0) {
      return Math.max(0, Math.floor(due - scheduleUiSecondTick.value))
    }
    const expiry = sessionStore.businessData?.racingManagerExpiresAtSeconds
    if (Number.isFinite(expiry)) return Math.max(0, Math.ceil(expiry - scheduleUiSecondTick.value))
    const rem = Number(sessionStore.businessData?.racingTeamManagerAssignIntervalRemainingSec)
    return Number.isFinite(rem) ? Math.max(0, Math.floor(rem)) : null
  })

  const managerBookingTimerText = computed(() => {
    if (!showManagerAutomationPanel.value || !managerAutoAssign.value) return null
    const sec = managerIntervalCountdownSec.value
    if (sec === null) return null
    return `Next booking in ~${formatManagerCountdown(sec)}`
  })

  const managerAutoToggleBusy = ref(false)
  const managerIntervalBusy = ref(false)

  function selectManagerInterval (sec) {
    const n = Number(sec)
    if (!Number.isFinite(n) || n <= 0 || managerIntervalBusy.value) return
    if (managerIntervalModel.value === n) return
    managerIntervalModel.value = n
  }

  async function onManagerAutoToggle (ev) {
    const enabled = ev.target.checked
    managerAutoToggleBusy.value = true
    try {
      await lua.overhaul_career_business_racingTeam_racingTeam.setRacingTeamManagerAutoAssign(sessionStore.businessId, enabled)
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    } catch (err) {
      safeLua(() => { throw err }, "Set racing team manager auto-assign")
    } finally {
      managerAutoToggleBusy.value = false
    }
  }

  watch(managerIntervalModel, async (sec, prevSec) => {
    if (sec === prevSec || managerIntervalBusy.value) return
    if (!Number.isFinite(sec) || sec <= 0) return
    const stored = Number(sessionStore.businessData?.racingTeamManagerAssignIntervalSec)
    if (sec === stored) return
    managerIntervalBusy.value = true
    try {
      await lua.overhaul_career_business_racingTeam_racingTeam.setRacingTeamManagerAssignInterval(sessionStore.businessId, sec)
      await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    } catch (err) {
      safeLua(() => { throw err }, "Set racing team manager assign interval")
      const rollback = Number.isFinite(stored) && stored > 0 ? stored : DEFAULT_MANAGER_INTERVAL_SEC
      managerIntervalModel.value = rollback
    } finally {
      managerIntervalBusy.value = false
    }
  })

  async function onManagerSettingsUpdated (data) {
    if (!data || String(data.businessId) !== String(sessionStore.businessId)) return
    if (!sessionStore.businessType || !sessionStore.businessId) return
    await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
  }
  return {
    showManagerAutomationPanel,
    managerSkillLevel,
    managerAutoAssign,
    managerIntervalOptions,
    managerIntervalModel,
    managerIntervalCountdownSec,
    managerBookingTimerText,
    managerAutoToggleBusy,
    managerIntervalBusy,
    selectManagerInterval,
    onManagerAutoToggle,
    onManagerSettingsUpdated
  }
}

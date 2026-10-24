<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Racing team dev console (dev key only), house style: title + hint, a status notice, one panel per
     group with a caption and neutral buttons, destructive resets as quiet-danger, and the dev log in a
     slim-scrolling sheet. -->
<template>
  <div class="rls-house dev-console-tab">
    <header class="page-head">
      <h2 class="page-title">Dev Console</h2>
      <p class="hint">Racing team debug tools (dev key required). Changes save immediately.</p>
    </header>

    <p v-if="statusMessage" class="notice" :class="statusTone">{{ statusMessage }}</p>

    <section class="panel dev-console-section">
      <h3 class="caption">Goals</h3>
      <div class="dev-console-grid">
        <HouseButton compact :disabled="busy" @click="run('completeCurrentGoal')">
          Complete current goal
        </HouseButton>
        <HouseButton compact :disabled="busy" @click="run('completeAllLeagueGoals')">
          Complete all league goals
        </HouseButton>
        <HouseButton compact variant="quiet" :disabled="busy" @click="run('resetCurrentLeagueGoals')">
          Reset current league
        </HouseButton>
      </div>
    </section>

    <section class="panel dev-console-section">
      <h3 class="caption">Skills &amp; races</h3>
      <div class="dev-console-grid">
        <HouseButton compact :disabled="busy" @click="run('maxAllSkills')">
          Unlock all skills
        </HouseButton>
        <HouseButton compact :disabled="busy" @click="run('refreshRaceOffers')">
          Refresh race offers
        </HouseButton>
        <HouseButton compact :disabled="busy" @click="run('forceLeagueInvite')">
          Force league invite
        </HouseButton>
      </div>
    </section>

    <section class="panel dev-console-section">
      <h3 class="caption">Economy</h3>
      <div class="dev-console-grid">
        <HouseButton compact :disabled="busy" @click="run('injectMoney')">
          Inject money (+<span class="money"><BngIcon class="cur" :type="icons.beamCurrency" />1,000,000</span>)
        </HouseButton>
        <HouseButton compact :disabled="busy" @click="run('injectXp')">
          Inject XP (+20,000)
        </HouseButton>
      </div>
    </section>

    <section class="panel dev-console-section">
      <h3 class="caption">Waiting</h3>
      <p class="dev-console-hint">
        Clears cooldowns, makes scheduled races ready to spectate, skips the manager booking timer (and retries auto-assign), and refreshes offer-board timing.
      </p>
      <div class="dev-console-grid">
        <HouseButton compact :disabled="busy" @click="run('clearCooldowns')">
          Skip waiting
        </HouseButton>
      </div>
    </section>

    <section class="panel dev-console-section">
      <h3 class="caption">Destructive</h3>
      <p class="dev-console-hint">
        Soft reset keeps bank and fleet. Hard reset wipes fleet, drivers, sponsors, bank (then starting capital), goals, league, skills, and dyno peaks.
      </p>
      <div class="dev-console-grid">
        <HouseButton compact variant="quiet-danger" :disabled="busy" @click="onResetBusinessSoft">
          Reset progress (soft)
        </HouseButton>
        <HouseButton compact variant="danger" :disabled="busy" @click="onResetBusinessHard">
          Full reset (hard)
        </HouseButton>
      </div>
    </section>

    <section class="panel dev-console-log">
      <div class="dev-console-log__header">
        <h3 class="caption">Dev log</h3>
        <HouseButton compact variant="quiet" :disabled="busy" @click="onClearLog">
          Clear
        </HouseButton>
      </div>
      <pre ref="logBodyRef" class="scroll dev-console-log__body">{{ logText }}</pre>
    </section>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, nextTick } from "vue"
import { useBridge } from "@/bridge"
import { HouseButton, openHouseConfirmation } from "../../../house/index.js"
import { BngIcon, icons } from "@/common/components/base"
import { useBusinessSessionStore } from "../../../../stores/businessComputer/businessSessionStore.js"
import { safeLua } from "../../../../utils/safeLua.js"

const { lua, events } = useBridge()
const sessionStore = useBusinessSessionStore()
const busy = ref(false)
const statusMessage = ref("")
const logLines = ref([])
const logBodyRef = ref(null)

// status notice: red only when an action failed, neutral otherwise
const statusTone = computed(() => (/^(Failed|Action failed|Error)/.test(statusMessage.value) ? "bad" : null))

const logText = computed(() => {
  if (!logLines.value.length) {
    return "No dev log entries yet. Warnings and scan results appear here while the dev key is active."
  }
  return logLines.value.join("\n")
})

const LUA_ACTIONS = {
  completeCurrentGoal: "devConsoleRacingTeamCompleteCurrentGoal",
  completeAllLeagueGoals: "devConsoleRacingTeamCompleteAllLeagueGoals",
  resetCurrentLeagueGoals: "devConsoleRacingTeamResetCurrentLeagueGoals",
  maxAllSkills: "devConsoleRacingTeamMaxAllSkills",
  refreshRaceOffers: "devConsoleRacingTeamRefreshRaceOffers",
  forceLeagueInvite: "devConsoleRacingTeamForceLeagueInvite",
  clearCooldowns: "devConsoleRacingTeamClearCooldowns",
  resetBusinessSoft: "devConsoleRacingTeamResetBusinessSoft",
  resetBusinessHard: "devConsoleRacingTeamResetBusinessHard",
  injectXp: "devConsoleRacingTeamInjectXp",
  injectMoney: "devConsoleRacingTeamInjectMoney",
}

function parseLuaResult(result) {
  if (result && typeof result === "object" && !Array.isArray(result) && "ok" in result) {
    return { ok: result.ok === true, extra: result.error ?? null }
  }
  if (Array.isArray(result)) {
    return { ok: result[0] === true, extra: result[1] }
  }
  if (result === true || result?.success === true) {
    return { ok: true, extra: result?.error }
  }
  return { ok: false, extra: result?.error ?? result }
}

async function scrollLogToEnd() {
  await nextTick()
  const el = logBodyRef.value
  if (el) {
    el.scrollTop = el.scrollHeight
  }
}

function applyLogLines(lines) {
  logLines.value = Array.isArray(lines) ? lines.filter((l) => typeof l === "string") : []
  scrollLogToEnd()
}

function onDevLogEvent(data) {
  if (!data || typeof data !== "object") return
  if (data.clear === true) {
    logLines.value = []
    return
  }
  if (typeof data.text === "string" && data.text.length) {
    logLines.value = [...logLines.value, data.text]
    scrollLogToEnd()
  }
}

async function loadDevLog() {
  const bid = sessionStore.businessId
  if (!bid) return
  try {
    const result = await lua.overhaul_career_business_computer.devConsoleRacingTeamGetDevLog(bid)
    if (result?.ok === true && Array.isArray(result.lines)) {
      applyLogLines(result.lines)
    }
  } catch (e) {
    safeLua(() => { throw e }, "Load dev console log")
  }
}

async function onClearLog() {
  busy.value = true
  try {
    await lua.overhaul_career_business_computer.devConsoleRacingTeamClearDevLog()
    logLines.value = []
  } catch (e) {
    safeLua(() => { throw e }, "Clear dev console log")
  } finally {
    busy.value = false
  }
}

async function reload() {
  const bid = sessionStore.businessId
  const btype = sessionStore.businessType
  if (!bid || !btype) return
  await sessionStore.loadBusinessData(btype, bid)
}

async function run(actionKey) {
  const bid = sessionStore.businessId
  if (!bid) return
  const fnName = LUA_ACTIONS[actionKey]
  if (!fnName) return
  busy.value = true
  statusMessage.value = ""
  try {
    const result = await lua.overhaul_career_business_computer[fnName](bid)
    const { ok, extra } = parseLuaResult(result)
    if (!ok) {
      const err = typeof extra === "string" ? extra : null
      statusMessage.value = err ? `Failed: ${err}` : "Action failed."
    } else {
      statusMessage.value = "Done."
    }
    await reload()
  } catch (e) {
    safeLua(() => { throw e }, `Run dev console action ${actionKey}`)
    statusMessage.value = "Error — see log."
  } finally {
    busy.value = false
  }
}

async function onResetBusinessSoft() {
  const confirmed = await openHouseConfirmation(
    "Reset progress (soft)?",
    "Clears goal progress, returns league to league 1, and wipes skill tree upgrades. Bank balance and fleet vehicles are kept.",
    [
      { label: "Reset", value: true, extras: { default: true, destructive: true } },
      { label: "Cancel", value: false, extras: { cancel: true } },
    ]
  )
  if (!confirmed) return
  await run("resetBusinessSoft")
}

async function onResetBusinessHard() {
  const confirmed = await openHouseConfirmation(
    "Full reset (hard)?",
    "Wipes fleet, parts, drivers, sponsors, goals, league progress, skill tree, skill XP, dyno peaks, and race state. Bank is cleared then set to starting capital. The business stays owned.",
    [
      { label: "Full reset", value: true, extras: { default: true, destructive: true } },
      { label: "Cancel", value: false, extras: { cancel: true } },
    ]
  )
  if (!confirmed) return
  await run("resetBusinessHard")
}

onMounted(() => {
  events.on("racingTeam:devLog", onDevLogEvent)
  loadDevLog()
})

onUnmounted(() => {
  events.off("racingTeam:devLog", onDevLogEvent)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.dev-console-tab {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  max-width: 46em;
  min-height: 0;
}

.page-head {
  display: grid;
  gap: 0.3em;
}

.page-title {
  margin: 0;
  color: #fff;
  font-size: 1.4em;
  font-weight: 800;
  line-height: 1.15;
}

.page-head .hint {
  font-size: 0.9em;
}

.dev-console-section {
  gap: 0.6em;
}

.dev-console-hint {
  margin: 0;
  max-width: 40em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.4;
}

.dev-console-grid {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-2);
}

.dev-console-log {
  flex: 1;
  min-height: 0;
  grid-template-rows: auto minmax(0, 1fr);

  &__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }

  &__body {
    margin: 0;
    padding: 0.75em var(--inset);
    border-radius: var(--radius-panel);
    background: rgba(0, 0, 0, 0.35);
    color: var(--muted);
    font-family: ui-monospace, Consolas, monospace;
    font-size: 0.78em;
    line-height: 1.45;
    white-space: pre-wrap;
    word-break: break-word;
    min-height: 10em;
    max-height: 18em;
    overflow-x: hidden;
    overflow-y: auto;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

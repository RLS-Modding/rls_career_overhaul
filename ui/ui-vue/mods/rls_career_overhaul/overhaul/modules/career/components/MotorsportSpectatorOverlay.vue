<!-- Owns spectator controls and the spectating HUD state. EntryOverlayPopup owns input; motorsportEvents.lua owns the session;
     the Event display card is OverhaulEventDisplay.vue, which docks right while spectating. -->
<template>
  <EntryOverlayPopup :key="popupRevision" :active="detailsReady && (state.arrivalChoice || state.watching)" :blur="!state.watching" :can-cancel="!busy" @cancel="onBack" @leave="onLeave">
    <div ref="root">
    <div v-if="state.arrivalChoice" class="rls-house rls-house-card arrival-backdrop">
      <div class="panel arrival-choice">
        <div class="head" :class="arrivalTone"><h3 class="ms-title">{{ state.outcomeChoice ? state.playerStatus?.step?.title || state.outcomeTitle || 'Your racing is finished' : 'Stay and watch?' }}</h3></div>
        <p class="ms-caption"><template v-for="(part, index) in promptDetail" :key="index"><span v-if="part.money" class="ms-money">{{ part.text }}</span><span v-else-if="part.time" class="ms-time">{{ part.text }}</span><template v-else>{{ part.text }}</template></template></p>
        <p v-if="state.playerStatus?.finishEvent?.reason" class="finish-reason ms-caption">{{ state.playerStatus.finishEvent.reason }}</p>
        <div class="actions ms-foot">
          <HouseButton data-fk="spectate" compact :icon="icons.eyeOutlineOpened" :busy="busy && activeAction === 'attendAsSpectator'" :disabled="busy" variant="primary" @click="cameraAction('attendAsSpectator')">Spectate</HouseButton>
          <HouseButton v-if="state.canFinishWeekend" data-fk="finish-event" compact :icon="icons.checkmark" :busy="busy && activeAction === 'finishSpectatorWeekend'" :disabled="busy" @click="finishEvent">Finish Event</HouseButton>
          <HouseButton data-fk="close" compact :disabled="busy" variant="quiet" @click="onBack">Close</HouseButton>
        </div>
        <p class="action-error ms-bad" role="alert">{{ error }}</p>
      </div>
    </div>
    <aside v-if="state.watching" class="rls-house rls-house-card spectator-popup">
      <div class="panel">
        <div class="dock-head">
          <span class="ms-status" :class="statusTone === 'ok' ? 'ms-tone-go' : 'ms-tone-wait'">{{ statusLabel }}</span>
          <span v-if="state.cameraCount > 1" class="ms-meta ms-num">{{ cameraLabel }}</span>
        </div>
        <p v-if="state.nowRacing" class="now-racing"><strong>{{ state.nowRacing.names.join(' vs ') }}</strong><span class="ms-caption">{{ state.nowRacing.className }}<template v-if="state.nowRacing.roundName">, {{ state.nowRacing.roundName }}</template></span></p>
        <p v-if="['out', 'done'].includes(state.playerStatus?.role) && state.playerStatus?.finishEvent?.reason" class="finish-reason ms-caption">{{ state.playerStatus.finishEvent.reason }}</p>
        <p v-if="state.betting?.reason && state.betting.reasonCode !== 'already_placed'" class="betting-closed ms-caption"><span class="betting-reason" :data-reason="state.betting.reasonCode">{{ state.betting.reason }}</span></p>
        <div class="actions ms-foot">
          <HouseButton v-if="state.cameraCount > 1" data-fk="camera" compact :icon="icons.photo" :busy="busy && activeAction === 'cycleSpectatorCamera'" :disabled="busy" @click="cameraAction('cycleSpectatorCamera')">Next camera</HouseButton>
          <HouseButton v-if="!state.seeResults" data-fk="leave" compact :icon="icons.exit" :busy="busy && activeAction === 'stopWatching'" :disabled="busy" @click="cameraAction('stopWatching')">Stop watching</HouseButton>
          <HouseButton v-if="state.seeResults" data-fk="results" compact variant="primary" :disabled="busy" @click="seeResults">See results</HouseButton>
          <HouseButton v-else-if="state.canFinishWeekend" data-fk="finish-event" compact :icon="icons.checkmark" :busy="busy && activeAction === 'finishSpectatorWeekend'" :disabled="busy" @click="finishEvent">Finish Event</HouseButton>
          <MotorsportBetting class="ms-foot-end" :state="state.betting" :watching="state.watching" @refresh="refresh" />
        </div>
        <p class="action-error ms-bad" role="alert">{{ error }}</p>
      </div>
    </aside>
    </div>
  </EntryOverlayPopup>
</template>

<script setup>
import { computed, ref, watch, onMounted, onUnmounted } from 'vue'
import { lua, useBridge } from '@/bridge'
import { HouseButton } from './house/index.js'
import { icons } from '@/common/components/base'
import EntryOverlayPopup from './EntryOverlayPopup.vue'
import MotorsportBetting from './MotorsportBetting.vue'
import { useActionFocus } from '../composables/useActionFocus.js'
import { confirmFinishEvent } from '../utils/motorsportConfirmations.js'

const state = ref({}), error = ref(''), root = ref(null), activeAction = ref('')
const popupRevision = ref(0)
const confirming = ref(false)
const detailsReady = ref(false)
const { busy, run } = useActionFocus(root)
const bridge = useBridge()
// playerHeat comes from getSpectatorState; your own pass is no longer labelled as an AI heat.
const arrivalTone = computed(() => `ms-tone-${state.value.playerStatus?.step?.tone || 'act'}`)
// The prompt's sentence, with any amount in it drawn as money and any time in the time face.
const promptDetail = computed(() => {
  const text = state.value.outcomeDetail || (state.value.canFinishWeekend
    ? 'Watch from the stands, or finish the event to simulate the remaining races and see results.'
    : 'Watch from the stands, or close this prompt to keep the event open.')
  return String(text).split(/(\$[\d,]+|\d+\.\d+ s\b)/).filter(Boolean).map(part => ({ text: part, money: part.startsWith('$'), time: /^\d+\.\d+ s$/.test(part) }))
})
const statusLabel = computed(() => state.value.eventComplete ? 'Event complete' : state.value.sessionComplete ? 'Between rounds' : state.value.phase === 'cooldown' ? 'Slowing down' : state.value.phase === 'racing' ? 'Racing' : state.value.phase && state.value.phase !== 'idle' ? 'Getting ready' : 'Between heats')
const statusTone = computed(() => state.value.eventComplete || (!state.value.sessionComplete && state.value.phase === 'racing') ? 'ok' : 'soft')
const cameraLabel = computed(() => {
  const { cameraName, cameraIndex, cameraCount } = state.value
  const name = cameraName && !/^Camera(?:\s+\d+)?$/i.test(cameraName) ? cameraName : 'Camera'
  return `${name} ${cameraIndex} of ${cameraCount}`
})
watch([
  () => state.value.watching, () => state.value.phase,
  () => state.value.arrivalChoice, () => state.value.eventComplete,
], () => { error.value = '' }, { flush: 'sync' })
watch(() => state.value.watching, value => {
  document.body.classList.toggle('motorsport-spectating', value === true)
  if (value === false) requestAnimationFrame(() => window.dispatchEvent(new Event('resize')))
}, { flush: 'sync' })
const detailPollIntervalMs = 1000
const detailRequestTimeoutMs = 3000
let activityRevision = 0, disposed = false, timer = null, detailRequest = null
const needsDetails = () => state.value.arrivalChoice === true || state.value.watching === true
function cancelDetails() {
  const pending = detailRequest
  detailRequest = null
  pending?.cancel()
}
function syncPolling() {
  if (!disposed && needsDetails()) {
    if (timer === null) timer = setInterval(poll, detailPollIntervalMs)
  } else {
    clearInterval(timer)
    timer = null
    detailsReady.value = false
    cancelDetails()
  }
}
function applyActivity(activity) {
  if (disposed || typeof activity?.watching !== 'boolean' || typeof activity?.arrivalChoice !== 'boolean') return
  if ((state.value.watching === true) === activity.watching && (state.value.arrivalChoice === true) === activity.arrivalChoice) return
  activityRevision++
  // Closed views retain a snapshot for actions, never for the next first paint.
  if (!needsDetails()) detailsReady.value = false
  state.value = { ...state.value, watching: activity.watching, arrivalChoice: activity.arrivalChoice }
  syncPolling()
  if (!actionNeedsRefresh) poll()
}
function onActivity(activity) {
  if (disposed || typeof activity?.watching !== 'boolean' || typeof activity?.arrivalChoice !== 'boolean') return
  try { lua.overhaul_events_motorsportEvents.acknowledgeSpectatorActivity(activity.syncId)?.catch(() => {}) } catch (_) {}
  applyActivity(activity)
}
function onWatching(value) { applyActivity({ arrivalChoice: state.value.arrivalChoice === true, watching: value === true }) }
function poll() {
  if (disposed || !needsDetails()) return
  // Reuse the visible polling clock; a lost bridge callback must not lock input.
  if (detailRequest && Date.now() - detailRequest.startedAtMs >= detailRequestTimeoutMs) cancelDetails()
  return requestDetails()
}
function requestDetails() {
  if (disposed || !needsDetails()) return Promise.resolve()
  if (detailRequest) return detailRequest.promise
  const cancelled = Symbol('cancelled')
  let cancel
  const cancellation = new Promise(resolve => { cancel = () => resolve(cancelled) })
  const pending = { cancel, startedAtMs: Date.now(), promise: null }
  detailRequest = pending
  pending.promise = (async () => {
    let revision
    do {
      revision = activityRevision
      pending.startedAtMs = Date.now()
      try {
        const result = await Promise.race([lua.overhaul_events_motorsportEvents.getSpectatorState(), cancellation])
        if (result === cancelled) return
        if (!disposed && detailRequest === pending && revision === activityRevision && typeof result?.watching === 'boolean') {
          state.value = result
          detailsReady.value = true
          syncPolling()
        }
      } catch (_) {}
      // A new activation or completed action needs fresh data after an older reply.
    } while (!disposed && detailRequest === pending && needsDetails() && revision !== activityRevision)
  })().finally(() => { if (detailRequest === pending) detailRequest = null })
  return pending.promise
}
function refresh() {
  activityRevision++
  // Actions must not wait for a poll that captured state before the action.
  cancelDetails()
  return requestDetails()
}
function syncActivity() {
  try { lua.overhaul_events_motorsportEvents.requestSpectatorActivity()?.catch(() => {}) } catch (_) {}
}
let pendingAction = Promise.resolve(), leavePromise = null, spectatorNavigation = false, actionNeedsRefresh = false
function cameraAction(method, navigate = true) {
  if (busy.value || confirming.value || leavePromise) return
  pendingAction = performAction(method, navigate)
  return pendingAction
}
function performAction(method, navigate) {
  return run(async () => {
    activeAction.value = method
    error.value = ''
    try {
      actionNeedsRefresh = true
      const result = await lua.overhaul_events_motorsportEvents[method]()
      if (!result?.ok) error.value = result?.error || actionFailure(method)
      if (result?.ok && typeof result.eventComplete === 'boolean') state.value = { ...state.value, eventComplete: result.eventComplete }
      await refresh()
      actionNeedsRefresh = false
      if (result?.ok && navigate && !leavePromise) {
        if (result.eventComplete) await lua.extensions.ui_router.navigate('phone-motorsport-events', {})
        else if (method === 'attendAsSpectator') {
          spectatorNavigation = true
          try { await lua.extensions.ui_router.navigate('play', {}) }
          finally { spectatorNavigation = false }
        } else if (method === 'stopWatching') await lua.extensions.ui_router.navigate('play', {})
      }
      return result?.ok === true
    } catch (_) { error.value = actionFailure(method); return false }
    finally { actionNeedsRefresh = false; activeAction.value = '' }
  })
}
const actionNames = {attendAsSpectator: 'start watching', cycleSpectatorCamera: 'change the camera', stopWatching: 'stop watching', dismissSpectatorChoice: 'close the prompt', finishSpectatorWeekend: 'finish the event'}
function actionFailure(method) { return `Couldn't ${actionNames[method] || 'complete the action'}. Try again.` }
async function finishEvent() {
  if (busy.value || confirming.value || leavePromise) return
  if (!state.value.canFinishWeekend) {
    error.value = state.value.playerStatus?.finishEvent?.reason || 'Finish Event is unavailable right now.'
    return
  }
  confirming.value = true
  let accepted = false
  try { accepted = await confirmFinishEvent({eventName: state.value.eventName, reward: state.value.playerStatus?.outcome?.reward || 0}) }
  finally { confirming.value = false }
  if (accepted) return cameraAction('finishSpectatorWeekend')
}
async function seeResults() {
  if (busy.value || confirming.value || leavePromise) return
  return cameraAction('stopWatching')
}
async function onBack() {
  if (busy.value || confirming.value || leavePromise) return
  const ok = await cameraAction(state.value.arrivalChoice ? 'dismissSpectatorChoice' : 'stopWatching')
  if (!ok && (state.value.arrivalChoice || state.value.watching)) popupRevision.value++
}
function onLeave() {
  if (spectatorNavigation) { popupRevision.value++; return Promise.resolve(true) }
  if (leavePromise) return leavePromise
  const pending = pendingAction
  leavePromise = (async () => {
    try { await pending } catch (_) {}
    if (!state.value.arrivalChoice && !state.value.watching) return true
    const ok = await performAction(state.value.arrivalChoice ? 'dismissSpectatorChoice' : 'stopWatching', false)
    if (!ok && (state.value.arrivalChoice || state.value.watching)) popupRevision.value++
    if (ok && state.value.eventComplete) await lua.extensions.ui_router.navigate('phone-motorsport-events', {})
    return ok
  })().finally(() => { leavePromise = null })
  return leavePromise
}
onMounted(() => {
  bridge.events.on('MotorsportSpectatorWatching', onWatching)
  bridge.events.on('MotorsportSpectatorActivity', onActivity)
  syncActivity()
})
onUnmounted(() => {
  disposed = true
  activityRevision++
  bridge.events.off('MotorsportSpectatorWatching', onWatching)
  bridge.events.off('MotorsportSpectatorActivity', onActivity)
  syncPolling()
  document.body.classList.remove('motorsport-spectating')
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.spectator-popup, .arrival-backdrop { @include ms.ms-scale-overlay; }
// No clipping on the panel: the bet slip opens above the dock from inside it.
.panel { display: flex; flex-direction: column; gap: var(--ms-stack); padding: 0; }
.panel > * { margin-left: var(--ms-pad); margin-right: var(--ms-pad); }
// Dock: what is happening in its status colour (green while a heat runs, blue between heats), who is on track,
// then one line of controls with the bet button at its end. The dock widens to keep that line whole.
.spectator-popup { position: fixed; bottom: 2rem; left: 2rem; z-index: 1000; width: fit-content; min-width: min(30em, calc(100vw - 4rem)); max-width: calc(100vw - 4rem); pointer-events: auto; }
.spectator-popup .panel { background: var(--page); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07), 0 .6em 1.6em rgba(0, 0, 0, 0.45); padding-top: calc(var(--ms-pad) * .85); padding-bottom: var(--ms-pad); }
.dock-head { display: flex; align-items: baseline; justify-content: space-between; gap: 1.5em; }
.dock-head .ms-status { font-size: 1.05em; }
.now-racing { display: grid; gap: .1em; max-width: 44em; margin-top: 0; margin-bottom: 0; }
.now-racing strong { font-size: 1.15em; font-weight: 800; line-height: 1.2; }
.finish-reason, .betting-closed { max-width: 44em; margin-top: 0; margin-bottom: 0; }
.actions { justify-content: flex-start; }
.spectator-popup .actions { margin-top: .15em; }
.action-error { margin-top: 0; margin-bottom: 0; }
.action-error:empty { display: none; }
// Prompt: a plain title. When it reports how the player's racing ended it takes that outcome's colour.
.arrival-backdrop { position: fixed; inset: 0; z-index: 2000; display: grid; place-items: center; background: rgba(0, 0, 0, 0.6); pointer-events: auto; }
.arrival-choice { box-sizing: border-box; width: min(30em, calc(100vw - 4rem)); gap: var(--ms-gap); padding-top: calc(var(--ms-pad) * 1.2); padding-bottom: calc(var(--ms-pad) * 1.2); background: var(--page); border-radius: var(--radius-panel); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07), 0 1.2em 4em rgba(0, 0, 0, .65); }
.arrival-choice > * { margin-left: calc(var(--ms-pad) * 1.4); margin-right: calc(var(--ms-pad) * 1.4); }
.head .ms-title { color: var(--tone); }
.head.ms-tone-act .ms-title { color: #fff; }
.arrival-choice .ms-caption { margin-top: 0; margin-bottom: 0; font-size: max(12px, .95em); }
</style>

<style>
dialog.popup-wrapper:has(.spectator-popup)::backdrop,
dialog.popup-wrapper:has(.spectator-popup) > .popup-background {
  background: transparent;
  backdrop-filter: none;
}
body.motorsport-spectating .ui-app-host,
body.motorsport-spectating [app-container],
body.motorsport-spectating .app-infobar-wrapper,
body.motorsport-spectating .app-pause-button-host {
  display: none !important;
}
</style>

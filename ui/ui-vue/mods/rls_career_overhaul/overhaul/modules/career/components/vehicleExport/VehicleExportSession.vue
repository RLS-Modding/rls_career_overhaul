<template>
  <EntryOverlayPopup :key="state.phase" :active="!!state.sessionVisible" :can-cancel="false">
    <div class="export-session-shade">
    <section class="rls-house rls-house-card export-session modal" role="dialog" aria-labelledby="export-session-title">
      <div class="export-status" :class="state.recoveryRequired ? 'tone-stop' : 'tone-wait'">
        <div class="status-head">
          <h2 id="export-session-title" class="status-title">{{ title }}</h2>
          <span v-if="exporting && stepNumber > 0" class="step-count">Step {{ stepNumber }} of {{ steps.length }}</span>
        </div>
        <p v-for="line in lines" :key="line" class="status-text">{{ line }}</p>
      </div>
      <HouseLoader v-if="!state.recoveryRequired" class="session-loader tone-wait" :label="returnCaption" />
      <p v-if="error" class="session-note tone-stop session-error" role="alert">{{ error }}</p>
      <p v-if="hint" class="hint">{{ hint }}</p>
      <HouseButton v-if="state.recoveryRequired || manualReturn" variant="primary" block :disabled="pending || !state.recoveryRequired" data-test="session-restore" @click="act('restoreCareer')">Return to career</HouseButton>
      <HouseButton v-else block :disabled="pending || !exporting || !canCancel" data-test="session-cancel" @click="act('cancel')">Cancel export</HouseButton>
      <template v-if="state.canContinueCareer">
        <p class="hint">You can keep playing and keep the recovery checkpoint for later.</p>
        <HouseButton variant="quiet" block :disabled="pending" data-test="session-continue" @click="act('continueCareer')">Continue career</HouseButton>
      </template>
    </section>
    </div>
  </EntryOverlayPopup>
</template>
<script setup>
import {computed, onBeforeUnmount, onMounted, ref} from 'vue'
import {useBridge} from '@/bridge'
import EntryOverlayPopup from '../EntryOverlayPopup.vue'
import {HouseButton, HouseLoader} from '../house/index.js'
import {callModLua} from '../../utils/installLuaBridgeFallbacks.js'
import {exportSteps} from './exportSteps.js'
const {events}=useBridge()
const state=ref({}), error=ref(''), pending=ref(false)
// The same step count the panel shows, for players who are away from the computer.
const steps=computed(()=>exportSteps({runTests:state.value.request?.runTests===true,showroomPhoto:state.value.request?.thumbnailMode==='showroom'}))
const stepNumber=computed(()=>steps.value.findIndex(step=>step.key===state.value.stage)+1)
const buildName=computed(()=>state.value.request?.name || state.value.vehicle?.name || 'your build')
// On the way back because the player pressed Return to career, pressed Cancel export, or the export failed.
const manualReturn=computed(()=>!state.value.recoveryRequired && state.value.manualReturn===true)
const cancelling=computed(()=>!state.value.recoveryRequired && !manualReturn.value && (pending.value || state.value.cancelled===true))
const stopping=computed(()=>!state.value.recoveryRequired && !manualReturn.value && !cancelling.value && !!state.value.error)
const exporting=computed(()=>!state.value.recoveryRequired && !manualReturn.value && !cancelling.value && !stopping.value)
const canCancel=computed(()=>!['returning','restoring','verify','stoppingThumbnail'].includes(state.value.phase))
const title=computed(()=>{
  if (state.value.recoveryRequired) return 'Finish returning to your career'
  if (manualReturn.value) return 'Returning to your career'
  if (cancelling.value) return 'Cancelling export of '+buildName.value
  return (stopping.value ? 'Stopping export of ' : 'Exporting ')+buildName.value
})
// Under the title: what is happening now, then what it means for the player.
const lines=computed(()=>{
  const reason=String(state.value.error || '').split('\n')[0]
  if (state.value.recoveryRequired) return [reason, state.value.manualReturn===true ? 'If you turned off any vehicle mods, turn them back on, then press Return to career again.' : 'Press Return to career.'].filter(Boolean)
  if (manualReturn.value) return []
  if (cancelling.value) return ['Nothing will be exported.']
  if (stopping.value) return [reason, 'The game is bringing you back to your career.']
  return [state.value.message, 'The game returns you to your career when it is done.'].filter(Boolean)
})
// On the way back the loader shows the game's stage, unless the title already says it.
const returnCaption=computed(()=>{
  const message=(cancelling.value || manualReturn.value) && state.value.stage==='return' ? String(state.value.message || '') : ''
  return message.startsWith(title.value) ? '' : message
})
const hint=computed(()=>{
  if (state.value.recoveryRequired) return 'Your career was saved before the export began.'
  return exporting.value && canCancel.value && !pending.value ? 'Cancelling brings you back without exporting.' : ''
})
let mounted=true
function update(value) {
  if (!value) return
  if (Number.isFinite(value.sequence) && Number.isFinite(state.value.sequence) && value.sequence < state.value.sequence) return
  if (value.id===state.value.id && !(Number.isFinite(value.sequence) && value.sequence > (state.value.sequence ?? -1)) && (value.revision || 0)<(state.value.revision || 0)) return
  if (value.id!==state.value.id) {pending.value=false;error.value=''}
  state.value=value
}
async function act(method) {
  if (pending.value) return
  const id=state.value.id
  pending.value=true;error.value=''
  try {
    const result=await callModLua('overhaul_vehicles_configExport.'+method,id)
    if (!mounted || state.value.id!==id) return
    if (result?.status) update(result.status)
    if (!result?.ok) error.value=result?.message || (method==='cancel' ? 'The game could not cancel the export yet. Press Cancel export again.' : 'The game could not bring you back yet.')
  } catch (_) {if(mounted && state.value.id===id)error.value=method==='cancel' ? 'The game did not respond. Press Cancel export again. If it still fails, restart the game.' : 'The game did not respond. If it keeps failing, restart the game.'}
  finally {if(state.value.id===id)pending.value=false}
}
onMounted(()=>{
  events.on('RlsVehicleExportJob',update)
  callModLua('overhaul_vehicles_configExport.getStatus').then(value=>{if(mounted)update(value)}).catch(()=>{error.value='The game did not respond. If this stays, restart the game. Your career was saved.'})
})
onBeforeUnmount(()=>{mounted=false;events.off('RlsVehicleExportJob',update)})
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/vehicleExport.scss" as *;
// Same scale as the export panel: 1.5em to the edge, --space-4 between blocks.
.export-session-shade { position: fixed; inset: 0; display: grid; place-items: center; padding: 1.5em; overflow: auto; }
.export-session { width: min(34em, 90vw); display: grid; gap: var(--space-4); padding: 1.5em; background: var(--page); border-radius: var(--radius-panel); }
// The one thing to do next reads as body text, not as a footnote.
.export-session .session-note { margin: 0; font-size: 0.92em; font-weight: 600; line-height: 1.4; overflow-wrap: anywhere; text-wrap: pretty; }
.export-session .session-error { color: var(--tone-ink); }
</style>

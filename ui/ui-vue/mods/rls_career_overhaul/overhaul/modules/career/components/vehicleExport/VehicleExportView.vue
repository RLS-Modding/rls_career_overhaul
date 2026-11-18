<template>
  <VehicleExportPanel v-if="vehicle" :vehicle="vehicle" :metadata-options="metadataOptions"
    :export-configuration="exportConfiguration" :restore-career="restoreCareer" :open-folder="openFolder"
    :job-state="jobState" persist-on-unmount @back="back" />
  <div v-else class="rls-house rls-house-card export-loading">
    <div class="load-body">
      <HouseLoader v-if="!error" class="session-loader tone-wait" label="Loading your vehicle…" />
      <div v-else class="export-status tone-stop" role="alert">
        <h2 class="status-title">{{ vehicleGone ? 'This vehicle is no longer in your garage' : 'Your vehicle could not be loaded' }}</h2>
        <p class="status-text">{{ error }}</p>
      </div>
    </div>
    <!-- A vehicle that left the garage cannot be loaded by trying again: the way forward is back. -->
    <div v-if="error" class="load-actions">
      <HouseButton :variant="vehicleGone ? 'primary' : 'quiet'" data-test="load-back" @click="back">Back to computer</HouseButton>
      <HouseButton v-if="!vehicleGone" variant="primary" data-test="load-retry" @click="load">Try again</HouseButton>
    </div>
  </div>
</template>
<script setup>
import {onBeforeUnmount, onMounted, ref} from 'vue'
import {useBridge} from '@/bridge'
import VehicleExportPanel from './VehicleExportPanel.vue'
import {HouseButton, HouseLoader} from '../house/index.js'
const props=defineProps({inventoryId:[Number,String],computerId:[Number,String],callLua:Function})
const {events}=useBridge()
const vehicle=ref(null), metadataOptions=ref({}), jobState=ref(null), error=ref(''), vehicleGone=ref(false)
const pending=new Map()
let mounted=true, selectedProfile
const call=(method,...args)=>props.callLua('overhaul_vehicles_configExport.'+method,...args)
function older(state,observed) {
  if (!state || !observed) return false
  if (Number.isFinite(state.sequence) && Number.isFinite(observed.sequence) && state.sequence !== observed.sequence) return state.sequence < observed.sequence
  return state.id === observed.id && (state.revision || 0) < (observed.revision || 0)
}
function update(state) {
  if (state?.id && !state.busy && ((selectedProfile && state.profile && selectedProfile !== state.profile)
      || (vehicle.value?.model && state.model && vehicle.value.model !== state.model))) return
  if (older(state,jobState.value)) return
  if (!state?.id && jobState.value?.busy) return
  if (state?.id && state.inventoryId != null && props.inventoryId != null
      && Number(state.inventoryId) !== Number(props.inventoryId) && !state.busy && state.id !== jobState.value?.id) return
  jobState.value=state
  if (state?.busy && state.vehicle && String(state.inventoryId) !== String(vehicle.value?.inventoryId)) vehicle.value=state.vehicle
  const wait=pending.get(state?.id)
  if (!wait) return
  wait.onProgress?.({stage:state.stage,message:state.message})
  if (state.recoveryRequired || !state.busy) {
    pending.delete(state.id);wait.detach?.()
    wait.resolve(state.result || {ok:false,careerRestored:state.careerRestored,message:state.error || state.message})
  }
}
function waitForJob(status,options={}) {
  if (jobState.value?.id === status?.id && !older(jobState.value,status)) status = jobState.value
  update(status)
  if (!status.busy || status.recoveryRequired) return Promise.resolve(status.result || {ok:false,careerRestored:status.careerRestored,message:status.error || status.message})
  return new Promise(resolve=>{
    const failedCancel=message=>{
      const wait=pending.get(status.id)
      if (!wait) return
      pending.delete(status.id);wait.detach?.()
      resolve({ok:false,careerRestored:false,message})
    }
    const abort=()=>Promise.resolve().then(()=>call('cancel',status.id)).then(async response=>{
      if (response?.status) update(response.status)
      if (response?.ok) return
      // Cancellation can race completion. Prefer the actual terminal result.
      try { update(await call('getStatus')) } catch (_) {}
      failedCancel(response?.message || 'The game could not confirm the cancel.')
    }).catch(()=>failedCancel('The connection to the game was interrupted. If the Overhaul mod is turned off, turn it back on.'))
    options.signal?.addEventListener('abort',abort,{once:true})
    pending.set(status.id,{resolve,onProgress:options.onProgress,detach:()=>options.signal?.removeEventListener('abort',abort)})
    // A short export can finish between the start reply and listener attachment.
    call('getStatus').then(update).catch(()=>{})
    if (options.signal?.aborted) abort()
  })
}
async function exportConfiguration(request,options) {
  const response=await call('start',{...request,computerId:props.computerId})
  if (!response?.ok) return response || {ok:false,message:'Export is not responding.'}
  return waitForJob(response.status,options)
}
async function restoreCareer() {
  const response=await call('restoreCareer',jobState.value?.id)
  if (!response?.ok) return response || {ok:false}
  return waitForJob(response.status)
}
async function openFolder() { return call('openFolder',jobState.value?.id) }
async function back() { await call('backToComputer',props.computerId) }
async function load() {
  error.value='';vehicleGone.value=false
  try {
    const status=await call('getStatus')
    const data=await call('getView',props.inventoryId || status?.inventoryId)
    if (!mounted) return
    if (!data?.vehicle) {vehicleGone.value=true;error.value='Press Back to computer and pick another vehicle.';return}
    selectedProfile=data.profile
    if (!jobState.value?.busy || !vehicle.value) vehicle.value=jobState.value?.busy && jobState.value.vehicle || data.vehicle
    metadataOptions.value=data.metadataOptions || {};update(data.job)
  } catch (err) {if(mounted)error.value='Press Try again. If it still fails, press Back to computer and pick the vehicle again.'}
}
onMounted(()=>{events.on('RlsVehicleExportJob',update);load()})
onBeforeUnmount(()=>{
  mounted=false;events.off('RlsVehicleExportJob',update)
  for(const wait of pending.values())wait.detach?.()
  pending.clear() // Detach the menu; only explicit Cancel stops the persistent Lua job.
})
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/vehicleExport.scss" as *;
// Same frame as the export panel: content, then the actions on the right under a hairline.
.export-loading { width: min(54em, 100%); border-radius: var(--radius-panel); background: var(--page); overflow: hidden; }
.load-body { padding: 1.5em; }
.load-actions { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: var(--space-2); padding: var(--space-4) 1.5em; border-top: 1px solid var(--line); }
</style>

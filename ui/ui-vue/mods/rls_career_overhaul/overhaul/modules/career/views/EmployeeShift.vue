<template>
  <LayoutSingle
    class="employee-shift-layout"
    v-bng-blur
    bng-ui-scope="employeeShift"
    v-bng-on-ui-nav:back,menu="onBack">
    <div class="shift-wrapper">
      <BngCard class="shift-card">
        <BngCardHeading type="ribbon">
          <span class="hd-name">{{ state.employerName || 'Employment' }}</span>
          <span v-if="loaded" class="hd-status" :class="shiftStatus.cls">{{ shiftStatus.text }}</span>
        </BngCardHeading>
        <div class="card-content" v-bng-ui-nav-scroll>
          <div class="stats">
            <div class="stat" v-if="repLevel !== null">
              <span class="stat-key">Reputation</span>
              <span class="stat-value">{{ state.employerRepLabel || 'Level ' + repLevel }} <small v-if="state.employerRepLabel">Lv {{ repLevel }}</small></span>
            </div>
            <div class="stat" v-if="skillStat">
              <span class="stat-key">{{ skillStat.label }}</span>
              <span class="stat-value">Lv {{ skillStat.level }}</span>
            </div>
            <div class="stat" v-if="commission !== null">
              <span class="stat-key">Your cut</span>
              <span class="stat-value">{{ commission }}%</span>
            </div>
            <div class="stat money" v-if="wagesHeld > 0">
              <span class="stat-key">{{ state.assignment?.jobKind === 'paramedic' ? 'Unpaid shift wages' : state.assignment?.openEnded ? "Today's wages" : 'Wages held' }}</span>
              <span class="stat-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(wagesHeld) }}</span>
              <span v-if="state.assignment?.jobKind === 'paramedic'" class="stat-note">Includes completed calls; paid at End Day.</span>
            </div>
            <div class="stat money" v-if="bonusHeld > 0">
              <span class="stat-key">Demand bonus</span>
              <span class="stat-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(bonusHeld) }}</span>
            </div>
            <div class="stat warn" v-if="state.damageStatus">
              <span class="stat-key">Equipment damage</span>
              <span class="stat-value">{{ state.damageStatus.detail }}</span>
            </div>
          </div>

          <section v-if="!loaded" class="block">
            <p class="muted">Loading…</p>
          </section>

          <section v-else-if="state.assignment && !state.shiftStartPending && !state.shiftStartReady" class="block">
            <div class="block-head">
              <h3 class="block-title">{{ state.assignment.label }}</h3>
              <span class="hint hints" v-if="state.assignment.subtext"><span v-for="(part, i) in textParts(state.assignment.subtext)" :key="i">{{ part }}</span></span>
            </div>
            <ol v-if="state.assignment.shiftAssignments?.length" class="checklist">
              <li v-for="item in state.assignment.shiftAssignments" :key="item.id" :class="{ done: item.complete }">
                <span class="mark"><BngIcon :type="icons.checkmark" /></span>
                <div class="checklist-copy">
                  <strong>{{ item.label }}</strong>
                  <small v-if="item.subtext" class="hints"><span v-for="(part, i) in textParts(item.subtext)" :key="i">{{ part }}</span></small>
                </div>
              </li>
            </ol>
            <p class="note accident" v-if="state.assignment.accident">{{ state.assignment.accident.subtext || state.assignment.accident.label }}</p>
          </section>

          <section v-else class="block">
            <div class="block-head">
              <div class="kicker">Dispatch</div>
              <span class="hint">Dispatch picks from these</span>
            </div>
            <ul v-if="state.employerOfferings?.length" class="tiles">
              <li v-for="offering in state.employerOfferings" :key="offering.id" class="tile" :class="offeringState(offering)">
                <span class="tile-icon"><BngIcon :type="jobIcon(offering.id)" /></span>
                <strong class="tile-name">{{ offering.label }}</strong>
                <span v-if="offeringState(offering) === 'assigned'" class="pill accent">Assigned</span>
                <span v-else-if="offeringState(offering) === 'locked'" class="pill lock-pill" :title="offeringPill(offering)?.title"><svg class="lock" viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>{{ offeringPill(offering)?.text || 'Locked' }}</span>
              </li>
            </ul>
            <p v-else class="muted">Nothing to assign here yet.</p>

            <template v-if="state.shiftStartReady">
              <div class="kicker spaced">Assigned vehicles</div>
              <div v-if="state.assignedVehicles?.length" class="fleet-panel">
                <ul class="fleet">
                  <li v-for="vehicle in state.assignedVehicles" :key="vehicle.inventoryId" class="vehicle assigned">
                    <div class="vehicle-img"><img :src="vehicle.thumbnail" :alt="vehicle.name" /></div>
                    <div class="vehicle-copy">
                      <strong>{{ vehicle.name }}</strong>
                      <span class="pills"><span class="pill accent">{{ vehicle.role || 'Assigned' }}</span></span>
                    </div>
                  </li>
                </ul>
              </div>
              <p v-else class="muted">No vehicle needed.</p>
            </template>
            <template v-else>
              <div class="kicker spaced">Company vehicles</div>
              <!-- a taste of the fleet: three random vehicles, the third says how many more there are -->
              <div v-if="state.companyVehicles?.length" class="fleet-panel">
                <ul class="fleet">
                  <li
                    v-for="(vehicle, i) in fleetPreview"
                    :key="vehicle.id"
                    class="vehicle"
                    :class="{ locked: !vehicle.available, 'more-card': i === fleetPreview.length - 1 && fleetMore > 0 }">
                    <div class="vehicle-img">
                      <img :src="vehicle.thumbnail" :alt="vehicle.name" />
                      <span v-if="i === fleetPreview.length - 1 && fleetMore > 0" class="more-overlay">
                        <strong>+{{ fleetMore }}</strong>
                        <span>more vehicles</span>
                      </span>
                      <span v-else-if="!vehicle.available" class="img-lock"><svg class="lock" viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg></span>
                    </div>
                    <div class="vehicle-copy">
                      <strong>{{ vehicle.name }}</strong>
                      <span class="pills">
                        <template v-if="vehicle.available">
                          <span class="pill soft">{{ vehicle.vehicleType === 'trailer' ? 'Trailer' : 'Truck' }}</span>
                        </template>
                        <template v-else>
                          <span v-for="(p, i) in vehiclePills(vehicle)" :key="i" class="pill" :title="p.title"><BngIcon v-if="p.icon" :type="p.icon" />{{ p.text }}</span>
                        </template>
                      </span>
                    </div>
                  </li>
                </ul>
              </div>
              <p v-else class="muted">No company vehicles here.</p>
            </template>
          </section>

          <p v-if="statusMessage" class="status-error">{{ statusMessage }}</p>

          <section
            v-if="showAbandonConfirm"
            class="abandon-panel">
            <div class="abandon-panel-row">
              <span class="abandon-panel-title">Abandon this assignment?</span>
              <span class="abandon-panel-fine"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(state.assignment.abandonFine || 0) }}</span>
            </div>
            <p class="abandon-panel-detail">This ends your day and returns company equipment. You stay employed. Standard delivery fines and reputation penalties apply.</p>
            <div class="abandon-panel-actions">
              <button type="button" class="btn btn-quiet keep-working-btn" :disabled="busy" :bng-no-nav="busy ? 'true' : null" bng-nav-item @click="cancelAbandonConfirm"><BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Keep working</button>
              <button type="button" class="btn btn-danger" :disabled="busy" :bng-no-nav="busy ? 'true' : null" bng-nav-item @click="confirmAbandonAssignment">
                {{ busy ? 'Abandoning…' : 'Confirm abandon' }}
              </button>
            </div>
          </section>

          <div class="actions">
            <p v-if="assignmentNote && state.assignment && !state.shiftStartReady" class="actions-note">{{ assignmentNote }}</p>
            <button
              type="button"
              class="btn btn-quiet"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="close">
              <BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Back
            </button>
            <button type="button" v-if="state.shiftStartPending" class="btn btn-primary" disabled bng-no-nav="true">Preparing…</button>
            <button type="button"
              v-if="state.shiftStartReady"
              class="btn btn-primary"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="close">
              Continue
            </button>
            <button type="button"
              v-if="!state.onShift && !state.assignment?.held"
              class="btn btn-primary"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="startShift">
              {{ busy ? 'Starting…' : 'Start shift' }}
            </button>
            <button type="button"
              v-if="!state.onShift && state.assignment?.held"
              class="btn btn-primary"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="startShift">
              {{ busy ? 'Clocking in…' : 'Continue assignment' }}
            </button>
            <button type="button"
              v-if="state.assignment?.spawnBlocked"
              class="btn btn-primary"
              :disabled="busy || !state.assignment.canSpawnBlockedEquipment"
              :bng-no-nav="(busy || !state.assignment.canSpawnBlockedEquipment) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="spawnBlockedEquipment">
              {{ busy ? 'Spawning…' : 'Spawn vehicle' }}
            </button>
            <button type="button"
              v-if="state.assignment?.canNextRun && !state.shiftStartReady && !state.shiftStartPending"
              class="btn btn-primary"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="nextRun">
              {{ busy ? 'Starting…' : 'Next job' }}
            </button>
            <button type="button"
              v-if="state.assignment?.accident?.canClaim && !state.shiftStartReady && !state.shiftStartPending"
              class="btn btn-primary"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              @click="claimReplacement">
              {{ busy ? 'Issuing…' : 'Claim replacement' }}
            </button>
            <button type="button"
              v-if="state.assignment?.canAbandonAssignment && !showAbandonConfirm && !state.shiftStartReady && !state.shiftStartPending"
              class="btn btn-quiet-danger abandon-btn"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              @click="startAbandonConfirm">
              Abandon assignment
            </button>
            <button type="button"
              v-if="state.assignment?.canEndDay && !state.shiftStartReady && !state.shiftStartPending"
              class="btn btn-quiet"
              :disabled="busy || state.assignment?.endAfterAssignment"
              :bng-no-nav="(busy || state.assignment?.endAfterAssignment) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="endDay">
              {{ state.assignment?.endAfterAssignment ? 'Finishing…' : 'End day' }}
            </button>
            <button
              type="button"
              v-if="state.assignment?.canEndBusShiftNow"
              class="btn btn-quiet"
              :disabled="busy"
              :bng-no-nav="(busy) ? 'true' : null"
              bng-nav-item
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="endBusShiftNow">
              End day now
            </button>
          </div>

          <section v-if="state.devTools" class="dev" :class="{ open: devOpen }">
            <button type="button" class="dev-toggle" @click.stop="devOpen = !devOpen" @mousedown.stop>
              <svg viewBox="0 0 24 24" class="chev"><path d="M9 6l6 6-6 6"/></svg>
              Developer tools
            </button>
            <div v-if="devOpen" class="dev-body">
              <template v-if="canPickDevJob">
                <p v-if="!devJobs.length" class="muted">No job types at this yard.</p>
                <div v-else class="dev-job-row">
                  <button
                    v-for="job in devJobs"
                    :key="job.kind"
                    type="button"
                    class="dev-job-chip"
                    :class="{ active: selectedJobKind === job.kind }"
                    :disabled="busy"
                    :bng-no-nav="(busy) ? 'true' : null"
                    bng-nav-item
                    @click.stop="selectedJobKind = job.kind"
                    @mousedown.stop>
                    {{ job.label }}
                  </button>
                </div>
              </template>
              <p v-else class="muted">Forced jobs are unavailable during an assignment.</p>
              <div class="dev-actions">
                <button type="button"
                  v-if="canPickDevJob"
                  class="btn btn-primary"
                  :disabled="busy || !selectedJobKind"
                  :bng-no-nav="(busy || !selectedJobKind) ? 'true' : null"
                  bng-nav-item
                  @click="startSelectedJob">
                  {{ busy ? 'Starting…' : 'Start selected' }}
                </button>
                <button type="button" class="btn btn-danger" bng-nav-item @click="resetShift">Reset shift</button>
              </div>
            </div>
          </section>
        </div>

      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, onMounted, onBeforeUnmount, watch } from 'vue'
import { LayoutSingle } from '@/common/layouts'
import { BngCard, BngCardHeading, BngIcon, BngBinding, icons } from '@/common/components/base'
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'
import { lua, useBridge } from '@/bridge'
import { confirmEndBusShiftNow } from '../utils/endBusShift'
import { refocusIfLost } from '../composables/useScreenEntryFocus'

useUINavScope('employeeShift')

const props = defineProps({
  facilityId: { type: String, default: '' },
})

const { events } = useBridge()
const loaded = ref(false)
const busy = ref(false)
const statusMessage = ref('')
const state = ref({})

// Company fleet preview: a random three, picked once per fleet so refreshes don't reshuffle the cards.
const FLEET_PREVIEW = 3
let fleetPickKey = ''
let fleetPickIds = []
const fleetPreview = computed(() => {
  const list = state.value.companyVehicles || []
  if (list.length <= FLEET_PREVIEW) return list
  const key = list.map(v => v.id).sort().join('|')
  if (key !== fleetPickKey) {
    const ids = list.map(v => v.id)
    for (let i = ids.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1))
      ;[ids[i], ids[j]] = [ids[j], ids[i]]
    }
    fleetPickKey = key
    fleetPickIds = ids.slice(0, FLEET_PREVIEW)
  }
  const byId = new Map(list.map(v => [v.id, v]))
  return fleetPickIds.map(id => byId.get(id)).filter(Boolean)
})
// vehicles not shown as their own card (the third card stands in for them)
const fleetMore = computed(() => {
  const total = state.value.companyVehicles?.length || 0
  return total > FLEET_PREVIEW ? total - (FLEET_PREVIEW - 1) : 0
})
const devJobs = ref([])
const selectedJobKind = ref('')
const devOpen = ref(false)
const confirmingAbandon = ref(false)
const showAbandonConfirm = computed(() =>
  confirmingAbandon.value
  && state.value.assignment?.canAbandonAssignment
  && !state.value.shiftStartReady
  && !state.value.shiftStartPending)

// Template puts the game currency glyph before it.
const money = (v) => Math.round(Number(v) || 0).toLocaleString('en-US')
const bonusHeld = computed(() => Math.round(Number(state.value.surgeBonusHeld) || 0))
const wagesHeld = computed(() => Math.round(Number(state.value.escrowMoney) || 0))
const repLevel = computed(() => { const n = Number(state.value.employerRepLevel); return Number.isFinite(n) ? n : null })
const skillStat = computed(() => {
  const label = state.value.skillLabel
  const level = Number(state.value.skillLevel)
  if (!label || !Number.isFinite(level)) return null
  return { label, level }
})
const commission = computed(() => { const n = Number(state.value.commissionPercent); return Number.isFinite(n) ? Math.round(n) : null })
const offeringState = (offering) => isAssignedOffering(offering) ? 'assigned' : (offering.available ? 'ready' : 'locked')
const assignmentNote = computed(() => {
  const a = state.value.assignment
  if (!a) return ''
  if (a.spawnBlocked) return 'Clear the highlighted spawn stalls, then select Spawn vehicle. Your assignment stays reserved.'
  if (a.held) return 'Clock in to continue. Pay is held until the job is done.'
  if (a.busShift) return "Can't continue? End day now pays the work you finished."
  if (a.endAfterAssignment) return 'Final assignment. Finish it to get paid and clock out.'
  if (a.openEnded) return "End day to collect today's wages and return the vehicle."
  if (a.yardDropOffPending) return 'Drop the truck off at the yard to collect pay and end the day.'
  if (a.holdsOnEndDay) return 'End day makes this your final assignment.'
  if (state.value.escrowMoney) return 'End day to collect wages and return the vehicle.'
  return ''
})

const JOB_ICONS = { parcel: 'cardboardBox', trailer: 'smallTrailer', hauling: 'keys1', fluid: 'droplet', dryBulk: 'rocks', cement: 'concreteRoadBlock', cash: 'banknotes', bus: 'bus', police: 'police', paramedic: 'shieldHandPlus' } // same glyphs vanilla uses in its cargo tabs and material data
const jobIcon = (id) => icons[JOB_ICONS[id]] || icons.delivery

// Requirement chips: an icon plus a level instead of a sentence. Star = employer reputation, truck = Logistics skill.
const offeringPill = (offering) => {
  if (['bus', 'police', 'paramedic'].includes(offering?.id)) return offering.available ? null : { text: offering.unavailableReason || 'Needs a service vehicle' }
  const level = Number(offering?.availableFromLevel)
  return Number.isFinite(level) && level > 1 ? { icon: icons.deliveryTruck, text: `Lv ${level}`, title: `Logistics level ${level}` } : null
}

// Lua joins progress facts with a middle dot; show them as spaced facts instead of dotted text.
const textParts = (text) => String(text || '').split(/\s*[·•]\s*/).map(x => x.trim()).filter(Boolean)

const vehiclePills = (vehicle) => {
  // upstream 804ee2ee8: vehicles issued from the RLS loaner pool say so
  const out = vehicle?.fromLoanerPool ? [{ text: 'Loaner pool', title: 'Issued from the RLS loaner pool' }] : []
  if (!vehicle?.available && vehicle?.disableReason) return [...out, { text: vehicle.disableReason }]
  if (vehicle?.serviceUnlockLabel) return [...out, { text: vehicle.serviceUnlockLabel }]
  const reputation = Number(vehicle?.reputationLevel)
  const logistics = Number(vehicle?.logisticsLevel)
  if (Number.isFinite(reputation) && reputation > 0) out.push({ icon: icons.star, text: `Lv ${reputation}`, title: `Reputation level ${reputation}` })
  if (!state.value.roleplayFacility && Number.isFinite(logistics) && logistics > 0) out.push({ icon: icons.deliveryTruck, text: `Lv ${logistics}`, title: `Logistics level ${logistics}` })
  return out
}

const shiftStatus = computed(() => {
  if (state.value.shiftStartReady) return { cls: 'ready', text: 'Ready' }
  if (state.value.onShift) return { cls: 'on', text: 'On shift' }
  if (state.value.assignment?.held) return { cls: 'off', text: 'Paused' }
  return { cls: 'off', text: 'Off duty' }
})

const isAssignedOffering = (offering) => {
  const assignment = state.value.assignment
  if (!assignment || !offering) return false
  if (assignment.jobKind === 'materials') return offering.id === assignment.cargoType
  if (assignment.jobKind === 'parcel') return offering.id === 'parcel'
  if (assignment.jobKind === 'trailer') return offering.id === 'trailer'
  return ['vehicle', 'repo', 'vehicle_repo_bundle'].includes(assignment.jobKind) && offering.id === 'hauling'
}

const canPickDevJob = computed(() =>
  (!state.value.onShift && !state.value.assignment?.held)
  || !!state.value.assignment?.canNextRun
)

const refreshDevJobs = async () => {
  if (!state.value.devTools || !canPickDevJob.value) {
    devJobs.value = []
    selectedJobKind.value = ''
    return
  }
  try {
    const result = await lua.overhaul_career_work_employment.getDevJobOptions(props.facilityId)
    const options = result?.options || []
    devJobs.value = options
    if (!options.some((job) => job.kind === selectedJobKind.value)) {
      selectedJobKind.value = options[0]?.kind || ''
    }
  } catch (e) {
    reportUiFailure(e, "[employment] getDevJobOptions failed (EmployeeShift)")
    devJobs.value = []
  }
}

const refresh = async () => {
  confirmingAbandon.value = false
  try {
    state.value = await lua.overhaul_career_work_employment.getUiState(props.facilityId) || {}
    loaded.value = true
    await refreshDevJobs()
  } catch (e) {
    reportUiFailure(e, "Failed to load employee shift (EmployeeShift)")
    loaded.value = true
  }
}

const close = () => {
  lua.overhaul_career_work_employment.closeShiftUi()
}

const shiftActionSucceeded = (result) =>
  result?.success === true || result?.success === 1 || result?.ok === true || result?.ok === 1

const readShiftResult = (result) => {
  if (result === true) return { success: true, ok: true }
  if (result === false) return { success: false, ok: false, message: 'Lua returned false (no detail).' }
  if (typeof result === 'string' && result.length) {
    return { success: false, ok: false, message: result }
  }
  if (result && typeof result === 'object') {
    const success = shiftActionSucceeded(result)
    return { ...result, success, ok: success }
  }
  return { success: false, ok: false, message: `Unexpected shift result: ${String(result)}` }
}

const resolveShiftActionResult = async (rawResult) => {
  let result = readShiftResult(rawResult)
  const missingDetail = !result.message && !result.detail && !result.reason
  if ((rawResult === false || rawResult == null || missingDetail) && !shiftActionSucceeded(result)) {
    try {
      const stored = await lua.overhaul_career_work_employment.getLastShiftActionResult()
      if (stored) result = readShiftResult(stored)
    } catch (e) {
      reportUiFailure(e, "[employment] getLastShiftActionResult failed (EmployeeShift)")
    }
  }
  return result
}

const formatShiftFailure = (result, fallback) => {
  if (!result) return fallback
  const message = result.message || result.reason
  if (message) return String(message)
  reportUiFailure(result, "Shift action failed without message (EmployeeShift)")
  return fallback
}

const startShift = async () => {
  busy.value = true
  statusMessage.value = ''
  try {
    const result = await resolveShiftActionResult(await lua.overhaul_career_work_employment.startShift(props.facilityId))
    if (shiftActionSucceeded(result)) {
      await refresh()
      if (state.value.onShift) {
        statusMessage.value = ''
      }
      return
    }
    statusMessage.value = formatShiftFailure(result, 'Could not start shift.')
    reportUiFailure(result, "[employment] startShift failed (EmployeeShift)")
  } catch (e) {
    reportUiFailure(e, "[employment] startShift threw (EmployeeShift)")
    statusMessage.value = `Shift start error: ${e?.message || e}`
  } finally {
    busy.value = false
  }
}

const startSelectedJob = async () => {
  if (!selectedJobKind.value) return
  busy.value = true
  statusMessage.value = ''
  try {
    const result = await resolveShiftActionResult(
      await lua.overhaul_career_work_employment.startShiftWithJob(props.facilityId, selectedJobKind.value)
    )
    if (shiftActionSucceeded(result)) {
      await refresh()
      return
    }
    statusMessage.value = formatShiftFailure(result, 'Could not start selected job.')
    reportUiFailure(result, "[employment] startShiftWithJob failed (EmployeeShift)")
  } catch (e) {
    reportUiFailure(e, "[employment] startShiftWithJob threw (EmployeeShift)")
    statusMessage.value = `Selected job error: ${e?.message || e}`
  } finally {
    busy.value = false
  }
}

const nextRun = async () => {
  busy.value = true
  statusMessage.value = ''
  try {
    const result = await resolveShiftActionResult(await lua.overhaul_career_work_employment.startNextRun(props.facilityId))
    if (shiftActionSucceeded(result)) {
      await refresh()
      return
    }
    statusMessage.value = formatShiftFailure(result, 'No further assignments are ready.')
    reportUiFailure(result, "[employment] startNextRun failed (EmployeeShift)")
  } catch (e) {
    reportUiFailure(e, "[employment] startNextRun threw (EmployeeShift)")
    statusMessage.value = `Next run error: ${e?.message || e}`
  } finally {
    busy.value = false
  }
}

const spawnBlockedEquipment = async () => {
  if (busy.value) return
  busy.value = true
  statusMessage.value = ''
  try {
    const started = await lua.overhaul_career_work_employment.spawnBlockedEquipment()
    if (!started) statusMessage.value = 'Move near the highlighted stalls and make sure they are clear.'
    await refresh()
  } catch (e) {
    reportUiFailure(e, "Failed to spawn company equipment (EmployeeShift)")
    statusMessage.value = 'Unable to spawn. Please try again.'
  } finally {
    busy.value = false
  }
}

const claimReplacement = async () => {
  busy.value = true
  statusMessage.value = ''
  try {
    await lua.overhaul_career_work_employment.claimAccidentReplacement()
    await refresh()
  } catch (e) {
    reportUiFailure(e, "Claim replacement failed (EmployeeShift)")
    statusMessage.value = 'Could not issue replacement equipment.'
  } finally {
    busy.value = false
  }
}

const startAbandonConfirm = () => {
  if (busy.value || !state.value.assignment?.canAbandonAssignment) return
  confirmingAbandon.value = true
}

const cancelAbandonConfirm = () => {
  confirmingAbandon.value = false
}

// ---- controller
// The screen has no scoped-nav scope, so it picks its own focus: the main action (Start shift, Next job,
// Continue...) on entry and whenever a refresh or a busy (disabled) phase removed the focused button.
const screenEl = () => document.querySelector('.employee-shift-layout')
const pickMainAction = () =>
  screenEl()?.querySelector('.actions .btn-primary:not(:disabled)')
  || screenEl()?.querySelector('.actions .btn:not(:disabled)')
watch(loaded, isLoaded => { if (isLoaded) refocusIfLost(pickMainAction) }, { flush: 'post' })
watch(busy, isBusy => { if (!isBusy) refocusIfLost(pickMainAction) }, { flush: 'post' })
watch(state, () => refocusIfLost(pickMainAction), { flush: 'post' })
// abandon confirm row: opening it focuses the safe "Keep working"; closing it returns to its opener
watch(showAbandonConfirm, (open, wasOpen) => {
  if (open) refocusIfLost(() => screenEl()?.querySelector('.keep-working-btn'), { force: true })
  else if (wasOpen) refocusIfLost(() => screenEl()?.querySelector('.abandon-btn:not(:disabled)') || pickMainAction(), { force: true })
}, { flush: 'post' })

// B unwinds one level: the abandon confirm row first, then the screen
const onBack = () => {
  if (showAbandonConfirm.value) return cancelAbandonConfirm()
  close()
}

const confirmAbandonAssignment = async () => {
  if (busy.value || !state.value.assignment?.canAbandonAssignment) return
  busy.value = true
  statusMessage.value = ''
  confirmingAbandon.value = false
  try {
    const result = await resolveShiftActionResult(
      await lua.overhaul_career_work_employment.abandonAssignment(props.facilityId)
    )
    if (shiftActionSucceeded(result)) {
      await refresh()
      return
    }
    statusMessage.value = formatShiftFailure(result, 'Could not abandon the assignment.')
  } catch (e) {
    reportUiFailure(e, "Abandon assignment failed (EmployeeShift)")
    statusMessage.value = 'Could not abandon the assignment.'
  } finally {
    busy.value = false
  }
}

const endDay = async () => {
  if (busy.value) return
  busy.value = true
  statusMessage.value = ''
  try {
    await lua.overhaul_career_work_employment.endDay(props.facilityId)
    await refresh()
  } catch (e) {
    reportUiFailure(e, "End day failed (EmployeeShift)")
    statusMessage.value = 'Could not end the day.'
  } finally {
    busy.value = false
  }
}

const endBusShiftNow = async () => {
  if (busy.value || !state.value.assignment?.canEndBusShiftNow) return
  const routeId = state.value.assignment.busShift?.routeId
  busy.value = true
  statusMessage.value = ''
  try {
    if (await confirmEndBusShiftNow(routeId) === false) {
      statusMessage.value = 'The shift changed. Review the current assignment and try again.'
    }
    await refresh()
  } catch (e) {
    reportUiFailure(e, "End bus shift failed (EmployeeShift)")
    statusMessage.value = 'Could not end the shift. Please try again.'
  } finally {
    busy.value = false
  }
}

const resetShift = () => {
  lua.overhaul_career_work_employment.resetShiftAndEquipment()
}

const onShiftActionResult = (payload) => {
  if (!payload || shiftActionSucceeded(payload)) return
  statusMessage.value = formatShiftFailure(readShiftResult(payload), 'Could not start shift.')
  reportUiFailure(payload, "[employment] shift action result event (EmployeeShift)")
}

onMounted(() => {
  refresh()
  events.on('employmentUpdated', refresh)
  events.on('employmentShiftActionResult', onShiftActionResult)
})

onBeforeUnmount(() => {
  events.off('employmentUpdated', refresh)
  events.off('employmentShiftActionResult', onShiftActionResult)
})
</script>

<style scoped lang="scss">
/* Controller focus: the house ring (same values as rlsHouse.scss --focus / house-focus; this screen keeps
   its own .btn, so it cannot import the house sheet). Drawn for the game's controller class
   (.focus-visible) as well as :focus-visible, without the game's ::before frame. */
$shift-focus-ring: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600), 0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
@mixin shift-focus {
  position: relative; // anchors the game's absolute frame on the control, never on an ancestor
  &.focus-visible {
    outline: none;
    box-shadow: $shift-focus-ring;
  }
  &.focus-visible::before {
    display: none !important;
  }
}

/* Sizing: everything is in em off one font-size that follows the viewport height, so the card keeps the
   same share of the screen at 720p, 1080p, 1440p and 4K. --ui-scale is the player's UI scale setting. */
.employee-shift-layout {
  color: white;
}
.shift-wrapper {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(50em, 100%);
  min-width: 0;
  max-height: 100%;
  min-height: 0;
  align-self: flex-start;
  display: flex;
}
.shift-wrapper > .shift-card {
  --bng-card-height: auto;
  --bg-opacity: 0.9; /* the card's default 0.6 washes out over bright scenes */
  font-size: inherit;
  border-radius: 0.6em;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  flex: 1 1 auto;
  min-height: 0;
  max-height: 100%;
}
.shift-card :deep(.card-cnt) { border-radius: 0.6em; }
.shift-card :deep(.card-heading) {
  font-size: 1.45em;
  display: flex;
  align-items: center;
  gap: 0.6em;
  padding-right: 0.9em;
}
.hd-name { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hd-status {
  flex: 0 0 auto;
  font-size: 0.5em;
  font-style: normal;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  padding: 0.55em 0.75em 0.15em; /* Overpass caps sit high at line-height 1; measured to centre the ink */
  line-height: 1;
  border-radius: 1em;
  background: rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.75);
}
.hd-status.on { background: rgba(74, 222, 128, 0.18); color: #86efac; }
.hd-status.ready { background: rgba(255, 102, 0, 0.22); color: #ffb27a; }

.card-content {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;
  padding: 0.25em 1em 0.9em;
  display: flex;
  flex-direction: column;
  gap: 1em;
  --bng-icon-color: currentColor; /* game icons follow the text colour of their container */
}
.card-content::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
.card-content::-webkit-scrollbar-track { background: transparent; }
.card-content::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.12em solid transparent; background-clip: padding-box; }
.card-content::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
.card-content::-webkit-scrollbar-thumb:active { background: var(--bng-orange-b400, #ff6600); background-clip: padding-box; }

/* ---- action row (no footer band) */
.actions { display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: 0.5em 0.6em; padding-top: 0.35em; }
.actions-note { flex: 1 1 14em; min-width: 0; margin: 0; align-self: flex-end; padding-bottom: 0.45em; color: rgba(255, 255, 255, 0.6); font-size: 0.82em; line-height: 1.3; }

/* ---- buttons: our own, Overpass bold, soft corners */
.btn {
  appearance: none;
  border: 0;
  margin: 0;
  padding: 0.72em 1.2em 0.58em;
  border-radius: 0.6em;
  font: inherit;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.01em;
  color: #fff;
  background: rgba(255, 255, 255, 0.1);
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 0.12s, transform 0.08s, box-shadow 0.12s;
}
.btn:hover { background: rgba(255, 255, 255, 0.18); }
.btn:active { transform: translateY(1px); }
.btn { @include shift-focus; }
.btn:disabled { opacity: 0.45; cursor: default; transform: none; }
.btn-glyph { margin-right: 0.4em; vertical-align: -0.15em; }
.btn-primary { background: var(--bng-orange-b400, #ff6600); }
.btn-primary:hover { background: #ff7a1f; }
.btn-primary:disabled { background: var(--bng-orange-b400, #ff6600); }
.btn-danger { background: #b91c1c; }
.btn-danger:hover { background: #dc2626; }
.btn-quiet-danger { background: rgba(185, 28, 28, 0.2); color: #fecaca; border: 1px solid rgba(248, 113, 113, 0.45); }
.btn-quiet-danger:hover { background: rgba(185, 28, 28, 0.35); }
.abandon-panel {
  width: 100%;
  padding: 0.7em 0.85em;
  border-radius: 0.45em;
  background: rgba(15, 23, 42, 0.65);
  border: 1px solid rgba(248, 113, 113, 0.35);
  margin-top: 0.25em;
}
.abandon-panel-row { display: flex; justify-content: space-between; align-items: baseline; gap: 0.75em; flex-wrap: wrap; }
.abandon-panel-title { font-weight: 700; font-size: 0.95em; }
.abandon-panel-fine { font-weight: 800; font-size: 1.05em; color: #fca5a5; }
.abandon-panel-detail { margin: 0.4em 0 0.65em; color: rgba(255, 255, 255, 0.62); font-size: 0.82em; line-height: 1.35; }
.abandon-panel-actions { display: flex; justify-content: flex-end; gap: 0.5em; flex-wrap: wrap; }

/* ---- stat strip */
.stats {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em 1.9em;
  padding-bottom: 0.8em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}
.stat { display: grid; gap: 0.15em; }
.stat-key {
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.5);
}
.stat-value { font-weight: 700; font-size: 1.08em; line-height: 1.2; }
.stat-value small { font-weight: 600; font-size: 0.75em; color: rgba(255, 255, 255, 0.55); margin-left: 0.2em; }
.stat-note { font-size: 0.75em; color: rgba(255, 255, 255, 0.6); }
.stat.money .stat-value { color: #fde68a; }
.stat.warn .stat-key { color: #fbbf24; }
.stat.warn .stat-value { color: #fde68a; font-size: 0.95em; font-weight: 600; }

/* ---- sections */
.block { display: grid; gap: 0.65em; }
.block-head { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 0.25em 1em; }
.kicker {
  font-size: 0.75em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--bng-orange-b400, #ff6600);
}
.kicker.spaced { margin-top: 0.4em; }
.hint { font-size: 0.8em; font-weight: 600; color: rgba(255, 255, 255, 0.55); }
.hints { display: inline-flex; flex-wrap: wrap; gap: 0.2em 1.1em; }
.block-title { margin: 0; font-size: 1.3em; font-weight: 700; line-height: 1.2; }
.muted { margin: 0; color: rgba(255, 255, 255, 0.72); font-size: 0.92em; font-weight: 600; }
.note { margin: 0; color: #cbd5e1; font-size: 0.95em; font-weight: 600; }
.note.accident { color: #fdba74; }
.status-error { margin: 0; color: #fca5a5; font-weight: 600; }
.chev { width: 0.8em; height: 0.8em; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; transition: transform 0.15s; }

/* ---- pills: short requirement / state chips */
.pills { display: flex; flex-wrap: wrap; gap: 0.3em; }
.pill {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
  padding: 0.4em 0.5em 0.1em; /* Overpass caps sit high at line-height 1; measured to centre the ink */
  line-height: 1;
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.74em;
  font-weight: 700;
  white-space: nowrap;
}
.pill :deep(.bng-icon), .pill :deep(svg) { font-size: 1.15em; }
.pill.accent { background: rgba(255, 102, 0, 0.25); color: #ffb27a; }
.pill.soft { background: transparent; color: rgba(255, 255, 255, 0.45); padding-left: 0; }

/* ---- assignment checklist: green check when done, ghost check when pending; no rings, no strikethrough */
.checklist { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.4em; }
.checklist li {
  display: flex;
  gap: 0.6em;
  align-items: center;
  padding: 0.55em 0.75em 0.55em 0.6em;
  border-radius: 0.35em;
  background: rgba(255, 255, 255, 0.06);
}
.mark { flex: 0 0 auto; width: 1.6em; display: grid; place-items: center; color: rgba(255, 255, 255, 0.18); }
.mark :deep(.bng-icon) { font-size: 1.5em; }
.checklist li.done .mark { color: #4ade80; }
.checklist li.done .checklist-copy { opacity: 0.55; }
.checklist-copy { display: grid; gap: 0.1em; min-width: 0; overflow-wrap: anywhere; }
.checklist-copy strong { line-height: 1.2; }
.checklist-copy small { color: rgba(255, 255, 255, 0.6); font-size: 0.85em; }

/* ---- dispatch tiles: icon-accented, no stripes */
.tiles {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(14.5em, 100%), 1fr));
  gap: 0.5em;
}
.tile {
  display: flex;
  align-items: center;
  gap: 0.6em;
  min-height: 3.1em;
  padding: 0.45em 0.6em 0.45em 0.65em;
  border-radius: 0.35em;
  background: rgba(255, 255, 255, 0.06);
  min-width: 0;
}
.tile-icon {
  flex: 0 0 auto;
  width: 2.1em;
  display: grid;
  place-items: center;
  color: #fff;
}
.tile-icon :deep(.bng-icon) { font-size: 1.9em; }
.tile.assigned .tile-icon { color: var(--bng-orange-b400, #ff6600); }
.tile-name { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; line-height: 1.2; }
.tile .pill { flex: 0 0 auto; }
.lock { width: 1.45em; height: 1.45em; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; flex: 0 0 auto; }
.lock-pill .lock { width: 0.95em; height: 0.95em; position: relative; top: -0.13em; }
.tile.locked .tile-icon { color: rgba(255, 255, 255, 0.4); }
.tile.locked .tile-name { color: rgba(255, 255, 255, 0.55); }
.tile.assigned { background: rgba(255, 102, 0, 0.14); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); }

/* ---- vehicle tiles: image first; panel scrolls after two rows */
.fleet-panel {
  --fleet-gap: 0.6em;
  --fleet-copy-h: 3.4em;
  container-type: inline-size;
  max-height: calc(2 * (((100cqw - var(--fleet-gap)) / 2) * 0.5 + var(--fleet-copy-h)) + var(--fleet-gap));
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;
}
.fleet-panel::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
.fleet-panel::-webkit-scrollbar-track { background: transparent; }
.fleet-panel::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.12em solid transparent; background-clip: padding-box; }
.fleet-panel::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
.fleet-panel::-webkit-scrollbar-thumb:active { background: var(--bng-orange-b400, #ff6600); background-clip: padding-box; }

.fleet {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(14em, 100%), 1fr));
  gap: var(--fleet-gap);
}
.vehicle {
  display: grid;
  /* one shrinkable column so a tile never grows past its grid cell (the "+N more" tile did), and the
     copy row takes any slack so every photo keeps the same 16:8 height across a row */
  grid-template-columns: minmax(0, 1fr);
  grid-template-rows: auto 1fr;
  align-content: start;
  border-radius: 0.4em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.06);
  min-width: 0;
}
.vehicle-img { position: relative; aspect-ratio: 16 / 8; background: rgba(0, 0, 0, 0.35); }
.vehicle-img img { display: block; width: 100%; height: 100%; object-fit: cover; }
.vehicle-img::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(20, 20, 22, 0.75), rgba(20, 20, 22, 0) 55%);
  pointer-events: none;
}
.vehicle.locked .vehicle-img img { filter: grayscale(0.9) brightness(0.55); }
.vehicle.locked strong { color: rgba(255, 255, 255, 0.55); }
.img-lock {
  position: absolute;
  top: 0.45em;
  right: 0.45em;
  color: #fff;
  display: grid;
  place-items: center;
  z-index: 1;
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.9));
}
/* third preview card: dimmed photo with "+N more vehicles" over it */
.vehicle.more-card .vehicle-img img { filter: brightness(0.38) saturate(0.6); }
.vehicle.more-card .vehicle-copy { opacity: 0.55; }
.vehicle.more-card .pills { display: none; }
.more-overlay {
  position: absolute;
  inset: 0;
  z-index: 1;
  display: grid;
  place-content: center;
  justify-items: center;
  gap: 0.1em;
  color: #fff;
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.7);
  strong { font-size: 2em; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums; }
  span { font-size: 0.85em; font-weight: 700; color: rgba(255, 255, 255, 0.8); }
}
.vehicle.assigned { box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.5); }
.vehicle-copy { display: grid; gap: 0.3em; padding: 0.5em 0.65em 0.6em; min-width: 0; }
/* vehicle names get two lines before they clip */
.vehicle-copy strong { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; overflow-wrap: anywhere; line-height: 1.2; align-self: start; max-height: 2.4em; }

/* ---- developer drawer (dev key holders only; folded by default so the card looks like the player build) */
.dev { margin-top: 0.25em; border-top: 1px dashed rgba(255, 255, 255, 0.18); padding-top: 0.5em; }
.dev-toggle {
  appearance: none;
  border: 0;
  background: none;
  padding: 0.2em 0;
  font: inherit;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.45);
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
}
.dev-toggle:hover { color: #fca5a5; }
.dev-toggle, .dev-job-chip { @include shift-focus; }
.dev.open .dev-toggle .chev { transform: rotate(90deg); }
.dev-body { display: grid; gap: 0.6em; padding-top: 0.5em; }
.dev-actions { display: flex; justify-content: flex-end; gap: 0.5em; flex-wrap: wrap; }
.dev-job-row { display: flex; flex-wrap: wrap; gap: 0.4em; }
.dev-job-chip {
  appearance: none;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(255, 255, 255, 0.06);
  color: #fecaca;
  border-radius: 0.3em;
  padding: 0.4em 0.7em;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}
.dev-job-chip:hover:not(:disabled) { background: rgba(248, 113, 113, 0.18); border-color: rgba(248, 113, 113, 0.55); }
.dev-job-chip.active { background: rgba(248, 113, 113, 0.28); border-color: #f87171; color: #fff; }
.dev-job-chip:disabled { opacity: 0.5; cursor: default; }

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

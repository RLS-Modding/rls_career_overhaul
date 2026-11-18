<!-- Owns venue registration and inspection forms. EntryOverlayPopup owns input; motorsportEvents.lua validates actions. -->
<template>
  <EntryOverlayPopup :active="visible" :can-cancel="!busy" @cancel="close" @leave="close">
    <div v-if="visible" class="registration-backdrop">
      <section ref="root" class="rls-house rls-house-card registration-popup">
        <header class="popup-head">
          <h2 class="ms-title">{{ checkInMode ? 'Check-in' : 'Registration' }}</h2>
          <HouseButton compact data-fk="close" variant="quiet" :icon="icons.xmark" :disabled="busy" @click="close">Close</HouseButton>
        </header>
        <dl class="ms-facts ruled head-facts">
          <div><dt class="ms-label">Venue</dt><dd>{{ event.stripName }}</dd></div>
          <div v-if="checkInMode"><dt class="ms-label">Inspection</dt><dd class="ms-num">Day {{ state.session.day }}</dd></div>
          <template v-else>
            <div><dt class="ms-label">League</dt><dd>{{ offeredLeague?.name || 'League' }}</dd></div>
            <div><dt class="ms-label">Entry per class</dt><dd class="ms-num" :class="moneyTone(offeredLeague?.fee)">{{ money(offeredLeague?.fee) }}</dd></div>
            <div><dt class="ms-label">Includes</dt><dd>Day 1 inspection</dd></div>
          </template>
        </dl>
        <p v-if="error && !failureOnRow" class="alert ms-wash ms-tone-blocked" role="alert">{{ error }}</p>
        <main class="scroll" v-bng-ui-nav-scroll.force>
          <template v-if="checkInMode">
            <p class="ms-caption">Bring your registered cars, on the trailer or driven in.</p>
            <div class="sheet lines">
              <div v-for="entry in checkIn.entries" :key="entry.registrationId" class="line inspection-row">
                <span><strong class="ms-body">{{ entry.name }}</strong><small class="ms-meta">{{ entry.className }}</small><small v-if="entryFailure(entry)" class="ms-meta ms-bad inspection-reason" role="alert">{{ failureReason(entry) }}</small></span>
                <div class="entry-state">
                  <span class="ms-meta presence">{{ presenceLabel(entry) }}</span>
                  <span class="pill" :class="entryFailure(entry) ? 'ms-tone-blocked' : entry.inspected ? 'ms-tone-done' : 'ms-tone-act'">{{ entryFailure(entry) ? 'Failed' : entry.inspected ? 'Passed' : 'To inspect' }}</span>
                  <MotorsportPartChanges v-if="entryFailure(entry)?.partChanges?.length" :changes="entryFailure(entry).partChanges" :car-name="entry.name" context="inspection" :disabled="busy" />
                </div>
              </div>
            </div>
            <MotorsportFold id="motorsport-inspection-rules" icon="info" title="Inspection rules" :model-value="inspectionOpen" @update:model-value="value => inspectionOpen = value">
              <ul class="inspection-rules ms-caption"><li v-for="rule in inspectionRules" :key="rule">{{ rule }}</li></ul>
            </MotorsportFold>
          </template>
          <template v-else>
            <p v-if="!registeredRows.length" class="ms-caption">Pick classes for each car, then pay.</p>
            <div v-if="entriesWithoutGroup.length" class="sheet lines" aria-label="Registered entries">
              <div v-for="entry in entriesWithoutGroup" :key="entry.registrationId" class="line"><span><strong class="ms-body">{{ entry.vehicleName || entry.model }}</strong><small class="ms-meta">{{ entry.declaredClassName || selectedClassName(entry.declaredClassId) }}</small></span><span class="pill ms-tone-done">Registered</span></div>
            </div>
            <div v-for="entry in registrationFailures" :key="entry.registrationId || entry.id || entry.inventoryId" class="status ms-caption">
              <span><strong>{{ entry.vehicleName || entry.model }}:</strong> {{ entry.classError || entry.error || entry.reason || "Didn't meet its class rules." }}</span>
              <span class="pill" :class="entry.refundPaid ? 'ms-tone-done' : 'ms-tone-wait'"><template v-if="entry.refundPaid">Refunded <span class="ms-money">{{ money(entry.fee) }}</span></template><template v-else>Refund pending</template></span>
            </div>
            <MotorsportFold id="motorsport-class-rules" icon="raceFlag" title="Class rules" :model-value="rulesOpen" @update:model-value="value => rulesOpen = value">
              <div class="sheet lines">
                  <MotorsportClassDetails v-for="choice in offeredClasses" :key="choice.id" :choice="choice" context="registration" />
              </div>
            </MotorsportFold>
            <p v-if="!registrationCars.length" class="ms-caption">No cars nearby. Park a race car next to registration.</p>
            <template v-for="car in registrationCars" :key="car.inventoryId">
              <section v-if="car.available === false || car.disabled" class="car">
                <div class="car-head"><BngIcon class="ms-icon" :type="icons.car" /><strong class="ms-body">{{ car.name || car.model }}</strong><span class="pill" :class="car.availabilityKind === 'notHere' ? 'ms-tone-act' : 'ms-tone-blocked'">{{ car.availabilityKind === 'notHere' ? 'Not here' : 'Not eligible' }}</span></div>
                <p class="ms-caption">{{ car.availabilityKind === 'notHere' ? 'Bring it to registration.' : car.error || 'Not a race car for this event.' }}</p>
              </section>
              <section v-else class="car">
                <div class="car-head"><BngIcon class="ms-icon" :type="icons.car" /><strong class="ms-body">{{ car.name || car.model }}</strong></div>
                <p v-if="car.error" class="ms-meta ms-bad">{{ car.error }}</p>
                <p v-if="sharesClass(car)" class="ms-meta ms-bad" role="alert">One car per class. Clear one of the two.</p>
                <div v-if="carEntries(car).length || openClasses(car).length" class="sheet lines">
                  <div v-for="entry in carEntries(car)" :key="entry.registrationId" class="line"><strong class="ms-body">{{ entry.declaredClassName || selectedClassName(entry.declaredClassId) }}</strong><span class="pill ms-tone-done">Registered</span></div>
                  <div v-for="choice in openClasses(car)" :key="choice.id" class="line class-row" :class="{ 'ms-picked': !!selectedCars[String(car.inventoryId)]?.classIds?.includes(choice.id) }">
                    <HouseSwitch row :model-value="!!selectedCars[String(car.inventoryId)]?.classIds?.includes(choice.id)" :disabled="busy" :aria-label="`Select ${choice.name} for ${car.name || car.model}`" @update:model-value="value => toggleClass(car, choice.id, value)">
                      <span class="class-copy"><strong class="ms-body">{{ choice.name }}</strong><span class="class-index"><template v-if="Number.isFinite(choice.indexSeconds)"><span class="ms-label">Index</span><strong class="ms-time">{{ choice.indexSeconds.toFixed(2) }} s</strong></template><small v-else class="ms-meta">No index</small></span></span>
                    </HouseSwitch>
                  </div>
                </div>
                <div v-if="commonBlockers(car).length" class="reason-chips"><span v-for="reason in commonBlockers(car)" :key="`${reason.kind}-${reason.text}`" class="pill ms-tone-blocked">{{ reasonLabel(reason) }}</span></div>
                <div v-for="choice in closedClasses(car)" v-show="!commonBlockers(car).length" :key="choice.id" class="closed ms-meta"><strong>{{ choice.name }}</strong><template v-if="!carFits(car, choice) && choice.available !== false"><span v-for="reason in classBlockers(car, choice)" :key="`${reason.kind}-${reason.text}`" class="pill ms-tone-blocked">{{ reasonLabel(reason) }}</span></template><span v-else>{{ closedReason(car, choice) }}</span></div>
              </section>
            </template>
            <HouseButton v-if="registration.vehicles?.length" data-fk="browse-cars" compact :icon="icons.cars" :disabled="busy" @click="toggleBrowse">{{ showAllCars ? 'Show nearby cars' : 'Show all my cars' }}</HouseButton>
          </template>
        </main>
        <footer class="popup-foot ms-foot">
          <template v-if="checkInMode">
            <HouseButton class="ms-foot-end" data-fk="check-in" variant="primary" :icon="icons.shieldCheckmark" :busy="busy && checkInMode" :disabled="!canInspect(state) || !inspectableCarCount" @click="checkInVehicles">Inspect {{ inspectableCarCount }} {{ inspectableCarCount === 1 ? 'car' : 'cars' }}</HouseButton>
          </template>
          <template v-else>
            <dl class="registration-totals ms-facts ruled ms-num">
              <div v-if="registeredRows.length"><dt class="ms-label">Registered</dt><dd>{{ registeredRows.length }}</dd></div>
              <div v-if="selectedRows.length"><dt class="ms-label">Selected</dt><dd>{{ selectedRows.length }}</dd></div>
              <div><dt class="ms-label">Balance</dt><dd class="ms-money">{{ money(balance) }}</dd></div>
              <div v-if="shortfall"><dt class="ms-label ms-bad">Short by</dt><dd class="ms-money">{{ money(shortfall) }}</dd></div>
            </dl>
            <HouseButton data-fk="start-event" :variant="registeredRows.length && !selectedRows.length ? 'primary' : 'neutral'" :busy="busy && activeAction === 'start'" :icon="icons.raceFlag" :disabled="busy || !registeredRows.length || selectedRows.length > 0" @click="startEvent">{{ labels.startEvent }}</HouseButton>
            <HouseButton v-if="selectedRows.length" data-fk="register" variant="primary" :busy="busy && activeAction === 'register'" :icon="icons.banknotes" :disabled="busy || !registration.atRegistration || !selectionComplete || duplicateClass || !canAffordSelection" @click="registerVehicles">Register <span class="ms-money">{{ money(totalFee) }}</span></HouseButton>
          </template>
        </footer>
      </section>
    </div>
  </EntryOverlayPopup>
</template>

<script>
let registrationOwner = null
</script>

<script setup>
import MotorsportClassDetails from './motorsport/MotorsportClassDetails.vue'
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { vBngUiNavScroll } from '@/common/directives'
import EntryOverlayPopup from './EntryOverlayPopup.vue'
import { HouseButton, HouseSwitch, openHouseConfirmation } from './house/index.js'
import { BngIcon, icons } from '@/common/components/base'
import { useActionFocus } from '../composables/useActionFocus.js'
import MotorsportFold from './motorsport/MotorsportFold.vue'
import MotorsportPartChanges from './motorsport/MotorsportPartChanges.vue'
import { actionError, labels, money, moneyTone } from '../utils/motorsportLabels.js'
import { confirmationRows, confirmStartEvent } from '../utils/motorsportConfirmations.js'

const events = useBridge().events
const owner = {}
const root = ref(null), visible = ref(false), state = ref({}), error = ref('')
const inspectionChanges = ref([])
const inspectionVehicleName = ref('')
const inspectionFailure = ref(null)
const activeAction = ref('')
const selectedCars = ref({}), showAllCars = ref(false)
const inspectionOpen = ref(false), rulesOpen = ref(false)
const inspectionRules = [
  'Keep the parts you registered with, and meet the class rules.',
  'Failed? Put the changed parts back and try again.',
  'Registration covers Day 1. Come back each later day.',
]
const { busy, run, remember, restore } = useActionFocus(root)
const asArray = value => Array.isArray(value) ? value : []
const payload = value => Array.isArray(value) ? value.find(item => item && typeof item === 'object') : value
const event = computed(() => state.value.event || {})
const registration = computed(() => state.value.registration || {})
const checkIn = computed(() => state.value.checkIn || {})
const checkInMode = computed(() => event.value.phase !== 'registration')
const leagues = computed(() => asArray(registration.value.leagues))
const offeredLeague = computed(() => leagues.value.find(league => league.id === event.value.offeredLeagueId) || leagues.value[0])
const offeredClasses = computed(() => asArray(offeredLeague.value?.classes))
const registrationFailures = computed(() => asArray(event.value.registrationFailures))
const registeredRows = computed(() => asArray(event.value.registrations || registration.value.registrations))
const registrationCars = computed(() => showAllCars.value && asArray(registration.value.vehicles).length ? registration.value.vehicles : asArray(registration.value.nearby))
const selectedRows = computed(() => Object.entries(selectedCars.value).flatMap(([inventoryId, choice]) => (choice.classIds || []).map(classId => ({ inventoryId: /^\d+$/.test(inventoryId) ? Number(inventoryId) : inventoryId, classId, leagueId: leagues.value.find(l => asArray(l.classes).some(c => c.id === classId))?.id }))))
const selectedCarCount = computed(() => new Set(selectedRows.value.map(row => row.inventoryId)).size)
const totalFee = computed(() => selectedRows.value.reduce((sum, row) => sum + Number(leagues.value.find(l => l.id === row.leagueId)?.fee || 0), 0))
const balance = computed(() => Number(registration.value.balance || 0))
const canAffordSelection = computed(() => !selectedRows.value.length || (offeredLeague.value?.affordableEntries?.[selectedRows.value.length - 1]
  ?? totalFee.value <= balance.value))
const shortfall = computed(() => canAffordSelection.value ? 0 : Math.max(0, totalFee.value - balance.value))
const inspectableCarCount = computed(() => new Set(asArray(checkIn.value.entries)
  .filter(entry => ['here', 'onTrailer'].includes(entry.presence)).map(entry => entry.inventoryId)).size)
const presenceLabel = entry => ({ here: 'Here', onTrailer: 'On trailer', notHere: 'Not here' }[entry.presence] || 'Presence unavailable')
const entryFailure = entry => entry.failure || (inspectionFailure.value?.registrationId === entry.registrationId ? inspectionFailure.value : null)
// The row is headed by its car and class, so a reason that arrives prefixed with them is shown without that prefix.
function failureReason(entry) {
  const reason = String(entryFailure(entry)?.error || '')
  const heading = [`${entry.name} (${entry.className}): `, `${entry.name}: `].find(prefix => reason.startsWith(prefix))
  return heading ? reason.slice(heading.length) : reason
}
// A failed inspection is explained on its car's row, so the window does not repeat it above the list.
const failureOnRow = computed(() => checkInMode.value && asArray(checkIn.value.entries).some(entry => inspectionFailure.value?.registrationId === entry.registrationId))
const duplicateClass = computed(() => { const ids = selectedRows.value.map(row => row.classId); return new Set(ids).size !== ids.length })
const selectionComplete = computed(() => selectedRows.value.length > 0 && selectedRows.value.every(row => {
  const car = registrationCars.value.find(c => String(c.inventoryId) === String(row.inventoryId))
  const cls = offeredClasses.value.find(c => c.id === row.classId)
  return car && cls && canSelectClass(car, cls)
}))
const canRegister = data => data?.careerActive && data.event?.phase === 'registration' && data.registration?.atRegistration
const canInspect = data => data?.careerActive && data.event?.checkInVersion === 1
  && !['registration', 'complete'].includes(data.event.phase) && data.session?.day > 1
  && !data.session.spectatorOnly && (data.session.inspectionAvailable ?? !data.session.waiting)
  && data.checkIn?.atCheckIn && asArray(data.checkIn.entries).some(entry => !entry.inspected)
const canUseOverlay = data => canRegister(data) || canInspect(data)
function selectedClassName(id) { return leagues.value.flatMap(l => asArray(l.classes)).find(c => c.id === id)?.name || id }
// Lua grades every nearby car against every class (classEligibility). An empty eligibleClassIds arrives as {}, not [],
// so the per-class verdict is the source of truth and the id list only a fallback.
function carFits(car, cls) {
  if (car.available === false || car.disabled || cls.available === false) return false
  const verdict = car.classEligibility?.[cls.id]
  if (verdict && typeof verdict.eligible === 'boolean') return verdict.eligible
  return !Array.isArray(car.eligibleClassIds) || car.eligibleClassIds.includes(cls.id)
}
function takenBy(car, cls) { return registeredRows.value.find(r => r.declaredClassId === cls.id) || selectedRows.value.find(r => r.classId === cls.id && String(r.inventoryId) !== String(car.inventoryId)) }
function canSelectClass(car, cls) { return carFits(car, cls) && !takenBy(car, cls) }
// Toggles appear only for classes this car can enter now; the rest collapse to one muted line.
function openClasses(car) { return offeredClasses.value.filter(cls => canSelectClass(car, cls)) }
// A class this car is already registered in is a Registered row in its group, so it is not listed again as closed.
function closedClasses(car) { return offeredClasses.value.filter(cls => !canSelectClass(car, cls) && !ownEntry(car, cls)) }
// A car's paid entries are rows in its own group; only entries whose car has no group are listed on their own.
const sameCar = (row, car) => String(row.inventoryId) === String(car.inventoryId)
const hasGroup = car => !(car.available === false || car.disabled)
function carEntries(car) { return registeredRows.value.filter(row => sameCar(row, car)) }
const entriesWithoutGroup = computed(() => registeredRows.value.filter(row => !registrationCars.value.some(car => hasGroup(car) && sameCar(row, car))))
function sharesClass(car) { return selectedRows.value.some(row => sameCar(row, car) && selectedRows.value.some(other => other.classId === row.classId && !sameCar(other, car))) }
function ownEntry(car, cls) { return registeredRows.value.some(row => row.declaredClassId === cls.id && String(row.inventoryId) === String(car.inventoryId)) }
function closedReason(car, cls) {
  const taken = carFits(car, cls) && takenBy(car, cls)
  if (taken) {
    const other = asArray(registration.value.vehicles).concat(asArray(registration.value.nearby)).find(c => String(c.inventoryId) === String(taken.inventoryId))
    const status = registeredRows.value.includes(taken) ? 'Registered for' : 'Selected for'
    return `${status} ${taken.vehicleName || other?.name || other?.model || 'another car'}.`
  }
  if (cls.available === false) return cls.unavailableReason || 'is not running this weekend.'
  return blockerText(classBlockers(car, cls))
}
function classBlockers(car, cls) {
  const verdict = car.classEligibility?.[cls.id] || {}
  return asArray(verdict.reasons).length ? verdict.reasons : [{ kind: 'reason', text: verdict.reason || 'Not eligible.' }]
}
function reasonLabel(reason) {
  const label = { needs: 'Needs', notAllowed: 'Not allowed', couldNotCheck: "Couldn't check" }[reason.kind]
  return label ? `${label}: ${reason.text}` : reason.text
}
const blockerText = reasons => reasons.map(reasonLabel).join('. ')
function commonBlockers(car) {
  if (!offeredClasses.value.length || offeredClasses.value.some(cls => carFits(car, cls) || cls.available === false)) return []
  const reasons = classBlockers(car, offeredClasses.value[0])
  return offeredClasses.value.every(cls => JSON.stringify(classBlockers(car, cls)) === JSON.stringify(reasons)) ? reasons : []
}
async function toggleClass(car, classId, value) {
  if (busy.value) return
  const cls = offeredClasses.value.find(c => c.id === classId)
  if (!cls || value && !canSelectClass(car, cls)) return
  remember()
  const choice = selectedCars.value[String(car.inventoryId)] ||= { classIds: [] }
  choice.classIds = value ? [...new Set([...(choice.classIds || []), classId])] : (choice.classIds || []).filter(id => id !== classId)
  await restore()
}
function toggleBrowse() { if (!busy.value) showAllCars.value = !showAllCars.value }
function close() {
  if (busy.value) return
  visible.value = false
  if (registrationOwner === owner) registrationOwner = null
}
function update(data) {
  data = payload(data)
  if (!data || !visible.value) return
  if (data.event?.id !== event.value.id) { visible.value = false; return }
  state.value = data
  if (!busy.value && !canUseOverlay(data)) visible.value = false
}
function open(data) {
  data = payload(data)
  if (busy.value || !canUseOverlay(data) || registrationOwner && registrationOwner !== owner) return
  if (visible.value && data.event.id === event.value.id) { update(data); return }
  registrationOwner = owner
  selectedCars.value = {}; inspectionOpen.value = false; rulesOpen.value = false; showAllCars.value = false; error.value = ''; inspectionChanges.value = []; inspectionFailure.value = null
  state.value = data; visible.value = true
}
async function refresh() {
  if (visible.value) update(await lua.overhaul_events_motorsportEvents.getState())
}
async function registerVehicles() {
  if (busy.value || !visible.value || !canRegister(state.value) || !selectionComplete.value || duplicateClass.value || !canAffordSelection.value) return
  let registered = false
  await run(async () => {
    activeAction.value = 'register'
    error.value = ''
    const rows = selectedRows.value.map(row => ({ ...row })), fee = totalFee.value, eventId = event.value.id
    try {
      const carCount = new Set(rows.map(row => row.inventoryId)).size
      const confirmed = await openHouseConfirmation('Register entries?', confirmationRows({
        intro: 'Registration stays open for more cars.',
        // The Register button carries the fee. Cars is listed only when a car is entered in more than one class.
        rows: [{ label: 'Entries', value: rows.length }, ...(carCount === rows.length ? [] : [{ label: 'Cars', value: carCount }]),
          { label: 'Balance', value: balance.value, money: true }, { label: 'After payment', value: balance.value - fee, money: true }],
      }), [{ label: `Register ${money(fee)}`, value: true, extras: { default: true } }, { label: 'Cancel', value: false, extras: { cancel: true } }])
      if (confirmed !== true) return
      const current = await lua.overhaul_events_motorsportEvents.getState()
      update(current)
      if (!visible.value || current.event?.id !== eventId || !canRegister(current)) { error.value = 'Something changed. Park at registration and check your entries again.'; return }
      if (!canAffordSelection.value) {
        error.value = actionError('register', shortfall.value > 0 ? `Your balance changed. You need ${money(shortfall.value)} more.` : 'Payment is unavailable. Check your balance and try again.')
        return
      }
      const result = await lua.overhaul_events_motorsportEvents.addRegistrations(rows, eventId)
      if (result?.ok) registered = true
      else error.value = actionError('register', result?.error)
    } catch (_) { error.value = actionError('register') }
    finally { try { await refresh() } catch (_) {} }
  })
  if (registered) { selectedCars.value = {}; await restore() }
  if (visible.value && !canRegister(state.value)) visible.value = false
}
async function startEvent() {
  if (busy.value || !visible.value || !canRegister(state.value) || !registeredRows.value.length || selectedRows.value.length) return
  const eventId = event.value.id
  await run(async () => {
    activeAction.value = 'start'
    error.value = ''
    try {
      const confirmed = await confirmStartEvent({ entries: registeredRows.value, eventName: event.value.name })
      if (confirmed !== true) return
      const current = await lua.overhaul_events_motorsportEvents.getState()
      update(current)
      if (!visible.value || current.event?.id !== eventId || !canRegister(current)) return
      const result = await lua.overhaul_events_motorsportEvents.startRegisteredEvent(eventId)
      if (result?.ok) visible.value = false
      else error.value = actionError('startRegisteredEvent', result?.error)
    } catch (_) { error.value = actionError('startRegisteredEvent') }
    finally { try { await refresh() } catch (_) {} }
  })
}
async function checkInVehicles() {
  if (busy.value || !visible.value || !canInspect(state.value) || !inspectableCarCount.value) return
  const eventId = event.value.id
  await run(async () => {
    activeAction.value = 'start'
    error.value = ''; inspectionChanges.value = []; inspectionFailure.value = null
    try {
      const current = await lua.overhaul_events_motorsportEvents.getState()
      update(current)
      if (!visible.value || current.event?.id !== eventId || !canInspect(current) || !inspectableCarCount.value) return
      const result = await lua.overhaul_events_motorsportEvents.checkIn()
      if (result?.ok) { if (result.complete) visible.value = false }
      else {
        inspectionFailure.value = result
        inspectionChanges.value = result?.partChanges || []
        inspectionVehicleName.value = result?.vehicleName || asArray(checkIn.value.entries).find(entry => entry.registrationId === result?.registrationId)?.name || ''
        const message = actionError('inspect', result?.error)
        error.value = inspectionVehicleName.value && !message.includes(inspectionVehicleName.value) ? `${inspectionVehicleName.value}: ${message}` : message
      }
    } catch (_) { error.value = actionError('inspect') }
    finally { try { await refresh() } catch (_) {} }
  })
  if (visible.value && !canUseOverlay(state.value)) visible.value = false
}
let timer
watch(visible, value => {
  clearInterval(timer)
  if (value) timer = setInterval(() => refresh().catch(() => {}), 1000)
  else if (registrationOwner === owner) registrationOwner = null
})
onMounted(() => {
  events.on('MotorsportRegistrationOpen', open)
  events.on('motorsportEventsUpdated', update)
})
onUnmounted(() => {
  clearInterval(timer)
  if (registrationOwner === owner) registrationOwner = null
  events.off('MotorsportRegistrationOpen', open)
  events.off('motorsportEventsUpdated', update)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.registration-backdrop { position: fixed; inset: 0; display: grid; align-items: start; justify-items: center; padding: max(1rem, 8vh) 1.5rem 1rem; background: rgba(0, 0, 0, 0.6); pointer-events: auto; }
// One window: a plain title, the labelled facts, the scrolling list, then one footer line. It is as tall as its
// content needs, from the top down, so the title stays put when the list grows.
.registration-popup { @include ms.ms-scale-overlay; display: flex; flex-direction: column; width: min(46em, 100%); min-height: min(24rem, 60vh); max-height: min(44rem, 83vh); box-sizing: border-box; overflow: hidden; background: var(--page); border-radius: var(--radius-panel); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07), 0 1.2em 4em rgba(0, 0, 0, .65); }
.registration-popup > * { padding-left: calc(var(--ms-pad) * 1.4); padding-right: calc(var(--ms-pad) * 1.4); }
.registration-popup > :not(main) { flex-shrink: 0; }
.popup-head { display: flex; align-items: center; justify-content: space-between; gap: var(--ms-gap); padding-top: .9em; }
.head-facts { padding-top: .7em; padding-bottom: .85em; border-bottom: 1px solid var(--line); }
.alert { margin: .7em calc(var(--ms-pad) * 1.4) 0; padding: .6em .8em .5em; color: var(--tone-ink); font-weight: 600; }
main { flex: 1 1 auto; min-height: 0; overflow-y: auto; overscroll-behavior: contain; display: flex; flex-direction: column; gap: var(--ms-gap); padding-top: .85em; padding-bottom: .85em; }
main > * { flex-shrink: 0; }
.car { display: grid; gap: var(--space-1); }
.car-off, .closed { display: flex; align-items: baseline; gap: .4em; margin: 0; color: var(--faint); }
.car-off { padding: var(--space-1) 0; }
.closed { padding-left: .2em; flex-wrap: wrap; color: var(--muted); }
.car-off .ms-icon, .closed .ms-icon { font-size: 1em; align-self: center; }
.car-off strong, .closed strong { color: var(--muted); font-weight: 600; }
.car-head { display: flex; align-items: center; gap: var(--ms-stack); }
.car-head > .ms-meta { margin-left: auto; }
.car-head > strong { min-width: 0; flex: 1; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.car-head > .ms-meta, .car-head > .pill { flex-shrink: 0; white-space: nowrap; }
.reason-chips, .entry-state { display: flex; gap: .5em; flex-wrap: wrap; align-items: center; }
.entry-state { justify-content: flex-end; }
.inspection-row { gap: var(--ms-gap); }
.inspection-reason { white-space: normal; overflow-wrap: anywhere; }
.registration-popup .pill { font-size: max(12px, .74em); }
.status .pill { flex: 0 0 auto; display: inline-flex; gap: .4em; white-space: nowrap; }
.line { padding: var(--ms-row) var(--ms-pad) calc(var(--ms-row) - .08em); }
.line > span:first-child { min-width: 0; display: grid; gap: .1em; }
.class-row :deep(.house-switch) { width: 100%; }
.class-row :deep(.switch-label) { flex: 1 1 auto; min-width: 0; }
.class-copy { display: flex; align-items: center; justify-content: space-between; gap: .6em; width: 100%; }
.class-index { display: flex; align-items: baseline; gap: .5em; margin-right: 1em; white-space: nowrap; }
.inspection-rules { margin: 0; padding-left: 1.2em; display: grid; gap: .3em; }
.status { display: flex; align-items: baseline; justify-content: space-between; gap: .9em; margin: 0; padding: var(--ms-stack) var(--space-3); background: var(--panel); border-radius: var(--radius-tile); }
.status small { display: block; }
// Footer: one line. What is registered and selected, the balance, then the buttons.
// The Register button carries the total, so the footer does not repeat it.
.popup-foot { gap: .6em; padding-top: .8em; padding-bottom: .9em; border-top: 1px solid var(--line); }
.popup-foot > .ms-facts { align-items: start; }
.popup-foot > .ms-facts.ruled > * { padding: 0 .75em; }
.popup-foot > .ms-facts.ruled > :first-child { padding-left: 0; }
</style>

<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ComputerPanel class="vehicle-export rls-house rls-house-card">
    <div class="export-body scroll" v-bng-ui-nav-scroll>
      <div v-if="!vehicle" class="empty-state empty">
        <h3>Choose a vehicle first</h3>
        <p>Pick a vehicle on the garage computer, then open Export configuration.</p>
      </div>

      <template v-else>
        <header class="vehicle-head">
          <div class="vehicle-photo">
            <img v-if="vehicle.thumbnail && !imageFailed" :src="vehicle.thumbnail" :alt="vehicle.name" @error="imageFailed = true" />
          </div>
          <div class="vehicle-identity">
            <h2 class="block-title">{{ vehicle.name }}</h2>
            <p class="muted">{{ vehicle.modelName }}</p>
          </div>
        </header>

        <section v-if="vehicle.dependencies?.length && (editing || result)" class="group dependency-section">
          <h3 class="group-title">Mods this build needs</h3>
          <div class="export-block">
            <p v-for="dependency in vehicle.dependencies" :key="dependency" class="content-row dependency">{{ dependency }}</p>
          </div>
          <p v-if="editing" class="hint">They are not in the ZIP. Anyone you share it with needs them installed.</p>
        </section>

        <main class="export-column" aria-live="polite" :aria-busy="busy">
          <template v-if="result">
            <div class="export-status" :class="testsIncomplete ? 'tone-warn' : 'tone-go'" role="status">
              <h2 class="status-title result-heading">{{ resultTitle }}</h2>
              <p class="status-text">{{ resultHolds }}</p>
              <p class="status-text">{{ shareText }}</p>
              <p v-if="result.returnWarnings?.length" class="status-text tone-warn" data-test="return-warning">Your career is ready. Some vehicle details could not be restored exactly.</p>
              <div v-if="result.archive || result.folder" class="fact saved-as">
                <span class="fact-key">In your BeamNG user folder</span>
                <span class="export-path">{{ String(result.archive || result.folder).replace(/^\/+/, '') }}</span>
              </div>
            </div>

            <div v-if="figures.length" class="export-block test-results" :data-test="testsIncomplete ? 'incomplete-tests' : undefined">
              <div class="perf-facts">
                <div v-for="figure in figures" :key="figure.label" class="fact perf-fact">
                  <span class="fact-key">{{ figure.label }}</span>
                  <span v-if="figure.measured" class="perf-value">{{ measurement(figure.value).number }}<small v-if="measurement(figure.value).unit">{{ measurement(figure.value).unit }}</small></span>
                  <span v-else class="perf-value perf-missing tone-warn"><span>Not measured</span></span>
                </div>
              </div>
              <p v-for="issue in issues" :key="issue.labels" class="content-row issue-row">
                <span class="issue-label">{{ issue.labels }}</span>
                <span class="content-label">{{ issue.message }}</span>
              </p>
            </div>

            <p v-if="notice" class="next-step" :class="{ 'tone-stop folder-failed': folderFailed }" role="status">{{ notice }}</p>
          </template>

          <section v-else-if="busy && visitsMaps && !recoveryPending" class="test-session" data-test="test-session">
            <div class="export-status tone-wait">
              <h2 class="status-title">{{ busyTitle }}</h2>
              <p v-if="busyText" class="status-text">{{ busyText }}</p>
            </div>
            <HouseLoader v-if="!stepsShown" class="session-loader tone-wait" :label="returnCaption" />
            <ol v-else class="export-block">
              <li v-for="(step, index) in testSteps" :key="step.key" class="content-row test-step"
                :class="[index < currentStep ? 'tone-go' : index === currentStep ? 'tone-wait active' : 'tone-idle']">
                <span class="step-number">{{ index + 1 }}</span>
                <span class="content-label">{{ index === currentStep ? progress.message : step.label }}</span>
                <strong v-if="index < currentStep" class="content-value step-state">Done</strong>
                <HouseLoader v-else-if="index === currentStep" class="row-loader tone-wait" label="" />
              </li>
            </ol>
          </section>

          <template v-else-if="recoveryPending">
            <section v-if="busy" class="test-session" role="status">
              <div class="export-status tone-wait">
                <h2 class="status-title">Returning to your career</h2>
              </div>
              <HouseLoader class="session-loader tone-wait" label="" />
            </section>
            <div v-else class="export-status tone-stop" role="alert">
              <h2 class="status-title">Finish returning to your career</h2>
              <p v-if="errorLines.length" class="status-text">{{ errorLines[0] }}</p>
              <p class="status-text">{{ returnFailed ? 'If you turned off any vehicle mods, turn them back on, then press Return to career again.' : 'Press Return to career.' }}</p>
            </div>
          </template>

          <template v-else>
            <section v-if="busy" class="test-session" role="status">
              <div class="export-status tone-wait">
                <h2 class="status-title">Exporting your build</h2>
              </div>
              <HouseLoader class="session-loader tone-wait" label="" />
            </section>
            <div v-else-if="error" class="export-status tone-stop" role="alert">
              <h2 class="status-title">Nothing was exported</h2>
              <p class="status-text">{{ errorLines[0] }}</p>
              <p v-for="line in errorLines.slice(1)" :key="line" class="status-text detail">{{ line }}</p>
            </div>
            <div v-else-if="replaceRequested" class="export-status tone-warn replace-footer-copy" role="alert">
              <h2 class="status-title">An export with this name already exists</h2>
              <p class="status-text">Replace it, or change Export name and export again.</p>
            </div>
            <div v-else-if="notice" class="export-status tone-ask" role="status">
              <h2 class="status-title">{{ noticeLines.length > 1 ? noticeLines[0] : 'Nothing was exported' }}</h2>
              <p class="status-text">{{ noticeLines.length > 1 ? noticeLines.slice(1).join(' ') : noticeLines[0] }}</p>
            </div>

            <div class="fields form-heading">
              <label class="field-block">
                <span class="field-label">Export name</span>
                <input v-model="draft.name" v-bng-text-input bng-nav-item class="field" :class="{ 'needs-change tone-warn': replaceRequested, invalid: !!nameError }" data-test="export-name"
                  :disabled="formLocked" maxlength="80" spellcheck="false" autocomplete="off"
                  :aria-invalid="!!nameError" :aria-describedby="nameError ? 'export-name-error' : undefined" />
                <span v-if="nameError" id="export-name-error" class="validation-error" role="status">{{ nameError }}</span>
              </label>
              <div class="field-block">
                <div class="metadata-fields">
                  <div class="field-block">
                    <span id="export-config-type-label" class="field-label">Build type</span>
                    <HouseMenu v-model="draft.configType" :items="configTypeItems" :disabled="formLocked" teleport
                      aria-labelledby="export-config-type-label" data-test="export-config-type" />
                  </div>
                  <div class="field-block">
                    <span id="export-body-style-label" class="field-label">Body type</span>
                    <HouseMenu v-model="draft.bodyStyle" :items="bodyStyleItems" :disabled="formLocked" teleport
                      aria-labelledby="export-body-style-label" data-test="export-body-style" />
                  </div>
                </div>
                <span class="hint">Both set how this build is listed in the vehicle selector.</span>
              </div>
              <label class="field-block">
                <span class="field-label">Description <span class="optional">Optional</span></span>
                <textarea v-model="draft.description" v-bng-text-input bng-nav-item class="field area" data-test="export-description"
                  :disabled="formLocked" maxlength="320" placeholder="What makes this build yours?" />
              </label>
            </div>

            <div class="export-block export-options">
              <div class="option-line">
                <HouseSwitch :model-value="effectiveFuel" row :disabled="formLocked || !vehicle.fuel" data-test="include-fuel" @update:model-value="draft.includeFuel = $event">Include fuel setup</HouseSwitch>
                <p class="hint">{{ vehicle.fuel ? 'Only used when the build is driven in RLS Career Overhaul.' : 'This vehicle has no fuel setup to include.' }}</p>
                <div v-if="vehicle.fuel" class="fuel-facts" :class="{ 'left-out': !effectiveFuel }">
                  <div v-for="(fact, index) in vehicle.fuel.summary" :key="index" class="fact fuel-fact"
                    :class="{ 'starts-row': index > 0 && fact.group !== vehicle.fuel.summary[index - 1].group }" role="group" :aria-label="fact.label">
                    <span class="fact-key">{{ fact.label }}</span>
                    <span class="fact-value">{{ fact.value }}</span>
                  </div>
                </div>
              </div>
              <div class="option-line">
                <div class="option-head">
                  <span id="export-thumbnail-label" class="option-title">Photo</span>
                  <HouseMenu v-model="draft.thumbnailMode" :items="thumbnailItems" :disabled="formLocked" teleport aria-labelledby="export-thumbnail-label" data-test="export-thumbnail" />
                </div>
                <p v-if="!vehicle.thumbnail" class="hint">This vehicle has no garage photo yet.</p>
              </div>
              <div class="option-line">
                <HouseSwitch :model-value="effectiveTests" row :disabled="formLocked || vehicle.testsAvailable === false" data-test="run-tests" @update:model-value="draft.runTests = $event">Run performance tests</HouseSwitch>
                <p class="hint">{{ vehicle.testsAvailable === false ? vehicle.testUnavailableReason || 'Performance tests are not available for this vehicle.' : 'Measures 0–60 mph, top speed, braking from 60 mph and off-road score.' }}</p>
              </div>
              <p v-if="visitsMaps" class="option-line hint away-note" data-test="away-note">The game leaves the garage to load {{ awayPlaces }}, then brings you back.</p>
            </div>
          </template>
        </main>
      </template>
    </div>

    <template #footer>
      <div class="export-footer">
        <p class="hint footer-hint">{{ footerHint }}</p>
        <div class="footer-actions">
          <HouseButton v-if="recoveryPending" variant="primary" :disabled="busy || !restoreCareer" data-test="restore-career" @click="retryReturn">Return to career</HouseButton>
          <HouseButton v-else-if="busy && visitsMaps" :disabled="!canCancel" data-test="cancel-tests" @click="cancelTests">Cancel export</HouseButton>
          <template v-else-if="replaceRequested">
            <HouseButton :disabled="busy" data-test="cancel-replace" @click="replaceRequested = false">Keep existing export</HouseButton>
            <HouseButton variant="primary" :disabled="busy" data-test="confirm-replace" @click="runExport(true)">Replace export</HouseButton>
          </template>
          <template v-else>
            <HouseButton variant="quiet" :disabled="busy" data-test="export-back" @click="emit('back')">Back to computer</HouseButton>
            <template v-if="result">
              <HouseButton data-test="edit-export" @click="editExport">Change options</HouseButton>
              <HouseButton v-if="openFolder" variant="primary" data-test="open-export-folder" @click="showFolder">Open export folder</HouseButton>
            </template>
            <HouseButton v-else variant="primary" :disabled="!canExport" data-test="export-submit" @click="runExport(false)">
              {{ error ? 'Try again' : 'Export configuration' }}
            </HouseButton>
          </template>
        </div>
      </div>
    </template>
  </ComputerPanel>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { vBngTextInput, vBngUiNavScroll } from '@/common/directives'
import ComputerPanel from '../ComputerPanel.vue'
import { HouseButton, HouseLoader, HouseMenu, HouseSwitch } from '../house/index.js'
import { exportSteps } from './exportSteps.js'

// The caller owns reading the selected garage vehicle and writing an export.
// BeamLab supplies an explicit fixture adapter; this component never writes files or changes parts.
const props = defineProps({
  vehicle: { type: Object, default: null },
  exportConfiguration: Function,
  openFolder: Function,
  restoreCareer: Function,
  metadataOptions: { type: Object, default: () => ({}) },
  jobState: { type: Object, default: null },
  persistOnUnmount: Boolean,
})
const emit = defineEmits(['back'])
const draft = reactive({ name: '', description: '', configType: '', bodyStyle: '', includeFuel: true, thumbnailMode: 'showroom', runTests: false })
const busy = ref(false)
const error = ref('')
const notice = ref('')
const result = ref(null)
const unavailableTests = computed(() => result.value?.tests?.items?.filter(test => test.status !== 'measured') || [])
const testsIncomplete = computed(() => result.value?.tests?.status === 'incomplete')
const resultTitle = computed(() => {
  if (!testsIncomplete.value) return 'Ready to share'
  const missing = unavailableTests.value.length
  return `Ready to share, ${missing} ${missing === 1 ? 'test' : 'tests'} not measured`
})
// "4.2 s" reads as a numeral with a quiet unit beside it.
function measurement(value) {
  const parts = /^(-?[\d.,]+)\s*(.*)$/.exec(String(value ?? ''))
  return parts ? { number: parts[1], unit: parts[2] } : { number: String(value ?? ''), unit: '' }
}
const replaceRequested = ref(false)
const imageFailed = ref(false)
const cancelRequested = ref(false)
const recoveryPending = ref(false)
// A manual return was tried and did not get the player back.
const returnFailed = ref(false)
const progress = ref({ stage: 'prepare', message: 'Saving your career…' })
// The job is on its way back because the player pressed Return to career.
const manualReturn = computed(() => props.jobState?.manualReturn === true)
const testSteps = computed(() => exportSteps({ runTests: draft.runTests, showroomPhoto: draft.thumbnailMode === 'showroom' }))
const currentStep = computed(() => testSteps.value.findIndex(step => step.key === progress.value.stage))
let controller
let generation = 0
let applyingJob = false

const nameError = computed(() => {
  const name = draft.name.trim()
  if (!name) return 'Give the export a name.'
  if (name.endsWith('.')) return 'Names cannot end with a period.'
  if (/[<>:"/\\|?*\x00-\x1f]/.test(name)) return 'Names cannot use < > : " / \\ | ? or *.'
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) return 'Windows reserves this name. Pick another one.'
  return ''
})
const effectiveFuel = computed(() => !!props.vehicle?.fuel && draft.includeFuel)
const thumbnailItems = computed(() => [
  { value: 'showroom', label: 'New showroom photo' },
  { value: 'garage', label: 'Current garage photo', disabled: !props.vehicle?.thumbnail },
  { value: 'none', label: 'No photo' },
])
const effectivePreview = computed(() => draft.thumbnailMode === 'showroom' || (draft.thumbnailMode === 'garage' && !!props.vehicle?.thumbnail))
const effectiveTests = computed(() => props.vehicle?.testsAvailable !== false && draft.runTests)
const visitsMaps = computed(() => effectiveTests.value || draft.thumbnailMode === 'showroom')
const formLocked = computed(() => busy.value || recoveryPending.value)
// The form is on screen: no result, no export away from the garage, no failed return.
const editing = computed(() => !result.value && !recoveryPending.value && !(busy.value && visitsMaps.value))
// A message may carry secondary detail after a line break; the first line is the headline.
const errorLines = computed(() => String(error.value || '').split('\n').filter(Boolean))
const noticeLines = computed(() => String(notice.value || '').split('\n').filter(Boolean))
// What the finished export holds, as one plain sentence.
const resultHolds = computed(() => {
  const contents = ['parts', 'tuning', 'paint']
  if (effectiveFuel.value) contents.push('the fuel setup')
  if (effectivePreview.value) contents.push('a photo')
  const tests = result.value?.tests?.items || []
  if (tests.length > unavailableTests.value.length) contents.push(testsIncomplete.value ? 'the measured test results' : 'the test results')
  const container = result.value?.archive ? 'The ZIP' : 'The folder'
  return `${container} includes ${contents.slice(0, -1).join(', ')} and ${contents[contents.length - 1]}.`
})
// How to pass it on. A build that needs other mods says so here, next to the instruction.
const shareText = computed(() => {
  const share = result.value?.archive ? 'Send it to a friend. They put it in their BeamNG mods folder.' : 'Share all the files in this folder together.'
  return props.vehicle?.dependencies?.length ? `${share} They also need the mods listed above.` : share
})
// One slot per test, in test order: its figure, or "Not measured". A result without a test report,
// or with labels that do not line up, falls back to the measured figures alone.
const figures = computed(() => {
  const facts = (result.value?.performance || []).map(fact => ({ ...fact, measured: true }))
  const tests = result.value?.tests?.items
  if (!tests?.length) return facts
  const byLabel = new Map(facts.map(fact => [fact.label, fact]))
  if (tests.some(test => test.status === 'measured' && !byLabel.has(test.label))) return facts
  return tests.map(test => test.status === 'measured' ? byLabel.get(test.label) : { label: test.label, measured: false })
})
// Why tests have no figure. A reason shared by several tests is said once, with their names.
const issues = computed(() => {
  const groups = new Map()
  for (const test of unavailableTests.value) groups.set(test.message || '', [...(groups.get(test.message || '') || []), test.label])
  const all = result.value?.tests?.items?.length
  return [...groups].filter(([message]) => message).map(([message, labels]) => ({ message, labels: labels.length > 1 && labels.length === all ? 'All tests' : labels.join(', ') }))
})
// What the busy status adds to its title, by stage.
// A failure on the way sends the game back on its own; the reason is shown while it returns.
const stopReason = computed(() => busy.value && !cancelRequested.value && !manualReturn.value ? String(props.jobState?.error || '').split('\n')[0] : '')
const stepsShown = computed(() => !cancelRequested.value && !manualReturn.value && !stopReason.value)
const canCancel = computed(() => stepsShown.value && progress.value.stage !== 'return' && progress.value.stage !== 'write')
const busyTitle = computed(() => {
  if (cancelRequested.value) return 'Cancelling the export'
  if (manualReturn.value) return 'Returning to your career'
  return stopReason.value ? 'Stopping the export' : 'Exporting your build'
})
// On the way back the loader shows the game's stage, unless the title already says it.
const returnCaption = computed(() => {
  const message = progress.value.stage === 'return' ? String(progress.value.message || '') : ''
  return message.startsWith(busyTitle.value) ? '' : message
})
const busyText = computed(() => {
  if (cancelRequested.value) return 'Nothing will be exported.'
  if (manualReturn.value) return ''
  if (stopReason.value) return stopReason.value
  return progress.value.stage === 'write' ? 'You are back in your career.' : 'Your own vehicle stays parked.'
})
const awayPlaces = computed(() => effectiveTests.value
  ? draft.thumbnailMode === 'showroom' ? 'the test track and the showroom' : 'the test track'
  : 'the showroom')
// One line, only where it tells the player something the screen above does not.
const footerHint = computed(() => {
  if (recoveryPending.value) return busy.value ? '' : 'Your career was saved before the export began.'
  if (busy.value) return visitsMaps.value && canCancel.value ? 'Cancelling brings you back without exporting.' : ''
  if (replaceRequested.value || result.value || error.value || notice.value) return ''
  return 'Parts, tuning and paint are always included. Exporting does not change your vehicle.'
})
const canExport = computed(() => !!props.vehicle && typeof props.exportConfiguration === 'function' && !formLocked.value && !nameError.value)
// The host supplies the native metadata editor's catalogue options. Keep a mod's
// original value even when it isn't present in the shared catalogue.
function metadataItems(options, current, original) {
  const items = (options || []).map(option => typeof option === 'string' ? { value: option, label: option } : option)
  for (const value of [original, current]) {
    if (value && !items.some(option => option.value === value)) items.unshift({ value, label: value })
  }
  return [{ value: '', label: 'Unspecified' }, ...items.filter(option => option.value !== '')]
}
const configTypeItems = computed(() => metadataItems(props.metadataOptions.configTypes, draft.configType, props.vehicle?.metadata?.['Config Type']))
const bodyStyleItems = computed(() => metadataItems(props.metadataOptions.bodyStyles, draft.bodyStyle, props.vehicle?.metadata?.['Body Style']))

watch(() => props.vehicle, vehicle => {
  generation++
  if (!props.persistOnUnmount) controller?.abort()
  busy.value = false
  cancelRequested.value = false
  recoveryPending.value = false
  returnFailed.value = false
  imageFailed.value = false
  draft.name = vehicle?.name || ''
  draft.description = vehicle?.description || ''
  draft.configType = vehicle?.metadata?.['Config Type'] || ''
  draft.bodyStyle = vehicle?.metadata?.['Body Style'] || ''
  draft.includeFuel = true
  draft.thumbnailMode = 'showroom'
  draft.runTests = false
  clearFeedback()
}, { immediate: true })

watch(() => [draft.name, draft.description, draft.configType, draft.bodyStyle, draft.includeFuel, draft.thumbnailMode, draft.runTests], () => {
  if (applyingJob) return
  error.value = ''
  notice.value = ''
  replaceRequested.value = false
})

let observedJob
watch(() => props.jobState, state => {
  if (!state?.id || String(state.inventoryId) !== String(props.vehicle?.inventoryId)) return
  applyingJob = true
  nextTick(() => { applyingJob = false })
  if (observedJob !== state.id) {
    observedJob = state.id
    returnFailed.value = false
    const request = state.request || {}
    draft.name = request.name || draft.name
    draft.description = request.description || ''
    draft.configType = request.metadata?.['Config Type'] || ''
    draft.bodyStyle = request.metadata?.['Body Style'] || ''
    draft.includeFuel = request.includeFuel === true
    draft.thumbnailMode = request.thumbnailMode || 'none'
    draft.runTests = request.runTests === true
  }
  busy.value = state.busy === true && state.recoveryRequired !== true
  recoveryPending.value = state.recoveryRequired === true
  if (state.cancelled === true && state.busy === true && !state.recoveryRequired) cancelRequested.value = true
  if (state.manualReturn === true && state.recoveryRequired === true) returnFailed.value = true
  if (state.stage) progress.value = {stage: state.stage, message: state.message}
  if (state.result?.ok) result.value = state.result
  else if (!state.busy && state.phase === 'cancelled') notice.value = state.message || state.result?.message
  else if (state.error) error.value = state.error
}, {immediate: true})

function clearFeedback() {
  error.value = ''
  notice.value = ''
  result.value = null
  replaceRequested.value = false
}
function editExport() { clearFeedback() }

async function runExport(replace) {
  if (!canExport.value) return
  const token = ++generation
  const request = {
    inventoryId: props.vehicle.inventoryId,
    name: draft.name.trim(),
    description: draft.description.trim(),
    metadata: { 'Config Type': draft.configType || false, 'Body Style': draft.bodyStyle || false },
    includeFuel: effectiveFuel.value,
    includePreview: effectivePreview.value,
    thumbnailMode: draft.thumbnailMode,
    fuelActivation: 'career',
    runTests: effectiveTests.value,
    replace: replace === true,
  }
  busy.value = true
  cancelRequested.value = false
  returnFailed.value = false
  controller = new AbortController()
  progress.value = { stage: 'prepare', message: 'Saving your career…' }
  error.value = ''
  notice.value = ''
  try {
    // The service owns cleanup, including cancellation, even if this UI unmounts.
    // It must resolve only after returning to career or retaining a recovery ticket.
    const response = await props.exportConfiguration(request, {
      signal: controller.signal,
      onProgress: update => { if (token === generation && testSteps.value.some(step => step.key === update?.stage)) progress.value = update },
    })
    if (token !== generation) return
    if (response?.code === 'exists') {
      replaceRequested.value = true
      return
    }
    if (response?.started === false) {
      error.value = response.message || 'The export could not start. Check the selected vehicle and try again.'
      return
    }
    if ((request.runTests || request.thumbnailMode === 'showroom') && response?.careerRestored !== true) {
      recoveryPending.value = true
      error.value = response?.message || 'The game could not confirm that you are back in your career.'
      return
    }
    if (response?.code === 'cancelled') {
      notice.value = response.message || 'Export cancelled\nNothing was exported. Your vehicle is unchanged.'
      return
    }
    if (!response?.ok || !Array.isArray(response.files) || response.files.length === 0) {
      error.value = response?.message || 'The export could not be saved. Try again.'
      return
    }
    replaceRequested.value = false
    result.value = response
  } catch (err) {
    if (token === generation) {
      recoveryPending.value = request.runTests || request.thumbnailMode === 'showroom'
      error.value = recoveryPending.value ? 'The export was interrupted before the game could bring you back.' : 'The export could not be saved. Your vehicle is unchanged.'
    }
  } finally {
    if (token === generation) busy.value = false
  }
}

function cancelTests() {
  cancelRequested.value = true
  controller?.abort()
}

async function retryReturn() {
  if (busy.value || !props.restoreCareer) return
  const token = generation
  busy.value = true
  try {
    const response = await props.restoreCareer()
    if (token !== generation) return
    if (response?.careerRestored === true) {
      recoveryPending.value = false
      returnFailed.value = false
      error.value = ''
      notice.value = response.message || 'You are back in your career\nNothing was exported. Your career is ready.'
    } else { if (response?.status?.manualReturn === true) returnFailed.value = true; error.value = response?.message || 'The game could not bring you back yet.' }
  } catch (err) {
    if (token === generation) error.value = 'The game could not bring you back yet.'
  } finally {
    if (token === generation) busy.value = false
  }
}

const folderFailed = ref(false)
async function showFolder() {
  const token = generation
  const failed = 'The folder could not be opened. You can find the export at the path shown above.'
  try {
    const response = await props.openFolder(result.value)
    if (token !== generation) return
    folderFailed.value = response?.ok === false
    notice.value = response?.message || (folderFailed.value ? failed : '')
  } catch (err) {
    if (token === generation) { folderFailed.value = true; notice.value = failed }
  }
}
onBeforeUnmount(() => { generation++; if (!props.persistOnUnmount) controller?.abort() })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/vehicleExport.scss" as *;

// One spacing scale, from the house tokens: --space-1 inside a row, --space-2 title to content,
// --space-4 between fields and inside a group, --gutter between groups and to the panel edge.
// One column under a compact vehicle header, like the vehicle card on the garage computer.
// The panel is as tall as its content, up to the height of the screen.
.vehicle-export { --gutter: 1.5em; --scrollbar: 0.5em; width: min(54em, 100%); height: auto; max-height: 100%; border-bottom: 0; background: var(--page); }
.vehicle-export :deep(> .panel-content) { flex: 1 1 auto; min-height: 0; }
.vehicle-export :deep(> .footer-container) { padding: 0; border-top: 1px solid var(--line); }
// The scrollbar sits inside the right gutter, so the blocks keep the same inset on both sides.
.export-body {
  display: grid; grid-auto-rows: max-content; align-content: start; gap: var(--gutter);
  padding: var(--gutter) calc(var(--gutter) - var(--scrollbar)) var(--gutter) var(--gutter);
  min-height: 0; overflow-y: auto; scrollbar-gutter: stable;
}
.export-column { min-width: 0; display: grid; align-content: start; gap: var(--gutter); }
// Status and its steps read as one group.
.test-session { min-width: 0; display: grid; align-content: start; gap: var(--space-4); }
.group { display: grid; gap: var(--space-2); min-width: 0; }
// The one heading left names a list that would not explain itself. Sentence case, never capitals.
.group-title { margin: 0; font-size: 0.92em; font-weight: 700; line-height: 1.25; }

.vehicle-head { display: grid; grid-template-columns: 16em minmax(0, 1fr); align-items: center; gap: var(--gutter); min-width: 0; }
.vehicle-photo { aspect-ratio: 16 / 9; background: var(--photo); border-radius: var(--radius-panel); overflow: hidden; display: grid; place-items: center; }
.vehicle-photo img { display: block; width: 100%; height: 100%; object-fit: cover; }
.vehicle-identity { display: grid; gap: var(--space-1); min-width: 0; }
.vehicle-identity .block-title { font-size: 1.6em; overflow-wrap: anywhere; }
.dependency { overflow-wrap: anywhere; }

// Labelled values: a small plain label over each value, never joined into one line.
.fact-key { font-size: 0.8em; font-weight: 600; letter-spacing: 0; text-transform: none; color: var(--faint); }
.fuel-facts, .perf-facts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: var(--space-4); }
// Four across: the engine's values on one row, the tank's on the next.
// They sit under the switch that includes them, and dim when it is off.
.fuel-facts { padding-top: var(--space-3); }
.fuel-facts.left-out { opacity: 0.45; }
.fuel-fact { align-content: start; }
.fuel-fact.starts-row { grid-column-start: 1; }
.fuel-fact .fact-value { font-size: 0.92em; white-space: normal; overflow-wrap: anywhere; }
// One slot per test, always in the same order. A figure is large and plain: its colour would
// read as good or bad, and the screen only knows measured or not.
.perf-facts { padding-top: var(--inset); padding-bottom: var(--inset); }
.perf-fact { align-content: start; }
.perf-value { font-size: 1.7em; font-weight: 800; line-height: 1.1; font-variant-numeric: tabular-nums; }
.perf-value small { margin-left: 0.3em; color: var(--muted); font-size: 0.5em; font-weight: 700; }
// "Not measured" keeps the figure's line box, so the four slots share one baseline.
.perf-missing > span { color: var(--tone-ink); font-size: calc(0.92em / 1.7); font-weight: 700; }
// Why a test has no figure: one line each under the row of slots, on the same columns.
// The test's name looks like the slot label above it; the reason is the text to read.
.perf-facts + .issue-row { border-top: 1px solid var(--line); }
.issue-row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: var(--space-4); font-size: 1em; }
.issue-label { color: var(--faint); font-size: 0.8em; }
.issue-row .content-label { grid-column: 2 / -1; font-size: 0.92em; }

// Finished steps are green, the running one is blue and carries the loader, the ones to come stay faint.
.test-step { align-items: center; }
.test-step.tone-go .step-number, .test-step.active .step-number, .test-step.active .content-label { color: var(--tone-ink); }
.test-step.tone-go .content-label { color: var(--muted); }
.test-step.tone-idle .content-label { color: var(--faint); }
.test-step.active .content-label { font-weight: 700; }
.test-step .row-loader { --accent: var(--tone-ink); flex: 0 0 auto; padding: 0; font-size: 0.34em; }
.row-loader :deep(.house-loader__label) { display: none; }

.fields { display: grid; gap: var(--space-4); }
.field-label, .option-title { font-size: 0.92em; font-weight: 700; line-height: 1.25; }
.optional { margin-left: var(--space-1); color: var(--faint); font-size: 0.87em; font-weight: 600; }
.field { width: 100%; @include house-focus; }
.field.area { min-height: 4.5em; resize: none; }
// While the name question is open, the field it is about carries the same amber.
.field.needs-change { border-color: var(--tone-ink); }
.field.invalid { border-color: var(--bad); }
.metadata-fields { display: grid; grid-template-columns: 1fr 1fr; gap: var(--space-4); align-items: start; }
.metadata-fields .field-block { min-width: 0; }
.metadata-fields :deep(.house-menu), .metadata-fields :deep(.menu-btn) { width: 100%; }
.validation-error { color: var(--bad); font-size: 0.8em; font-weight: 600; }

.option-line { display: grid; gap: var(--space-1); margin: 0; padding: var(--inset) 0; border-bottom: 1px solid var(--line); }
.option-line:last-child { border-bottom: 0; }
.option-line :deep(.house-switch.switch-row) { width: 100%; font-size: 0.92em; font-weight: 700; }
.option-head { display: flex; align-items: center; justify-content: space-between; gap: var(--space-4); }
.option-head :deep(.house-menu) { flex: 0 1 17em; min-width: 0; }
.option-head :deep(.menu-btn) { width: 100%; }

.saved-as { padding-top: var(--space-2); }
.export-path { font-size: 0.92em; font-weight: 700; overflow-wrap: anywhere; }
.next-step { margin: 0; font-size: 0.92em; font-weight: 600; line-height: 1.4; text-wrap: pretty; }
.folder-failed { color: var(--tone-ink); }

// ComputerPanel centres a lone footer child; this footer is a hint on the left and the actions on the right,
// on the same left and right edges as the blocks above.
.vehicle-export.rls-house.rls-house-card :deep(> .footer-container > .export-footer) { display: flex; align-items: center; justify-content: space-between; gap: var(--gutter); width: 100%; padding: var(--space-4) var(--gutter); }
.footer-hint { flex: 1 1 auto; min-width: 0; line-height: 1.4; text-wrap: balance; }
.footer-actions { flex: 0 0 auto; display: flex; align-items: center; justify-content: flex-end; flex-wrap: wrap; gap: var(--space-2); margin-left: auto; }
@media (max-width: 700px) {
  .vehicle-export { --gutter: 1.1em; }
  .vehicle-head { grid-template-columns: 9em minmax(0, 1fr); }
  .fuel-facts, .perf-facts, .issue-row { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .export-footer { flex-wrap: wrap; }
}
</style>

<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!--
  ChallengeCreateModal: the create and edit form for a challenge, shown over the profile screen.

  Map, in reading order
    1. Props, emits, and the UI-only refs (tab, searches, seed text, copy status, dropdown and overlay refs).
    2. The form: useChallengeForm owns every form value and the operations that write them. It is destructured
       below into top-level names. The seed codec and the multiselect state are created after it.
    3. Dropdowns: useDropdown owns open state and placement; this component registers their listeners in
       onMounted and removes them in onBeforeUnmount.
    4. Watchers, in creation order: tabs, win condition, props.open, seedPayload (deep), seedInput, editChallengeId.
       Their order decides which encode request goes first, so do not reorder them.
    5. Open and edit session, the edit-data response, lifecycle, save, seed actions, copy.

  Parts (challengeCreate/)
    ChallengeBasicFields    name, ID, description, difficulty and map dropdowns (both teleported menus)
    ChallengeStartingTab    starting capital, win condition select, debt block
    ChallengeMultiselectModal  teleported multiselect picker
  The seed section, the win-condition variable fields, the garages, starter vehicles and economy tabs are in this template;
  their inputs write the form state with v-model. ChallengeBasicFields and ChallengeStartingTab take values as
  props and report changes as events; neither writes a prop.

  Modules (challengeCreate/)
    useChallengeForm        form state and writes
    useWinConditionSchema, useMultiselectVariables
    seedCodec               Lua encode and decode traffic
    variableSchema, rounding
-->
<template>
  <!-- Text editing needs a keyboard; Cancel and Save remain in the pad path. -->
  <div
    v-show="open"
    ref="overlayRef"
    v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (onRequestClose(), false) }"
    class="ccm-overlay"
    tabindex="-1"
    @click.stop
    @mousedown.stop
    @keydown.stop>
    <div class="rls-house ccm-content" @click.stop @mousedown.stop @keydown.stop>
      <div class="ccm-header">
        <h2 class="ccm-title">{{ editChallengeData ? 'Edit Challenge' : 'Create Challenge' }}</h2>
      </div>

      <!-- The body is the one scroll box: tabs and their panels flow inside it, so no field hides in a nested scroller. -->
      <div class="ccm-body scroll" v-bng-ui-nav-scroll>
        <ChallengeBasicFields
          v-model:name="formName"
          v-model:fieldId="formId"
          v-model:description="formDescription"
          :id-locked="!!editChallengeData"
          :difficulty="formDifficulty"
          :difficulty-open="difficultyDropdownOpen"
          :difficulty-style="difficultyDropdownStyle"
          :map-label="formMapLabel"
          :map-id="formMap"
          :map-options="mapOptions"
          :map-open="mapDropdownOpen"
          :map-style="mapDropdownStyle"
          :set-difficulty-container="setDifficultyContainer"
          :set-map-container="setMapContainer"
          @toggleDifficulty="toggleDifficultyDropdown"
          @selectDifficulty="selectDifficulty"
          @closeDifficulty="closeDifficultyDropdown"
          @toggleMap="toggleMapDropdown"
          @selectMap="selectMap"
          @closeMap="closeMapDropdown"
        />

        <div class="ccm-seed-section">
          <div class="ccm-field">
            <label>Challenge Seed</label>
            <input v-bng-text-input
              v-model="seedInput"
              type="text"
              class="ccm-input ccm-seed-input"
              placeholder="Enter seed or leave empty for random"
              @keyup.enter="onSeedEnter()"
              @blur="onSeedBlur()"
            />
          </div>
          <div class="ccm-seed-row">
            <HouseButton class="ccm-seed-btn" @click.stop="onGenerateSeed()" @mousedown.stop>Generate Random Seed</HouseButton>
            <HouseButton class="ccm-seed-btn" :disabled="!seedInput" @click.stop="onCopySeed()" @mousedown.stop>{{ copyStatus || 'Copy Seed' }}</HouseButton>
          </div>
          <div v-if="seedError" class="ccm-seed-error">{{ seedError }}</div>
        </div>

        <div class="ccm-tabs">
          <div class="ccm-tab-nav seg bar">
            <button
              v-for="tab in tabs"
              :key="tab.id"
              type="button"
              :aria-pressed="activeTab === tab.id"
              :class="{ active: activeTab === tab.id }"
              @click.stop="activeTab = tab.id"
            >
              {{ tab.label }}
            </button>
          </div>

          <div class="ccm-tab-content">
            <ChallengeStartingTab
              v-if="activeTab === 'starting'"
              v-model:startingCapital="formStartingCapital"
              v-model:winCondition="formWinCondition"
              v-model:loanAmount="formLoanAmount"
              v-model:interestPercent="interestPercent"
              v-model:loanPayments="formLoanPayments"
              :win-condition-options="winConditionOptions"
              :loans-required="loansRequired"
              :payments-minutes="paymentsMinutes"
              :per-payment-display="perPaymentDisplay"
              @roundCapital="roundStartingCapital"
              @roundLoanAmount="roundLoanAmount"
            />

            <div v-if="activeTab === 'winCondition'" class="ccm-tab-panel">
              <div class="ccm-variables-section">
                <div class="ccm-section-title">Win Condition Settings</div>
                <div v-for="{ variable, value } in variableRows" :key="variable.id" class="ccm-field">
                  <label :for="'var-' + variable.id">{{ variable.label }}</label>
                  <input v-bng-text-input
                    v-if="variable.type === 'number' || variable.type === 'integer'"
                    :id="'var-' + variable.id"
                    v-model.number="formVariables[variable.id]"
                    type="number"
                    v-bind="variable.props"
                    class="ccm-input"
                    @keyup.enter="onVariableEnter(variable)"
                    @blur="onVariableBlur(variable)"
                  />
                  <input
                    v-else-if="variable.type === 'boolean'"
                    :id="'var-' + variable.id"
                    v-model="formVariables[variable.id]"
                    type="checkbox"
                    class="ccm-checkbox"
                  />
                  <input v-bng-text-input
                    v-else-if="variable.type === 'string'"
                    :id="'var-' + variable.id"
                    v-model="formVariables[variable.id]"
                    type="text"
                    v-bind="variable.props"
                    class="ccm-input"
                    @keyup.enter="onVariableEnter(variable)"
                  />
                  <div
                    v-else-if="variable.type === 'array'"
                    :id="'var-' + variable.id"
                    class="ccm-array-input"
                  >
                    <div class="ccm-hint">{{ variable.hint }}</div>
                    <div class="ccm-hint">This variable is handled by the Target Garages tab</div>
                  </div>
                  <!-- Multiselect variable handling -->
                  <div v-else-if="variable.type === 'multiselect'" class="ccm-multiselect-section">
                    <div v-if="variable.hint" class="ccm-hint">{{ variable.hint }}</div>
                    <button
                      type="button"
                      class="ccm-multiselect-button"
                      @click.stop="openMultiselectModal(variable.id)"
                      @mousedown.stop
                    >
                      <span>Select {{ variable.label }}</span>
                      <span v-if="value?.length > 0" class="ccm-multiselect-count">
                        ({{ value.length }} selected)
                      </span>
                      <span class="ccm-multiselect-arrow">▾</span>
                    </button>
                  </div>
                  <div v-if="variable.hint && variable.type !== 'multiselect'" class="ccm-hint">{{ variable.hint }}</div>
                </div>
              </div>
            </div>

            <div v-if="activeTab === 'garages'" class="ccm-tab-panel">
              <div class="ccm-field">
                <input v-bng-text-input v-model="garageQuery" class="ccm-input" placeholder="Search garages..." />
              </div>

              <div class="ccm-garage-default">
                <button
                  class="ccm-garage-default-btn"
                  type="button"
                  @click.stop="onUseDefaultGarages()"
                  :class="{ 'ccm-garage-default-active': formStartingGarages.length === 0 && formStartingGarageMode !== 'none' }"
                >
                  Default
                </button>
                <button
                  class="ccm-garage-default-btn"
                  type="button"
                  @click.stop="onUseNoGarage()"
                  :class="{ 'ccm-garage-default-active': formStartingGarageMode === 'none' }"
                >
                  No garage
                </button>
                <div class="ccm-hint">{{ formStartingGarageMode === 'none' ? 'Start without any garage' : 'Default starter garage (free)' }}</div>
              </div>

              <div v-if="formStartingGarages.length > 0" class="ccm-garage-selection">
                <div class="ccm-garage-selected">
                  <div class="ccm-garage-selected-title">Selected Garages ({{ formStartingGarages.length }})</div>
                  <div class="ccm-garage-selected-list">
                    <div v-for="garage in selectedGarageRows" :key="garage.id" class="ccm-garage-selected-item">
                      <span>{{ garage.name }}</span>
                      <button
                        class="ccm-garage-remove"
                        type="button"
                        @click.stop="removeGarage(garage.id)"
                        @mousedown.stop
                      >
                        ×
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="ccm-garages">
                <div v-for="garage in filteredGarages" :key="garage.id" class="ccm-garage-row">
                  <label class="ccm-garage-label">
                    <input
                      v-model="formStartingGarages"
                      :value="garage.id"
                      type="checkbox"
                      class="ccm-garage-checkbox"
                      :disabled="formStartingGarageMode === 'none'"
                    />
                    <div class="ccm-garage-info">
                      <div class="ccm-garage-name">{{ garage.name }}</div>
                      <div class="ccm-garage-details">
                        <span class="ccm-garage-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ garage.price?.toLocaleString() || '0' }}</span>
                        <span class="ccm-garage-capacity">{{ garage.capacity || 0 }} slots</span>
                        <span v-if="garage.starterGarage" class="ccm-garage-starter">Starter</span>
                      </div>
                    </div>
                  </label>
                </div>
              </div>
            </div>

            <div v-if="activeTab === 'starterVehicles'" class="ccm-tab-panel">
              <p class="ccm-hint">Optional. One listed vehicle is gifted at random on a new career, worn out like the hardcore starter.</p>
              <div class="ccm-field">
                <input v-bng-text-input v-model="starterVehicleQuery" class="ccm-input" placeholder="Search vehicles..." />
              </div>

              <div v-if="formStarterVehicles.length > 0" class="ccm-garage-selection">
                <div class="ccm-garage-selected">
                  <div class="ccm-garage-selected-title">Selected Vehicles ({{ formStarterVehicles.length }})</div>
                  <div class="ccm-garage-selected-list">
                    <div v-for="vehicle in selectedStarterVehicleRows" :key="vehicle.id" class="ccm-garage-selected-item">
                      <span>{{ vehicle.name }}</span>
                      <button
                        class="ccm-garage-remove"
                        type="button"
                        @click.stop="removeStarterVehicle(vehicle.id)"
                        @mousedown.stop
                      >
                        ×
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="ccm-garages">
                <div v-for="vehicle in filteredStarterVehicles" :key="vehicle.id" class="ccm-garage-row">
                  <label class="ccm-garage-label">
                    <input
                      v-model="formStarterVehicles"
                      :value="vehicle.id"
                      type="checkbox"
                      class="ccm-garage-checkbox"
                    />
                    <div class="ccm-garage-info">
                      <div class="ccm-garage-name">{{ vehicle.name }}</div>
                      <div class="ccm-garage-details">
                        <span>{{ vehicle.id }}</span>
                      </div>
                    </div>
                  </label>
                </div>
              </div>
            </div>

            <div v-if="activeTab === 'economy'" class="ccm-tab-panel">
              <div class="ccm-econ-section">
                <p class="ccm-hint">Optional. 1.0 keeps normal pay.</p>
                <div class="ccm-field">
                  <input v-bng-text-input v-model="econQuery" class="ccm-input" placeholder="Search multipliers..." />
                </div>
                <div class="ccm-econ">
                  <div v-for="row in economyRows" :key="row.id" class="ccm-econ-row">
                    <label>{{ row.name }}</label>
                    <input v-bng-text-input
                      v-model.number="formEconomyAdjuster[row.id]"
                      type="number"
                      step="0.25"
                      min="0.0"
                      max="10.0"
                      class="ccm-input"
                      placeholder="1.0"
                      @keyup.enter="roundEconomyMultiplier(row.id)"
                      @blur="roundEconomyMultiplier(row.id)"
                    />
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="ccm-footer">
        <HouseButton variant="quiet" bng-scoped-nav-autofocus @click.stop="onRequestClose()" @mousedown.stop>Cancel</HouseButton>
        <HouseButton variant="primary" :disabled="!canSave" @click.stop="onSave()" @mousedown.stop>Save</HouseButton>
      </div>
    </div>
  </div>

  <ChallengeMultiselectModal
    v-if="multiselectModalOpen"
    :variable-label="currentMultiselectVariable?.label"
    :selected="formVariables[currentMultiselectVariableId]"
    :query="multiselectQueries[currentMultiselectVariableId]"
    :options="getFilteredMultiselectOptions(currentMultiselectVariableId)"
    :item-name="itemId => getMultiselectItemName(currentMultiselectVariableId, itemId)"
    @update:selected="value => setMultiselectSelection(currentMultiselectVariableId, value)"
    @update:query="value => setMultiselectQuery(currentMultiselectVariableId, value)"
    @remove="itemId => removeMultiselectItem(currentMultiselectVariableId, itemId)"
    @close="closeMultiselectModal"
  />
</template>

<script setup>
import { computed, ref, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'
import { vBngScopedNav, vBngTextInput, vBngUiNavScroll } from '@/common/directives'
import { returnFocusToOpener } from '../../composables/useScreenEntryFocus'
import { useDropdown } from '../../composables/useDropdown'
import { safeLua } from '../../utils/safeLua.js'
import HouseButton from '../../components/house/HouseButton.vue'
import ChallengeBasicFields from './challengeCreate/ChallengeBasicFields.vue'
import ChallengeStartingTab from './challengeCreate/ChallengeStartingTab.vue'
import ChallengeMultiselectModal from './challengeCreate/ChallengeMultiselectModal.vue'
import { useChallengeForm } from './challengeCreate/useChallengeForm.js'
import { createSeedCodec } from './challengeCreate/seedCodec.js'
import { useMultiselectVariables } from './challengeCreate/useMultiselectVariables.js'

const props = defineProps({
  open: { type: Boolean, default: false },
  editorData: { type: Object, default: () => ({}) },
  editChallengeData: { type: Object, default: null },
  editChallengeId: { type: String, default: null }
})
const emit = defineEmits(['close', 'saved'])

const seedInput = ref('')
const seedError = ref('')
const econQuery = ref('')
const garageQuery = ref('')
const starterVehicleQuery = ref('')
const activeTab = ref('starting')
const copyStatus = ref('')
// How long "Copied!" stays on the copy button.
const COPY_STATUS_RESET_MS = 3000
let copyStatusTimer

const overlayRef = ref(null)
const difficultyDropdownRef = ref(null)
const mapDropdownRef = ref(null)
// ChallengeBasicFields renders both dropdown wrappers and hands each element back here.
const setDifficultyContainer = element => { difficultyDropdownRef.value = element }
const setMapContainer = element => { mapDropdownRef.value = element }
const mapOptions = ref([])

const fullEditorData = ref(null)
const editorDataLoading = ref(false)

const activeEditorData = computed(() => {
  if (fullEditorData.value) return fullEditorData.value
  return props.editorData || {}
})

const {
  formId, formName, formDescription, formDifficulty, formStartingCapital, formWinCondition, formVariables,
  formLoanAmount, formLoanInterest, formLoanPayments, formEconomyAdjuster, formStartingGarages, formMap,
  formStartingGarageMode, formStarterVehicles,
  multiselectQueries, isApplyingSeed, seedPayload, canSave,
  winConditionOptions, variableDefinitions, loansRequired, activeVariables, variableRows,
  paymentsMinutes, perPaymentDisplay, interestPercent,
  markInitialSnapshot, initializeVariables, resetFormDefaults, applySeedDataToForm,
  roundVariableToStep, roundEconomyMultiplier, roundLoanAmount, roundStartingCapital,
  removeGarage, onUseDefaultGarages, onUseNoGarage, removeStarterVehicle,
} = useChallengeForm({ activeEditorData, seedError, onSeedApplied: () => updateSeedFromPayload() })

const events = useEvents()
// The two dropdowns are independent: opening one does not close the other.
const difficultyDropdown = useDropdown({
  containerRef: difficultyDropdownRef,
  triggerSelector: '.ccm-difficulty-trigger',
  menuSelector: '.ccm-difficulty-content',
  gapPx: 8,
  zIndex: 3001,
  widthProperty: 'width',
  onClose: () => returnFocusToOpener(difficultyDropdown.trigger),
})
const {
  open: difficultyDropdownOpen, style: difficultyDropdownStyle,
  toggle: toggleDifficultyDropdown, close: closeDifficultyDropdown,
  position: positionDifficultyDropdown, onDocumentClick: onDifficultyDocClick,
} = difficultyDropdown

const mapDropdown = useDropdown({
  containerRef: mapDropdownRef,
  triggerSelector: '.ccm-map-trigger',
  menuSelector: '.ccm-map-content',
  gapPx: 8,
  zIndex: 3001,
  widthProperty: 'width',
  onClose: () => returnFocusToOpener(mapDropdown.trigger),
})
const {
  open: mapDropdownOpen, style: mapDropdownStyle,
  toggle: toggleMapDropdown, close: closeMapDropdown,
  position: positionMapDropdown, onDocumentClick: onMapDocClick,
} = mapDropdown

function selectDifficulty(difficulty) {
  formDifficulty.value = difficulty
  closeDifficultyDropdown()
}

const formMapLabel = computed(() => {
  if (!formMap.value) return 'Any'
  const map = mapOptions.value.find(m => m.id === formMap.value)
  return map ? map.name : 'Any'
})

function selectMap(mapId) {
  formMap.value = mapId
  closeMapDropdown()
}

function onKeyDown(e) {
  if (!props.open) return
  e.stopPropagation()
}

// The seed codec owns the pending request ids and the latest encode id. Decoded data is applied through the form.
const {
  requestEncode, applySeedToForm, handleSeedGenerated, handleSeedEncodeResponse, handleSeedDecodeResponse,
} = createSeedCodec({ lua, seedInput, seedError, onDecoded: applySeedDataToForm })

const {
  multiselectModalOpen, currentMultiselectVariableId, currentMultiselectVariable,
  getFilteredMultiselectOptions, getMultiselectItemName, removeMultiselectItem,
  setMultiselectSelection, setMultiselectQuery, openMultiselectModal, closeMultiselectModal,
} = useMultiselectVariables({ activeVariables, formVariables, multiselectQueries, overlayRef, formMap })

// The starting-garages tab's list: the editor's garages on the chosen map, filtered by the search box, and the
// selected ids as { id, name } chips. The selection itself stays in the parent.
function useStartingGarages({ activeEditorData, garageQuery, formStartingGarages, formMap }) {
  const availableGarages = computed(() => {
    const raw = activeEditorData.value && activeEditorData.value.availableGarages
    return Array.isArray(raw) ? raw : []
  })

  const filteredGarages = computed(() => {
    const q = garageQuery.value.trim().toLowerCase()
    const mapId = formMap.value
    const garages = mapId ? availableGarages.value.filter(g => !g.mapId || g.mapId === mapId) : availableGarages.value
    if (!q) return garages
    return garages.filter(g => ((g.name || g.id || '').toLowerCase().includes(q)))
  })

  function getGarageName(garageId) {
    const garage = availableGarages.value.find(g => g.id === garageId)
    return garage ? garage.name : garageId
  }

  const selectedGarageRows = computed(() => formStartingGarages.value.map(garageId => ({ id: garageId, name: getGarageName(garageId) })))

  return { filteredGarages, selectedGarageRows, getGarageName }
}

// The economy tab's list: activity types filtered by the search box, and one { id, name } row per type, by name.
// Each row's input writes formEconomyAdjuster[id] directly.
function useEconomyMultipliers({ activeEditorData, econQuery }) {
  const filteredActivityTypes = computed(() => {
    const q = econQuery.value.trim().toLowerCase()
    const raw = activeEditorData.value && activeEditorData.value.activityTypes
    const types = Array.isArray(raw) ? raw : []
    if (!q) return types
    return types.filter(t => ((t.name || t.id || '').toLowerCase().includes(q)))
  })

  const economyRows = computed(() => filteredActivityTypes.value
    .map(t => ({ id: t.id, name: t.name || t.id }))
    .sort((a, b) => String(a.name).localeCompare(String(b.name), undefined, { sensitivity: 'base' })))

  return { filteredActivityTypes, economyRows }
}

// The starter-vehicles tab's list: the editor's starter configs filtered by the search box, and the selected ids
// as { id, name } chips. Ids are "model/config" strings, so a JSON-only entry still shows by its id.
function useStarterVehicles({ activeEditorData, starterVehicleQuery, formStarterVehicles }) {
  const availableStarterVehicles = computed(() => {
    const raw = activeEditorData.value && activeEditorData.value.availableStarterVehicles
    return Array.isArray(raw) ? raw : []
  })

  const filteredStarterVehicles = computed(() => {
    const q = starterVehicleQuery.value.trim().toLowerCase()
    const vehicles = availableStarterVehicles.value
    if (!q) return vehicles
    return vehicles.filter(v => ((v.name || '') + ' ' + (v.id || '')).toLowerCase().includes(q))
  })

  const selectedStarterVehicleRows = computed(() => formStarterVehicles.value.map(vehicleId => {
    const vehicle = availableStarterVehicles.value.find(v => v.id === vehicleId)
    return { id: vehicleId, name: vehicle ? vehicle.name : vehicleId }
  }))

  return { filteredStarterVehicles, selectedStarterVehicleRows }
}

const { filteredGarages, selectedGarageRows, getGarageName } = useStartingGarages({ activeEditorData, garageQuery, formStartingGarages, formMap })
const { filteredStarterVehicles, selectedStarterVehicleRows } = useStarterVehicles({ activeEditorData, starterVehicleQuery, formStarterVehicles })
const { filteredActivityTypes, economyRows } = useEconomyMultipliers({ activeEditorData, econQuery })

const tabs = computed(() => {
  const tabList = [{ id: 'starting', label: 'Starting Parameters' }]
  if (activeVariables.value.length > 0) {
    tabList.push({ id: 'winCondition', label: 'Win Condition Settings' })
  }
  tabList.push({ id: 'garages', label: 'Starting Garages' })
  tabList.push({ id: 'starterVehicles', label: 'Starter Vehicles' })
  tabList.push({ id: 'economy', label: 'Economy Multipliers' })
  return tabList
})

watch(tabs, (tabList) => {
  if (tabList && tabList.length > 0 && !tabList.some(tab => tab.id === activeTab.value)) {
    activeTab.value = tabList[0]?.id || 'starting'
  }
}, { immediate: false })

watch(() => formWinCondition.value, () => {
  initializeVariables()

  if (loansRequired.value && formLoanAmount.value === 0) {
    formLoanAmount.value = activeEditorData.value?.defaults?.loanAmount ?? 50000
    formLoanInterest.value = activeEditorData.value?.defaults?.loanInterest ?? 0.10
    formLoanPayments.value = activeEditorData.value?.defaults?.loanPayments ?? 12
  }

  seedError.value = ''
  updateSeedFromPayload()
})

watch(() => props.open, async (isOpen, oldIsOpen) => {
  if (!isOpen) return

  if (!fullEditorData.value && !editorDataLoading.value) {
    editorDataLoading.value = true
    await safeLua(async () => {
      const ed = await lua.overhaul_career_challengeModes.getChallengeEditorData()
      if (ed && typeof ed === 'object') {
        fullEditorData.value = ed
      }
    }, 'ChallengeCreateModal failed to load editor data')
    editorDataLoading.value = false
  }

  try {
    if (props.editChallengeId) {
      safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.editChallengeId), 'ChallengeCreateModal failed to request edit data on open')
    } else if (props.editChallengeData) {
      if (props.editChallengeData.seed) {
        seedInput.value = props.editChallengeData.seed
      }

      applySeedDataToForm(props.editChallengeData, true)
      formName.value = props.editChallengeData.name || ''
      formDescription.value = props.editChallengeData.description || ''
      formId.value = props.editChallengeData.id || ''

      if (props.editChallengeData.map !== undefined) {
        formMap.value = props.editChallengeData.map || null
      } else {
        formMap.value = null
      }
    } else if (seedInput.value && seedInput.value.trim() !== '') {
      applySeedToForm(seedInput.value)
    } else {
      resetFormDefaults()
      updateSeedFromPayload()
    }

    markInitialSnapshot()

    nextTick(() => {
      if (overlayRef.value) {
        overlayRef.value.focus()
      }
      overlayRef.value?.querySelector('[bng-scoped-nav-autofocus]')?.focus({ preventScroll: true })
    })
  } catch (error) {
    safeLua(() => { throw error }, 'ChallengeCreateModal failed in the open handler')
  }
})

function handleChallengeEditDataResponse(payload) {
  if (!payload || payload.challengeId !== props.editChallengeId) {
    return
  }

  if (!payload.success) {
    safeLua(() => { throw payload.error }, 'ChallengeCreateModal edit data fetch failed')
    seedError.value = payload.error || 'Failed to load challenge data'
    return
  }

  const challengeData = payload.data
  if (!challengeData) {
    safeLua(() => { throw new Error('No challenge data in response') }, 'ChallengeCreateModal received no challenge data')
    seedError.value = 'No challenge data received'
    return
  }

  if (challengeData.seed) {
    seedInput.value = challengeData.seed
  }

  applySeedDataToForm(challengeData, true)

  formName.value = challengeData.name || ''
  formDescription.value = challengeData.description || ''
  formId.value = challengeData.id || ''

  if (challengeData.map !== undefined) {
    formMap.value = challengeData.map || null
  } else {
    formMap.value = null
  }

  if (challengeData.difficulty) {
    formDifficulty.value = challengeData.difficulty
  }

  nextTick(() => {
    markInitialSnapshot()
  })
}

onMounted(async () => {
  events.on('challengeSeedGenerated', handleSeedGenerated)
  events.on('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.on('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.on('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.addEventListener('mousedown', onDifficultyDocClick)
  document.addEventListener('mousedown', onMapDocClick)
  document.addEventListener('keydown', onKeyDown, true)
  window.addEventListener('resize', positionDifficultyDropdown)
  window.addEventListener('scroll', positionDifficultyDropdown, true)
  window.addEventListener('resize', positionMapDropdown)
  window.addEventListener('scroll', positionMapDropdown, true)

  if (props.open && props.editChallengeId) {
    safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.editChallengeId), 'ChallengeCreateModal failed to request edit data on mount')
  }

  await safeLua(async () => {
    const maps = await lua.overhaul_world_maps.getCompatibleMaps()
    if (maps && Object.keys(maps).length > 0) {
      mapOptions.value = Object.entries(maps)
        .map(([key, value]) => ({
          id: key,
          name: value
        }))
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
    }
  }, 'ChallengeCreateModal failed to load maps')
})

onBeforeUnmount(() => {
  events.off('challengeSeedGenerated', handleSeedGenerated)
  events.off('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.off('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.off('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.removeEventListener('mousedown', onDifficultyDocClick)
  document.removeEventListener('mousedown', onMapDocClick)
  document.removeEventListener('keydown', onKeyDown, true)
  window.removeEventListener('resize', positionDifficultyDropdown)
  window.removeEventListener('scroll', positionDifficultyDropdown, true)
  window.removeEventListener('resize', positionMapDropdown)
  window.removeEventListener('scroll', positionMapDropdown, true)
  if (copyStatusTimer) {
    clearTimeout(copyStatusTimer)
    copyStatusTimer = null
  }
})

function onRequestClose() {
  if (!props.open) {
    return
  }
  emit('close')
}

async function onSave() {
  const payload = {
    id: formId.value,
    name: formName.value,
    description: formDescription.value,
    difficulty: formDifficulty.value,
    startingCapital: formStartingCapital.value,
    winCondition: formWinCondition.value,
    economyAdjuster: Object.keys(formEconomyAdjuster).length > 0 ? formEconomyAdjuster : undefined,
    startingGarages: formStartingGarages.value.length > 0 ? formStartingGarages.value : undefined,
    startingGarageMode: formStartingGarageMode.value === 'none' ? 'none' : undefined,
    starterVehicles: formStarterVehicles.value.length > 0 ? formStarterVehicles.value : undefined,
    map: formMap.value || undefined
  }

  const defs = variableDefinitions.value
  for (const [variableId, definition] of Object.entries(defs)) {
    const value = formVariables[variableId]
    if (value !== undefined) {
      payload[variableId] = definition.type === 'boolean' ? (value === true) : value
    }
  }

  if (formLoanAmount.value && formLoanAmount.value > 0) {
    payload.loans = { amount: formLoanAmount.value, interest: formLoanInterest.value, payments: formLoanPayments.value }
  }

  const resp = await lua.overhaul_career_challengeModes.createChallengeFromUI(payload)
  let ok, msg, challengeId
  if (Array.isArray(resp)) {
    ok = resp[0]; msg = resp[1]; challengeId = resp[2]
  } else if (resp && typeof resp === 'object') {
    ok = resp.ok; msg = resp.msg || resp.message; challengeId = resp.challengeId || resp.id
  } else {
    ok = resp
  }
  if (ok !== true) {
    safeLua(() => { throw msg }, 'ChallengeCreateModal create challenge failed')
    seedError.value = msg || 'Failed to save challenge'
    return
  }
  emit('saved', challengeId)
  emit('close')
}

function updateSeedFromPayload() {
  requestEncode(seedPayload.value)
}

function onGenerateSeed() {
  seedError.value = ''
  lua.overhaul_career_challengeModes.requestGenerateRandomSeed()
}

function onSeedEnter() {
  applySeedToForm(seedInput.value)
}

function onSeedBlur() {
  if (seedInput.value && seedInput.value.trim() !== '') {
    applySeedToForm(seedInput.value)
  }
}

async function onCopySeed() {
  if (!seedInput.value) {
    seedError.value = 'No seed to copy'
    return
  }
  if (!navigator.clipboard || !navigator.clipboard.writeText) {
    seedError.value = 'Clipboard not supported'
    return
  }
  try {
    await navigator.clipboard.writeText(seedInput.value)
    copyStatus.value = 'Copied!'
    if (copyStatusTimer) {
      clearTimeout(copyStatusTimer)
    }
    copyStatusTimer = setTimeout(() => {
      copyStatus.value = ''
      copyStatusTimer = null
    }, COPY_STATUS_RESET_MS)
  } catch (err) {
    seedError.value = 'Failed to copy to clipboard'
    safeLua(() => { throw err }, 'ChallengeCreateModal failed to copy the seed')
  }
}

// Enter on a number variable rounds it and then applies the seed. Enter on a string variable only applies the seed.
function onVariableEnter(variable) {
  if (variable.type === 'number' || variable.type === 'integer') {
    roundVariableToStep(variable)
  }
  onSeedEnter()
}

function onVariableBlur(variable) {
  roundVariableToStep(variable)
}

watch(seedPayload, () => {
  if (isApplyingSeed.value) {
    return
  }
  updateSeedFromPayload()
}, { deep: true })

watch(seedInput, (val) => {
  if (!val || val.trim() === '') {
    seedError.value = ''
  }
})

watch(() => props.editChallengeId, (newId, oldId) => {
  if (newId && props.open) {
    safeLua(() => lua.overhaul_career_challengeModes.requestChallengeDataForEdit(newId), 'ChallengeCreateModal failed to request edit data on id change')
  }
}, { immediate: true })
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// House look: one orange (Save, ticked boxes), neutral panels, the house focus ring and scrollbar.
// The child parts (ChallengeBasicFields, ChallengeStartingTab) read the same --panel / --line / --accent values.

.ccm-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.55);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3000;
}

.ccm-content {
  width: min(60em, 90vw);
  max-width: calc(100vw - 2em);
  height: 85vh;
  background: #1a1a1c;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  padding: 1em 1em 0.85em;
  font-size: calc-ui-em();
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.ccm-header {
  padding-bottom: 0.75em;
  border-bottom: 1px solid var(--line);
  flex-shrink: 0;
}

.ccm-title {
  margin: 0;
  font-size: 1.3em;
  font-weight: 700;
  line-height: 1.2;
}

.ccm-body {
  margin-top: 0.75em;
  // Keep edge controls' outer focus rings inside the scroll box.
  padding: 0.6em;
  margin-inline: -0.6em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  flex: 1;
  min-height: 0;
}

.ccm-footer {
  display: flex;
  gap: var(--space-2);
  padding-top: 0.75em;
  border-top: 1px solid var(--line);
  margin-top: 0.5em;
  justify-content: flex-end;
  flex-shrink: 0;
  > :deep(.house-button) {
    min-width: 6.5em;
  }
}

/* Shared form parts (also used by the child sections) */
:deep(.ccm-grid2) {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
}

:deep(.ccm-field) {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

:deep(.ccm-field .bng-select),
:deep(.ccm-field .bng-select-content),
:deep(.ccm-field .bng-select-content .label),
:deep(.ccm-field .bng-select-content .label *),
:deep(.ccm-field .bng-select-dropdown),
:deep(.ccm-field .bng-select-option),
:deep(.ccm-field .bng-select-option *),
:deep(.ccm-field .bng-button),
:deep(.ccm-field .bng-select .bng-button) {
  font-size: inherit !important;
}

:deep(.ccm-field label) {
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

:deep(.ccm-input),
:deep(.ccm-textarea) {
  width: 100%;
  margin: 0;
  padding: 0.72em 0.8em 0.5em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  font: inherit;
  font-weight: 400;
  line-height: 1.2;
  @include house-focus;
  // The global controller fallback forces an inset input ring with !important.
  // Keep this dialog on the house ring, with space reserved by the scroll box.
  &.focus-visible {
    outline: none !important;
    box-shadow: var(--focus) !important;
  }
  &::placeholder {
    color: var(--faint);
  }
  &:focus {
    outline: none;
    border-color: rgba(255, 255, 255, 0.35);
  }
  &:disabled {
    opacity: 0.45;
  }
}

// house number fields: no browser spin arrows (they appear on hover and cover the value)
:deep(.ccm-input[type="number"]) {
  appearance: textfield;
  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    appearance: none;
    margin: 0;
  }
}

:deep(.ccm-section-title) {
  margin: 0 0 0.25em;
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

:deep(.ccm-hint) {
  margin: 0;
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
}

:deep(.ccm-tab-panel) {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

/* Seed section */
.ccm-seed-section,
.ccm-variables-section {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}

.ccm-seed-row {
  display: flex;
  gap: var(--space-2);
}

.ccm-seed-row > .ccm-seed-btn {
  flex: 1 1 0;
  min-width: 0;
}

.ccm-seed-error {
  color: var(--bad);
  font-size: 0.85em;
  font-weight: 600;
}

/* Tabs: the house joined bar */
.ccm-tabs {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-tab-nav {
  align-self: flex-start;
  max-width: 100%;
  flex-wrap: wrap;
}

.ccm-tab-nav button {
  flex: 0 0 auto;
  padding-left: 0.85em;
  padding-right: 0.85em;
}

/* Checkboxes: the house .check box (dark square, orange with a white tick when on) */
.ccm-checkbox,
.ccm-garage-checkbox {
  appearance: none;
  flex: 0 0 auto;
  width: 1.15em;
  height: 1.15em;
  margin: 0;
  font: inherit;
  border: 1px solid rgba(255, 255, 255, 0.28);
  border-radius: 0.3em;
  background: rgba(0, 0, 0, 0.3) center / 0.75em no-repeat;
  cursor: pointer;
  @include house-focus;
  &:checked {
    border-color: var(--accent);
    background-color: var(--accent);
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23ffffff' stroke-width='3.2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M5 12.5l4.2 4.2L19 7.5'/%3E%3C/svg%3E");
  }
}

/* Win-condition variable fields */

.ccm-field:has(.ccm-checkbox) {
  flex-direction: row;
  align-items: center;
  gap: 0.5em;
}

.ccm-field:has(.ccm-checkbox) label {
  order: 2;
  cursor: pointer;
}

.ccm-field:has(.ccm-checkbox) .ccm-checkbox {
  order: 1;
}

.ccm-multiselect-button {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  padding: 0.72em 0.8em 0.5em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  font: inherit;
  font-weight: 600;
  line-height: 1;
  cursor: pointer;
  @include house-focus;
}

.ccm-multiselect-button:hover {
  background: var(--panel-2);
}

.ccm-multiselect-count {
  color: var(--accent-soft);
}

.ccm-multiselect-arrow {
  color: var(--faint);
}

/* Garages tab */
.ccm-garage-default {
  padding: 0.5em var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
  display: flex;
  align-items: center;
  gap: 0.75em;
}

.ccm-garage-default-btn {
  appearance: none;
  margin: 0;
  padding: 0.55em 0.85em 0.42em;
  border: 0;
  border-radius: var(--radius-control);
  background: var(--panel-2);
  color: var(--muted);
  font: inherit;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
  white-space: nowrap;
  @include house-focus;
}

.ccm-garage-default-btn:hover {
  background: var(--panel-hover);
  color: #fff;
}

.ccm-garage-default-btn.ccm-garage-default-active {
  color: var(--accent-soft);
}

.ccm-garage-selected {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
  display: grid;
  gap: 0.6em;
}

.ccm-garage-selected-title {
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.ccm-garage-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
}

.ccm-garage-selected-item {
  display: flex;
  align-items: center;
  gap: 0.45em;
  padding: 0.35em 0.4em 0.3em 0.65em;
  border-radius: var(--radius-pill);
  background: var(--panel-2);
  font-size: 0.85em;
  font-weight: 600;
}

.ccm-garage-remove {
  appearance: none;
  display: grid;
  place-items: center;
  width: 1.4em;
  height: 1.4em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--muted);
  font: inherit;
  line-height: 1;
  cursor: pointer;
  @include house-focus;
}

.ccm-garage-remove:hover {
  background: var(--panel-hover);
  color: #fff;
}

.ccm-garages {
  display: grid;
  gap: 0.15em;
  padding: 0.35em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.ccm-garage-label {
  display: flex;
  align-items: center;
  gap: 0.75em;
  width: 100%;
  padding: 0.55em 0.6em;
  border-radius: var(--radius-thumb);
  cursor: pointer;
}

.ccm-garage-label:hover {
  background: rgba(255, 255, 255, 0.04);
}

.ccm-garage-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;
}

.ccm-garage-name {
  font-weight: 600;
}

.ccm-garage-details {
  display: flex;
  gap: 0.75em;
  font-size: 0.85em;
  font-weight: 600;
  color: var(--muted);
}

.ccm-garage-price {
  color: var(--money);
}

.ccm-garage-starter {
  padding: 0.3em 0.45em 0.15em;
  border-radius: var(--radius-pill);
  background: rgba(74, 222, 128, 0.18);
  color: var(--ok-ink);
  font-size: 0.85em;
  font-weight: 700;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

/* Economy tab */
.ccm-econ-section {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
}

.ccm-econ {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5em 1.25em;
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* Economy multiplier row */
.ccm-econ-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 6.5em;
  gap: 0.75em;
  align-items: center;
}

.ccm-econ-row label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 600;
}

.ccm-econ-row .ccm-input {
  font-variant-numeric: tabular-nums;
}
</style>

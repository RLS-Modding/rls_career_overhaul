<template>
  <div v-show="open" class="ccm-overlay" @click.stop @mousedown.stop>
    <!-- MODAL IS RENDERING -->
    <div class="ccm-content" @click.stop @mousedown.stop>
      <div class="ccm-header">
        <div class="ccm-title">{{ editChallengeData ? 'Edit Challenge' : 'Create Challenge' }}</div>
        <button class="ccm-close" @click.stop="onRequestClose" @mousedown.stop>×</button>
      </div>

      <div class="ccm-body">
        <div class="ccm-grid2">
          <div class="ccm-field">
            <label>Name</label>
            <input v-model="formName" type="text" class="ccm-input" placeholder="My Challenge" />
          </div>
          <div class="ccm-field">
            <label>ID</label>
            <input v-model="formId" type="text" class="ccm-input" placeholder="myChallengeId" :disabled="!!editChallengeData" />
          </div>
        </div>

        <div class="ccm-grid2">
          <div class="ccm-field">
            <label>Difficulty</label>
            <div class="ccm-difficulty-dropdown" ref="difficultyDropdownRef">
              <button 
                type="button" 
                class="ccm-difficulty-trigger" 
                @click.stop="toggleDifficultyDropdown"
                @mousedown.stop
              >
                <span>{{ formDifficulty }}</span>
                <span class="ccm-difficulty-chevron">▾</span>
              </button>
              <teleport to="body">
                <div 
                  v-if="difficultyDropdownOpen" 
                  class="ccm-difficulty-content" 
                  :style="difficultyDropdownStyle"
                  @click.stop
                  @mousedown.stop
                >
                  <div 
                    v-for="diff in difficultyOptions" 
                    :key="diff"
                    class="ccm-difficulty-option"
                    :class="{ 'ccm-difficulty-selected': diff === formDifficulty }"
                    @click.stop="selectDifficulty(diff)"
                    @mousedown.stop
                  >
                    {{ diff }}
                  </div>
                </div>
              </teleport>
            </div>
          </div>
          <div class="ccm-field">
            <label>Starting Map</label>
            <div class="ccm-map-dropdown" ref="mapDropdownRef">
              <button 
                type="button" 
                class="ccm-map-trigger" 
                @click.stop="toggleMapDropdown"
                @mousedown.stop
              >
                <span>{{ formMapLabel }}</span>
                <span class="ccm-map-chevron">▾</span>
              </button>
              <teleport to="body">
                <div 
                  v-if="mapDropdownOpen" 
                  class="ccm-map-content" 
                  :style="mapDropdownStyle"
                  @click.stop
                  @mousedown.stop
                >
                  <div 
                    class="ccm-map-option"
                    :class="{ 'ccm-map-selected': formMap === null }"
                    @click.stop="selectMap(null)"
                    @mousedown.stop
                  >
                    Any
                  </div>
                  <div v-if="mapOptions.length > 0" class="ccm-map-sep"></div>
                  <div 
                    v-for="map in mapOptions" 
                    :key="map.id"
                    class="ccm-map-option"
                    :class="{ 'ccm-map-selected': map.id === formMap }"
                    @click.stop="selectMap(map.id)"
                    @mousedown.stop
                  >
                    {{ map.name }}
                  </div>
                </div>
              </teleport>
            </div>
          </div>
        </div>

        <div class="ccm-field">
          <label>Description</label>
          <textarea v-model="formDescription" class="ccm-textarea" rows="3" />
        </div>

        <div class="ccm-seed-section">
          <div class="ccm-field">
            <label>Challenge Seed</label>
            <input 
              v-model="seedInput" 
              type="text" 
              class="ccm-input ccm-seed-input" 
              placeholder="Enter seed or leave empty for random"
              @keyup.enter="onSeedEnter"
              @blur="onSeedBlur"
            />
            <div class="ccm-hint">Leave empty to generate a random seed, or enter a custom seed</div>
          </div>
          <div class="ccm-seed-row">
            <button class="ccm-seed-btn ccm-seed-generate" type="button" @click.stop="onGenerateSeed" @mousedown.stop>Generate Random Seed</button>
            <button class="ccm-seed-btn ccm-seed-action ccm-seed-copy" type="button" @click.stop="onCopySeed" @mousedown.stop :disabled="!seedInput">{{ copyStatus || 'Copy Seed' }}</button>
          </div>
          <div v-if="seedError" class="ccm-seed-error">{{ seedError }}</div>
        </div>

        <div class="ccm-tabs">
          <div class="ccm-tab-nav">
            <button 
              v-for="tab in tabs" 
              :key="tab.id"
              :class="['ccm-tab-btn', { 'ccm-tab-active': activeTab === tab.id }]"
              @click.stop="activeTab = tab.id"
            >
              {{ tab.label }}
            </button>
          </div>

          <div class="ccm-tab-content">
            <!-- Starting Parameters Tab -->
            <div v-if="activeTab === 'starting'" class="ccm-tab-panel">
              <div class="ccm-grid2">
                <div class="ccm-field">
                  <label>Starting Capital</label>
                  <input 
                    v-model.number="formStartingCapital" 
                    type="number" 
                    step="500" 
                    min="0" 
                    class="ccm-input" 
                    @keyup.enter="onStartingCapitalEnter"
                    @blur="onStartingCapitalBlur"
                  />
                </div>
                <div class="ccm-field">
                  <label>Win Condition</label>
                  <template v-if="winConditionOptions && winConditionOptions.length > 0">
                    <BngSelect v-model="formWinCondition" :options="winConditionOptions" :config="winConditionConfig" placeholder="Select win condition" />
                  </template>
                  <template v-else>
                    <div class="ccm-hint">Loading win conditions…</div>
                  </template>
                </div>
              </div>

              <div class="ccm-section-title">Debt {{ loansRequired ? '(required)' : '(optional)' }}</div>
              <div class="ccm-grid3">
                <div class="ccm-field">
                  <label>Amount{{ loansRequired ? ' *' : '' }}</label>
                  <input 
                    v-model.number="formLoanAmount" 
                    type="number" 
                    step="1000" 
                    min="10000" 
                    max="10000000" 
                    class="ccm-input" 
                    :class="{ 'ccm-required': loansRequired && !formLoanAmount }" 
                    @keyup.enter="onLoanAmountEnter"
                    @blur="onLoanAmountBlur"
                  />
                </div>
                <div class="ccm-field">
                  <label>Interest (%){{ loansRequired ? ' *' : '' }}</label>
                  <input v-model="interestPercent" type="number" min="0" max="100" step="0.1" class="ccm-input" :class="{ 'ccm-required': loansRequired && !formLoanAmount }" />
                </div>
                <div class="ccm-field">
                  <label>Payments{{ loansRequired ? ' *' : '' }}</label>
                  <input v-model.number="formLoanPayments" type="number" :min="loansRequired ? 1 : 0" step="1" class="ccm-input" :class="{ 'ccm-required': loansRequired && !formLoanAmount }" />
                  <div class="ccm-hint">≈ {{ paymentsMinutes }} min • ${{ perPaymentDisplay }} per</div>
                </div>
              </div>
            </div>

            <!-- Win Condition Settings Tab -->
            <div v-if="activeTab === 'winCondition'" class="ccm-tab-panel">
              <div class="ccm-variables-section">
                <div class="ccm-section-title">Win Condition Settings</div>
                <div v-for="variable in activeVariables" :key="variable.id" class="ccm-field">
                  <label :for="'var-' + variable.id">{{ variable.label }}</label>
                  <input
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
                  <input
                    v-else-if="variable.type === 'string'"
                    :id="'var-' + variable.id"
                    v-model="formVariables[variable.id]"
                    type="text"
                    v-bind="variable.props"
                    class="ccm-input"
                    @keyup.enter="onSeedEnter"
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
                      <span v-if="getMultiselectValues(variable.id).length > 0" class="ccm-multiselect-count">
                        ({{ getMultiselectValues(variable.id).length }} selected)
                      </span>
                      <span class="ccm-multiselect-arrow">▾</span>
                    </button>
                  </div>
                  <div v-if="variable.hint && variable.type !== 'multiselect'" class="ccm-hint">{{ variable.hint }}</div>
                </div>
              </div>
            </div>


            <!-- Starting Garages Tab -->
            <div v-if="activeTab === 'garages'" class="ccm-tab-panel">
              <div class="ccm-field">
                <input v-model="garageQuery" class="ccm-input" placeholder="Search garages..." />
              </div>
              
              <div class="ccm-garage-default">
                <button 
                  class="ccm-garage-default-btn" 
                  type="button" 
                  @click.stop="onUseDefaultGarages"
                  :class="{ 'ccm-garage-default-active': formStartingGarages.length === 0 }"
                >
                  Default
                </button>
                <div class="ccm-hint">Default starter garage (free)</div>
              </div>

              <div v-if="formStartingGarages.length > 0" class="ccm-garage-selection">
                <div class="ccm-garage-selected">
                  <div class="ccm-garage-selected-title">Selected Garages ({{ formStartingGarages.length }})</div>
                  <div class="ccm-garage-selected-list">
                    <div v-for="garageId in formStartingGarages" :key="garageId" class="ccm-garage-selected-item">
                      <span>{{ getGarageName(garageId) }}</span>
                      <button 
                        class="ccm-garage-emove" 
                        type="button" 
                        @click.stop="emoveGarage(garageId)"
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
                    />
                    <div class="ccm-garage-info">
                      <div class="ccm-garage-name">{{ garage.name }}</div>
                      <div class="ccm-garage-details">
                        <span class="ccm-garage-price">${{ garage.price?.toLocaleString() || '0' }}</span>
                        <span class="ccm-garage-capacity">{{ garage.capacity || 0 }} slots</span>
                        <span v-if="garage.starterGarage" class="ccm-garage-starter">Starter</span>
                      </div>
                    </div>
                  </label>
                </div>
              </div>
            </div>

            <!-- Economy Multipliers Tab -->
            <div v-if="activeTab === 'economy'" class="ccm-tab-panel">
              <div class="ccm-section-title">Economy Multipliers (optional)</div>
              <div class="ccm-field">
                <input v-model="econQuery" class="ccm-input" placeholder="Search multipliers..." />
              </div>
              <div class="ccm-econ">
                <div v-for="t in filteredActivityTypes" :key="t.id" class="ccm-econ-row">
                  <label>{{ t.name }}</label>
                  <input
                    v-model.number="formEconomyAdjuster[t.id]"
                    type="number"
                    step="0.25"
                    min="0.0"
                    max="10.0"
                    class="ccm-input"
                    placeholder="1.0"
                    @keyup.enter="onEconomyMultiplierEnter(t.id)"
                    @blur="onEconomyMultiplierBlur(t.id)"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="ccm-footer">
        <button class="ccm-primary" :disabled="!canSave" @click.stop="onSave" @mousedown.stop>Save</button>
        <button class="ccm-outline" @click.stop="onRequestClose" @mousedown.stop>Cancel</button>
      </div>
    </div>
  </div>

  <teleport to="body">
    <div v-if="multiselectModalOpen" class="ccm-multiselect-overlay" @click.stop="closeMultiselectModal" @mousedown.stop>
      <div class="ccm-multiselect-modal" @click.stop @mousedown.stop>
        <div class="ccm-multiselect-header">
          <div class="ccm-multiselect-title">{{ currentMultiselectVariable?.label || 'Select Items' }}</div>
          <button class="ccm-multiselect-close" @click.stop="closeMultiselectModal" @mousedown.stop>×</button>
        </div>
        <div class="ccm-multiselect-body">
          <div v-if="getMultiselectValues(currentMultiselectVariableId).length > 0" class="ccm-multiselect-selected-section">
            <div class="ccm-multiselect-selected-title">
              Selected {{ currentMultiselectVariable?.label || 'Items' }} ({{ getMultiselectValues(currentMultiselectVariableId).length }})
            </div>
            <div class="ccm-multiselect-selected-list">
              <div v-for="itemId in getMultiselectValues(currentMultiselectVariableId)" :key="itemId" class="ccm-multiselect-selected-item">
                <span>{{ getMultiselectItemName(currentMultiselectVariableId, itemId) }}</span>
                <button 
                  class="ccm-multiselect-remove" 
                  type="button" 
                  @click.stop="emoveMultiselectItem(currentMultiselectVariableId, itemId)"
                  @mousedown.stop
                >
                  ×
                </button>
              </div>
            </div>
          </div>

          <div class="ccm-multiselect-field">
            <input 
              v-model="multiselectQueries[currentMultiselectVariableId]" 
              class="ccm-multiselect-input" 
              :placeholder="`Search ${currentMultiselectVariable?.label?.toLowerCase() || 'items'}...`" 
            />
          </div>

          <div class="ccm-multiselect-list">
            <div v-for="item in getFilteredMultiselectOptions(currentMultiselectVariableId)" :key="item.id" class="ccm-multiselect-row">
              <label class="ccm-multiselect-label">
                <input
                  v-model="formVariables[currentMultiselectVariableId]"
                  :value="item.id"
                  type="checkbox"
                  class="ccm-multiselect-checkbox"
                />
                <div class="ccm-multiselect-info">
                  <div class="ccm-multiselect-name">{{ item.name }}</div>
                  <div class="ccm-multiselect-details">
                    <span v-if="item.price" class="ccm-multiselect-price">${{ item.price?.toLocaleString() || '0' }}</span>
                    <span v-if="item.capacity" class="ccm-multiselect-capacity">{{ item.capacity || 0 }} slots</span>
                    <span v-if="item.category" class="ccm-multiselect-category">{{ item.category }}</span>
                    <span v-if="item.starterGarage" class="ccm-multiselect-starter">Starter</span>
                  </div>
                </div>
              </label>
            </div>
          </div>
        </div>
        <div class="ccm-multiselect-footer">
          <button class="ccm-multiselect-save" @click.stop="closeMultiselectModal" @mousedown.stop>Done</button>
        </div>
      </div>
    </div>
  </teleport>
</template>

<script setup>
import { computed, reactive, ref, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngSelect } from '@/common/components/base'

const props = defineProps({
  open: { type: Boolean, default: false },
  editorData: { type: Object, default: () => ({}) },
  editChallengeData: { type: Object, default: null },
  editChallengeId: { type: String, default: null }
})
const emit = defineEmits(['close', 'saved'])

const formId = ref('')
const formName = ref('')
const formDescription = ref('')
const formDifficulty = ref('Medium')
const formStartingCapital = ref(10000)
const formWinCondition = ref('payOffLoan')
const formVariables = reactive({})
const formLoanAmount = ref(0)
const formLoanInterest = ref(0.10)
const formLoanPayments = ref(12)
const formEconomyAdjuster = reactive({})
const formStartingGarages = ref([])
const formMap = ref(null)
const seedInput = ref('')
const seedError = ref('')
const econQuery = ref('')
const garageQuery = ref('')
const activeTab = ref('starting')
const copyStatus = ref('')
const multiselectQueries = reactive({})
const multiselectModalOpen = ref(false)
const currentMultiselectVariableId = ref('')
let copyStatusTimer

const difficultyDropdownRef = ref(null)
const difficultyDropdownOpen = ref(false)
const difficultyDropdownStyle = ref('')
const difficultyOptions = ['Easy', 'Medium', 'Hard', 'Impossible']

const mapDropdownRef = ref(null)
const mapDropdownOpen = ref(false)
const mapDropdownStyle = ref('')
const mapOptions = ref([])

function selectDifficulty(difficulty) {
  formDifficulty.value = difficulty
  difficultyDropdownOpen.value = false
}

function toggleDifficultyDropdown() {
  difficultyDropdownOpen.value = !difficultyDropdownOpen.value
  if (difficultyDropdownOpen.value) {
    nextTick(positionDifficultyDropdown)
  }
}

function positionDifficultyDropdown() {
  if (!difficultyDropdownRef.value) return
  const trigger = difficultyDropdownRef.value.querySelector('.ccm-difficulty-trigger')
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const width = rect.width
  const margin = 8
  const left = rect.left
  const top = rect.bottom + margin
  difficultyDropdownStyle.value = `position:fixed;z-index:3001;top:${top}px;left:${left}px;width:${width}px;`
}

function onDifficultyDocClick(e) {
  if (!difficultyDropdownOpen.value) return
  const dropdown = document.querySelector('.ccm-difficulty-content')
  const trigger = difficultyDropdownRef.value?.querySelector('.ccm-difficulty-trigger')
  if (dropdown && dropdown.contains(e.target)) return
  if (trigger && trigger.contains(e.target)) return
  difficultyDropdownOpen.value = false
}

const formMapLabel = computed(() => {
  if (!formMap.value) return 'Any'
  const map = mapOptions.value.find(m => m.id === formMap.value)
  return map ? map.name : 'Any'
})

function toggleMapDropdown() {
  mapDropdownOpen.value = !mapDropdownOpen.value
  if (mapDropdownOpen.value) {
    nextTick(positionMapDropdown)
  }
}

function positionMapDropdown() {
  if (!mapDropdownRef.value) return
  const trigger = mapDropdownRef.value.querySelector('.ccm-map-trigger')
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const width = rect.width
  const margin = 8
  const left = rect.left
  const top = rect.bottom + margin
  mapDropdownStyle.value = `position:fixed;z-index:3001;top:${top}px;left:${left}px;width:${width}px;`
}

function selectMap(mapId) {
  formMap.value = mapId
  mapDropdownOpen.value = false
}

function onMapDocClick(e) {
  if (!mapDropdownOpen.value) return
  const dropdown = document.querySelector('.ccm-map-content')
  const trigger = mapDropdownRef.value?.querySelector('.ccm-map-trigger')
  if (dropdown && dropdown.contains(e.target)) return
  if (trigger && trigger.contains(e.target)) return
  mapDropdownOpen.value = false
}

const events = useEvents()
const isApplyingSeed = ref(false)
const pendingRequests = ref(new Set())

const form = computed(() => ({
  id: formId.value,
  name: formName.value,
  description: formDescription.value,
  difficulty: formDifficulty.value,
  startingCapital: formStartingCapital.value,
  winCondition: formWinCondition.value,
  variables: { ...formVariables },
  loans: {
    amount: formLoanAmount.value,
    interest: formLoanInterest.value,
    payments: formLoanPayments.value
  },
  economyAdjuster: formEconomyAdjuster,
  startingGarages: formStartingGarages.value,
  map: formMap.value || undefined
}))
const initialSnapshot = ref('')

const seedPayload = computed(() => {
  const payload = {
    startingCapital: formStartingCapital.value,
    winCondition: formWinCondition.value,
    difficulty: formDifficulty.value,
    loans: formLoanAmount.value && formLoanAmount.value > 0
      ? {
          amount: formLoanAmount.value,
          interest: formLoanInterest.value,
          payments: formLoanPayments.value
        }
      : undefined,
    economyAdjuster: Object.keys(formEconomyAdjuster).length > 0 ? formEconomyAdjuster : undefined,
    startingGarages: formStartingGarages.value.length > 0 ? formStartingGarages.value : undefined,
    map: formMap.value || undefined
  }
  for (const [key, value] of Object.entries(formVariables)) {
    if (value !== undefined) {
      payload[key] = value
    }
  }
  return payload
})

const winConditionOptions = computed(() => {
  try {
    const raw = props.editorData && props.editorData.winConditions
    const list = Array.isArray(raw) ? raw : []
    return list.map(w => ({
      id: w.id,
      name: w.name || w.id,
      description: w.description || '',
      variables: w.variables || {},
      requiresLoans: w.requiresLoans || false
    })).map(w => ({ value: w.id, label: w.name, data: w }))
  } catch (error) {
    console.error('[ChallengeCreateModal] Error in winConditionOptions:', error)
    return []
  }
})
const winConditionConfig = { value: opt => opt.value, label: opt => opt.label }

const variableDefinitions = computed(() => {
  try {
    const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
    return (selected && selected.data && selected.data.variables) || {}
  } catch (error) {
    console.error('[ChallengeCreateModal] Error in variableDefinitions:', error)
    return {}
  }
})

const loansRequired = computed(() => {
  const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
  return (selected && selected.data && selected.data.requiresLoans) === true
})


const hasMultiselectVariables = computed(() => {
  return activeVariables.value.some(v => v.type === 'multiselect')
})

const multiselectVariables = computed(() => {
  return activeVariables.value.filter(v => v.type === 'multiselect')
})

const activeVariables = computed(() => {
  try {
    const defs = variableDefinitions.value
    const result = []
    for (const [variableId, definition] of Object.entries(defs)) {
    const type = definition.type || 'number'
    if (type === 'number' || type === 'integer') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {
          min: definition.min,
          max: definition.max,
          step: definition.step || (definition.decimals !== undefined ? Math.pow(10, -(definition.decimals)) : 1)
        }
      })
    } else if (type === 'string') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {
          maxlength: definition.maxLength,
          minlength: definition.minLength,
          placeholder: definition.placeholder
        }
      })
    } else if (type === 'boolean') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {}
      })
    } else if (type === 'array') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {}
      })
    } else if (type === 'multiselect') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {},
        options: definition.options
      })
    }
  }
  result.sort((a, b) => {
    const da = (defs[a.id] && defs[a.id].order) || 0
    const db = (defs[b.id] && defs[b.id].order) || 0
    return da - db
  })
  return result
  } catch (error) {
    console.error('[ChallengeCreateModal] Error in activeVariables:', error)
    return []
  }
})

const availableGarages = computed(() => {
  const raw = props.editorData && props.editorData.availableGarages
  return Array.isArray(raw) ? raw : []
})

const filteredGarages = computed(() => {
  const q = garageQuery.value.trim().toLowerCase()
  const garages = availableGarages.value
  if (!q) return garages
  return garages.filter(g => ((g.name || g.id || '').toLowerCase().includes(q)))
})

const tabs = computed(() => {
  const tabList = [{ id: 'starting', label: 'Starting Parameters' }]
  if (activeVariables.value.length > 0) {
    tabList.push({ id: 'winCondition', label: 'Win Condition Settings' })
  }
  tabList.push({ id: 'garages', label: 'Starting Garages' })
  tabList.push({ id: 'economy', label: 'Economy Multipliers' })
  return tabList
})

watch(tabs, (tabList) => {
  if (tabList && tabList.length > 0 && !tabList.some(tab => tab.id === activeTab.value)) {
    activeTab.value = tabList[0]?.id || 'starting'
  }
}, { immediate: false })

function initializeVariables() {
  const defs = variableDefinitions.value
  Object.keys(formVariables).forEach(key => { delete formVariables[key] })
  Object.keys(multiselectQueries).forEach(key => { delete multiselectQueries[key] })
  
  for (const [variableId, definition] of Object.entries(defs)) {
    if (definition.default !== undefined) {
      formVariables[variableId] = definition.default
    } else if (definition.type === 'array' || definition.type === 'multiselect') {
      // Initialize array/multiselect variables as empty arrays
      formVariables[variableId] = []
    }
    
    // Initialize multiselect query
    if (definition.type === 'multiselect') {
      multiselectQueries[variableId] = ''
    }
  }
}

watch(() => formWinCondition.value, () => {
  initializeVariables()
  
  if (loansRequired.value && formLoanAmount.value === 0) {
    formLoanAmount.value = props.editorData?.defaults?.loanAmount ?? 50000
    formLoanInterest.value = props.editorData?.defaults?.loanInterest ?? 0.10
    formLoanPayments.value = props.editorData?.defaults?.loanPayments ?? 12
  }
  
  seedError.value = ''
  updateSeedFromPayload()
})

const filteredActivityTypes = computed(() => {
  const q = econQuery.value.trim().toLowerCase()
  const raw = props.editorData && props.editorData.activityTypes
  const types = Array.isArray(raw) ? raw : []
  if (!q) return types
  return types.filter(t => ((t.name || t.id || '').toLowerCase().includes(q)))
})

const paymentsMinutes = computed(() => {
  const p = Number(formLoanPayments.value || 0)
  return p * 5
})

const perPaymentDisplay = computed(() => {
  const amount = Number(formLoanAmount.value || 0)
  const rate = Number(formLoanInterest.value || 0)
  const payments = Number(formLoanPayments.value || 0)
  if (!amount || !payments) return '0.00'
  const base = amount / payments
  const per = base * (1 + (rate || 0))
  return per.toFixed(2)
})

const interestPercent = computed({
  get() {
    return Number((formLoanInterest.value || 0) * 100).toFixed(1)
  },
  set(v) {
    const num = Math.max(0, Math.min(100, Number(v || 0)))
    formLoanInterest.value = num / 100
  }
})

watch(() => props.open, async (isOpen, oldIsOpen) => {
  if (!isOpen) {
    if (lua.setCEFTyping) {
      lua.setCEFTyping(false)
    }
    return
  }

  try {
    if (props.editChallengeId) {
      try {
        lua.career_challengeModes.requestChallengeDataForEdit(props.editChallengeId)
      } catch (err) {
        console.error('[ChallengeCreateModal] Error calling requestChallengeDataForEdit:', err)
      }
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

    initialSnapshot.value = JSON.stringify(form.value)

    nextTick(() => {
      if (lua.setCEFTyping) {
        lua.setCEFTyping(true)
      }
      const firstInput = document.querySelector('.ccm-input')
      if (firstInput) {
        firstInput.focus()
      }
    })
  } catch (error) {
    console.error('[ChallengeCreateModal] Error in watch handler:', error)
  }
})

function handleSeedGenerated(payload) {
  if (!payload || payload.success === false) {
    seedError.value = payload?.error || 'Failed to generate seed'
    return
  }

  if (!payload.seed || payload.seed.trim() === '') {
    seedError.value = 'Generated seed is empty'
    return
  }

  seedInput.value = payload.seed
  seedError.value = ''
  applySeedToForm(payload.seed)
}

function handleSeedEncodeResponse(payload) {
  if (!payload || !pendingRequests.value.has(payload.requestId)) {
    return
  }
  
  pendingRequests.value.delete(payload.requestId)
  
  if (payload.success) {
    seedInput.value = payload.seed || ''
    seedError.value = ''
  } else {
    seedError.value = payload.error || 'Failed to encode seed'
  }
}

function handleSeedDecodeResponse(payload) {
  if (!payload || !pendingRequests.value.has(payload.requestId)) {
    return
  }
  
  pendingRequests.value.delete(payload.requestId)
  
  if (payload.success) {
    applySeedDataToForm(payload.data)
  } else {
    seedError.value = payload.error || 'Failed to decode seed'
  }
}

function handleChallengeEditDataResponse(payload) {
  if (!payload || payload.challengeId !== props.editChallengeId) {
    return
  }
  
  if (!payload.success) {
    console.error('[ChallengeCreateModal] Edit data fetch failed:', payload.error)
    seedError.value = payload.error || 'Failed to load challenge data'
    return
  }
  
  const challengeData = payload.data
  if (!challengeData) {
    console.error('[ChallengeCreateModal] No challenge data in response')
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
    initialSnapshot.value = JSON.stringify(form.value)
  })
}

onMounted(async () => {
  events.on('challengeSeedGenerated', handleSeedGenerated)
  events.on('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.on('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.on('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.addEventListener('mousedown', onDifficultyDocClick)
  document.addEventListener('mousedown', onMapDocClick)
  window.addEventListener('resize', positionDifficultyDropdown)
  window.addEventListener('scroll', positionDifficultyDropdown, true)
  window.addEventListener('resize', positionMapDropdown)
  window.addEventListener('scroll', positionMapDropdown, true)
  
  if (props.open && props.editChallengeId) {
    try {
      lua.career_challengeModes.requestChallengeDataForEdit(props.editChallengeId)
    } catch (err) {
      console.error('[ChallengeCreateModal] Error requesting edit data on mount:', err)
    }
  }
  
  try {
    const maps = await lua.overhaul_maps.getCompatibleMaps()
    if (maps && Object.keys(maps).length > 0) {
      mapOptions.value = Object.entries(maps).map(([key, value]) => ({
        id: key,
        name: value
      }))
    }
  } catch (error) {
    console.error('Failed to load maps:', error)
  }
})

onBeforeUnmount(() => {
  events.off('challengeSeedGenerated', handleSeedGenerated)
  events.off('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.off('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  events.off('challengeEditDataResponse', handleChallengeEditDataResponse)
  document.removeEventListener('mousedown', onDifficultyDocClick)
  document.removeEventListener('mousedown', onMapDocClick)
  window.removeEventListener('resize', positionDifficultyDropdown)
  window.removeEventListener('scroll', positionDifficultyDropdown, true)
  window.removeEventListener('resize', positionMapDropdown)
  window.removeEventListener('scroll', positionMapDropdown, true)
  if (copyStatusTimer) {
    clearTimeout(copyStatusTimer)
    copyStatusTimer = null
  }
})

const canSave = computed(() => !!formId.value && !!formName.value)
const isDirty = computed(() => JSON.stringify(form.value) !== initialSnapshot.value)

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

  const resp = await lua.career_challengeModes.createChallengeFromUI(payload)
  let ok, msg, challengeId
  if (Array.isArray(resp)) {
    ok = resp[0]; msg = resp[1]; challengeId = resp[2]
  } else if (resp && typeof resp === 'object') {
    ok = resp.ok; msg = resp.msg || resp.message; challengeId = resp.challengeId || resp.id
  }
  if (ok === false) {
    console.warn('CreateChallenge failed', msg)
    emit('close')
  } else {
    emit('saved', challengeId)
    emit('close')
  }
}

function resetFormDefaults() {
  formId.value = ''
  formName.value = ''
  formDescription.value = ''
  formDifficulty.value = props.editorData?.defaults?.difficulty ?? 'Medium'
  formStartingCapital.value = props.editorData?.defaults?.startingCapital ?? 10000
  const rawWin = props.editorData?.winConditions
  const list = Array.isArray(rawWin) ? rawWin : []
  formWinCondition.value = list[0]?.id || 'payOffLoan'
  formLoanAmount.value = props.editorData?.defaults?.loanAmount ?? 0
  formLoanInterest.value = props.editorData?.defaults?.loanInterest ?? 0.10
  formLoanPayments.value = props.editorData?.defaults?.loanPayments ?? 12
  formStartingGarages.value = []
  formMap.value = null
  
  Object.keys(formEconomyAdjuster).forEach(k => delete formEconomyAdjuster[k])
  const rawTypes = props.editorData?.activityTypes
  const types = Array.isArray(rawTypes) ? rawTypes : []
  for (const t of types) {
    if (t && t.id) {
      formEconomyAdjuster[t.id] = 1.0
    }
  }
  
  initializeVariables()
  seedError.value = ''
}

function updateSeedFromPayload() {
  const requestId = 'encode_' + Date.now() + '_' + Math.random()
  pendingRequests.value.add(requestId)
  
  lua.career_challengeModes.requestSeedEncode(requestId, seedPayload.value)
}

function applySeedToForm(seed) {
  seedError.value = ''
  if (!seed || seed.trim() === '') {
    seedError.value = 'Seed cannot be empty'
    return
  }
  
  const requestId = 'decode_' + Date.now() + '_' + Math.random()
  pendingRequests.value.add(requestId)
  
  lua.career_challengeModes.requestSeedDecode(requestId, seed)
}

function applySeedDataToForm(challenge, skipSeedUpdate = false) {
  isApplyingSeed.value = true
  
  if (challenge.startingCapital !== undefined) {
    formStartingCapital.value = challenge.startingCapital
  }
  
  if (challenge.difficulty !== undefined) {
    formDifficulty.value = challenge.difficulty
  }
  
  if (challenge.winCondition) {
    formWinCondition.value = challenge.winCondition
  }
  
  if (challenge.map !== undefined) {
    formMap.value = challenge.map || null
  } else {
    formMap.value = null
  }
  
  Object.keys(formVariables).forEach(k => delete formVariables[k])
  
  if (challenge.loans) {
    formLoanAmount.value = challenge.loans.amount || 0
    formLoanInterest.value = challenge.loans.interest || 0
    formLoanPayments.value = challenge.loans.payments || 0
  } else {
    formLoanAmount.value = 0
    formLoanInterest.value = 0
    formLoanPayments.value = 0
  }
  
  if (challenge.startingGarages) {
    formStartingGarages.value = Array.isArray(challenge.startingGarages) ? challenge.startingGarages : []
  } else {
    formStartingGarages.value = []
  }
  
  Object.keys(formEconomyAdjuster).forEach(k => delete formEconomyAdjuster[k])
  if (challenge.economyAdjuster) {
    for (const [k, v] of Object.entries(challenge.economyAdjuster)) {
      formEconomyAdjuster[k] = v
    }
  }
  
  nextTick(() => {
    const defs = variableDefinitions.value
    for (const [variableId, definition] of Object.entries(defs)) {
      if (challenge[variableId] !== undefined) {
        formVariables[variableId] = challenge[variableId]
      } else if (definition.default !== undefined) {
        formVariables[variableId] = definition.default
      } else if (definition.type === 'array' || definition.type === 'multiselect') {
        formVariables[variableId] = []
      }
      
      // Initialize multiselect query
      if (definition.type === 'multiselect') {
        multiselectQueries[variableId] = ''
      }
    }
    
    seedError.value = ''
    if (!skipSeedUpdate) {
      updateSeedFromPayload()
    }
    isApplyingSeed.value = false
  })
}

function onGenerateSeed() {
  seedError.value = ''
  lua.career_challengeModes.requestGenerateRandomSeed()
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
    }, 3000)
  } catch (err) {
    seedError.value = 'Failed to copy to clipboard'
  }
}

function onVariableEnter(variable) {
  roundVariableToStep(variable)
  onSeedEnter()
}

function onVariableBlur(variable) {
  roundVariableToStep(variable)
}

function roundVariableToStep(variable) {
  const value = formVariables[variable.id]
  if (value === undefined || value === null) return
  
  const step = variable.props.step || 1
  if (step <= 0) return
  
  let rounded = Math.floor((value / step) + 0.5) * step
  
  // Enforce min/max constraints
  const min = variable.props.min
  const max = variable.props.max
  if (min !== undefined && rounded < min) {
    rounded = min
  }
  if (max !== undefined && rounded > max) {
    rounded = max
  }
  
  formVariables[variable.id] = rounded
}

function onEconomyMultiplierEnter(activityId) {
  roundEconomyMultiplier(activityId)
}

function onEconomyMultiplierBlur(activityId) {
  roundEconomyMultiplier(activityId)
}

function roundEconomyMultiplier(activityId) {
  const value = formEconomyAdjuster[activityId]
  if (value === undefined || value === null) return
  
  const step = 0.25
  const min = 0.0  // Allow 0 for disabled modules
  const max = 10.0
  
  let rounded = Math.floor((value / step) + 0.5) * step
  
  // Enforce min/max constraints
  if (rounded < min) {
    rounded = min
  }
  if (rounded > max) {
    rounded = max
  }
  
  formEconomyAdjuster[activityId] = rounded
}

function onLoanAmountEnter() {
  roundLoanAmount()
}

function onLoanAmountBlur() {
  roundLoanAmount()
}

function roundLoanAmount() {
  const value = formLoanAmount.value
  if (value === undefined || value === null) return
  
  const step = 1000
  const min = 10000
  const max = 10000000
  
  let rounded = Math.floor((value / step) + 0.5) * step
  
  // Enforce min/max constraints
  if (rounded < min) {
    rounded = min
  }
  if (rounded > max) {
    rounded = max
  }
  
  formLoanAmount.value = rounded
}

function onStartingCapitalEnter() {
  roundStartingCapital()
}

function onStartingCapitalBlur() {
  roundStartingCapital()
}

function roundStartingCapital() {
  const value = formStartingCapital.value
  if (value === undefined || value === null) return
  
  const step = 500
  
  let rounded = Math.floor((value / step) + 0.5) * step
  
  // Enforce min constraint (no max)
  if (rounded < 0) {
    rounded = 0
  }
  
  formStartingCapital.value = rounded
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
    try {
      lua.career_challengeModes.requestChallengeDataForEdit(newId)
    } catch (err) {
      console.error('[ChallengeCreateModal] Error requesting edit data:', err)
    }
  }
}, { immediate: true })


function getGarageName(garageId) {
  const garage = availableGarages.value.find(g => g.id === garageId)
  return garage ? garage.name : garageId
}

function emoveGarage(garageId) {
  const index = formStartingGarages.value.indexOf(garageId)
  if (index > -1) {
    formStartingGarages.value.splice(index, 1)
  }
}


function onUseDefaultGarages() {
  formStartingGarages.value = []
}

function getMultiselectOptions(variableId) {
  const variable = multiselectVariables.value.find(v => v.id === variableId)
  if (!variable || !variable.options) return []
  
  // Options is now a direct table/array
  return Array.isArray(variable.options) ? variable.options : []
}

function getFilteredMultiselectOptions(variableId) {
  const options = getMultiselectOptions(variableId)
  const query = multiselectQueries[variableId] || ''
  const q = query.trim().toLowerCase()
  
  if (!q) return options
  return options.filter(item => 
    (item.name || item.id || '').toLowerCase().includes(q)
  )
}

function getMultiselectValues(variableId) {
  return formVariables[variableId] || []
}

function getMultiselectItemName(variableId, itemId) {
  const options = getMultiselectOptions(variableId)
  const item = options.find(opt => opt.id === itemId)
  return item ? item.name : itemId
}

function emoveMultiselectItem(variableId, itemId) {
  const values = formVariables[variableId] || []
  const index = values.indexOf(itemId)
  if (index > -1) {
    values.splice(index, 1)
  }
}

const currentMultiselectVariable = computed(() => {
  if (!currentMultiselectVariableId.value) return null
  return activeVariables.value.find(v => v.id === currentMultiselectVariableId.value)
})

function openMultiselectModal(variableId) {
  currentMultiselectVariableId.value = variableId
  if (!multiselectQueries[variableId]) {
    multiselectQueries[variableId] = ''
  }
  multiselectModalOpen.value = true
}

function closeMultiselectModal() {
  multiselectModalOpen.value = false
  currentMultiselectVariableId.value = ''
}
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

.ccm-overlay {
  position: fixed;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(2, 8, 23, 0.6), rgba(2, 8, 23, 0.75));
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3000;
}

.ccm-content {
  width: min(46em, 90vw);
  max-width: calc(100vw - 2em);
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 14px;
  box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
  color: #fff;
  padding: 1em;
  font-size: calc-ui-rem();
  max-height: 90vh;
  overflow-y: auto;
}

.ccm-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.ccm-title {
  font-weight: 600;
  font-size: 1.05em;
}

.ccm-close {
  background: transparent;
  border: 0;
  color: #94a3b8;
  font-size: 1.25em;
  cursor: pointer;
}

.ccm-body {
  margin-top: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-grid2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75em;
}

.ccm-grid3 {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 0.75em;
}

.ccm-field {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  
  :deep(.bng-select) {
    font-size: inherit !important;
  }
  
  :deep(.bng-select-content),
  :deep(.bng-select-content .label),
  :deep(.bng-select-content .label *) {
    font-size: inherit !important;
  }
  
  :deep(.bng-select-dropdown),
  :deep(.bng-select-option),
  :deep(.bng-select-option *) {
    font-size: inherit !important;
  }
  
  :deep(.bng-button),
  :deep(.bng-select .bng-button) {
    font-size: inherit !important;
  }
}

.ccm-input,
.ccm-textarea,
select {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  font-size: inherit;
}

.ccm-textarea {
  resize: vertical;
}

.ccm-difficulty-dropdown {
  position: relative;
}

.ccm-difficulty-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  cursor: pointer;
  transition: background 0.2s ease, border-color 0.2s ease;
  font-size: inherit;
}

.ccm-difficulty-trigger:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-difficulty-chevron {
  opacity: 0.8;
  font-size: 0.9em;
}

.ccm-difficulty-content {
  position: fixed;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  max-height: 12.5em;
  overflow: auto;
  z-index: 3001;
  font-size: inherit;
}

.ccm-difficulty-option {
  padding: 0.5em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  transition: background 0.2s ease;
  font-size: inherit;
}

.ccm-difficulty-option:hover {
  background: rgba(30, 41, 59, 0.6);
}

.ccm-difficulty-option.ccm-difficulty-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.ccm-map-dropdown {
  position: relative;
}

.ccm-map-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  cursor: pointer;
  transition: background 0.2s ease, border-color 0.2s ease;
  font-size: inherit;
}

.ccm-map-trigger:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-map-chevron {
  opacity: 0.8;
  font-size: 0.9em;
}

.ccm-map-content {
  position: fixed;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  max-height: 12.5em;
  overflow: auto;
  z-index: 3001;
  font-size: inherit;
}

.ccm-map-option {
  padding: 0.5em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  transition: background 0.2s ease;
  font-size: inherit;
}

.ccm-map-option:hover {
  background: rgba(30, 41, 59, 0.6);
}

.ccm-map-option.ccm-map-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.ccm-map-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.5);
  margin: 0.25em 0;
}

.ccm-section-title {
  margin-top: 0.25em;
  font-weight: 600;
}

.ccm-seed-section {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-seed-row {
  display: flex;
  gap: 0.5em;
  align-items: center;
  flex-wrap: wrap;
}
.ccm-seed-btn {
  white-space: nowrap;
  flex: 1 1 0;
  min-width: 0;
  border-radius: 8px;
  padding: 0.5em 0.75em;
  border: 1px solid transparent;
  cursor: pointer;
  transition: background 0.2s ease, transform 0.1s ease;
  font-size: inherit;
}
.ccm-seed-generate {
  background: rgba(30, 41, 59, 0.75);
  border-color: rgba(100, 116, 139, 0.45);
  color: #e2e8f0;
}
.ccm-seed-generate:hover {
  background: rgba(30, 41, 59, 0.85);
}
.ccm-seed-action {
  font-weight: 600;
  color: #0b1120;
  box-shadow: 0 4px 14px rgba(15, 23, 42, 0.2);
}
.ccm-seed-copy {
  background: rgba(96, 165, 250, 0.9);
}
.ccm-seed-action:hover {
  transform: translateY(-1px);
}
.ccm-seed-action:active {
  transform: translateY(0);
}
.ccm-seed-copy:disabled {
  background: rgba(148, 163, 184, 0.5);
  color: rgba(15, 23, 42, 0.65);
  cursor: not-allowed;
  box-shadow: none;
}

.ccm-seed-input {
  font-family: 'Courier New', monospace;
  font-size: 0.9em;
  width: 100%;
}

.ccm-seed-error {
  color: #f87171;
  font-size: 0.85em;
  padding-left: 0.25em;
}

.ccm-hint {
  color: #94a3b8;
  font-size: 0.75em;
  margin-top: 0.15em;
}

.ccm-econ {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5em 1em;
  max-height: 14em;
  overflow: auto;
  padding-right: 0.25em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
}

.ccm-econ::-webkit-scrollbar {
  width: 8px;
}

.ccm-econ::-webkit-scrollbar-track {
  background: transparent;
  border-radius: 4px;
}

.ccm-econ::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 4px;
}

.ccm-econ::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

.ccm-econ-row {
  display: grid;
  grid-template-columns: 1fr 7.5em;
  gap: 0.5em;
  align-items: center;
}

.ccm-footer {
  display: flex;
  gap: 0.5em;
  padding-top: 0.75em;
  justify-content: flex-end;
}

.ccm-primary {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  border: 0;
  color: #fff;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-outline {
  background: transparent;
  border: 1px solid rgba(100, 116, 139, 0.5);
  color: #cbd5e1;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-variables-section {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 10px;
  padding: 0.75em;
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-checkbox {
  width: 1.25em;
  height: 1.25em;
  cursor: pointer;
  accent-color: #2563eb;
}

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

.ccm-required {
  border-color: rgba(239, 68, 68, 0.6) !important;
  background: rgba(239, 68, 68, 0.08) !important;
}

.ccm-section-title:has-text('required') {
  color: #fca5a5;
}

.ccm-tabs {
  margin-top: 0.5em;
}

.ccm-tab-nav {
  display: flex;
  border-bottom: 1px solid rgba(100, 116, 139, 0.3);
  margin-bottom: 1em;
}

.ccm-tab-btn {
  background: transparent;
  border: 0;
  color: #94a3b8;
  padding: 0.75em 1em;
  cursor: pointer;
  border-bottom: 2px solid transparent;
  transition: all 0.2s ease;
  font-size: 0.9em;
  border-radius: 8px 8px 0 0;
}

.ccm-tab-btn:hover {
  color: #cbd5e1;
  background: rgba(100, 116, 139, 0.1);
}

.ccm-tab-btn.ccm-tab-active {
  color: #3b82f6;
  border-bottom-color: #3b82f6;
  background: rgba(59, 130, 246, 0.08);
}

.ccm-tab-content {
  min-height: 12.5em;
}

.ccm-tab-panel {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-no-settings {
  text-align: center;
  color: #94a3b8;
  padding: 2em;
  font-style: italic;
}

.ccm-garage-default {
  margin-bottom: 0.75em;
  padding: 0.375em 0.5em;
  background: rgba(34, 197, 94, 0.08);
  border: 1px solid rgba(34, 197, 94, 0.25);
  border-radius: 6px;
  display: flex;
  align-items: center;
  gap: 0.5em;
}

.ccm-garage-default-btn {
  background: rgba(34, 197, 94, 0.15);
  border: 1px solid rgba(34, 197, 94, 0.4);
  color: #22c55e;
  padding: 0.25em 0.5em;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 500;
  font-size: 0.8em;
  transition: all 0.2s ease;
  white-space: nowrap;
}

.ccm-garage-default-btn:hover {
  background: rgba(34, 197, 94, 0.25);
  border-color: rgba(34, 197, 94, 0.6);
}

.ccm-garage-default-btn.ccm-garage-default-active {
  background: rgba(34, 197, 94, 0.3);
  border-color: rgba(34, 197, 94, 0.7);
  box-shadow: 0 0 0 2px rgba(34, 197, 94, 0.2);
}

.ccm-garage-selection {
  margin-bottom: 1em;
}

.ccm-garage-selected {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 8px;
  padding: 0.75em;
}

.ccm-garage-selected-title {
  font-weight: 600;
  margin-bottom: 0.5em;
  color: #3b82f6;
}

.ccm-garage-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}

.ccm-garage-selected-item {
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 6px;
  padding: 0.25em 0.5em;
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.85em;
}

.ccm-garage-remove {
  background: transparent;
  border: 0;
  color: #ef4444;
  cursor: pointer;
  font-size: 1em;
  padding: 0;
  width: 1em;
  height: 1em;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 2px;
}

.ccm-garage-remove:hover {
  background: rgba(239, 68, 68, 0.2);
}

.ccm-garages {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.5em;
  max-height: 14em;
  overflow: auto;
  padding-right: 0.25em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
}

.ccm-garages::-webkit-scrollbar {
  width: 8px;
}

.ccm-garages::-webkit-scrollbar-track {
  background: transparent;
  border-radius: 4px;
}

.ccm-garages::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 4px;
}

.ccm-garages::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

.ccm-garage-row {
  display: flex;
  align-items: center;
}

.ccm-garage-label {
  display: flex;
  align-items: center;
  gap: 0.75em;
  cursor: pointer;
  padding: 0.5em;
  border-radius: 6px;
  transition: background 0.2s ease;
  width: 100%;
}

.ccm-garage-label:hover {
  background: rgba(100, 116, 139, 0.1);
}

.ccm-garage-checkbox {
  width: 1.125em;
  height: 1.125em;
  cursor: pointer;
  accent-color: #3b82f6;
}

.ccm-garage-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-garage-name {
  font-weight: 500;
  color: #e2e8f0;
}

.ccm-garage-details {
  display: flex;
  gap: 0.75em;
  font-size: 0.8em;
  color: #94a3b8;
}

.ccm-garage-price {
  color: #22c55e;
  font-weight: 500;
}

.ccm-garage-capacity {
  color: #8b5cf6;
}

.ccm-garage-category {
  color: #f59e0b;
}

.ccm-garage-starter {
  background: rgba(34, 197, 94, 0.2);
  color: #22c55e;
  padding: 0.1em 0.4em;
  border-radius: 4px;
  font-size: 0.75em;
  font-weight: 500;
}

.ccm-multiselect-button {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  cursor: pointer;
  transition: background 0.2s ease, border-color 0.2s ease;
  font-size: inherit;
}

.ccm-multiselect-button:hover {
  background: rgba(30, 41, 59, 0.8);
  border-color: rgba(100, 116, 139, 0.5);
}

.ccm-multiselect-count {
  color: #60a5fa;
  font-weight: 500;
}

.ccm-multiselect-arrow {
  opacity: 0.8;
  font-size: 0.9em;
}

.ccm-multiselect-overlay {
  position: fixed;
  inset: 0;
  background: radial-gradient(ellipse at center, rgba(2, 8, 23, 0.6), rgba(2, 8, 23, 0.75));
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 3001;
}

.ccm-multiselect-modal {
  width: min(42em, 90vw);
  max-width: calc(100vw - 2em);
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 14px;
  box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
  color: #fff;
  font-size: calc-ui-rem();
  max-height: 90vh;
  display: flex;
  flex-direction: column;
}

.ccm-multiselect-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.6);
}

.ccm-multiselect-title {
  font-weight: 600;
  font-size: 1.05em;
}

.ccm-multiselect-close {
  background: transparent;
  border: 0;
  color: #94a3b8;
  font-size: 1.25em;
  cursor: pointer;
  padding: 0;
  width: 1.5em;
  height: 1.5em;
  display: flex;
  align-items: center;
  justify-content: center;
  line-height: 1;
}

.ccm-multiselect-close:hover {
  color: #e2e8f0;
}

.ccm-multiselect-body {
  padding: 1em 1.5em;
  overflow-y: auto;
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.ccm-multiselect-selected-section {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 8px;
  padding: 0.75em;
}

.ccm-multiselect-selected-title {
  font-weight: 600;
  margin-bottom: 0.5em;
  color: #3b82f6;
}

.ccm-multiselect-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}

.ccm-multiselect-selected-item {
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 6px;
  padding: 0.25em 0.5em;
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.85em;
}

.ccm-multiselect-remove {
  background: transparent;
  border: 0;
  color: #ef4444;
  cursor: pointer;
  font-size: 1em;
  padding: 0;
  width: 1em;
  height: 1em;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 2px;
}

.ccm-multiselect-remove:hover {
  background: rgba(239, 68, 68, 0.2);
}

.ccm-multiselect-field {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-multiselect-input {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5em;
  font-size: inherit;
}

.ccm-multiselect-list {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.5em;
  max-height: 20em;
  overflow: auto;
  padding-right: 0.25em;
  scrollbar-width: thin;
  scrollbar-color: rgba(100, 116, 139, 0.5) transparent;
}

.ccm-multiselect-list::-webkit-scrollbar {
  width: 8px;
}

.ccm-multiselect-list::-webkit-scrollbar-track {
  background: transparent;
  border-radius: 4px;
}

.ccm-multiselect-list::-webkit-scrollbar-thumb {
  background: rgba(100, 116, 139, 0.5);
  border-radius: 4px;
}

.ccm-multiselect-list::-webkit-scrollbar-thumb:hover {
  background: rgba(100, 116, 139, 0.7);
}

.ccm-multiselect-row {
  display: flex;
  align-items: center;
}

.ccm-multiselect-label {
  display: flex;
  align-items: center;
  gap: 0.75em;
  cursor: pointer;
  padding: 0.5em;
  border-radius: 6px;
  transition: background 0.2s ease;
  width: 100%;
}

.ccm-multiselect-label:hover {
  background: rgba(100, 116, 139, 0.1);
}

.ccm-multiselect-checkbox {
  width: 1.125em;
  height: 1.125em;
  cursor: pointer;
  accent-color: #3b82f6;
}

.ccm-multiselect-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.ccm-multiselect-name {
  font-weight: 500;
  color: #e2e8f0;
}

.ccm-multiselect-details {
  display: flex;
  gap: 0.75em;
  font-size: 0.8em;
  color: #94a3b8;
}

.ccm-multiselect-price {
  color: #22c55e;
  font-weight: 500;
}

.ccm-multiselect-capacity {
  color: #8b5cf6;
}

.ccm-multiselect-category {
  color: #f59e0b;
}

.ccm-multiselect-starter {
  background: rgba(34, 197, 94, 0.2);
  color: #22c55e;
  padding: 0.1em 0.4em;
  border-radius: 4px;
  font-size: 0.75em;
  font-weight: 500;
}

.ccm-multiselect-footer {
  display: flex;
  gap: 0.5em;
  padding: 1em 1.5em;
  border-top: 1px solid rgba(71, 85, 105, 0.6);
  justify-content: flex-end;
}

.ccm-multiselect-save {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  border: 0;
  color: #fff;
  padding: 0.6em 1em;
  border-radius: 8px;
  cursor: pointer;
  font-size: inherit;
}

.ccm-multiselect-save:hover {
  opacity: 0.9;
}
</style>

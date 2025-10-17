<template>
  <div v-if="open" class="ccm-overlay">
    <div class="ccm-content" @click.stop>
      <div class="ccm-header">
        <div class="ccm-title">Create Challenge</div>
        <button class="ccm-close" @click="onRequestClose" @mousedown.stop>×</button>
      </div>

      <div class="ccm-body">
        <div class="ccm-grid2">
          <div class="ccm-field">
            <label>Name</label>
            <input v-model="formName" type="text" class="ccm-input" placeholder="My Challenge" />
          </div>
          <div class="ccm-field">
            <label>ID</label>
            <input v-model="formId" type="text" class="ccm-input" placeholder="myChallengeId" />
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
            <button class="ccm-seed-btn ccm-seed-generate" type="button" @click="onGenerateSeed" @mousedown.stop>Generate Random Seed</button>
            <button class="ccm-seed-btn ccm-seed-action ccm-seed-copy" type="button" @click="onCopySeed" @mousedown.stop :disabled="!seedInput">{{ copyStatus || 'Copy Seed' }}</button>
          </div>
          <div v-if="seedError" class="ccm-seed-error">{{ seedError }}</div>
        </div>

        <div class="ccm-tabs">
          <div class="ccm-tab-nav">
            <button 
              v-for="tab in tabs" 
              :key="tab.id"
              :class="['ccm-tab-btn', { 'ccm-tab-active': activeTab === tab.id }]"
              @click="activeTab = tab.id"
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
                  <BngSelect v-model="formWinCondition" :options="winConditionOptions" :config="winConditionConfig" placeholder="Select win condition" />
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
                  <div v-if="variable.hint" class="ccm-hint">{{ variable.hint }}</div>
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
                  @click="onUseDefaultGarages"
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
                        class="ccm-garage-remove" 
                        type="button" 
                        @click="removeGarage(garageId)"
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
        <button class="ccm-primary" :disabled="!canSave" @click="onSave" @mousedown.stop>Save</button>
        <button class="ccm-outline" @click="onRequestClose" @mousedown.stop>Cancel</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, reactive, ref, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngSelect } from '@/common/components/base'

const props = defineProps({
  open: { type: Boolean, default: false },
  editorData: { type: Object, default: () => ({}) }
})
const emit = defineEmits(['close', 'saved'])

const formId = ref('')
const formName = ref('')
const formDescription = ref('')
const formStartingCapital = ref(10000)
const formWinCondition = ref('payOffLoan')
const formVariables = reactive({})
const formLoanAmount = ref(0)
const formLoanInterest = ref(0.10)
const formLoanPayments = ref(12)
const formEconomyAdjuster = reactive({})
const formStartingGarages = ref([])
const seedInput = ref('')
const seedError = ref('')
const econQuery = ref('')
const garageQuery = ref('')
const activeTab = ref('starting')
const copyStatus = ref('')
let copyStatusTimer

const events = useEvents()
const isApplyingSeed = ref(false)
const pendingRequests = ref(new Set())

const form = computed(() => ({
  id: formId.value,
  name: formName.value,
  description: formDescription.value,
  startingCapital: formStartingCapital.value,
  winCondition: formWinCondition.value,
  variables: { ...formVariables },
  loans: {
    amount: formLoanAmount.value,
    interest: formLoanInterest.value,
    payments: formLoanPayments.value
  },
  economyAdjuster: formEconomyAdjuster,
  startingGarages: formStartingGarages.value
}))
const initialSnapshot = ref('')

const seedPayload = computed(() => {
  const payload = {
    startingCapital: formStartingCapital.value,
    winCondition: formWinCondition.value,
    loans: formLoanAmount.value && formLoanAmount.value > 0
      ? {
          amount: formLoanAmount.value,
          interest: formLoanInterest.value,
          payments: formLoanPayments.value
        }
      : undefined,
    economyAdjuster: Object.keys(formEconomyAdjuster).length > 0 ? formEconomyAdjuster : undefined,
    startingGarages: formStartingGarages.value.length > 0 ? formStartingGarages.value : undefined
  }
  for (const [key, value] of Object.entries(formVariables)) {
    if (value !== undefined) {
      payload[key] = value
    }
  }
  return payload
})

const winConditionOptions = computed(() => {
  const raw = props.editorData && props.editorData.winConditions
  const list = (Array.isArray(raw) && raw.length > 0)
    ? raw
    : [
        { id: 'payOffLoan', name: 'Get out of debt', description: '', variables: {}, requiresLoans: true },
        { id: 'reachTargetMoney', name: 'Reach Target Money', description: '', variables: {
            targetMoney: {
              type: 'number', label: 'Target Money', min: 1000, max: 100000000000, default: 1000000,
              decimals: 0, step: 1000
            }
          }
        }
      ]
  return list.map(w => ({
    id: w.id,
    name: w.name || w.id,
    description: w.description || '',
    variables: w.variables || {},
    requiresLoans: w.requiresLoans || false
  })).map(w => ({ value: w.id, label: w.name, data: w }))
})
const winConditionConfig = { value: opt => opt.value, label: opt => opt.label }

const variableDefinitions = computed(() => {
  const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
  return (selected && selected.data && selected.data.variables) || {}
})

const loansRequired = computed(() => {
  const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
  return (selected && selected.data && selected.data.requiresLoans) === true
})

const activeVariables = computed(() => {
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
    }
  }
  result.sort((a, b) => {
    const da = (defs[a.id] && defs[a.id].order) || 0
    const db = (defs[b.id] && defs[b.id].order) || 0
    return da - db
  })
  return result
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
  if (!tabList.some(tab => tab.id === activeTab.value)) {
    activeTab.value = tabList[0]?.id || 'starting'
  }
})

function initializeVariables() {
  const defs = variableDefinitions.value
  Object.keys(formVariables).forEach(key => { delete formVariables[key] })
  for (const [variableId, definition] of Object.entries(defs)) {
    if (definition.default !== undefined) {
      formVariables[variableId] = definition.default
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

watch(() => props.open, (isOpen) => {
  if (!isOpen) {
    if (lua.setCEFTyping) {
      lua.setCEFTyping(false)
    }
    return
  }

  if (seedInput.value && seedInput.value.trim() !== '') {
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
})

function handleSeedGenerated(payload) {
  console.log('handleSeedGenerated')
  console.log('challengeSeedGenerated event received:', payload)

  if (!payload || payload.success === false) {
    seedError.value = payload?.error || 'Failed to generate seed'
    console.error('Seed generation failed:', payload?.error)
    return
  }

  if (!payload.seed || payload.seed.trim() === '') {
    seedError.value = 'Generated seed is empty'
    console.error('Empty seed in event:', payload)
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

onMounted(() => {
  events.on('challengeSeedGenerated', handleSeedGenerated)
  events.on('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.on('challengeSeedDecodeResponse', handleSeedDecodeResponse)
})

onBeforeUnmount(() => {
  events.off('challengeSeedGenerated', handleSeedGenerated)
  events.off('challengeSeedEncodeResponse', handleSeedEncodeResponse)
  events.off('challengeSeedDecodeResponse', handleSeedDecodeResponse)
  if (copyStatusTimer) {
    clearTimeout(copyStatusTimer)
    copyStatusTimer = null
  }
})

const canSave = computed(() => !!formId.value && !!formName.value)
const isDirty = computed(() => JSON.stringify(form.value) !== initialSnapshot.value)

function onRequestClose() {
  emit('close')
}

async function onSave() {
  const payload = {
    id: formId.value,
    name: formName.value,
    description: formDescription.value,
    startingCapital: formStartingCapital.value,
    winCondition: formWinCondition.value,
    economyAdjuster: Object.keys(formEconomyAdjuster).length > 0 ? formEconomyAdjuster : undefined,
    startingGarages: formStartingGarages.value.length > 0 ? formStartingGarages.value : undefined,
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
  formStartingCapital.value = props.editorData?.defaults?.startingCapital ?? 10000
  const rawWin = props.editorData?.winConditions
  const list = Array.isArray(rawWin) ? rawWin : []
  formWinCondition.value = list[0]?.id || 'payOffLoan'
  formLoanAmount.value = props.editorData?.defaults?.loanAmount ?? 0
  formLoanInterest.value = props.editorData?.defaults?.loanInterest ?? 0.10
  formLoanPayments.value = props.editorData?.defaults?.loanPayments ?? 12
  formStartingGarages.value = []
  
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

function applySeedDataToForm(challenge) {
  console.log('applySeedDataToForm challenge data:', challenge)
  isApplyingSeed.value = true
  
  if (challenge.startingCapital !== undefined) {
    formStartingCapital.value = challenge.startingCapital
  }
  
  if (challenge.winCondition) {
    formWinCondition.value = challenge.winCondition
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
      }
    }
    
    seedError.value = ''
    updateSeedFromPayload()
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
    console.warn('Failed to copy to clipboard:', err)
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

function getGarageName(garageId) {
  const garage = availableGarages.value.find(g => g.id === garageId)
  return garage ? garage.name : garageId
}

function removeGarage(garageId) {
  const index = formStartingGarages.value.indexOf(garageId)
  if (index > -1) {
    formStartingGarages.value.splice(index, 1)
  }
}

function onUseDefaultGarages() {
  formStartingGarages.value = []
}
</script>

<style scoped lang="scss">
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
  width: min(46rem, calc(100% - 2rem));
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 14px;
  box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
  color: #fff;
  padding: 1rem;
}

.ccm-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.ccm-title {
  font-weight: 600;
  font-size: 1.05rem;
}

.ccm-close {
  background: transparent;
  border: 0;
  color: #94a3b8;
  font-size: 1.25rem;
  cursor: pointer;
}

.ccm-body {
  margin-top: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.ccm-grid2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75rem;
}

.ccm-grid3 {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 0.75rem;
}

.ccm-field {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.ccm-input,
.ccm-textarea,
select {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.35);
  color: #fff;
  border-radius: 8px;
  padding: 0.5rem;
}

.ccm-textarea {
  resize: vertical;
}

.ccm-section-title {
  margin-top: 0.25rem;
  font-weight: 600;
}

.ccm-seed-section {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.ccm-seed-row {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  flex-wrap: wrap;
}
.ccm-seed-btn {
  white-space: nowrap;
  flex: 1 1 0;
  min-width: 0;
  border-radius: 8px;
  padding: 0.5rem 0.75rem;
  border: 1px solid transparent;
  cursor: pointer;
  transition: background 0.2s ease, transform 0.1s ease;
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
  font-size: 0.9rem;
  width: 100%;
}

.ccm-seed-error {
  color: #f87171;
  font-size: 0.85rem;
  padding-left: 0.25rem;
}

.ccm-hint {
  color: #94a3b8;
  font-size: 0.75rem;
  margin-top: 0.15rem;
}

.ccm-econ {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5rem 1rem;
  max-height: 14rem;
  overflow: auto;
  padding-right: 0.25rem;
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
  grid-template-columns: 1fr 120px;
  gap: 0.5rem;
  align-items: center;
}

.ccm-footer {
  display: flex;
  gap: 0.5rem;
  padding-top: 0.75rem;
  justify-content: flex-end;
}

.ccm-primary {
  background: linear-gradient(90deg, #2563eb, #1d4ed8);
  border: 0;
  color: #fff;
  padding: 0.6rem 1rem;
  border-radius: 8px;
  cursor: pointer;
}

.ccm-outline {
  background: transparent;
  border: 1px solid rgba(100, 116, 139, 0.5);
  color: #cbd5e1;
  padding: 0.6rem 1rem;
  border-radius: 8px;
  cursor: pointer;
}

.ccm-variables-section {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 10px;
  padding: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.ccm-checkbox {
  width: 20px;
  height: 20px;
  cursor: pointer;
  accent-color: #2563eb;
}

.ccm-field:has(.ccm-checkbox) {
  flex-direction: row;
  align-items: center;
  gap: 0.5rem;
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
  margin-top: 0.5rem;
}

.ccm-tab-nav {
  display: flex;
  border-bottom: 1px solid rgba(100, 116, 139, 0.3);
  margin-bottom: 1rem;
}

.ccm-tab-btn {
  background: transparent;
  border: 0;
  color: #94a3b8;
  padding: 0.75rem 1rem;
  cursor: pointer;
  border-bottom: 2px solid transparent;
  transition: all 0.2s ease;
  font-size: 0.9rem;
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
  min-height: 200px;
}

.ccm-tab-panel {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.ccm-no-settings {
  text-align: center;
  color: #94a3b8;
  padding: 2rem;
  font-style: italic;
}

.ccm-garage-default {
  margin-bottom: 0.75rem;
  padding: 0.375rem 0.5rem;
  background: rgba(34, 197, 94, 0.08);
  border: 1px solid rgba(34, 197, 94, 0.25);
  border-radius: 6px;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.ccm-garage-default-btn {
  background: rgba(34, 197, 94, 0.15);
  border: 1px solid rgba(34, 197, 94, 0.4);
  color: #22c55e;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 500;
  font-size: 0.8rem;
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
  margin-bottom: 1rem;
}

.ccm-garage-selected {
  background: rgba(59, 130, 246, 0.08);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 8px;
  padding: 0.75rem;
}

.ccm-garage-selected-title {
  font-weight: 600;
  margin-bottom: 0.5rem;
  color: #3b82f6;
}

.ccm-garage-selected-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.ccm-garage-selected-item {
  background: rgba(59, 130, 246, 0.15);
  border: 1px solid rgba(59, 130, 246, 0.3);
  border-radius: 6px;
  padding: 0.25rem 0.5rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.85rem;
}

.ccm-garage-remove {
  background: transparent;
  border: 0;
  color: #ef4444;
  cursor: pointer;
  font-size: 1rem;
  padding: 0;
  width: 16px;
  height: 16px;
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
  gap: 0.5rem;
  max-height: 14rem;
  overflow: auto;
  padding-right: 0.25rem;
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
  gap: 0.75rem;
  cursor: pointer;
  padding: 0.5rem;
  border-radius: 6px;
  transition: background 0.2s ease;
  width: 100%;
}

.ccm-garage-label:hover {
  background: rgba(100, 116, 139, 0.1);
}

.ccm-garage-checkbox {
  width: 18px;
  height: 18px;
  cursor: pointer;
  accent-color: #3b82f6;
}

.ccm-garage-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.ccm-garage-name {
  font-weight: 500;
  color: #e2e8f0;
}

.ccm-garage-details {
  display: flex;
  gap: 0.75rem;
  font-size: 0.8rem;
  color: #94a3b8;
}

.ccm-garage-price {
  color: #22c55e;
  font-weight: 500;
}

.ccm-garage-capacity {
  color: #8b5cf6;
}

.ccm-garage-starter {
  background: rgba(34, 197, 94, 0.2);
  color: #22c55e;
  padding: 0.1rem 0.4rem;
  border-radius: 4px;
  font-size: 0.75rem;
  font-weight: 500;
}
</style>

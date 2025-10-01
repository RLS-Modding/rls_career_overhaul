<template>
  <div v-if="open" class="ccm-overlay" @click.self="onRequestClose">
    <div class="ccm-content" @click.stop>
      <div class="ccm-header">
        <div class="ccm-title">Create Challenge</div>
        <button class="ccm-close" @click="onRequestClose">×</button>
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

        <div class="ccm-grid2">
          <div class="ccm-field">
            <label>Starting Capital</label>
            <input v-model.number="formStartingCapital" type="number" min="0" class="ccm-input" />
          </div>
          <div class="ccm-field">
            <label>Win Condition</label>
            <BngSelect v-model="formWinCondition" :options="winConditionOptions" :config="winConditionConfig" placeholder="Select win condition" />
          </div>
        </div>

        <div class="ccm-section-title">Loan (optional)</div>
        <div class="ccm-grid3">
          <div class="ccm-field">
            <label>Amount</label>
            <input v-model.number="formLoanAmount" type="number" min="0" class="ccm-input" />
          </div>
          <div class="ccm-field">
            <label>Interest (%)</label>
            <input v-model="interestPercent" type="number" min="0" max="100" step="0.1" class="ccm-input" />
          </div>
          <div class="ccm-field">
            <label>Payments</label>
            <input v-model.number="formLoanPayments" type="number" min="0" step="1" class="ccm-input" />
            <div class="ccm-hint">≈ {{ paymentsMinutes }} min • ${{ perPaymentDisplay }} per</div>
          </div>
        </div>

        <div class="ccm-section-title">Economy Multipliers (optional)</div>
        <div class="ccm-field">
          <input v-model="econQuery" class="ccm-input" placeholder="Search multipliers..." />
        </div>
        <div class="ccm-econ">
          <div v-for="t in filteredActivityTypes" :key="t.id" class="ccm-econ-row">
            <label>{{ t.name }}</label>
            <input v-model.number="formEconomyAdjuster[t.id]" type="number" step="0.05" class="ccm-input" placeholder="1.0" />
          </div>
        </div>
      </div>

      <div class="ccm-footer">
        <button class="ccm-primary" :disabled="!canSave" @click="onSave">Save</button>
        <button class="ccm-outline" @click="onRequestClose">Cancel</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, reactive, ref, watch, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { lua } from '@/bridge'
import { BngSelect } from '@/common/components/base'

const props = defineProps({
  open: { type: Boolean, default: false },
  editorData: { type: Object, default: () => ({}) }
})
const emit = defineEmits(['close', 'saved'])

// Use individual refs instead of reactive object to match the working econQuery pattern
const formId = ref('')
const formName = ref('')
const formDescription = ref('')
const formStartingCapital = ref(10000)
const formWinCondition = ref('payOffLoan')
const formLoanAmount = ref(0)
const formLoanInterest = ref(0.10)
const formLoanPayments = ref(12)
// Use reactive for the economy adjuster object since it has nested properties
const formEconomyAdjuster = reactive({})

const econQuery = ref('')

// Create computed form object for compatibility with existing code
const form = computed(() => ({
  id: formId.value,
  name: formName.value,
  description: formDescription.value,
  startingCapital: formStartingCapital.value,
  winCondition: formWinCondition.value,
  loans: {
    amount: formLoanAmount.value,
    interest: formLoanInterest.value,
    payments: formLoanPayments.value
  },
  economyAdjuster: formEconomyAdjuster
}))
const initialSnapshot = ref('')

const winConditionOptions = computed(() => {
  const raw = props.editorData && props.editorData.winConditions
  const list = (Array.isArray(raw) && raw.length > 0)
    ? raw
    : [
        { id: 'payOffLoan', name: 'Pay Off Loan' },
        { id: 'reachTargetMoney', name: 'Reach Target Money' }
      ]
  return list.map(w => ({ value: w.id, label: w.name || w.id }))
})
const winConditionConfig = { value: opt => opt.value, label: opt => opt.label }

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

// Watch for modal open/close
watch(() => props.open, (isOpen) => {
  if (!isOpen) {
    // Disable typing when modal closes
    if (lua.setCEFTyping) {
      lua.setCEFTyping(false)
    }
    return
  }

  // initialize defaults when opening
  formId.value = ''
  formName.value = ''
  formDescription.value = ''
  formStartingCapital.value = props.editorData?.defaults?.startingCapital ?? 10000
  {
    const raw = props.editorData && props.editorData.winConditions
    const list = Array.isArray(raw) ? raw : []
    const first = list[0]?.id || 'payOffLoan'
    formWinCondition.value = first
  }
  formLoanAmount.value = props.editorData?.defaults?.loanAmount ?? 0
  formLoanInterest.value = props.editorData?.defaults?.loanInterest ?? 0.10
  formLoanPayments.value = props.editorData?.defaults?.loanPayments ?? 12
  // Clear the reactive object
  Object.keys(formEconomyAdjuster).forEach(key => delete formEconomyAdjuster[key])
  const rawTypes = props.editorData && props.editorData.activityTypes
  const types = Array.isArray(rawTypes) ? rawTypes : []
  for (const t of types) {
    if (t && t.id) formEconomyAdjuster[t.id] = 1.0
  }
  initialSnapshot.value = JSON.stringify(form.value)

  // Enable typing and focus once when modal opens
  nextTick(() => {
    if (lua.setCEFTyping) {
      lua.setCEFTyping(true)
    }
    
    // Focus first input after DOM is ready
    const firstInput = document.querySelector('.ccm-input')
    if (firstInput) {
      firstInput.focus()
    }
  })
})

onBeforeUnmount(() => {
  if (lua.setCEFTyping) {
    lua.setCEFTyping(false)
  }
})

const canSave = computed(() => !!formId.value && !!formName.value)
const isDirty = computed(() => JSON.stringify(form.value) !== initialSnapshot.value)

function onRequestClose() {
  if (isDirty.value) {
    const ok = window.confirm('Discard unsaved changes?')
    if (!ok) return
  }
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
    // Emit the created challenge ID so parent can select it
    // Even if challengeId is null, we still emit saved to trigger a refresh
    emit('saved', challengeId)
    emit('close')
  }
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

.ccm-econ {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5rem 1rem;
  max-height: 14rem;
  overflow: auto;
  padding-right: 0.25rem;
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
</style>

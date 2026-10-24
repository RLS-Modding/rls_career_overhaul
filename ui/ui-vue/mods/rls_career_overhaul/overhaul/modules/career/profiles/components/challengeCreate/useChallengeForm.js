// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, reactive, ref, nextTick } from 'vue'
import { useWinConditionSchema } from './useWinConditionSchema.js'
import { roundVariableValue, roundEconomyValue, roundLoanValue, roundCapitalValue } from './rounding.js'

// The summary line ("≈ N min") counts each payment as this many minutes.
const MINUTES_PER_PAYMENT = 10

// Loan summary: the payment time, the per-payment amount, and the interest as the percent the input shows.
// interestPercent writes the fraction back, and clamps it to 0..100 first.
function useLoanTerms({ formLoanAmount, formLoanInterest, formLoanPayments }) {
  const paymentsMinutes = computed(() => {
    const p = Number(formLoanPayments.value || 0)
    return p * MINUTES_PER_PAYMENT
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

  return { paymentsMinutes, perPaymentDisplay, interestPercent }
}

// The challenge form: every value the editor edits, and the operations that write them (defaults, applying a
// challenge or decoded seed, rounding on commit, list edits). This is the one owner of these refs. The parent
// destructures them into its top-level names. No watchers, lifecycle or Lua calls live here: the parent keeps
// those, in their original order. seedError is the parent's ref, passed in, because the seed traffic reads it.
export function useChallengeForm({ activeEditorData, seedError, onSeedApplied }) {
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
  const multiselectQueries = reactive({})
  const isApplyingSeed = ref(false)
  const initialSnapshot = ref('')

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

  // The encode payload. The parent's deep watcher on it decides when the seed is re-encoded.
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

  const canSave = computed(() => !!formId.value && !!formName.value)
  const isDirty = computed(() => JSON.stringify(form.value) !== initialSnapshot.value)

  const {
    winConditionOptions, variableDefinitions, loansRequired, activeVariables, variableRows,
  } = useWinConditionSchema({ activeEditorData, formWinCondition, formVariables })

  const { paymentsMinutes, perPaymentDisplay, interestPercent } = useLoanTerms({ formLoanAmount, formLoanInterest, formLoanPayments })

  function markInitialSnapshot() {
    initialSnapshot.value = JSON.stringify(form.value)
  }

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

  function resetFormDefaults() {
    formId.value = ''
    formName.value = ''
    formDescription.value = ''
    formDifficulty.value = activeEditorData.value?.defaults?.difficulty ?? 'Medium'
    formStartingCapital.value = activeEditorData.value?.defaults?.startingCapital ?? 10000
    const rawWin = activeEditorData.value?.winConditions
    const list = Array.isArray(rawWin) ? rawWin : []
    formWinCondition.value = list[0]?.id || 'payOffLoan'
    formLoanAmount.value = activeEditorData.value?.defaults?.loanAmount ?? 0
    formLoanInterest.value = activeEditorData.value?.defaults?.loanInterest ?? 0.10
    formLoanPayments.value = activeEditorData.value?.defaults?.loanPayments ?? 12
    formStartingGarages.value = []
    formMap.value = null

    Object.keys(formEconomyAdjuster).forEach(k => delete formEconomyAdjuster[k])
    const rawTypes = activeEditorData.value?.activityTypes
    const types = Array.isArray(rawTypes) ? rawTypes : []
    for (const t of types) {
      if (t && t.id) {
        formEconomyAdjuster[t.id] = 1.0
      }
    }

    initializeVariables()
    seedError.value = ''
  }

  // Writes a challenge (or decoded seed data) into the form. The variable writes wait for nextTick, as before;
  // onSeedApplied runs after them unless skipSeedUpdate is set, so the encode sees the applied values.
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
        onSeedApplied()
      }
      isApplyingSeed.value = false
    })
  }

  // Each commit rounds the stored value in place. A value that cannot be rounded (undefined or null) is left alone.
  function roundVariableToStep(variable) {
    const rounded = roundVariableValue(formVariables[variable.id], variable.props)
    if (rounded !== undefined) {
      formVariables[variable.id] = rounded
    }
  }

  function roundEconomyMultiplier(activityId) {
    const rounded = roundEconomyValue(formEconomyAdjuster[activityId])
    if (rounded !== undefined) {
      formEconomyAdjuster[activityId] = rounded
    }
  }

  function roundLoanAmount() {
    const rounded = roundLoanValue(formLoanAmount.value, loansRequired.value)
    if (rounded !== undefined) {
      formLoanAmount.value = rounded
    }
  }

  function roundStartingCapital() {
    const rounded = roundCapitalValue(formStartingCapital.value)
    if (rounded !== undefined) {
      formStartingCapital.value = rounded
    }
  }

  // Splices in place, as the list was before this composable existed.
  function removeGarage(garageId) {
    const index = formStartingGarages.value.indexOf(garageId)
    if (index > -1) {
      formStartingGarages.value.splice(index, 1)
    }
  }

  function onUseDefaultGarages() {
    formStartingGarages.value = []
  }

  return {
    formId, formName, formDescription, formDifficulty, formStartingCapital, formWinCondition, formVariables,
    formLoanAmount, formLoanInterest, formLoanPayments, formEconomyAdjuster, formStartingGarages, formMap,
    multiselectQueries, isApplyingSeed, form, seedPayload, canSave, isDirty,
    winConditionOptions, variableDefinitions, loansRequired, activeVariables, variableRows,
    paymentsMinutes, perPaymentDisplay, interestPercent,
    markInitialSnapshot, initializeVariables, resetFormDefaults, applySeedDataToForm,
    roundVariableToStep, roundEconomyMultiplier, roundLoanAmount, roundStartingCapital,
    removeGarage, onUseDefaultGarages,
  }
}

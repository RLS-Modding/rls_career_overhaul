import { computed } from 'vue'
import { projectVariables } from './variableSchema.js'
import { safeLua } from '../../../utils/safeLua.js'

// What the selected win condition asks for: its options, its variable definitions and rows, and whether it
// requires a loan. Read-only: the parent writes the selection and the values.
export function useWinConditionSchema({ activeEditorData, formWinCondition, formVariables }) {
  const winConditionOptions = computed(() => {
    try {
      const raw = activeEditorData.value && activeEditorData.value.winConditions
      const list = Array.isArray(raw) ? raw : []
      return list.map(w => ({
        id: w.id,
        name: w.name || w.id,
        description: w.description || '',
        variables: w.variables || {},
        requiresLoans: w.requiresLoans || false
      })).map(w => ({ value: w.id, label: w.name, data: w }))
    } catch (error) {
      safeLua(() => { throw error }, 'ChallengeCreateModal failed to read win condition options')
      return []
    }
  })

  const variableDefinitions = computed(() => {
    try {
      const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
      return (selected && selected.data && selected.data.variables) || {}
    } catch (error) {
      safeLua(() => { throw error }, 'ChallengeCreateModal failed to read variable definitions')
      return {}
    }
  })

  const loansRequired = computed(() => {
    const selected = winConditionOptions.value.find(opt => opt.value === formWinCondition.value)
    return (selected && selected.data && selected.data.requiresLoans) === true
  })

  const activeVariables = computed(() => {
    try {
      return projectVariables(variableDefinitions.value)
    } catch (error) {
      safeLua(() => { throw error }, 'ChallengeCreateModal failed to project active variables')
      return []
    }
  })

  // Each row pairs a variable definition with its current value. The win-condition tab edits values by id.
  const variableRows = computed(() => activeVariables.value.map(variable => ({ variable, value: formVariables[variable.id] })))

  return { winConditionOptions, variableDefinitions, loansRequired, activeVariables, variableRows }
}

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, ref } from 'vue'
import { returnFocusToOpener } from '../../../composables/useScreenEntryFocus'

// State of the multiselect modal: which variable is open, and the button that opened it, so focus can return
// there. Values and search queries stay in the parent's refs. This module reads and writes them by variable id.
export function useMultiselectVariables({ activeVariables, formVariables, multiselectQueries, overlayRef, formMap }) {
  const multiselectModalOpen = ref(false)
  const currentMultiselectVariableId = ref('')
  let multiselectOpener = null

  const multiselectVariables = computed(() => activeVariables.value.filter(v => v.type === 'multiselect'))

  const currentMultiselectVariable = computed(() => {
    if (!currentMultiselectVariableId.value) return null
    return activeVariables.value.find(v => v.id === currentMultiselectVariableId.value)
  })

  function getMultiselectOptions(variableId) {
    const variable = multiselectVariables.value.find(v => v.id === variableId)
    if (!variable || !variable.options) return []

    // Options is now a direct table/array
    const options = Array.isArray(variable.options) ? variable.options : []
    // Map-bound options (garages) only resolve on the challenge's map, so a chosen map hides the others.
    const mapId = formMap && formMap.value
    if (!mapId) return options
    return options.filter(item => !item.mapId || item.mapId === mapId)
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

  function getMultiselectItemName(variableId, itemId) {
    const options = getMultiselectOptions(variableId)
    const item = options.find(opt => opt.id === itemId)
    return item ? item.name : itemId
  }

  function setMultiselectSelection(variableId, value) {
    formVariables[variableId] = value
  }

  function setMultiselectQuery(variableId, value) {
    multiselectQueries[variableId] = value
  }

  // Splices in place, as the list was before this module existed.
  function removeMultiselectItem(variableId, itemId) {
    const values = formVariables[variableId] || []
    const index = values.indexOf(itemId)
    if (index > -1) {
      values.splice(index, 1)
    }
  }

  function openMultiselectModal(variableId) {
    multiselectOpener = document.activeElement?.closest?.('.ccm-multiselect-button') || null
    currentMultiselectVariableId.value = variableId
    if (!multiselectQueries[variableId]) {
      multiselectQueries[variableId] = ''
    }
    multiselectModalOpen.value = true
  }

  function closeMultiselectModal() {
    if (!multiselectModalOpen.value) return
    multiselectModalOpen.value = false
    currentMultiselectVariableId.value = ''
    const opener = multiselectOpener
    multiselectOpener = null
    returnFocusToOpener(() => opener || overlayRef.value?.querySelector('.ccm-multiselect-button'))
  }

  return {
    multiselectModalOpen, currentMultiselectVariableId, currentMultiselectVariable,
    getFilteredMultiselectOptions, getMultiselectItemName, removeMultiselectItem,
    setMultiselectSelection, setMultiselectQuery, openMultiselectModal, closeMultiselectModal,
  }
}

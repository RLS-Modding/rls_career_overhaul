// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Computed values and bound helpers for the Loading Work screen.
// The caller passes only the refs these values read, so nothing here can write the rest of the view's state.
import { computed } from 'vue'
import {
  formatTimeRemaining as formatRemainingFor,
  getMaterialDelivered as deliveredFor,
  getMaterialProgressPercent as materialPercentOf,
  getTimeRemaining as remainingFor,
} from './quarryMath.js'

export function usePhoneQuarryDerived({ activeContract, contractProgress, currentLoadMass, targetLoad, currentSimTime }) {
  const loadPercent = computed(() => {
    if (targetLoad.value <= 0) return 0
    return Math.min(100, (currentLoadMass.value / targetLoad.value) * 100)
  })

  const getMaterialDelivered = materialKey => deliveredFor(contractProgress.value, materialKey)
  const getMaterialProgressPercent = mat => materialPercentOf(contractProgress.value, mat)
  const getTimeRemaining = contract => remainingFor(contract, currentSimTime.value)
  const formatTimeRemaining = contract => formatRemainingFor(contract, currentSimTime.value)

  const isContractComplete = computed(() => {
    if (!activeContract.value) return false
    // For marble contracts, check block counts
    if (activeContract.value.material === 'marble' && activeContract.value.requiredBlocks) {
      const delivered = contractProgress.value.deliveredBlocks || { big: 0, small: 0 }
      const required = activeContract.value.requiredBlocks
      return (delivered.big >= required.big) && (delivered.small >= required.small)
    }
    // For rocks contracts, check tons. A requirement of 0 reads as Infinity, so it never completes.
    return (contractProgress.value.deliveredTons || 0) >= (activeContract.value.requiredTons || Infinity)
  })

  const progressPercent = computed(() => {
    if (!activeContract.value) return 0
    if (activeContract.value.materialBreakdown && activeContract.value.materialBreakdown.length > 0) {
      let totalDelivered = 0
      let totalRequired = 0
      for (const mat of activeContract.value.materialBreakdown) {
        totalDelivered += getMaterialDelivered(mat.materialKey) || 0
        totalRequired += mat.required || 0
      }
      if (totalRequired === 0) return 0
      return (totalDelivered / totalRequired) * 100
    }
    if (activeContract.value.unitType === 'item') {
      if (!activeContract.value.requiredItems) return 0
      return ((contractProgress.value.deliveredItems || 0) / activeContract.value.requiredItems) * 100
    }
    if (!activeContract.value.requiredTons) return 0
    return ((contractProgress.value.deliveredTons || 0) / activeContract.value.requiredTons) * 100
  })

  return {
    loadPercent,
    isContractComplete,
    progressPercent,
    getMaterialDelivered,
    getMaterialProgressPercent,
    getTimeRemaining,
    formatTimeRemaining,
  }
}

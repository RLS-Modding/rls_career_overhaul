// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { luaLiteral } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
import { api } from './presentation.js'

export function bindSessionActions($scope, requestState, invalidateGraphModel) {

  function runLua(command, afterDelay) {
    const luaApi = api()
    if (!luaApi) return
    luaApi.engineLua(command)
    window.setTimeout(requestState, afterDelay || 150)
  }

  $scope.startSession = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.startSession(' + luaLiteral($scope.selectedHubId || 'rls') + ')', 250)
  }

  $scope.repairAndStart = function() {
    const quote = $scope.state && $scope.state.repairQuote
    const revisionArg = quote && quote.revision != null ? ', ' + luaLiteral(String(quote.revision)) : ''
    runLua('overhaul_career_parts_dyno_dynoSession.repairAndStart(' + luaLiteral($scope.selectedHubId || 'rls') + revisionArg + ')', 300)
  }

  $scope.selectHub = function(hubId) {
    if ($scope.state && $scope.state.phase === 'starting') return
    $scope.selectedHubId = hubId
  }

  $scope.armPull = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.startPull()', 100)
  }

  $scope.openMaintenance = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.openMaintenance()', 250)
  }

  $scope.openTuning = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.openTuning()', 250)
  }

  $scope.leaveSession = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.leaveSession()', 250)
  }

  $scope.savePull = function() {
    runLua('overhaul_career_parts_dyno_dynoSession.saveCurrentPull()', 100)
  }

  $scope.selectComparison = function(pullId) {
    $scope.selectedComparisonId = pullId === '' || String($scope.selectedComparisonId) === String(pullId) ? null : String(pullId)
    $scope.graphHover = null
    invalidateGraphModel()
  }

  $scope.comparisonPull = function() {
    if ($scope.selectedComparisonId == null) return null
    return (($scope.state && $scope.state.savedPulls) || []).find(function(pull) {
      return String(pull.id) === String($scope.selectedComparisonId)
    }) || null
  }

  let deletePending = false
  $scope.deleteSavedPull = async function(pullId) {
    const openConfirmation = window.bngVue && window.bngVue.openHouseConfirmation
    const id = Number(pullId)
    const inventoryId = $scope.state && $scope.state.inventoryId
    if (deletePending || $scope.$$destroyed || !openConfirmation || !Number.isFinite(id)) return
    deletePending = true
    try {
      const confirmed = await openConfirmation('Delete saved pull', 'Delete this saved dyno pull?', [
        { label: 'Cancel', value: false, extras: { cancel: true } },
        { label: 'Delete', value: true, extras: { confirm: true, destructive: true } }
      ])
      if (!confirmed || $scope.$$destroyed || !$scope.visible || window.bngVue.openHouseConfirmation !== openConfirmation || inventoryId !== ($scope.state && $scope.state.inventoryId)) return
      if (String($scope.selectedComparisonId) === String(pullId)) $scope.selectedComparisonId = null
      invalidateGraphModel()
      runLua('overhaul_career_parts_dyno_dynoSession.deleteSavedPull(' + luaLiteral(id) + ')', 100)
    } finally {
      deletePending = false
    }
  }

  $scope.formatSavedPullDate = function(savedAt) {
    const timestamp = Number(savedAt)
    if (!isFinite(timestamp) || timestamp <= 0) return 'Saved Pull'
    return new Date(timestamp * 1000).toLocaleString()
  }

  $scope.formatSavedPullSummary = function(pull) {
    return $scope.formatPower(pull && pull.peakPower) + ' at ' + $scope.formatRpm(pull && pull.peakPowerRpm) + ' RPM'
  }
}

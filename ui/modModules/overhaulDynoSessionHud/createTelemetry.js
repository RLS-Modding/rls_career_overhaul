// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { api, normalizeFlags, pollMs } from './presentation.js'

export function createTelemetry($scope, safeApply, applyLayout, invalidateGraphModel, howToWasDismissed) {
  let pollTimer = null
  let refreshTimer = null
  let pollingGeneration = 0
  let active = false
  let inFlight = false
  let stateVersion = 0
  let historyRevision
  let historyVehicle
  let howToAutoShownThisSession = false

  function setState(payload) {
    const previous = $scope.state || {}
    let next = payload && typeof payload === 'object' ? payload : {}
    const sameVehicle = String(previous.inventoryId) === String(next.inventoryId)
    if (next.liveOnly) {
      next = { ...next, savedPulls: sameVehicle ? previous.savedPulls : [], hubOptions: previous.hubOptions }
    } else {
      historyRevision = next.savedPullsRevision
      historyVehicle = String(next.inventoryId)
    }
    if (sameVehicle && next.resultRevision != null && next.resultRevision === previous.resultRevision) {
      next = { ...next, result: previous.result }
    }
    $scope.state = next
    ++stateVersion
    if (previous.result !== next.result || previous.savedPulls !== next.savedPulls) invalidateGraphModel()
    scheduleHistoryRefresh()
    const hubOptions = Array.isArray($scope.state.hubOptions) ? $scope.state.hubOptions : []
    const selectionIsValid = hubOptions.some(function(hub) { return hub.id === $scope.selectedHubId })
    if (!$scope.hubSelectionInitialized || !selectionIsValid) {
      $scope.selectedHubId = $scope.state.selectedHubId || (hubOptions[0] && hubOptions[0].id) || 'rls'
      $scope.hubSelectionInitialized = true
    }
    if (!$scope.state.active) {
      howToAutoShownThisSession = false
    } else if ($scope.state.phase === 'ready' && !howToAutoShownThisSession) {
      howToAutoShownThisSession = true
      if (!howToWasDismissed()) {
        $scope.howToPreference.dontShowAgain = false
        $scope.showHowTo = true
      }
    }
    if (!$scope.showResults()) $scope.graphHover = null
    const displayed = $scope.displayResult()
    const flags = (displayed && displayed.qualityFlags) || $scope.state.qualityFlags
    $scope.flagList = normalizeFlags(flags)
    if ($scope.selectedComparisonId != null && !($scope.state.savedPulls || []).some(function(pull) {
      return String(pull.id) === String($scope.selectedComparisonId)
    })) {
      $scope.selectedComparisonId = null
    }
    if (previous.phase !== $scope.state.phase) applyLayout()
  }

  function historyNeedsRefresh() {
    const state = $scope.state || {}
    return historyRevision !== state.savedPullsRevision || historyVehicle !== String(state.inventoryId)
  }

  function scheduleHistoryRefresh() {
    if (!active || inFlight || refreshTimer != null || !historyNeedsRefresh()) return
    refreshTimer = window.setTimeout(function() {
      refreshTimer = null
      requestState(false)
    }, 0)
  }

  function requestState(liveOnly = true) {
    if (!active || inFlight) return
    const luaApi = api()
    if (!luaApi) return
    const generation = pollingGeneration
    const version = stateVersion
    inFlight = true
    // Indexing an unloaded career module raises a Lua error.
    luaApi.engineLua('(function() local m = rawget(_G, "overhaul_career_parts_dyno_dynoSession") if type(m) ~= "table" or type(m.requestSessionData) ~= "function" then return nil end return m.requestSessionData(' + (liveOnly ? 'true' : 'false') + ') end)()', function(result) {
      if (!active || generation !== pollingGeneration) return
      inFlight = false
      if (!result || typeof result !== 'object') {
        stopPolling()
        safeApply(function() {
          $scope.visible = false
          $scope.state = {}
        })
        return
      }
      safeApply(function() {
        if (!liveOnly) {
          // A history reply supplies static data only; pushes own the current phase and live sample.
          const state = $scope.state || {}
          if (String(result.inventoryId) === String(state.inventoryId) && result.savedPullsRevision >= state.savedPullsRevision) {
            setState({ ...state, liveOnly: false, savedPullsRevision: result.savedPullsRevision, savedPulls: result.savedPulls, hubOptions: result.hubOptions })
          } else if (version === stateVersion) {
            setState(result)
          }
        } else if (version === stateVersion) {
          setState(result)
        }
      })
      scheduleHistoryRefresh()
    })
  }

  function startPolling() {
    if (pollTimer) return
    active = true
    pollTimer = window.setInterval(() => requestState(true), pollMs)
    scheduleHistoryRefresh()
  }

  function stopPolling() {
    active = false
    inFlight = false
    ++pollingGeneration
    if (refreshTimer != null) window.clearTimeout(refreshTimer)
    refreshTimer = null
    if (pollTimer != null) window.clearInterval(pollTimer)
    pollTimer = null
  }

  return { requestState, setState, startPolling, stopPolling }
}

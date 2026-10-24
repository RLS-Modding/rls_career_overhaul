// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { toNumber, unitString } from './presentation.js'

export function bindResultDerivations($scope) {

  $scope.displayResult = function() {
    return $scope.state && $scope.state.phase === 'complete' ? $scope.state.result : null
  }

  $scope.showResults = function() {
    return !!$scope.displayResult() && $scope.isComplete()
  }

  $scope.isPulling = function() {
    return $scope.state && $scope.state.phase === 'pulling'
  }

  $scope.isComplete = function() {
    return $scope.state && $scope.state.phase === 'complete'
  }

  $scope.canStartSession = function() {
    return !!($scope.state && $scope.state.canStart && $scope.state.phase !== 'starting')
  }

  $scope.canArmPull = function() {
    return !!($scope.state && $scope.state.phase === 'ready')
  }

  $scope.selectedHubLabel = function() {
    const options = ($scope.state && $scope.state.hubOptions) || []
    const selectedId = ($scope.state && $scope.state.active && $scope.state.selectedHubId) || $scope.selectedHubId
    const option = options.find(function(hub) { return hub.id === selectedId })
    return option ? option.label : 'Dyno Hub'
  }

  $scope.formatStage = function(stage) {
    if (stage === 'armed') return 'Armed'
    if (stage === 'ready') return 'Ready'
    if (stage === 'recording') return 'Recording'
    if (stage === 'finishing') return 'Finishing'
    if (stage === 'complete') return 'Complete'
    return 'Waiting'
  }

  $scope.formatPhase = function() {
    const phase = $scope.state && $scope.state.phase
    if (phase === 'offer') return $scope.state.error ? 'Waiting' : 'Available'
    if (phase === 'starting') return 'Setting Up'
    if (phase === 'ready') return 'Ready'
    if (phase === 'pulling') return 'Pulling'
    if (phase === 'complete') return 'Complete'
    if (phase === 'leaving') return 'Restoring'
    if (phase === 'restoreFailed') return 'Restore failed'
    return 'Dyno'
  }

  $scope.formatPower = function(value) {
    return unitString('power', value, 'PS')
  }

  $scope.formatTorque = function(value) {
    return unitString('torque', value, 'Nm')
  }

  $scope.formatRpm = function(value) {
    return Math.max(0, Math.round(toNumber(value))).toLocaleString()
  }

  $scope.formatPercent = function(value) {
    return Math.round(Math.max(0, Math.min(1, toNumber(value))) * 100) + '%'
  }

  $scope.formatGear = function(sample) {
    if (!sample) return '-'
    const raw = sample.rawGear
    if (raw != null && typeof raw !== 'object' && raw !== '') return raw
    if (raw && typeof raw === 'object') {
      const candidates = [raw.gear, raw.gearIndex, raw.gearM, raw.visualGear, raw.deviceGearIndex]
      for (let i = 0; i < candidates.length; i++) {
        if (candidates[i] != null && candidates[i] !== '') return String(candidates[i])
      }
    }
    const gear = toNumber(sample.gear)
    if (gear > 0) return String(Math.round(gear))
    if (gear < 0) return 'R'
    return 'N'
  }

  $scope.qualityClass = function() {
    const result = $scope.displayResult()
    const quality = (result && result.pullQuality) || ($scope.state && $scope.state.pullQuality)
    if (result) return $scope.resultQuality() === 'Clean' ? 'dsh-quality-clean' : 'dsh-quality-warning'
    if (quality === 'clean') return 'dsh-quality-clean'
    return 'dsh-quality-warning'
  }

  $scope.statusText = function() {
    if ($scope.state && $scope.state.statusText) return $scope.state.statusText
    const phase = $scope.state && $scope.state.phase
    const stage = $scope.state && $scope.state.pullStage
    if (phase === 'offer') return 'Start a paid dyno session from this bay.'
    if (phase === 'ready') return 'Start the engine, select a high forward gear, then arm the pull.'
    if (stage === 'armed') return 'Hold the selected high gear steady.'
    if (stage === 'ready') return 'Apply at least 90% throttle to start recording.'
    if (stage === 'recording') return 'Recording. Hold gear and throttle; lift below 75% to finish.'
    if (stage === 'finishing') return 'Finishing the pull.'
    if (phase === 'complete') return 'Review the result, then press Done to restore the car.'
    return 'Manual dyno session.'
  }

  $scope.resultPower = function() {
    const result = $scope.displayResult()
    return $scope.formatPower(result && result.peakPower)
  }

  $scope.resultTorque = function() {
    const result = $scope.displayResult()
    return $scope.formatTorque(result && result.peakTorque)
  }

  $scope.resultPowerRpm = function() {
    const result = $scope.displayResult()
    const rpm = result && result.peakPowerRpm
    return rpm ? 'at ' + $scope.formatRpm(rpm) + ' RPM' : 'RPM unavailable'
  }

  $scope.resultTorqueRpm = function() {
    const result = $scope.displayResult()
    const rpm = result && result.peakTorqueRpm
    return rpm ? 'at ' + $scope.formatRpm(rpm) + ' RPM' : 'RPM unavailable'
  }

  $scope.resultQuality = function() {
    const result = $scope.displayResult()
    if (!result) return '-'
    if (!result.valid || result.measurementComplete === false || result.pullQuality === 'invalid' || result.pullQuality === 'warning') return 'Warning'
    const flags = result.qualityFlags || {}
    return Object.keys(flags).some(function(flag) { return !!flags[flag] }) ? 'Warning' : 'Clean'
  }
}

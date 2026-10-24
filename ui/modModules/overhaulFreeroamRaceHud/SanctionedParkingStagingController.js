// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('SanctionedParkingStagingController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.spVisible = false
  $scope.payload = {}

  const safeApply = createSafeApply($scope)

  $scope.formatRewardDollars = function(n) {
    if (n == null || (typeof n !== 'number' && typeof n !== 'string')) return '0'
    const v = Number(n)
    if (!isFinite(v)) return '0'
    return String(Math.floor(v))
  }

  $scope.stagingHeadline = function(p) {
    if (!p || typeof p !== 'object') return 'Sanctioned event'
    const laps = Math.max(1, Math.floor(Number(p.lapCount) || 1))
    const label = (p.raceLabel != null && String(p.raceLabel).trim() !== '') ? String(p.raceLabel).trim() : 'Track'
    return laps + '-Lap ' + label + ' Event'
  }

  $scope.cancelStaging = function() {
    $scope.spVisible = false
    if (typeof bngApi !== 'undefined') bngApi.engineLua('overhaul_events_competitiveTrackFlow.sanctionedParkingAbortStaging()')
  }

  $scope.stageAndSpawn = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('overhaul_events_competitiveTrackFlow.sanctionedParkingStageAndSpawn()')
    }
  }

  $scope.startEvent = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('overhaul_events_competitiveTrackFlow.sanctionedParkingStartEvent()')
    }
  }

  const spListener = angularRootScope.$on('SanctionedParkingStagingUi', function(_evt, data) {
    safeApply(function() {
      $scope.spVisible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
    })
  })

  $scope.$on('$destroy', function() {
    spListener()
  })
}])

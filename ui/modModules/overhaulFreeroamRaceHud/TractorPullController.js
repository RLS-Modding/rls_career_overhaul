// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { luaLiteral } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('TractorPullController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.mode = null
  $scope.payload = {}

  const safeApply = createSafeApply($scope)

  const encodeLuaString = value => luaLiteral(value == null ? '' : String(value))

  function luaCall(code) {
    if (typeof bngApi !== 'undefined') bngApi.engineLua(code)
  }

  $scope.number = function(value, decimals) {
    var n = Number(value)
    if (!isFinite(n)) n = 0
    return n.toLocaleString(undefined, {minimumFractionDigits: decimals, maximumFractionDigits: decimals})
  }
  $scope.money = function(value) { return '$' + $scope.number(value, 0) }
  $scope.time = function(value) {
    var seconds = Math.max(0, Number(value) || 0)
    var mins = Math.floor(seconds / 60)
    var rest = seconds - mins * 60
    return mins + ':' + rest.toFixed(2).padStart(5, '0')
  }
  $scope.progressStyle = function() {
    var distance = Number($scope.payload.distanceMeters) || 0
    var total = Number($scope.payload.fullDistanceMeters) || 1
    return {transform: 'scaleX(' + Math.max(0, Math.min(1, distance / total)) + ')'}
  }
  $scope.selectSled = function(id) {
    luaCall('if overhaul_events_tractorPull then overhaul_events_tractorPull.selectSled(' + encodeLuaString(id) + ') end')
  }
  $scope.selectHitch = function(id) {
    luaCall('if overhaul_events_tractorPull then overhaul_events_tractorPull.selectHitch(' + encodeLuaString(id) + ') end')
  }
  $scope.backToSleds = function() {
    luaCall('if overhaul_events_tractorPull then overhaul_events_tractorPull.backToSleds() end')
  }
  $scope.cancel = function() {
    $scope.visible = false
    luaCall('if overhaul_events_tractorPull then overhaul_events_tractorPull.cancel() end')
  }
  $scope.dismissResults = function() {
    $scope.visible = false
    luaCall('if overhaul_events_tractorPull then overhaul_events_tractorPull.dismissResults() end')
  }

  const listener = angularRootScope.$on('TractorPullUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.mode = data && data.mode || null
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
    })
  })
  $scope.$on('$destroy', function() { listener() })
}])

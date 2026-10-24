import { reportFailure } from '../../modules/overhaulAngular/reportFailure.js'
import { createDraggableCard } from '../../modules/overhaulAngular/draggableCard.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('MiningHaulController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 420 }
  var hudDefaulted = false
  var hasSavedLayout = false
  var layoutStorageKey = 'rlsMiningHaulLayout'

  const safeApply = createSafeApply($scope)

  function restoreLayout() {
    try {
      if (!window.localStorage) return false
      var saved = JSON.parse(window.localStorage.getItem(layoutStorageKey) || 'null')
      if (!saved || !isFinite(saved.x) || !isFinite(saved.y)) return false
      layout.x = Number(saved.x)
      layout.y = Number(saved.y)
      layout.width = Math.max(260, Math.min(Number(saved.width) || 340, window.innerWidth - 32))
      clampLayout()
      return true
    } catch (_err) {
      return false
    }
  }

  function saveLayout() {
    try {
      if (!window.localStorage || layout.x == null || layout.y == null) return
      window.localStorage.setItem(layoutStorageKey, JSON.stringify({
        x: Math.round(layout.x),
        y: Math.round(layout.y),
        width: Math.round(layout.width || 340)
      }))
      hasSavedLayout = true
    } catch (_err) { reportFailure(_err, 'Save mining haul HUD layout') }
  }

  function centerLayout() {
    layout.width = Math.min(420, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 340) / 2))
  }

  function hudLayout() {
    layout.width = Math.min(340, window.innerWidth - 32)
    layout.x = 16
    layout.y = Math.max(74, Math.min(118, window.innerHeight - 220))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  hasSavedLayout = restoreLayout()

  function luaCall(code) {
    if (typeof bngApi !== 'undefined') bngApi.engineLua(code)
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  const { onMouseMove, onMouseUp, dispose: disposeDrag } = createDraggableCard($scope, layout, clampLayout, safeApply, { onRelease: saveLayout })

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.money = function(value) {
    var n = Math.max(0, Math.floor(Number(value) || 0))
    return '$' + n.toLocaleString()
  }

  $scope.startShift = function() { luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.startShift then overhaul_jobs_miningHaul.startShift() end') }
  $scope.loadTruck = function() { luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.loadTruck then overhaul_jobs_miningHaul.loadTruck() end') }
  $scope.processOre = function() { luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.processOre then overhaul_jobs_miningHaul.processOre() end') }
  $scope.repairTruck = function() { luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.repairTruck then overhaul_jobs_miningHaul.repairTruck() end') }
  $scope.endShift = function() { luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.endShift then overhaul_jobs_miningHaul.endShift() end') }
  $scope.close = function() {
    $scope.visible = false
    luaCall('if overhaul_jobs_miningHaul and overhaul_jobs_miningHaul.closeUi then overhaul_jobs_miningHaul.closeUi() end')
  }

  const listener = angularRootScope.$on('MiningHaulUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && typeof data === 'object' ? data : {}
      if ($scope.visible && $scope.payload.mode === 'hud' && !hudDefaulted) {
        if (hasSavedLayout) clampLayout()
        else hudLayout()
        hudDefaulted = true
      }
      else if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
    disposeDrag()
  })
}])

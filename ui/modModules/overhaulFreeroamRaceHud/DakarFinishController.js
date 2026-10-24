import { createDraggableCard } from '../../modules/overhaulAngular/draggableCard.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('DakarFinishController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 420 }
  var hudDefaulted = false

  const safeApply = createSafeApply($scope)

  function centerLayout() {
    layout.width = 420
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 500) / 2))
  }

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
  }

  $scope.cardStyle = function() {
    if (layout.x == null || layout.y == null) centerLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  const { onMouseMove, onMouseUp, dispose: disposeDrag } = createDraggableCard($scope, layout, clampLayout, safeApply)

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.dismiss = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("local name = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureExtension and overhaul_world_maps.getOptionalFeatureExtension('dakar'); local config = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureConfig and overhaul_world_maps.getOptionalFeatureConfig('dakar'); local feature = name and extensions[name]; if feature and feature.dismissFinish then if config ~= nil then feature.dismissFinish(config) else feature.dismissFinish() end else log('W', 'overhaul_optional_events', 'Dakar finish dismiss disabled: provider or dismissFinish unavailable (' .. tostring(name) .. ')') end")
    }
  }

  $scope.seconds = function(value) {
    var s = Math.max(0, Math.floor(Number(value) || 0))
    return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0')
  }

  $scope.money = function(value) {
    var n = Math.max(0, Math.floor(Number(value) || 0))
    return '$' + n.toLocaleString()
  }

  const listener = angularRootScope.$on('DakarFinishUi', function(_evt, data) {
    safeApply(function() {
      $scope.visible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
      if ($scope.visible && (layout.x == null || layout.y == null)) centerLayout()
    })
  })

  $scope.$on('$destroy', function() {
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
    disposeDrag()
  })
}])

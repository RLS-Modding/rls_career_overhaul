import { createDraggableCard } from '../../modules/overhaulAngular/draggableCard.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('RoadAuthorityIntroController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 760 }

  const safeApply = createSafeApply($scope)

  function centerLayout() {
    layout.width = Math.min(760, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 560) / 2))
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
      bngApi.engineLua("local name = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureExtension and overhaul_world_maps.getOptionalFeatureExtension('roadAuthority'); local config = overhaul_world_maps and overhaul_world_maps.getOptionalFeatureConfig and overhaul_world_maps.getOptionalFeatureConfig('roadAuthority'); local feature = name and extensions[name]; if feature and feature.dismissIntro then if config ~= nil then feature.dismissIntro(config) else feature.dismissIntro() end else log('W', 'overhaul_optional_events', 'Road Authority intro dismiss disabled: provider or dismissIntro unavailable (' .. tostring(name) .. ')') end")
    }
  }

  const listener = angularRootScope.$on('RoadAuthorityIntroUi', function(_evt, data) {
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

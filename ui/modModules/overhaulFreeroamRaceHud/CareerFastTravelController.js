import { luaLiteral } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
import { createDraggableCard } from '../../modules/overhaulAngular/draggableCard.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('CareerFastTravelController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var layout = { x: null, y: null, width: 430 }

  const safeApply = createSafeApply($scope)

  function centerLayout() {
    layout.width = Math.min(430, window.innerWidth - 48)
    layout.x = Math.max(16, Math.floor((window.innerWidth - layout.width) / 2))
    layout.y = Math.max(16, Math.floor((window.innerHeight - 300) / 2))
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

  const encodeLuaString = value => luaLiteral(value == null ? '' : String(value))

  $scope.money = function(value) {
    var n = Number(value)
    if (!isFinite(n)) n = 0
    return '$' + (Math.round(n * 100) / 100).toLocaleString(undefined, {
      minimumFractionDigits: n % 1 === 0 ? 0 : 2,
      maximumFractionDigits: 2
    })
  }

  $scope.travelTo = function(destination) {
    if (!destination || !destination.id || destination.canPay === false) return
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if overhaul_career_garage_fastTravel and overhaul_career_garage_fastTravel.travelTo then overhaul_career_garage_fastTravel.travelTo(' + encodeLuaString(destination.id) + ') end')
    }
  }

  $scope.close = function() {
    $scope.visible = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('if overhaul_career_garage_fastTravel and overhaul_career_garage_fastTravel.closeTravelMenu then overhaul_career_garage_fastTravel.closeTravelMenu() end')
    }
  }

  const listener = angularRootScope.$on('CareerFastTravelUi', function(_evt, data) {
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

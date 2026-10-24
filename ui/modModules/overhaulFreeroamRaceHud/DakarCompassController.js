import { createDraggableCard } from '../../modules/overhaulAngular/draggableCard.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('DakarCompassController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.payload = {}
  var DEFAULT_LAYOUT = { x: 24, y: 120, width: 180 }
  var layout = { x: DEFAULT_LAYOUT.x, y: DEFAULT_LAYOUT.y, width: DEFAULT_LAYOUT.width }
  var layoutLoaded = false
  var layoutLoading = false
  var latestData = null
  var disposed = false
  var needleDegrees = null

  const safeApply = createSafeApply($scope)

  function clampLayout() {
    layout.x = Math.max(8, Math.min(layout.x, window.innerWidth - 120))
    layout.y = Math.max(8, Math.min(layout.y, window.innerHeight - 80))
    layout.width = Math.max(150, Math.min(layout.width, 240))
  }

  function persistLayout() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        "extensions.overhaul_shell_settings.setSetting('dakarCompassLayout', " +
        "{x = " + layout.x + ", y = " + layout.y + ", width = " + layout.width + "})"
      )
    }
  }

  function loadLayout(cb) {
    if (layoutLoaded) {
      if (cb) cb()
      return
    }
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("extensions.overhaul_shell_settings.getSetting('dakarCompassLayout')", function(result) {
        if (cb) cb(result)
      })
    } else {
      if (cb) cb()
    }
  }

  $scope.cardStyle = function() {
    clampLayout()
    return { left: layout.x + 'px', top: layout.y + 'px', width: layout.width + 'px' }
  }

  $scope.needleStyle = function() {
    return { transform: 'rotate(' + (needleDegrees == null ? 0 : needleDegrees) + 'deg)' }
  }

  function updateNeedle(heading) {
    if (heading == null || !Number.isFinite(Number(heading))) return
    var degrees = ((Number(heading) % 360) + 360) % 360
    // Accumulate the shortest turn so crossing north never spins a full circle.
    needleDegrees = needleDegrees == null ? degrees
      : needleDegrees + ((degrees - needleDegrees % 360 + 540) % 360 - 180)
  }

  const { onMouseMove, onMouseUp, dispose: disposeDrag } = createDraggableCard($scope, layout, clampLayout, safeApply, { ignoreButtons: false, onRelease: persistLayout })

  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  const listener = angularRootScope.$on('DakarCompassUi', function(_evt, data) {
    latestData = data
    if (!data || !data.visible) {
      needleDegrees = null
      safeApply(function() {
        $scope.visible = false
        $scope.payload = {}
      })
      return
    }
    if (layoutLoading) return
    layoutLoading = true
    loadLayout(function(candidate) {
      // Coalesce heading updates while placement loads; only the latest may reveal it.
      if (disposed) return
      layoutLoading = false
      safeApply(function() {
        if (!layoutLoaded) {
          candidate = candidate && typeof candidate === 'object' ? candidate : {}
          layout.x = Number.isFinite(candidate.x) ? candidate.x : DEFAULT_LAYOUT.x
          layout.y = Number.isFinite(candidate.y) ? candidate.y : DEFAULT_LAYOUT.y
          layout.width = Number.isFinite(candidate.width) ? candidate.width : DEFAULT_LAYOUT.width
          clampLayout()
          layoutLoaded = true
        }
        if (!latestData || !latestData.visible) return
        $scope.payload = latestData.payload && typeof latestData.payload === 'object' ? latestData.payload : {}
        updateNeedle($scope.payload.vehicleHeadingDegrees)
        $scope.visible = true
      })
    })
  })

  $scope.$on('$destroy', function() {
    disposed = true
    latestData = null
    listener()
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
    disposeDrag()
  })
}])

import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
import { createStandingsOvertakeTracker } from './raceStandings.js'
import { createHudLayout } from './raceLayout.js'
import { attachRaceFormatters, syncVanillaDragInfoSuppress, setVanillaDragInfoSuppressed } from './racePresentation.js'
import { createDemoToastTracker } from './demoToasts.js'
angular.module('beamng.stuff')
.controller('FreeroamRaceHudController', ['$scope', '$rootScope', '$timeout', function($scope, $rootScope, $timeout) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.state = {}
  $scope.criticalWarningText = null

  const standings = createStandingsOvertakeTracker($scope, $timeout)
  const layout = createHudLayout($scope, angularRootScope)

  const safeApply = createSafeApply($scope)

  attachRaceFormatters($scope)

  function setState(data) {
    $scope.state = data
    var st = data.standings
    if (st && st.length) standings.apply(st)
    else standings.reset()
  }

  const showListener = angularRootScope.$on('FreeroamRaceHudShow', function(_evt, snapshot) {
    safeApply(function() {
      standings.reset()
      $scope.visible = false
      $scope.state = {}
      $scope.criticalWarningText = null
      if (!snapshot || !snapshot.state || typeof snapshot.state !== 'object') {
        syncVanillaDragInfoSuppress($scope)
        return
      }
      // Bind placement and values in the same digest that reveals the panel.
      layout.adoptLayout(snapshot.layout)
      setState(snapshot.state)
      $scope.visible = true
      syncVanillaDragInfoSuppress($scope)
    })
    if ($scope.visible) layout.notifyGameBlur()
  })

  $scope.dismissCompletion = function() {
    if (!$scope.state.canDismissCompletion || typeof bngApi === 'undefined') return
    const generation = $scope.state.completionGeneration
    if (!Number.isSafeInteger(generation) || generation <= 0) return
    bngApi.engineLua('if overhaul_events_raceSession then overhaul_events_raceSession.dismissDragRaceHudCompletion(' + generation + ') end')
  }

  const hideListener = angularRootScope.$on('FreeroamRaceHudHide', function() {
    safeApply(function() {
      standings.reset()
      $scope.visible = false
      $scope.state = {}
      $scope.criticalWarningText = null
      syncVanillaDragInfoSuppress($scope)
    })
    layout.notifyGameBlur()
  })

  const criticalListener = angularRootScope.$on('FreeroamRaceHudCriticalWarning', function(_evt, data) {
    if (!$scope.visible) return
    safeApply(function() {
      var t = data && data.text
      $scope.criticalWarningText = (t != null && String(t).length > 0) ? String(t) : null
    })
    layout.notifyGameBlur()
  })

  const stateListener = angularRootScope.$on('FreeroamRaceHudState', function(_evt, data) {
    if (!$scope.visible) return
    safeApply(function() {
      setState(data && typeof data === 'object' ? data : {})
      syncVanillaDragInfoSuppress($scope)
    })
  })

  // ── Demo elimination toasts ──────────────────────────────
  $scope.demoToasts = []
  const toasts = createDemoToastTracker($scope, $timeout, safeApply)
  const elimToastListener = angularRootScope.$on('DemoEliminationToast', function(_evt, data) {
    toasts.add(data)
  })

  $scope.$on('$destroy', function() {
    standings.cancel()
    toasts.cancelAll()
    setVanillaDragInfoSuppressed(false)
    showListener()
    hideListener()
    criticalListener()
    stateListener()
    elimToastListener()
    layout.dispose()
  })
}])

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import '../overhaulFreeroamRaceHud/gameplayPopup.js'
// The entry owns the how-to dialog, the graph model cache, click dispatch and the listener lifecycle, and wires the
// layout, telemetry and binding helpers in scope-initialization order, before the stock loader mounts the overlay.
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
import { reportFailure } from '../../modules/overhaulAngular/reportFailure.js'
import { HOW_TO_STORAGE_KEY, toNumber, displayPowerValue, displayTorqueValue, graphPoint } from './presentation.js'
import { createLayout } from './createLayout.js'
import { createTelemetry } from './createTelemetry.js'
import { bindSessionActions } from './bindSessionActions.js'
import { bindResultDerivations } from './bindResultDerivations.js'
import { bindPlotPresentation } from './bindPlotPresentation.js'

angular.module('beamng.stuff')
.controller('DynoSessionHudController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  const safeApply = createSafeApply($scope)

  $scope.visible = false
  $scope.state = {}
  $scope.flagList = []
  $scope.graphHover = null
  $scope.selectedComparisonId = null
  $scope.showHowTo = false
  $scope.howToPreference = { dontShowAgain: false }

  $scope.controlsOpen = false
  $scope.openControls = function() { if ($scope.visible && !$scope.isPulling()) $scope.controlsOpen = true }
  $scope.closeControls = function() {
    $scope.controlsOpen = false
    if ($scope.state.phase === 'offer' || $scope.state.phase === 'starting') $scope.leaveSession()
  }
  const controlsListener = angularRootScope.$on('OverhaulDynoControls', function() { safeApply($scope.openControls) })

  // How-to dialog
  function howToWasDismissed() {
    try {
      return window.localStorage.getItem(HOW_TO_STORAGE_KEY) === '1'
    } catch (err) {
      return false
    }
  }

  $scope.openHowTo = function() {
    $scope.howToPreference.dontShowAgain = howToWasDismissed()
    $scope.showHowTo = true
  }

  $scope.closeHowTo = function() {
    if ($scope.howToPreference.dontShowAgain) {
      try {
        window.localStorage.setItem(HOW_TO_STORAGE_KEY, '1')
      } catch (err) { reportFailure(err, 'Save dyno how-to dismissal') }
    }
    $scope.showHowTo = false
  }

  // Graph model (cached until the state changes)
  let graphModelCache = { model: null }

  function invalidateGraphModel() {
    graphModelCache = { model: null }
  }

  function graphModel() {
    const powerScale = displayPowerValue(1)
    const torqueScale = displayTorqueValue(1)
    if (graphModelCache.model && graphModelCache.powerScale === powerScale && graphModelCache.torqueScale === torqueScale) return graphModelCache.model

    const result = $scope.displayResult()
    const curve = result && result.curve
    if (!Array.isArray(curve) || !curve.length) {
      return null
    }

    const comparison = $scope.comparisonPull()
    const allCurves = [curve]
    if (comparison && Array.isArray(comparison.curve)) allCurves.push(comparison.curve)
    const allPoints = [].concat.apply([], allCurves)
    const rpms = allPoints.map(function(point) { return toNumber(point.rpm) })
    const powers = allPoints.map(function(point) { return Math.max(0, displayPowerValue(point.power)) })
    const torques = allPoints.map(function(point) { return Math.max(0, displayTorqueValue(point.torque)) })
    const rawMaxRpm = Math.max.apply(Math, rpms)
    const minRpm = 1000
    const maxRpm = Math.max(minRpm + 500, Math.ceil(rawMaxRpm / 500) * 500)
    const rawMaxY = Math.max.apply(Math, powers.concat(torques).concat([50]))
    const yStep = rawMaxY > 600 ? 100 : 50
    const model = {
      curve: curve,
      plot: { x: 84, y: 34, w: 600, h: 226 },
      minRpm: minRpm,
      maxRpm: maxRpm,
      maxY: Math.max(yStep, Math.ceil(rawMaxY / yStep) * yStep),
      yStep: yStep
    }
    function pointsFor(source, kind) {
      return (source || []).map(function(point) {
        const value = kind === 'torque' ? displayTorqueValue(point.torque) : displayPowerValue(point.power)
        return graphPoint(model, point.rpm, value)
      }).join(' ')
    }
    model.polylines = {
      power: pointsFor(curve, 'power'),
      torque: pointsFor(curve, 'torque'),
      comparisonPower: pointsFor(comparison && comparison.curve, 'power'),
      comparisonTorque: pointsFor(comparison && comparison.curve, 'torque')
    }
    graphModelCache = { model: model, powerScale: powerScale, torqueScale: torqueScale }
    return model
  }

  // Parts
  const layout = createLayout($scope, angularRootScope)
  const telemetry = createTelemetry($scope, safeApply, layout.applyLayout, invalidateGraphModel, howToWasDismissed)
  bindSessionActions($scope, telemetry.requestState, invalidateGraphModel)
  bindResultDerivations($scope)
  bindPlotPresentation($scope, graphModel)

  // Document listeners and click dispatch
  function onClick(e) {
    if (!$scope.visible) return
    const button = e.target.closest('[data-dsh-action]')
    if (!button || !button.closest('.dsh-root, .gameplay-popup-content') || button.disabled) return

    const action = button.getAttribute('data-dsh-action')
    e.preventDefault()
    e.stopPropagation()

    if (action === 'start') {
      $scope.startSession()
    } else if (action === 'repair-start') {
      $scope.repairAndStart()
    } else if (action === 'arm') {
      $scope.armPull()
    } else if (action === 'howto') {
      safeApply($scope.openHowTo)
    } else if (action === 'howto-close') {
      safeApply($scope.closeHowTo)
    } else if (action === 'compare') {
      safeApply(function() { $scope.selectComparison(button.getAttribute('data-pull-id')) })
    } else if (action === 'delete-pull') {
      $scope.deleteSavedPull(button.getAttribute('data-pull-id'))
    } else if (action === 'maintenance') {
      $scope.openMaintenance()
    } else if (action === 'tuning') {
      $scope.openTuning()
    } else if (action === 'save') {
      $scope.savePull()
    } else if (action === 'leave') {
      $scope.leaveSession()
    }
  }

  function onResize() {
    if ($scope.visible) layout.applyLayout()
  }
  const resizeListener = angularRootScope.$on('windowResize', onResize)

  document.addEventListener('mousedown', layout.onMouseDown, true)
  document.addEventListener('mousemove', layout.onMouseMove, true)
  document.addEventListener('mouseup', layout.onMouseUp, true)
  document.addEventListener('click', onClick, true)

  // Rootscope events and teardown
  const showListener = angularRootScope.$on('DynoSessionHudShow', function(_evt, snapshot) {
    telemetry.stopPolling()
    safeApply(function() {
      $scope.controlsOpen = false
      $scope.visible = false
      $scope.state = {}
      $scope.flagList = []
      $scope.graphHover = null
      $scope.selectedComparisonId = null
      $scope.showHowTo = false
      if (!snapshot || !snapshot.state || typeof snapshot.state !== 'object') return
      telemetry.setState(snapshot.state)
      layout.adoptLayout(snapshot.layout)
      $scope.visible = true
    })
    if ($scope.visible) {
      layout.applyLayout()
      telemetry.startPolling()
      layout.notifyGameBlur()
    }
  })

  const hideListener = angularRootScope.$on('DynoSessionHudHide', function() {
    safeApply(function() {
      $scope.visible = false
      $scope.state = {}
      $scope.flagList = []
      $scope.graphHover = null
      $scope.showHowTo = false
      $scope.controlsOpen = false
      invalidateGraphModel()
    })
    telemetry.stopPolling()
    layout.notifyGameBlur()
  })

  const stateListener = angularRootScope.$on('DynoSessionHudState', function(_evt, payload) {
    if (!$scope.visible) return
    safeApply(function() {
      telemetry.setState(payload)
    })
  })

  $scope.$on('$destroy', function() {
    controlsListener()
    showListener()
    hideListener()
    stateListener()
    telemetry.stopPolling()
    layout.dispose()
    resizeListener()
    document.removeEventListener('mousedown', layout.onMouseDown, true)
    document.removeEventListener('mousemove', layout.onMouseMove, true)
    document.removeEventListener('mouseup', layout.onMouseUp, true)
    document.removeEventListener('click', onClick, true)
  })
}])

const dynoSessionHudModule = angular.module('overhaulDynoSessionHud', ['ui.router'])
.run(function() {
  function initializeDynoSessionHudOverlay() {
    const existing = document.getElementById('dyno-session-hud-overlay-container')
    if (existing) return

    const bodyElement = angular.element(document.body)
    const angularRoot = document.getElementById('angular-root')
    const injector = angularRoot && angular.element(angularRoot).injector()
    if (!injector) {
      window.setTimeout(initializeDynoSessionHudOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    const container = angular.element(
      '<div id="dyno-session-hud-overlay-container" ng-controller="DynoSessionHudController" ng-include="\'/ui/modModules/overhaulDynoSessionHud/overhaulDynoSessionHud.html\'"></div>'
    )
    bodyElement.append(container)
    $compile(container)($rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeDynoSessionHudOverlay)
  } else {
    window.setTimeout(initializeDynoSessionHudOverlay, 300)
  }
})

export default dynoSessionHudModule

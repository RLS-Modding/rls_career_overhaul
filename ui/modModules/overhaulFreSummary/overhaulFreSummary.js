// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
'use strict'

const FRE_SUMMARY_PAUSE_ID = 'freSummaryOverlay'

angular.module('beamng.stuff')
.controller('FreSummaryController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.data = null
  $scope.detailsOpen = false
  $scope.summaryPauseHeld = false

  var blurId = null

  const safeApply = createSafeApply($scope)

  function pushSummaryPause() {
    if ($scope.summaryPauseHeld) return
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("simTimeAuthority.pushPauseRequest('" + FRE_SUMMARY_PAUSE_ID + "')")
    }
    $scope.summaryPauseHeld = true
  }

  function popSummaryPause() {
    if (!$scope.summaryPauseHeld) return
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("simTimeAuthority.popPauseRequest('" + FRE_SUMMARY_PAUSE_ID + "')")
    }
    $scope.summaryPauseHeld = false
  }

  function enableBlur() {
    if (blurId != null) return
    var blurrer = window.bridge && window.bridge.gameBlurrer
    if (blurrer) {
      blurId = blurrer.register([0, 0, 1, 1, 1])
    }
  }

  function disableBlur() {
    if (blurId == null) return
    var blurrer = window.bridge && window.bridge.gameBlurrer
    if (blurrer) {
      blurrer.unregister(blurId)
    }
    blurId = null
  }

  $scope.formatTime = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '\u2014'
    const sign = seconds < 0 ? '-' : ''
    let s = Math.abs(seconds)
    const m = Math.floor(s / 60)
    s = s % 60
    const whole = Math.floor(s)
    const cent = Math.floor((s - whole) * 100)
    return sign + (m < 10 ? '0' : '') + m + ':' + (whole < 10 ? '0' : '') + whole + '.' + (cent < 10 ? '0' : '') + cent
  }

  $scope.formatTimeWhole = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '\u2014'
    const sign = seconds < 0 ? '-' : ''
    seconds = Math.max(0, Math.floor(Math.abs(seconds)))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return sign + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s
  }

  $scope.formatMoney = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '0.00'
    return (Math.round(n * 100) / 100).toFixed(2)
  }

  $scope.dismiss = function() {
    disableBlur()
    popSummaryPause()
    const shouldHideRaceHud = $scope.data && $scope.data.noPause === true
    safeApply(function() {
      $scope.visible = false
      $scope.data = null
      $scope.detailsOpen = false
    })
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        'if extensions.overhaul_events_host and extensions.overhaul_events_host.clearFreSummarySession then extensions.overhaul_events_host.clearFreSummarySession() end'
      )
      if (shouldHideRaceHud) {
        bngApi.engineLua(
          'if extensions.overhaul_events_raceSession and extensions.overhaul_events_raceSession.hideFreeroamRaceHud then extensions.overhaul_events_raceSession.hideFreeroamRaceHud(true) end'
        )
      }
    }
    if (typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(function() {
        angularRootScope.$broadcast('windowResize')
      })
    }
  }

  const showListener = angularRootScope.$on('FreerunSummaryShow', function(_evt, payload) {
    safeApply(function() {
      $scope.data = payload && typeof payload === 'object' ? payload : {}
      $scope.visible = true
      $scope.detailsOpen = false
      if ($scope.data.noPause === true) {
        disableBlur()
        popSummaryPause()
      } else {
        enableBlur()
        pushSummaryPause()
      }
      if (typeof window.requestAnimationFrame === 'function') {
        window.requestAnimationFrame(function() {
          angularRootScope.$broadcast('windowResize')
        })
      }
    })
  })

  const hideListener = angularRootScope.$on('FreerunSummaryHide', function() {
    $scope.dismiss()
  })

  $scope.$on('$destroy', function() {
    disableBlur()
    popSummaryPause()
    showListener()
    hideListener()
  })
}])

const freSummaryModule = angular.module('overhaulFreSummary', ['ui.router'])
.run(function() {
  function initializeFreSummaryOverlay() {
    const existing = document.getElementById('fre-summary-overlay-container')
    if (existing) return

    const bodyElement = angular.element(document.body)
    const angularRoot = document.getElementById('angular-root')
    const injector = angularRoot && angular.element(angularRoot).injector()
    if (!injector) {
      window.setTimeout(initializeFreSummaryOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    const container = angular.element(
      '<div id="fre-summary-overlay-container" ng-controller="FreSummaryController" ng-include="\'/ui/modModules/overhaulFreSummary/overhaulFreSummary.html\'"></div>'
    )
    bodyElement.append(container)
    $compile(container)($rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeFreSummaryOverlay)
  } else {
    window.setTimeout(initializeFreSummaryOverlay, 300)
  }
})

export default freSummaryModule

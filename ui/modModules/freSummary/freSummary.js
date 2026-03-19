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

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

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

  $scope.formatMoney = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '0.00'
    return (Math.round(n * 100) / 100).toFixed(2)
  }

  $scope.dismiss = function() {
    disableBlur()
    popSummaryPause()
    safeApply(function() {
      $scope.visible = false
      $scope.data = null
      $scope.detailsOpen = false
    })
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        'if extensions.gameplay_events_freeroamEvents and extensions.gameplay_events_freeroamEvents.clearFreSummarySession then extensions.gameplay_events_freeroamEvents.clearFreSummarySession() end'
      )
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
      enableBlur()
      pushSummaryPause()
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

const freSummaryModule = angular.module('freSummary', ['ui.router'])
.run(function() {
  function initializeFreSummaryOverlay() {
    const existing = document.getElementById('fre-summary-overlay-container')
    if (existing) return

    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    if (!injector) {
      window.setTimeout(initializeFreSummaryOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    const container = angular.element(
      '<div id="fre-summary-overlay-container" ng-controller="FreSummaryController" ng-include="\'/ui/modModules/freSummary/freSummary.html\'"></div>'
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

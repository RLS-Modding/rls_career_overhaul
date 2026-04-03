'use strict'

angular.module('beamng.stuff')
.controller('FreeroamRaceHudController', ['$scope', '$rootScope', '$timeout', function($scope, $rootScope, $timeout) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.visible = false
  $scope.state = {}
  $scope.criticalWarningText = null

  var standingsPrevPlace = {}
  var standingsAnimTimeout = null

  function applyStandingsOvertakeAnimations(standings) {
    if (standingsAnimTimeout) {
      $timeout.cancel(standingsAnimTimeout)
      standingsAnimTimeout = null
    }
    if (!standings || !standings.length) {
      standingsPrevPlace = {}
      return
    }
    for (var i = 0; i < standings.length; i++) {
      var row = standings[i]
      var key = row.label
      var prev = standingsPrevPlace[key]
      if (prev != null && prev !== row.place) {
        row._stAnim = row.place < prev ? 'up' : 'down'
      } else {
        delete row._stAnim
      }
    }
    var nextPrev = {}
    for (var j = 0; j < standings.length; j++) {
      nextPrev[standings[j].label] = standings[j].place
    }
    standingsPrevPlace = nextPrev
    standingsAnimTimeout = $timeout(function() {
      standingsAnimTimeout = null
      var st = $scope.state && $scope.state.standings
      if (!st) return
      for (var k = 0; k < st.length; k++) {
        delete st[k]._stAnim
      }
    }, 520)
  }

  var DEFAULT_LAYOUT = { x: 12, y: 12, width: 340 }
  var hudLayout = { x: 12, y: 12, width: 340 }
  var drag = null
  var resize = null
  var blurNotifyScheduled = false

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  function clampLayout(l) {
    var vw = window.innerWidth, vh = window.innerHeight
    l.x = Math.max(0, Math.min(l.x, vw - 100))
    l.y = Math.max(0, Math.min(l.y, vh - 40))
    l.width = Math.max(240, Math.min(560, l.width))
    return l
  }

  function notifyGameBlur() {
    if (blurNotifyScheduled) return
    blurNotifyScheduled = true
    window.requestAnimationFrame(function() {
      blurNotifyScheduled = false
      angularRootScope.$broadcast('windowResize')
    })
  }

  function applyLayout() {
    var root = document.querySelector('.frh-overlay-root')
    if (!root) return
    root.style.left = hudLayout.x + 'px'
    root.style.top = hudLayout.y + 'px'
    var panel = root.querySelector('.frh-panel')
    if (panel) panel.style.width = hudLayout.width + 'px'
    notifyGameBlur()
  }

  function persistLayout() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua(
        "extensions.overhaul_settings.setSetting('freeroamRaceHudLayout', " +
        "{x = " + hudLayout.x + ", y = " + hudLayout.y + ", width = " + hudLayout.width + "})"
      )
    }
  }

  function loadLayout(cb) {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua("extensions.overhaul_settings.getSetting('freeroamRaceHudLayout')", function(result) {
        if (result && typeof result === 'object') {
          hudLayout.x = result.x != null ? result.x : DEFAULT_LAYOUT.x
          hudLayout.y = result.y != null ? result.y : DEFAULT_LAYOUT.y
          hudLayout.width = result.width != null ? result.width : DEFAULT_LAYOUT.width
        }
        clampLayout(hudLayout)
        if (cb) cb()
      })
    } else {
      clampLayout(hudLayout)
      if (cb) cb()
    }
  }

  function onMouseDown(e) {
    if (!$scope.visible) return
    var header = e.target.closest('.frh-header')
    if (header && header.closest('.frh-overlay-root')) {
      drag = {
        startX: e.clientX, startY: e.clientY,
        origX: hudLayout.x, origY: hudLayout.y
      }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'grabbing'
      e.preventDefault()
      return
    }
    var handle = e.target.closest('.frh-resize-handle')
    if (handle && handle.closest('.frh-overlay-root')) {
      resize = { startX: e.clientX, origWidth: hudLayout.width }
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'ew-resize'
      e.preventDefault()
    }
  }

  function onMouseMove(e) {
    if (drag) {
      hudLayout.x = Math.max(0, drag.origX + e.clientX - drag.startX)
      hudLayout.y = Math.max(0, drag.origY + e.clientY - drag.startY)
      applyLayout()
    } else if (resize) {
      hudLayout.width = Math.max(240, Math.min(560, resize.origWidth + e.clientX - resize.startX))
      applyLayout()
    }
  }

  function onMouseUp() {
    if (drag || resize) {
      document.body.style.userSelect = ''
      document.body.style.cursor = ''
      drag = null
      resize = null
      persistLayout()
    }
  }

  document.addEventListener('mousedown', onMouseDown, true)
  document.addEventListener('mousemove', onMouseMove, true)
  document.addEventListener('mouseup', onMouseUp, true)

  $scope.formatTime = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    const sign = seconds < 0 ? '-' : ''
    seconds = Math.abs(seconds)
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    const whole = Math.floor(s)
    const cent = Math.floor((s - whole) * 100)
    return sign + (m < 10 ? '0' : '') + m + ':' + (whole < 10 ? '0' : '') + whole + '.' + (cent < 10 ? '0' : '') + cent
  }

  $scope.formatDelta = function(delta) {
    if (delta == null || typeof delta !== 'number' || !isFinite(delta)) return '—'
    const sign = delta > 0 ? '+' : (delta < 0 ? '' : '')
    return sign + delta.toFixed(2) + 's'
  }

  $scope.formatSectorValue = function(v, useScore) {
    if (v == null || typeof v !== 'number' || !isFinite(v)) return '—'
    if (useScore) return String(Math.round(v))
    return $scope.formatTime(v)
  }

  $scope.formatSectorDelta = function(delta, useScore) {
    if (delta == null || typeof delta !== 'number' || !isFinite(delta)) return '—'
    if (useScore) {
      const sign = delta > 0 ? '+' : (delta < 0 ? '' : '')
      return sign + Math.round(delta)
    }
    return $scope.formatDelta(delta)
  }

  $scope.deltaClass = function(delta) {
    if (delta == null || typeof delta !== 'number') return ''
    if (delta < 0) return 'frh-delta-fast'
    if (delta > 0) return 'frh-delta-slow'
    return ''
  }

  $scope.formatMoney = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '0'
    return (Math.round(n * 100) / 100).toFixed(2)
  }

  $scope.formatSpeedMph = function(n) {
    if (n == null || typeof n !== 'number' || !isFinite(n)) return '—'
    return n.toFixed(2) + ' mph'
  }

  $scope.formatStandingsGap = function(row) {
    if (!row || row.isPlayer) return '—'
    var g = row.gapSec
    if (g != null && typeof g === 'number' && isFinite(g)) {
      var sign = g > 0 ? '+' : ''
      return sign + g.toFixed(2) + 's'
    }
    return '—'
  }

  const showListener = angularRootScope.$on('FreeroamRaceHudShow', function() {
    loadLayout(function() {
      safeApply(function() {
        standingsPrevPlace = {}
        if (standingsAnimTimeout) {
          $timeout.cancel(standingsAnimTimeout)
          standingsAnimTimeout = null
        }
        $scope.visible = true
        $scope.state = {}
        $scope.criticalWarningText = null
      })
      setTimeout(applyLayout, 0)
    })
  })

  const hideListener = angularRootScope.$on('FreeroamRaceHudHide', function() {
    safeApply(function() {
      standingsPrevPlace = {}
      if (standingsAnimTimeout) {
        $timeout.cancel(standingsAnimTimeout)
        standingsAnimTimeout = null
      }
      $scope.visible = false
      $scope.state = {}
      $scope.criticalWarningText = null
    })
    notifyGameBlur()
  })

  const criticalListener = angularRootScope.$on('FreeroamRaceHudCriticalWarning', function(_evt, data) {
    safeApply(function() {
      var t = data && data.text
      $scope.criticalWarningText = (t != null && String(t).length > 0) ? String(t) : null
    })
    setTimeout(notifyGameBlur, 0)
  })

  const stateListener = angularRootScope.$on('FreeroamRaceHudState', function(_evt, data) {
    safeApply(function() {
      $scope.state = data && typeof data === 'object' ? data : {}
      var st = $scope.state.standings
      if (st && st.length) {
        applyStandingsOvertakeAnimations(st)
      } else {
        standingsPrevPlace = {}
        if (standingsAnimTimeout) {
          $timeout.cancel(standingsAnimTimeout)
          standingsAnimTimeout = null
        }
      }
    })
  })

  $scope.$on('$destroy', function() {
    if (standingsAnimTimeout) {
      $timeout.cancel(standingsAnimTimeout)
      standingsAnimTimeout = null
    }
    showListener()
    hideListener()
    criticalListener()
    stateListener()
    document.removeEventListener('mousedown', onMouseDown, true)
    document.removeEventListener('mousemove', onMouseMove, true)
    document.removeEventListener('mouseup', onMouseUp, true)
  })
}])

angular.module('beamng.stuff')
.controller('SanctionedParkingStagingController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.spVisible = false
  $scope.payload = {}

  function safeApply(fn) {
    const phase = $scope.$$phase
    if (phase === '$apply' || phase === '$digest') fn()
    else $scope.$apply(fn)
  }

  $scope.formatRewardDollars = function(n) {
    if (n == null || (typeof n !== 'number' && typeof n !== 'string')) return '0'
    const v = Number(n)
    if (!isFinite(v)) return '0'
    return String(Math.floor(v))
  }

  $scope.stagingHeadline = function(p) {
    if (!p || typeof p !== 'object') return 'Sanctioned event'
    const laps = Math.max(1, Math.floor(Number(p.lapCount) || 1))
    const label = (p.raceLabel != null && String(p.raceLabel).trim() !== '') ? String(p.raceLabel).trim() : 'Track'
    return laps + '-Lap ' + label + ' Event'
  }

  $scope.stageAndSpawn = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_competitiveTrackFlow.sanctionedParkingStageAndSpawn()')
    }
  }

  $scope.startEvent = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('gameplay_events_freeroam_competitiveTrackFlow.sanctionedParkingStartEvent()')
    }
  }

  const spListener = angularRootScope.$on('SanctionedParkingStagingUi', function(_evt, data) {
    safeApply(function() {
      $scope.spVisible = !!(data && data.visible)
      $scope.payload = data && data.payload && typeof data.payload === 'object' ? data.payload : {}
    })
  })

  $scope.$on('$destroy', function() {
    spListener()
  })
}])

const freeroamRaceHudModule = angular.module('freeroamRaceHud', ['ui.router'])
.run(function() {
  function initializeFreeroamRaceHudOverlay() {
    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    if (!injector) {
      window.setTimeout(initializeFreeroamRaceHudOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    if (!document.getElementById('freeroam-race-hud-overlay-container')) {
      const container = angular.element(
        '<div id="freeroam-race-hud-overlay-container" ng-controller="FreeroamRaceHudController" ng-include="\'/ui/modModules/freeroamRaceHud/freeroamRaceHud.html\'"></div>'
      )
      bodyElement.append(container)
      $compile(container)($rootScope)
    }
    if (!document.getElementById('sanctioned-parking-staging-overlay-container')) {
      const spContainer = angular.element(
        '<div id="sanctioned-parking-staging-overlay-container" ng-controller="SanctionedParkingStagingController" ng-include="\'/ui/modModules/freeroamRaceHud/sanctionedParkingStaging.html\'"></div>'
      )
      bodyElement.append(spContainer)
      $compile(spContainer)($rootScope)
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeFreeroamRaceHudOverlay)
  } else {
    window.setTimeout(initializeFreeroamRaceHudOverlay, 300)
  }
})

export default freeroamRaceHudModule

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

function attachRaceFormatters($scope) {
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

  $scope.formatTimeWhole = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    const sign = seconds < 0 ? '-' : ''
    seconds = Math.max(0, Math.floor(Math.abs(seconds)))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return sign + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s
  }

  $scope.formatCountdownTime = function(seconds) {
    if (seconds == null || typeof seconds !== 'number' || !isFinite(seconds)) return '—'
    seconds = Math.max(0, Math.ceil(seconds))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s
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

  $scope.deltaClass = function(delta, useScore) {
    if (delta == null || typeof delta !== 'number') return ''
    if (useScore) {
      if (delta > 0) return 'frh-delta-fast'
      if (delta < 0) return 'frh-delta-slow'
      return ''
    }
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
}

// Hide vanilla drag apps while FRE drag HUD is visible (do not touch mount/.run).
// Covers topLeft dragInfo and topCenter tree staging (app id "drag").
var DRAG_INFO_SUPPRESS_STYLE_ID = 'rls-frh-suppress-draginfo'
function isDragRaceHud($scope) {
  var s = $scope.state
  if (!s || typeof s !== 'object') return false
  if (s.isDragRace) return true
  return !!(s.completion && s.completion.kind === 'drag')
}
function setVanillaDragInfoSuppressed(suppressed) {
  var existing = document.getElementById(DRAG_INFO_SUPPRESS_STYLE_ID)
  if (!suppressed) {
    if (existing && existing.parentNode) existing.parentNode.removeChild(existing)
    return
  }
  if (existing) return
  var style = document.createElement('style')
  style.id = DRAG_INFO_SUPPRESS_STYLE_ID
  style.textContent = [
    '.ui-app-host[data-app-name="dragInfo"],',
    '.ui-app-host[data-app-name="drag"],',
    '.ui-app-host[data-app-name="dragDialControl"],',
    '.app-slot--drag-info { display: none !important; visibility: hidden !important; }'
  ].join('\n')
  document.head.appendChild(style)
}
function syncVanillaDragInfoSuppress($scope) {
  setVanillaDragInfoSuppressed(!!$scope.visible && isDragRaceHud($scope))
}

// Demo elimination toasts: each toast fades at 2.5s and is removed at 3.5s. The timers are tracked so teardown can
// cancel them.

export { attachRaceFormatters, syncVanillaDragInfoSuppress, setVanillaDragInfoSuppressed }

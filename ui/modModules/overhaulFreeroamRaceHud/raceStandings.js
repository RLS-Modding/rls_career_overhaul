// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Standings nudges survive live row replacements until each overtake finishes.
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'

function createStandingsOvertakeTracker($scope, $timeout) {
  const safeApply = createSafeApply($scope)
  var standingsPrevPlace = Object.create(null)
  var animations = Object.create(null)

  function cancelAnimations() {
    Object.keys(animations).forEach(function(key) {
      $timeout.cancel(animations[key].timeout)
    })
    animations = Object.create(null)
  }

  function startAnimation(key, direction) {
    if (animations[key]) $timeout.cancel(animations[key].timeout)
    animations[key] = {
      direction: direction,
      timeout: $timeout(function() {
        delete animations[key]
        var standings = $scope.state && $scope.state.standings
        if (!standings) return
        safeApply(function() {
          for (var i = 0; i < standings.length; i++) {
            if (standings[i].label === key) delete standings[i]._stAnim
          }
        })
      }, 520, false),
    }
  }

  function apply(standings) {
    if (!standings || !standings.length) {
      reset()
      return
    }
    var nextPrev = Object.create(null)
    for (var i = 0; i < standings.length; i++) {
      var row = standings[i]
      var key = row.label
      var prev = standingsPrevPlace[key]
      if (prev != null && prev !== row.place) {
        startAnimation(key, row.place < prev ? 'up' : 'down')
      }
      if (animations[key]) row._stAnim = animations[key].direction
      else delete row._stAnim
      nextPrev[key] = row.place
    }
    Object.keys(animations).forEach(function(key) {
      if (nextPrev[key] != null) return
      $timeout.cancel(animations[key].timeout)
      delete animations[key]
    })
    standingsPrevPlace = nextPrev
  }

  function reset() {
    standingsPrevPlace = Object.create(null)
    cancelAnimations()
  }

  return { apply: apply, reset: reset, cancel: cancelAnimations }
}

export { createStandingsOvertakeTracker }

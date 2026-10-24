// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

function createDemoToastTracker($scope, $timeout, safeApply) {
  var toastIdCounter = 0
  var toastTimeouts = []
  function dropToastTimeout(promise) {
    var idx = toastTimeouts.indexOf(promise)
    if (idx !== -1) toastTimeouts.splice(idx, 1)
  }

  function add(data) {
    safeApply(function() {
      var id = ++toastIdCounter
      var toast = {
        id: id,
        label: data && data.label || 'Unknown',
        placementStr: data && data.placementStr || null,
        fading: false
      }
      $scope.demoToasts.push(toast)
      // Start fade at 2.5s
      var fadeTimeout = $timeout(function() {
        dropToastTimeout(fadeTimeout)
        safeApply(function() { toast.fading = true })
      }, 2500, false)
      toastTimeouts.push(fadeTimeout)
      // Remove at 3.5s
      var removeTimeout = $timeout(function() {
        dropToastTimeout(removeTimeout)
        safeApply(function() {
          var idx = $scope.demoToasts.indexOf(toast)
          if (idx !== -1) $scope.demoToasts.splice(idx, 1)
        })
      }, 3500, false)
      toastTimeouts.push(removeTimeout)
    })
  }

  function cancelAll() {
    for (var i = 0; i < toastTimeouts.length; i++) {
      $timeout.cancel(toastTimeouts[i])
    }
    toastTimeouts = []
  }

  return { add: add, cancelAll: cancelAll }
}



export { createDemoToastTracker }

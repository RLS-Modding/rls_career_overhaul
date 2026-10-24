// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Engine callbacks own only this HUD's subtree; an active Angular pass already covers its changes.
export function createSafeApply($scope) {
  return function safeApply(fn) {
    if ($scope.$$destroyed) return
    fn()
    if (!$scope.$$phase) $scope.$digest()
  }
}

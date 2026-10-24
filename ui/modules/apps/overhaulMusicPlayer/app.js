// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

'use strict'

angular.module('beamng.apps')
.directive('musicPlayerUiApp', [function() {
  return {
    restrict: 'E',
    replace: true,
    template:
      '<div class="rls-mp-uiapp bngApp">' +
      '<rls-music-player music-root="/music" start-playing="false" poll-ms="400"></rls-music-player>' +
      '</div>',
  }
}])
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
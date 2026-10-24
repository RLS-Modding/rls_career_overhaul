import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
angular.module('beamng.stuff')
.controller('DemoCongratulationsController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.dmcVisible = false
  $scope.payload = {}

  const safeApply = createSafeApply($scope)

  $scope.dismiss = function() {
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('overhaul_events_derby_derby.dismissCongratulations()')
    }
  }

  const dmcListener = angularRootScope.$on('DemoCongratulationsUi', function(_evt, data) {
    safeApply(function() {
      $scope.dmcVisible = !!(data && data.visible)
      $scope.payload = data && typeof data === 'object' ? data : {}
    })
  })

  $scope.$on('$destroy', function() {
    dmcListener()
  })
}])

'use strict'

angular.module('beamng.stuff')
.controller('OverhaulManagerController', ['$scope', '$state', function($scope, $state) {
  $scope.message = 'Welcome to the RLS Career Overhaul Manager!';
  
  $scope.toggles = {
    mapDevMode: false,
    noPoliceMode: false,
    noParkedMode: false
  };
  
  $scope.loadSettings = function() {
    bngApi.engineLua("extensions.rlsSettings.loadSettings()");
    
    bngApi.engineLua("extensions.rlsSettings.getSetting('mapDevMode')", function(result) {
      $scope.$apply(() => {
        $scope.toggles.mapDevMode = result || false;
      });
    });
    
    bngApi.engineLua("extensions.rlsSettings.getSetting('noPoliceMode')", function(result) {
      $scope.$apply(() => {
        $scope.toggles.noPoliceMode = result || false;
      });
    });
    
    bngApi.engineLua("extensions.rlsSettings.getSetting('noParkedMode')", function(result) {
      $scope.$apply(() => {
        $scope.toggles.noParkedMode = result || false;
      });
    });
  };
  
  $scope.toggleMapDevMode = function() {
    $scope.toggles.mapDevMode = !$scope.toggles.mapDevMode;
    bngApi.engineLua(`extensions.rlsSettings.setSetting('mapDevMode', ${$scope.toggles.mapDevMode})`);
  };
  
  $scope.toggleNoPoliceMode = function() {
    $scope.toggles.noPoliceMode = !$scope.toggles.noPoliceMode;
    bngApi.engineLua(`extensions.rlsSettings.setSetting('noPoliceMode', ${$scope.toggles.noPoliceMode})`);
  };
  
  $scope.toggleNoParkedMode = function() {
    $scope.toggles.noParkedMode = !$scope.toggles.noParkedMode;
    bngApi.engineLua(`extensions.rlsSettings.setSetting('noParkedMode', ${$scope.toggles.noParkedMode})`);
  };
  
  $scope.goBack = function() {
    $state.go('menu.mainmenu');
  };
  
  $scope.loadSettings();
}])

export default angular.module('overhaulManager', ['ui.router'])

.config(['$stateProvider', function($stateProvider) {
  $stateProvider.state('menu.overhaulManager', {
    url: '/overhaulManager',
    templateUrl: '/ui/modModules/overhaulManager/overhaulManager.html',
    controller: 'OverhaulManagerController',
  })
}])

.run(['$rootScope', function ($rootScope) {
  function addOverhaulManagerButton() {
    if (window.bridge && window.bridge.events) {
      try {
        window.bridge.events.on("MainMenuButtons", function(addButton) {
          if (typeof addButton === 'function') {
            const buttonConfig = {
              icon: '/ui/modModules/overhaulManager/icons/overhaulIcon.png',
              targetState: 'menu.overhaulManager',
              translateid: 'Overhaul Manager'
            };
            addButton(buttonConfig)
          }
        })
      } catch (e) {
        console.error('OverhaulManager: Error registering bridge event listener:', e)
      }
    }
  }

  addOverhaulManagerButton()
}])
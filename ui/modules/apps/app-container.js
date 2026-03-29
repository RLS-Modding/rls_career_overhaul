"use strict"

angular.module('beamng.apps')
.run(['$rootScope', function ($rootScope) {
  var api = (typeof bngApi !== 'undefined' && bngApi && bngApi.activeObjectLua && bngApi.engineLua) ? bngApi : (window.bngApi && window.bngApi.activeObjectLua && window.bngApi.engineLua ? window.bngApi : null)
  var LuaPower = '(function() local engines = powertrain.getDevicesByCategory("engine") local pmax = 0 if engines then for _, e in ipairs(engines) do local mp = (e and e.maxPower) or 0 if mp > pmax then pmax = mp end end end return pmax end)()'
  $rootScope.$on('careerRequestPlayerPower', function () {
    if (!api || !api.activeObjectLua || !api.engineLua) return
    api.activeObjectLua(LuaPower, function (power) {
      var watts = (power != null && !isNaN(power) && power >= 0) ? Number(power) : 0
      api.engineLua('(function() local g = _G.career_modules_competitiveRace_aiRacers if g and type(g.onPlayerVehiclePowerWeight) == "function" then g.onPlayerVehiclePowerWeight(' + watts + ', nil) end end)()')
    })
  })
}])

.directive('appContainer', ['$document', 'RateLimiter', 'UiAppsService', 'Utils', '$state',
function ($document, RateLimiter, UiAppsService, Utils, $state) {
  return {
    restrict: 'E',
    template: '<div ng-class="hideClass" style="position: absolute; left: 0; top: 0; right:0, bottom:0">' +
                '<div id="container" ng-transclude style="position:relative; width: 100%; height: 100%"></div>' +
              '</div>',
    transclude: true,
    replace: true,
    controller: ['$element', '$scope', '$window', 'UIAppStorage',
      function ($element, $scope, $window, UIAppStorage) {

      let container = angular.element($element[0].querySelector('#container'))
      let playmode = beamng.ingame ? 'freeroam' : 'externalUI'
      let canvas = null

      container[0].id = $element[0].id + '_apps'

      UIAppStorage.containers[container[0].id] = container[0]

      function setSize() {
        if (!canvas)
          return;
        const width = container[0].clientWidth,
              height = container[0].clientHeight;
        if (width === 0 || height === 0)
          return;
        canvas.width = width;
        canvas.height = height;
        window.bngVue?.updateOcclusion?.()
      }
      $element.ready(function () {
        canvas = $element[0].querySelector("canvas");
        setSize();
        $scope.$on("windowResize", setSize);
      });

      let wasShown = false;
      $scope.$watch(() => $scope.app?.showApps, () => {
        const shown = !!$scope.app?.showApps;
        $scope.hideClass = { "uiapps-hidden": !shown };
        if (wasShown !== shown) {
          if (window.vueGlobalStore) {
            window.vueGlobalStore.__uiAppsShown = shown;
          }
        }
        wasShown = shown;
      })


      $scope.editMode = false
      $scope.$on('VehicleReset', function () {
        StreamsManager.resubmit()
      })

      $scope.$on('appContainer:clear', function () { UiAppsService.clearCurrentLayout(container) })
      $scope.$on('appContainer:loadLayoutByType', function (_, data) { UiAppsService.loadLayout({type: data}, container, $scope) })
      $scope.$on('appContainer:loadLayoutByObject', function (_, data) { UiAppsService.loadLayout({object: data}, container, $scope) })
      $scope.$on('appContainer:loadLayoutByFilename', function (_, data) { UiAppsService.loadLayout({filename: data}, container, $scope) })
      $scope.$on('appContainer:loadLayoutByReqData', function (_, data) { UiAppsService.loadLayout(data, container, $scope) })

      $scope.$on('appContainer:ensureAppVisible', function (_, appDataJson) {
        UiAppsService.ensureAppVisible(JSON.parse(appDataJson), container, $scope)
      })
      $scope.$on('appContainer:spawn', function (_, appData) {
        UIAppStorage.layoutDirty = true
        UiAppsService.spawnApp(appData, container, $scope).then(() => {
          UiAppsService.saveLayout(UIAppStorage.current)
          $scope.$broadcast('appContainer:requestEdit', true)
        }, (error) => {
          console.error("Failed to spawn app:", error)
        })
      })
      $scope.$on('appContainer:addApp', function(_, appName) {
        const appData = UIAppStorage.availableApps[appName]
        if(appData) UiAppsService.spawnApp(appData, container, $scope)
      })
      $scope.$on('appContainer:removeApp', function(_, appName, appId) {
        UiAppsService.removeApp(appName, appId)
      })
      $scope.$on('appContainer:save', function () {
        UiAppsService.saveLayout(UIAppStorage.current)
        UIAppStorage.wasSaving = false
      })
      $scope.$on('appContainer:onUIDataUpdated', function () {
        if(UIAppStorage.queuedlayoutChange !== null) {
          UiAppsService.loadLayout(UIAppStorage.queuedlayoutChange, container, $scope)
          UIAppStorage.queuedlayoutChange = null
        }
        if(UIAppStorage.current.filename) {
          let valid = false
          for(let i = 0; i < UIAppStorage.availableLayouts.length; ++i) {
            if(UIAppStorage.availableLayouts[i].filename === UIAppStorage.current.filename) {
              valid = true
              break
            }
          }
          if(!valid) {
            if(UIAppStorage.availableLayouts.length > 0) {
              UiAppsService.loadLayout({filename: UIAppStorage.availableLayouts[0].filename}, container, $scope)
            } else {
              UiAppsService.clearCurrentLayout(container)
              UIAppStorage.current = { apps: [] }
            }
          } else {
            UiAppsService.loadLayout({filename: UIAppStorage.current.filename}, container, $scope)
          }
        }
      })
      $scope.$on('appContainer:saveAll', function () {
        for(let i = 0; i < UIAppStorage.availableLayouts.length; ++i) {
          let layout = UIAppStorage.availableLayouts[i]
          UIAppStorage.layoutDirty = true
          UiAppsService.saveLayout(layout)
        }
      })
      $scope.$on('appContainer:resetLayout', function () {
        UiAppsService.resetLayout(playmode, container, $scope)
      })
      $scope.$on('appContainer:deleteLayout', function () {
        UiAppsService.deleteLayout(container, $scope)
      })

      $scope.$on('appContainer:createNewLayout', function () {
        UiAppsService.createNewLayout()
      })


      let cameraMode = null
      $scope.$on('onCameraNameChanged', function (_, data) {
        $scope.$applyAsync(() => {
          cameraMode = data.name
          $scope.updateCockpitApps()
        })
      })

      $scope.$on('editApps', function (event, state) {
        $document.triggerHandler('mouseup')
        $scope.editMode = state
        $scope.updateCockpitApps()
        if (!state) {
          UiAppsService.saveLayout(UIAppStorage.current)
          bngApi.engineLua('core_camera.requestConfig()')
          UIAppStorage.wasSaving = false
        }
      })

      $scope.updateCockpitSetting = function() {
        UIAppStorage.layoutDirty = true
        $scope.updateCockpitApps()
      }
      $scope.updateCockpitApps = function() {
        UiAppsService.handleCameraChange(cameraMode, $scope.editMode)
      }

      $scope.$on('GameStateUpdate', function (event, data) {
        if($state.current.name === 'menu.appedit') {
          return
        }
        playmode = data.state
        if($scope.editMode === true) return
        if (typeof data.appLayout == "string") {
          if(data.appLayout == 'freeroam' && !beamng.ingame) data.appLayout = 'externalui'

          UiAppsService.loadLayout({type: data.appLayout}, container, $scope)
        } else if (typeof data.appLayout == "object") {
          UiAppsService.loadLayout({object: data.appLayout}, container, $scope)
        } else if (playmode !== undefined) {
          UiAppsService.loadLayout({type: playmode}, container, $scope)
        } else {
          console.debug(`Expected AppLayout but didn't get one :-( `, data)
        }
      })
    }]
  }
}])

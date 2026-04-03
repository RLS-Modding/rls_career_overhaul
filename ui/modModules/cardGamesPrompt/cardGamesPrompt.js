'use strict'

function getGameLuaApi() {
  if (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) return bngApi
  if (window.bngApi && window.bngApi.engineLua) return window.bngApi
  if (window.bridge && window.bridge.api && window.bridge.api.engineLua) return window.bridge.api
  return null
}

function openCardGamesVueRoute() {
  const bv = window.bngVue
  if (bv && typeof bv.gotoGameState === 'function') {
    bv.gotoGameState('card-games', { tryAngularJS: true, blankAngularJS: true })
  }
}

angular.module('beamng.stuff')

.controller('CardGamesPromptController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope

  $scope.visible = false

  function clearPlayerLockFromLua() {
    const api = getGameLuaApi()
    if (api) {
      api.engineLua('gameplay_cardGames.clearGamblingPromptPlayerLock()')
    }
  }

  $scope.cancel = function() {
    clearPlayerLockFromLua()
    $scope.visible = false
  }

  $scope.gamble = function() {
    $scope.visible = false
    const api = getGameLuaApi()
    if (api) {
      api.engineLua('gameplay_cardGames.startGambleCameraAnim()')
    }
    openCardGamesVueRoute()
  }

  const showListener = angularRootScope.$on('CardGamesGamblingPromptShow', function() {
    $scope.$evalAsync(function() {
      $scope.visible = true
    })
  })

  const hideListener = angularRootScope.$on('CardGamesGamblingPromptHide', function() {
    clearPlayerLockFromLua()
    $scope.$evalAsync(function() {
      $scope.visible = false
    })
  })

  $scope.$on('$destroy', function() {
    showListener()
    hideListener()
  })
}])

const cardGamesPromptModule = angular.module('cardGamesPrompt', ['ui.router'])

.run(function() {
  function initializeOverlay() {
    const existing = document.getElementById('card-games-prompt-overlay-container')
    if (existing) return

    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    if (!injector) {
      window.setTimeout(initializeOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    const container = angular.element(
      '<div id="card-games-prompt-overlay-container" ng-controller="CardGamesPromptController" ng-include="\'/ui/modModules/cardGamesPrompt/cardGamesPrompt.html\'"></div>'
    )

    bodyElement.append(container)
    $compile(container)($rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeOverlay)
  } else {
    window.setTimeout(initializeOverlay, 300)
  }
})

export default cardGamesPromptModule

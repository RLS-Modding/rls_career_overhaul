'use strict'

function defaultAuctionState() {
  return {
    phase: 'idle',
    musicEnabled: true,
    entryPromptActive: false,
    entryFee: 1000,
    canPayEntryFee: false,
    activeLotIndex: 1,
    currentLotIndex: null,
    statusMessage: '',
    purchasedCount: 0,
    lots: []
  }
}

angular.module('beamng.stuff')
.controller('UsedAuctionController', ['$scope', '$rootScope', function($scope, $rootScope) {
  let pollTimer = null
  const angularRootScope = window.globalAngularRootScope || $rootScope

  $scope.visible = false
  $scope.state = defaultAuctionState()

  function requestState() {
    bngApi.engineLua('extensions.career_modules_usedCarAuction.requestAuctionState()', function(result) {
      if (!result || typeof result !== 'object') return
      $scope.$evalAsync(function() {
        $scope.state = result
      })
    })
  }

  function startPolling() {
    if (pollTimer) return
    requestState()
    pollTimer = window.setInterval(requestState, 250)
  }

  function stopPolling() {
    if (!pollTimer) return
    window.clearInterval(pollTimer)
    pollTimer = null
  }

  function boolToLua(value) {
    return value ? 'true' : 'false'
  }

  function callAuctionLua(fnName, args) {
    const fn = 'extensions.career_modules_usedCarAuction.' + fnName
    const argList = args && args.length ? '(' + args.join(', ') + ')' : '()'
    bngApi.engineLua(fn + argList)
    window.setTimeout(requestState, 35)
  }

  $scope.isEntryPrompt = function() {
    return $scope.state.phase === 'entryPrompt' || $scope.state.entryPromptActive === true
  }

  $scope.entryPromptMessage = function() {
    const fee = Number($scope.state.entryFee)
    const safeFee = Number.isFinite(fee) && fee >= 0 ? Math.round(fee) : 1000
    return 'Do you want to pay $' + safeFee + ' to enter The Vault?'
  }

  $scope.activeLot = function() {
    const lots = ($scope.state && $scope.state.lots) || []
    if (!lots.length) return null

    const currentLotIndex = Number($scope.state.currentLotIndex || $scope.state.activeLotIndex || 0)
    if (currentLotIndex > 0) {
      for (let i = 0; i < lots.length; i++) {
        if (Number(lots[i].lotIndex || 0) === currentLotIndex) {
          return lots[i]
        }
      }
    }

    for (let j = 0; j < lots.length; j++) {
      const lotState = lots[j].state
      if (lotState === 'queued' || lotState === 'approaching' || lotState === 'active' || lotState === 'exiting') {
        return lots[j]
      }
    }

    return lots[0]
  }

  $scope.isActiveLot = function(lot) {
    const active = $scope.activeLot()
    if (!lot || !active) return false
    return Number(lot.lotIndex) === Number(active.lotIndex)
  }

  $scope.canBid = function() {
    const active = $scope.activeLot()
    return $scope.state.phase === 'bidding' && active && active.state === 'active'
  }

  $scope.formatBidder = function(lot) {
    if (!lot) return '-'
    const bidderName = ((lot.highestBidderName || '') + '').trim()
    if (bidderName) return bidderName
    if (lot.highestBidder === 'player') return 'You'
    if (lot.highestBidder === 'npc') return 'NPC'
    return '-'
  }

  $scope.formatMileage = function(mileage) {
    const n = Number(mileage)
    if (!Number.isFinite(n) || n <= 0) return 'Unknown'
    return n.toLocaleString() + ' mi'
  }

  $scope.formatCurrency = function(amount) {
    const n = Number(amount)
    if (!Number.isFinite(n) || n < 0) return '$0'
    return '$' + Math.round(n).toLocaleString()
  }

  $scope.startAuctionFromPrompt = function() {
    callAuctionLua('startAuction')
  }

  $scope.cancelEntryPrompt = function() {
    callAuctionLua('cancelTravelPrompt')
  }

  $scope.bid = function(amount) {
    const n = Number(amount) || 0
    callAuctionLua('placeBid', [String(n)])
  }

  $scope.setMusicEnabled = function(enabled) {
    callAuctionLua('setAuctionMusicEnabled', [boolToLua(enabled === true)])
  }

  const showListener = angularRootScope.$on('UsedAuctionShow', function() {
    $scope.$evalAsync(function() {
      $scope.visible = true
    })
    startPolling()
  })

  const hideListener = angularRootScope.$on('UsedAuctionHide', function() {
    $scope.$evalAsync(function() {
      $scope.visible = false
      $scope.state = defaultAuctionState()
    })
    stopPolling()
  })

  $scope.$on('$destroy', function() {
    showListener()
    hideListener()
    stopPolling()
  })
}])

const usedAuctionModule = angular.module('usedAuction', ['ui.router'])

.run(['$rootScope', function() {
  function initializeAuctionOverlay() {
    const existingContainer = document.getElementById('used-auction-overlay-container')
    if (existingContainer) return

    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    if (!injector) {
      window.setTimeout(initializeAuctionOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    const container = angular.element('<div id="used-auction-overlay-container" ng-controller="UsedAuctionController" ng-include="\'/ui/modModules/usedAuction/usedAuction.html\'"></div>')

    bodyElement.append(container)
    $compile(container)($rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeAuctionOverlay)
  } else {
    window.setTimeout(initializeAuctionOverlay, 300)
  }
}])

export default usedAuctionModule

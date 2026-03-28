'use strict'

import '../rlsMusicPlayer/rlsMusicPlayer.js'

function defaultAuctionState() {
  return {
    phase: 'idle',
    entryPromptActive: false,
    entryFee: 1000,
    canPayEntryFee: false,
    hasFreeGarageSlot: true,
    musicEnabled: null,
    activeLotIndex: 1,
    currentLotIndex: null,
    statusMessage: '',
    purchasedCount: 0,
    bidMessage: '',
    lots: []
  }
}

function getGameLuaApi() {
  if (typeof bngApi !== 'undefined' && bngApi && bngApi.engineLua) return bngApi
  if (window.bngApi && window.bngApi.engineLua) return window.bngApi
  if (window.bridge && window.bridge.api && window.bridge.api.engineLua) return window.bridge.api
  return null
}

angular.module('beamng.stuff')
.controller('UsedAuctionController', ['$scope', '$rootScope', function($scope, $rootScope) {
  let pollTimer = null
  const angularRootScope = window.globalAngularRootScope || $rootScope
  let timerPeakByLot = Object.create(null)
  let timerRingPrev = { lotIdx: null, t: null }

  function resetAuctionTimerUi() {
    timerPeakByLot = Object.create(null)
    timerRingPrev = { lotIdx: null, t: null }
  }

  $scope.visible = false
  $scope.state = defaultAuctionState()

  let lastActiveLotIndex = null

  function requestState() {
    const api = getGameLuaApi()
    if (!api) return
    api.engineLua('career_modules_usedCarAuction.requestAuctionState()', function(result) {
      if (!result || typeof result !== 'object') return
      $scope.$evalAsync(function() {
        $scope.state = result
        const newIdx = Number(result.currentLotIndex || result.activeLotIndex || 0)
        if (newIdx && newIdx !== lastActiveLotIndex) {
          lastActiveLotIndex = newIdx
          window.setTimeout(scrollToActiveLot, 50)
        }
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

  function callAuctionLua(fnName, args) {
    const api = getGameLuaApi()
    if (!api) return
    const fn = 'career_modules_usedCarAuction.' + fnName
    const argList = args && args.length ? '(' + args.join(', ') + ')' : '()'
    api.engineLua(fn + argList, function() {
      requestState()
    })
  }

  $scope.isEntryPrompt = function() {
    return $scope.state.phase === 'entryPrompt' || $scope.state.entryPromptActive === true
  }

  $scope.entryPromptMessage = function() {
    if ($scope.isEntryPrompt()) {
      const st = ($scope.state.statusMessage || '').trim()
      if (st) {
        return st
      }
    }
    const fee = Number($scope.state.entryFee)
    const safeFee = Number.isFinite(fee) && fee >= 0 ? Math.round(fee) : 1000
    return 'Do you want to pay $' + safeFee + ' to enter The Vault?'
  }

  $scope.activeLot = function() {
    const lots = ($scope.state && $scope.state.lots) || []
    if (!lots.length) return null

    for (let i = 0; i < lots.length; i++) {
      if (lots[i].state === 'active') {
        return lots[i]
      }
    }

    const currentLotIndex = Number($scope.state.currentLotIndex || $scope.state.activeLotIndex || 0)
    if (currentLotIndex > 0) {
      for (let i = 0; i < lots.length; i++) {
        if (Number(lots[i].lotIndex || 0) === currentLotIndex) {
          return lots[i]
        }
      }
    }

    for (let j = 0; j < lots.length; j++) {
      if (lots[j].state === 'exiting') {
        return lots[j]
      }
    }

    for (let j = 0; j < lots.length; j++) {
      const lotState = lots[j].state
      if (lotState === 'queued' || lotState === 'approaching') {
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
    if (!active || active.state !== 'active' || $scope.state.phase !== 'bidding') return false
    if (active.highestBidder === 'player') return false
    return true
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

  $scope.isLiveBidLot = function() {
    const active = $scope.activeLot()
    return !!(active && active.state === 'active')
  }

  $scope.bidCardLabel = function() {
    return $scope.isLiveBidLot() ? 'Current Bid' : 'Awaiting Lot'
  }

  $scope.phaseLabel = function() {
    const p = $scope.state.phase
    if (p === 'bidding') return 'Bidding'
    if (p === 'complete') return 'Complete'
    if (p === 'starting') return 'Starting'
    return 'Idle'
  }

  $scope.phaseClass = function() {
    const p = $scope.state.phase
    if (p === 'bidding') return 'phase-bidding'
    if (p === 'complete') return 'phase-complete'
    return ''
  }

  $scope.lotStatusLabel = function(lot) {
    if (!lot) return ''
    if (lot.state === 'active') return 'Live'
    if (lot.state === 'approaching') return 'Next'
    if (lot.state === 'exiting') return 'Closing'
    if (lot.state === 'finished' && lot.highestBidder === 'player') return 'Won'
    if (lot.state === 'finished') return 'Sold'
    if (lot.state === 'failed') return 'No Sale'
    return 'Upcoming'
  }

  $scope.lotBadgeClass = function(lot) {
    if (!lot) return 'badge-upcoming'
    if (lot.state === 'active') return 'badge-live'
    if (lot.state === 'approaching') return 'badge-approaching'
    if (lot.state === 'finished' && lot.highestBidder === 'player') return 'badge-won'
    if (lot.state === 'finished' || lot.state === 'failed') return 'badge-sold'
    return 'badge-upcoming'
  }

  $scope.bidLeaderClass = function() {
    const active = $scope.activeLot()
    if (!active) return ''
    if (active.highestBidder === 'player') return 'leader-player'
    return 'leader-npc'
  }

  $scope.bidTotalAfter = function(increment) {
    const active = $scope.activeLot()
    if (!active) return 0
    return (Number(active.currentBid) || 0) + (Number(increment) || 0)
  }

  $scope.canAffordBid = function(increment) {
    const active = $scope.activeLot()
    if (!active) return false
    const totalCost = $scope.bidTotalAfter(increment)
    const balance = Number($scope.state.playerBalance) || 0
    return balance >= totalCost
  }

  $scope.isLotBiddable = function() {
    const active = $scope.activeLot()
    return active && active.state === 'active' && (Number(active.timeLeft) || 0) > 0
  }

  $scope.timerUrgencyClass = function() {
    const active = $scope.activeLot()
    if (!active) return 'timer-safe'
    const t = Number(active.timeLeft) || 0
    if (t <= 5) return 'timer-critical'
    if (t <= 15) return 'timer-warning'
    return 'timer-safe'
  }

  $scope.timerDash = function() {
    const active = $scope.activeLot()
    if (!active) return '0 100'
    const t = Number(active.timeLeft) || 0
    const idx = Number(active.lotIndex) || 0
    if (idx > 0) {
      const prevPeak = timerPeakByLot[idx] || 0
      timerPeakByLot[idx] = Math.max(prevPeak, t)
    }
    const peak = idx > 0 ? Math.max(timerPeakByLot[idx] || 0, 1) : Math.max(t, 1)
    const pct = Math.min(1, Math.max(0, t / peak))
    const circumference = 2 * Math.PI * 16
    const filled = pct * circumference
    return filled.toFixed(1) + ' ' + circumference.toFixed(1)
  }

  $scope.timerProgressStyle = function() {
    const active = $scope.activeLot()
    if (!active) return {}
    const idx = Number(active.lotIndex) || 0
    const t = Number(active.timeLeft) || 0
    const gained = timerRingPrev.lotIdx === idx && timerRingPrev.t !== null && t > timerRingPrev.t + 0.35
    timerRingPrev.lotIdx = idx
    timerRingPrev.t = t
    return {
      transition: gained ? 'stroke-dasharray 0.14s ease-out' : 'stroke-dasharray 0.88s linear'
    }
  }

  function scrollToActiveLot() {
    const active = $scope.activeLot()
    if (!active) return
    const el = document.getElementById('ua-lot-' + active.lotIndex)
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
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

  const showListener = angularRootScope.$on('UsedAuctionShow', function() {
    resetAuctionTimerUi()
    $scope.$evalAsync(function() {
      $scope.visible = true
    })
    startPolling()
  })

  const hideListener = angularRootScope.$on('UsedAuctionHide', function() {
    const api = getGameLuaApi()
    if (api) {
      api.engineLua('extensions.overhaul_musicPlayer.uiStop()')
    }
    resetAuctionTimerUi()
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

.directive('uaDraggable', ['$document', function($document) {
  return {
    restrict: 'A',
    link: function(scope, element) {
      const panelEl = element[0]
      const dragHandle = panelEl.querySelector('.ua-header') || panelEl
      let dragging = false
      let dragOffsetX = 0
      let dragOffsetY = 0
      let panelWidth = 0
      let panelHeight = 0

      function clamp(value, min, max) {
        return Math.min(max, Math.max(min, value))
      }

      function onPointerMove(event) {
        if (!dragging) return
        const maxX = Math.max(0, window.innerWidth - panelWidth)
        const maxY = Math.max(0, window.innerHeight - panelHeight)
        const nextLeft = clamp(event.clientX - dragOffsetX, 0, maxX)
        const nextTop = clamp(event.clientY - dragOffsetY, 0, maxY)
        panelEl.style.left = nextLeft + 'px'
        panelEl.style.top = nextTop + 'px'
        panelEl.style.right = 'auto'
        panelEl.style.bottom = 'auto'
      }

      function stopDragging() {
        if (!dragging) return
        dragging = false
        $document.off('mousemove', onPointerMove)
        $document.off('mouseup', stopDragging)
      }

      function startDragging(event) {
        if (event.button !== 0) return
        const rect = panelEl.getBoundingClientRect()
        panelWidth = rect.width
        panelHeight = rect.height
        dragOffsetX = event.clientX - rect.left
        dragOffsetY = event.clientY - rect.top
        dragging = true
        panelEl.style.left = rect.left + 'px'
        panelEl.style.top = rect.top + 'px'
        panelEl.style.right = 'auto'
        panelEl.style.bottom = 'auto'
        event.preventDefault()
        $document.on('mousemove', onPointerMove)
        $document.on('mouseup', stopDragging)
      }

      dragHandle.addEventListener('mousedown', startDragging)

      scope.$on('$destroy', function() {
        stopDragging()
        dragHandle.removeEventListener('mousedown', startDragging)
      })
    }
  }
}])

const usedAuctionModule = angular.module('usedAuction', ['ui.router', 'rlsMusicPlayer'])

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

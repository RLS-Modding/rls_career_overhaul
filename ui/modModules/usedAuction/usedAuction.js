'use strict'

import '../rlsMusicPlayer/rlsMusicPlayer.js'

function defaultAuctionState() {
  return {
    phase: 'idle',
    entryPromptActive: false,
    entryFee: 1000,
    canPayEntryFee: false,
    canRegisterMoreLots: true,
    lotsRegisteredThisVisit: 0,
    hasFreeGarageSlot: true,
    musicEnabled: null,
    activeLotIndex: 1,
    currentLotIndex: null,
    statusMessage: '',
    purchasedCount: 0,
    bidMessage: '',
    lots: [],
    mainAuctionPanelActive: false,
    lotBatchSize: 10
  }
}

function defaultCounterState() {
  return {
    lotBatchSize: 10,
    canRegisterMoreLots: true,
    hasFreeGarageSlot: true,
    playerBalance: 0,
    entryCreditRemaining: 0,
    counterOffers: [],
    selectedAuctionTypeId: null,
    counterTab: 'auctions',
    counterShowAuctionsTab: true,
    myVehicles: [],
    listedVehicleInventoryId: null
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
  $scope.exitConfirmVisible = false
  $scope.state = defaultAuctionState()

  let lastActiveLotIndex = null
  let prevAuctionPhase = null

  function requestState() {
    const api = getGameLuaApi()
    if (!api) return
    api.engineLua('career_modules_usedCarAuction.requestAuctionState()', function(result) {
      if (!result || typeof result !== 'object') return
      $scope.$evalAsync(function() {
        const p = result.phase
        if (p === 'bidding' && prevAuctionPhase !== 'bidding') {
          resetAuctionTimerUi()
        }
        prevAuctionPhase = p
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

  $scope.isVaultSession = function() {
    const p = $scope.state.phase
    return p === 'vaultIdle' || p === 'starting' || p === 'bidding' || p === 'complete'
  }

  $scope.showMainAuctionPanel = function() {
    return $scope.state.mainAuctionPanelActive === true
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
    if (active.isPlayerListing) return false
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
    if (p === 'starting') return 'Entering'
    if (p === 'vaultIdle') return 'Inside'
    return 'Idle'
  }

  $scope.phaseClass = function() {
    const p = $scope.state.phase
    if (p === 'bidding') return 'phase-bidding'
    if (p === 'complete') return 'phase-complete'
    if (p === 'vaultIdle') return 'phase-vault'
    if (p === 'starting') return 'phase-starting'
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
      $scope.exitConfirmVisible = false
      $scope.state = defaultAuctionState()
    })
    stopPolling()
  })

  const exitRequestListener = angularRootScope.$on('UsedAuctionExitRequest', function() {
    $scope.$evalAsync(function() {
      $scope.exitConfirmVisible = true
      if (!$scope.visible) {
        $scope.visible = true
      }
    })
  })

  $scope.cancelLeaveAuction = function() {
    $scope.exitConfirmVisible = false
  }

  $scope.cancelLeaveAuctionBackdrop = function(ev) {
    if (ev && ev.target === ev.currentTarget) {
      $scope.cancelLeaveAuction()
    }
  }

  $scope.confirmLeaveAuction = function() {
    $scope.exitConfirmVisible = false
    const api = getGameLuaApi()
    if (api) {
      api.engineLua('career_modules_usedCarAuction.exitAuctionArea()')
    }
  }

  $scope.$on('$destroy', function() {
          showListener()
          hideListener()
          exitRequestListener()
          stopPolling()
        })
}])

.controller('UsedAuctionCounterController', ['$scope', '$rootScope', function($scope, $rootScope) {
  let pollTimer = null
  const angularRootScope = window.globalAngularRootScope || $rootScope

  $scope.visible = false
  $scope.state = defaultCounterState()

  function requestState() {
    const api = getGameLuaApi()
    if (!api) return
    api.engineLua('career_modules_usedCarAuction.requestAuctionState()', function(result) {
      if (!result || typeof result !== 'object') return
      $scope.$evalAsync(function() {
        const d = defaultCounterState()
        const previousSelection = $scope.state.selectedAuctionTypeId
        const counterOffers = Array.isArray(result.counterOffers) ? result.counterOffers : d.counterOffers
        const hasPreviousSelection = counterOffers.some(offer => offer && offer.id === previousSelection)
        const showAuctions = result.counterShowAuctionsTab !== false
        let counterTab = $scope.state.counterTab || d.counterTab
        if (!showAuctions) {
          counterTab = 'myVehicles'
        }
        $scope.state = {
          lotBatchSize: result.lotBatchSize ?? d.lotBatchSize,
          canRegisterMoreLots: result.canRegisterMoreLots ?? d.canRegisterMoreLots,
          hasFreeGarageSlot: result.hasFreeGarageSlot ?? d.hasFreeGarageSlot,
          playerBalance: result.playerBalance ?? d.playerBalance,
          entryCreditRemaining: result.entryCreditRemaining ?? d.entryCreditRemaining,
          counterOffers,
          selectedAuctionTypeId: hasPreviousSelection ? previousSelection : d.selectedAuctionTypeId,
          counterShowAuctionsTab: showAuctions,
          counterTab,
          myVehicles: Array.isArray(result.myVehicles) ? result.myVehicles : d.myVehicles,
          listedVehicleInventoryId: result.listedVehicleInventoryId != null ? result.listedVehicleInventoryId : d.listedVehicleInventoryId
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

  $scope.formatCurrency = function(amount) {
    const n = Number(amount)
    if (!Number.isFinite(n) || n < 0) return '$0'
    return '$' + Math.round(n).toLocaleString()
  }

  $scope.selectAuctionType = function(offer) {
    if (!offer || !offer.id) return
    $scope.state.selectedAuctionTypeId = offer.id
  }

  $scope.setLotBatchSize = function(value) {
    const n = Math.max(5, Math.min(25, Math.round(Number(value) || 10)))
    const prev = Math.round(Number($scope.state.lotBatchSize) || 10)
    if (prev === n) {
      return
    }
    $scope.state.lotBatchSize = n
    callAuctionLua('setCounterLotBatchSize', [String(n)])
  }

  const LOT_BATCH_MIN = 5
  const LOT_BATCH_MAX = 25
  const LOT_BATCH_SPAN = LOT_BATCH_MAX - LOT_BATCH_MIN

  function lotBatchPercent() {
    const n = Math.round(Number($scope.state.lotBatchSize) || 10)
    const clamped = Math.max(LOT_BATCH_MIN, Math.min(LOT_BATCH_MAX, n))
    return ((clamped - LOT_BATCH_MIN) / LOT_BATCH_SPAN) * 100
  }

  $scope.lotBatchSliderFillStyle = function() {
    return { width: lotBatchPercent() + '%' }
  }

  $scope.lotBatchSliderThumbStyle = function() {
    return { left: 'calc(' + lotBatchPercent() + '% - 0.43rem)' }
  }

  function lotBatchPointerClientX(ev) {
    if (ev.touches && ev.touches.length) {
      return ev.touches[0].clientX
    }
    if (ev.changedTouches && ev.changedTouches.length) {
      return ev.changedTouches[0].clientX
    }
    return ev.clientX
  }

  $scope.lotBatchSliderPointerDown = function(ev) {
    if (ev.type === 'mousedown' && ev.button !== 0) {
      return
    }
    let root = ev.currentTarget
    if (!root || !root.querySelector) {
      const t = ev.target
      if (t && t.closest) {
        root = t.closest('.ua-hslider')
      }
    }
    if (!root || !root.querySelector) {
      return
    }
    const track = root.querySelector('.ua-hslider-track')
    if (!track) {
      return
    }
    if (ev.preventDefault) {
      ev.preventDefault()
    }

    const win = window
    function updateFromEvent(e) {
      if (e.type === 'touchmove' && e.cancelable) {
        e.preventDefault()
      }
      const tr = track.getBoundingClientRect()
      const w = tr.width
      if (w <= 0) {
        return
      }
      const x = lotBatchPointerClientX(e)
      const t = (x - tr.left) / w
      const raw = LOT_BATCH_MIN + t * LOT_BATCH_SPAN
      const n = Math.max(LOT_BATCH_MIN, Math.min(LOT_BATCH_MAX, Math.round(raw)))
      $scope.$evalAsync(function() {
        $scope.setLotBatchSize(n)
      })
    }

    updateFromEvent(ev)

    function move(e) {
      updateFromEvent(e)
    }
    function up() {
      win.removeEventListener('mousemove', move, true)
      win.removeEventListener('mouseup', up, true)
      win.removeEventListener('touchmove', move, true)
      win.removeEventListener('touchend', up, true)
      win.removeEventListener('touchcancel', up, true)
    }
    win.addEventListener('mousemove', move, true)
    win.addEventListener('mouseup', up, true)
    win.addEventListener('touchmove', move, { capture: true, passive: false })
    win.addEventListener('touchend', up, true)
    win.addEventListener('touchcancel', up, true)
  }

  $scope.lotBatchSliderKeyDown = function(ev) {
    const k = ev.key
    const cur = Math.round(Number($scope.state.lotBatchSize) || 10)
    if (k === 'Home') {
      ev.preventDefault()
      $scope.setLotBatchSize(LOT_BATCH_MIN)
      return
    }
    if (k === 'End') {
      ev.preventDefault()
      $scope.setLotBatchSize(LOT_BATCH_MAX)
      return
    }
    let d = 0
    if (k === 'ArrowRight' || k === 'ArrowUp') {
      d = 1
    } else if (k === 'ArrowLeft' || k === 'ArrowDown') {
      d = -1
    }
    if (!d) {
      return
    }
    ev.preventDefault()
    $scope.setLotBatchSize(cur + d)
  }

  $scope.isAuctionTypeSelected = function(offer) {
    return !!(offer && offer.id && offer.id === $scope.state.selectedAuctionTypeId)
  }

  $scope.selectedAuctionOffer = function() {
    const offers = $scope.state.counterOffers || []
    for (let i = 0; i < offers.length; i++) {
      if (offers[i] && offers[i].id === $scope.state.selectedAuctionTypeId) {
        return offers[i]
      }
    }
    return null
  }

  $scope.canAffordSelectedAuctionOffer = function() {
    const offer = $scope.selectedAuctionOffer()
    if (!offer) return false
    const fee = Number(offer.registrationFee) || 0
    if (fee <= 0) return true
    const balance = Number($scope.state.playerBalance) || 0
    return balance >= fee
  }

  $scope.confirmButtonDisabled = function() {
    if ($scope.state.canRegisterMoreLots === false || $scope.state.hasFreeGarageSlot === false) return true
    return !$scope.selectedAuctionOffer() || !$scope.canAffordSelectedAuctionOffer()
  }

  $scope.confirmRegisterNextLot = function() {
    const offer = $scope.selectedAuctionOffer()
    if (!offer) return
    callAuctionLua('confirmRegisterNextLot', [JSON.stringify(String(offer.id)), String(Math.round(Number($scope.state.lotBatchSize) || 10))])
  }

  $scope.cancelCounterPrompt = function() {
    callAuctionLua('cancelCounterPrompt')
  }

  $scope.setCounterTab = function(tab) {
    if (tab === 'auctions' && $scope.state.counterShowAuctionsTab === false) {
      return
    }
    $scope.state.counterTab = tab
  }

  $scope.counterTabIs = function(tab) {
    return ($scope.state.counterTab || 'auctions') === tab
  }

  $scope.canListVehicleRow = function(row) {
    if (!row) return false
    if (row.listedForAuction) return false
    if (row.needsRepair) return false
    const listed = $scope.state.listedVehicleInventoryId
    if (listed != null && listed !== row.inventoryId) return false
    return true
  }

  $scope.listVehicleAtAuction = function(row) {
    if (!row || !$scope.canListVehicleRow(row)) return
    callAuctionLua('listVehicleForNextAnythingGoesAuction', [String(row.inventoryId)])
  }

  function hideCounterOverlay() {
    stopPolling()
    $scope.$evalAsync(function() {
      $scope.visible = false
      $scope.state = defaultCounterState()
    })
  }

  const showListener = angularRootScope.$on('UsedAuctionCounterShow', function() {
    $scope.$evalAsync(function() {
      $scope.visible = true
    })
    startPolling()
  })

  const hideListener = angularRootScope.$on('UsedAuctionCounterHide', hideCounterOverlay)
  const mainHideListener = angularRootScope.$on('UsedAuctionHide', hideCounterOverlay)

  $scope.$on('$destroy', function() {
    showListener()
    hideListener()
    mainHideListener()
    stopPolling()
  })
}])

.directive('uaCounterLotSlider', function() {
  return {
    restrict: 'A',
    link: function(scope, element) {
      function down(ev) {
        if (typeof scope.lotBatchSliderPointerDown === 'function') {
          scope.lotBatchSliderPointerDown(ev)
        }
      }
      element.on('mousedown', down)
      element.on('touchstart', down)
      scope.$on('$destroy', function() {
        element.off('mousedown', down)
        element.off('touchstart', down)
      })
    }
  }
})

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
        panelEl.style.position = 'fixed'
        panelEl.style.left = rect.left + 'px'
        panelEl.style.top = rect.top + 'px'
        panelEl.style.right = 'auto'
        panelEl.style.bottom = 'auto'
        panelEl.style.width = panelWidth + 'px'
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
    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()
    if (!injector) {
      window.setTimeout(initializeAuctionOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')

    if (!document.getElementById('used-auction-overlay-container')) {
      const container = angular.element('<div id="used-auction-overlay-container" ng-controller="UsedAuctionController" ng-include="\'/ui/modModules/usedAuction/usedAuction.html\'"></div>')
      bodyElement.append(container)
      $compile(container)($rootScope)
    }

    if (!document.getElementById('used-auction-counter-container')) {
      const counterEl = angular.element('<div id="used-auction-counter-container" ng-controller="UsedAuctionCounterController" ng-include="\'/ui/modModules/usedAuction/usedAuctionCounter.html\'"></div>')
      bodyElement.append(counterEl)
      $compile(counterEl)($rootScope)
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeAuctionOverlay)
  } else {
    window.setTimeout(initializeAuctionOverlay, 300)
  }
}])

export default usedAuctionModule

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Map: popup defaults and reward normalization; queue items; sound and timer ownership;
// queue advancement; controller event listeners and cleanup; stylesheet and overlay mounting.
import { reportFailure } from '../../modules/overhaulAngular/reportFailure.js'
'use strict'

const POPUP_KIND_LEVEL_UP = 'levelUp'
const POPUP_KIND_CONTRACT = 'contract'
const POPUP_KIND_RACE = 'raceComplete'

const RACE_COMPLETION_AUTO_CLOSE_MS = 5500

const BASE_AUTO_CLOSE_MS = 4000
const AUTO_CLOSE_MS_PER_UNLOCK = 1200
const CONTRACT_AUTO_CLOSE_MS = 4500
const FADE_OUT_MS = 300
const MAX_LEVEL_UP_AUTO_CLOSE_MS = 12000

const LEVEL_UP_SOUND_EVENT_ENTRY = "event:>UI>Career>EndScreen_Whoosh_Main"
const LEVEL_UP_SOUND_EVENT_IMPACT = "event:>UI>Career>EndScreen_Star_Bonus"
const LEVEL_UP_SOUND_IMPACT_DELAY_MS = 120

const CONTRACT_SOUND_EVENT_ENTRY = "event:>UI>Career>Computer"
const CONTRACT_SOUND_EVENT_IMPACT = "event:>UI>Career>Buy_01"
const CONTRACT_SOUND_IMPACT_DELAY_MS = 90

// Empty states: a fresh object on every call, so no two popups ever share one.

function buildEmptyContractState() {
  return {
    disciplineLabel: 'FRE',
    raceLabel: 'Race',
    tierLabel: 'Easy',
    requiredModelLabel: 'Any model',
    objectiveText: 'Objective cleared: 1 event under target',
    rewardMoney: '0',
    rewardXp: '0'
  }
}

function buildEmptyRaceState() {
  return {
    raceLabel: 'Race',
    position: null,
    fieldSize: null,
    raceTime: null,
    bestLap: null,
    lapsCompleted: null,
    lapsTotal: null,
    lapRows: [],
    rewardMoney: '0',
    rewardXp: '0',
    sanctionedNoRewardDetail: null
  }
}

function buildEmptyLevelUpState() {
  return { groups: [] }
}

function buildInitialPopupState() {
  return {
    visible: false,
    closing: false,
    kind: null,
    autoCloseMs: BASE_AUTO_CLOSE_MS,
    levelUp: buildEmptyLevelUpState(),
    contract: buildEmptyContractState(),
    race: buildEmptyRaceState()
  }
}

// Timer ids and queue state for one controller; the helpers below read and write it in place.
function createCelebrationState() {
  return {
    queue: [],
    processing: false,
    closeTimer: null,
    fadeTimer: null,
    impactTimer: null,
    destroyQueueAdvance: null
  }
}

// Derived data: raw career payloads become popup-ready values. None of these touch scope or timers.

function formatInteger(value) {
  return Math.floor(Number(value) || 0).toLocaleString()
}

function normalizeBranchLevels(branchLevels) {
  const sourceLevels = Array.isArray(branchLevels) ? branchLevels : Object.values(branchLevels || {})
  return sourceLevels
    .filter(function(level) {
      return level && Number.isFinite(Number(level.requiredValue))
    })
    .map(function(level) {
      return Object.assign({}, level, { requiredValue: Number(level.requiredValue) })
    })
    .sort(function(a, b) {
      return a.requiredValue - b.requiredValue
    })
}

function normalizeLevelUpEntry(entry) {
  if (!entry || typeof entry !== 'object') return null

  const animationData = entry.animationData && typeof entry.animationData === 'object' ? entry.animationData : {}
  const parsedLevel = Number(animationData.level)
  const level = Number.isFinite(parsedLevel) ? parsedLevel : undefined

  return Object.assign({}, entry, {
    animationData: Object.assign({}, animationData, {
      level: level,
      levelLabel: animationData.levelLabel || (level ? `Level ${level}` : 'Level Up')
    })
  })
}

function getLevelValue(reward) {
  const levels = normalizeBranchLevels(reward && reward.branchLevels)
  const value = Number(reward && reward.animationData && reward.animationData.value)
  const entryLevel = Number(reward && reward.animationData && reward.animationData.level)
  if (levels.length && Number.isFinite(value)) {
    let actualLevel = 1
    for (let i = 0; i < levels.length; i++) {
      if (value >= levels[i].requiredValue) {
        actualLevel = i + 1
      } else {
        break
      }
    }
    if (Number.isFinite(entryLevel) && entryLevel > 0) {
      return Math.max(1, Math.min(entryLevel, actualLevel))
    }
    return actualLevel
  }

  return Number.isFinite(entryLevel) && entryLevel > 0 ? entryLevel : 1
}

function getAutoCloseMs(unlockCount) {
  return BASE_AUTO_CLOSE_MS + Math.max(0, unlockCount - 1) * AUTO_CLOSE_MS_PER_UNLOCK
}

function normalizeContractEntry(entry) {
  if (!entry || typeof entry !== 'object') return null

  const requiredCount = Math.max(1, Math.floor(Number(entry.requiredCount || 1)))
  const objectiveType = entry.objectiveType === 'laps' ? 'laps' : 'events'
  const tier = entry.tier || 'easy'
  const tierLabel = `${String(tier).charAt(0).toUpperCase()}${String(tier).slice(1)}`
  const requiredModelLabel = entry.requiredModelLabel || entry.requiredModel || 'Any model'
  const objectiveText = objectiveType === 'laps'
    ? `Objective cleared: ${requiredCount} lap${requiredCount === 1 ? '' : 's'} under target`
    : `Objective cleared: ${requiredCount} event${requiredCount === 1 ? '' : 's'} under target`

  return {
    disciplineLabel: entry.disciplineLabel || 'FRE',
    raceLabel: entry.raceLabel || 'Race',
    tierLabel: tierLabel,
    requiredModelLabel: requiredModelLabel,
    objectiveText: objectiveText,
    rewardMoney: formatInteger(entry.rewardMoney),
    rewardXp: formatInteger(entry.rewardXp)
  }
}

function normalizeRaceEntry(entry) {
  if (!entry || typeof entry !== 'object') return null
  const lapRows = Array.isArray(entry.lapRows) ? entry.lapRows.map(function(r) {
    return {
      index: Number(r.index) || 0,
      time: String(r.time || ''),
      invalid: !!r.invalid,
      isBest: !!r.isBest
    }
  }) : []
  const detail = entry.sanctionedNoRewardDetail != null && String(entry.sanctionedNoRewardDetail).length > 0
    ? String(entry.sanctionedNoRewardDetail)
    : null
  return {
    raceLabel: entry.raceLabel || 'Race',
    position: entry.position != null ? Number(entry.position) : null,
    fieldSize: entry.fieldSize != null ? Number(entry.fieldSize) : null,
    raceTime: entry.raceTime || null,
    bestLap: entry.bestLap || null,
    lapsCompleted: entry.lapsCompleted != null ? Number(entry.lapsCompleted) : null,
    lapsTotal: entry.lapsTotal != null ? Number(entry.lapsTotal) : null,
    lapRows: lapRows,
    rewardMoney: formatInteger(entry.rewardMoney),
    rewardXp: formatInteger(entry.rewardXp),
    sanctionedNoRewardDetail: detail
  }
}

function flattenUnlocks(unlocks) {
  return unlocks.flatMap(item =>
    item && item.type === 'tasklist' && item.tasklistData && Array.isArray(item.tasklistData.tasks)
      ? item.tasklistData.tasks.map(task => ({ heading: task.label, description: task.description, icon: item.icon }))
      : [item]
  )
}

// Count distinct crossed levels, rather than event entries: a repeated event
// must not multiply a license point or payout bonus already in the summary.
function summarizeUnlocks(reward, fromLevel, toLevel) {
  const merged = new Map()
  const levels = normalizeBranchLevels(reward.branchLevels).slice(fromLevel, toLevel)
  for (const level of levels) {
    const seen = new Set()
    for (const item of flattenUnlocks(Array.isArray(level.unlocks) ? level.unlocks : [])) {
      const identity = JSON.stringify(item && typeof item === 'object'
        ? [item.type, item.heading, item.description, item.icon] : item)
      if (seen.has(identity)) continue
      seen.add(identity)
      if (!merged.has(identity)) {
        merged.set(identity, item && typeof item === 'object' ? Object.assign({}, item, { levelCount: 0 }) : item)
      }
      const unlock = merged.get(identity)
      if (unlock && typeof unlock === 'object') unlock.levelCount++
    }
  }
  return Array.from(merged.values())
}

// Group by the payload identity, never a catalog of skill names. Keep each range's
// earliest predecessor so repeated events cannot lose its first crossed unlock.
function mergeLevelUpGroups(groups, entries) {
  const merged = groups.slice()
  for (const entry of entries) {
    const reward = normalizeLevelUpEntry(entry)
    if (!reward) continue
    const levelValue = getLevelValue(reward)
    const key = reward.attributeKey || reward.animationData.id || reward.branchId || reward.animationData.name || 'Skill'
    let fromLevel = Math.max(0, levelValue - 1)
    if (Number(reward.rewardAmount) > 0) {
      const before = Object.assign({}, reward, { animationData: {
        value: Number(reward.animationData.value) - Number(reward.rewardAmount)
      } })
      fromLevel = Math.min(fromLevel, getLevelValue(before))
    }
    let group = merged.find(item => item.key === key)
    if (!group) {
      group = { key, reward, fromLevel, levelValue, currentUnlocks: [] }
      merged.push(group)
    }
    group.fromLevel = Math.min(group.fromLevel, fromLevel)
    group.levelValue = Math.max(group.levelValue, levelValue)
    if (normalizeBranchLevels(reward.branchLevels).length) group.reward = reward
    group.currentUnlocks = summarizeUnlocks(group.reward, group.fromLevel, group.levelValue)
  }
  return merged
}

function buildLevelUpQueueItem(entries, groups = []) {
  const merged = mergeLevelUpGroups(groups, entries)
  if (!merged.length) return null
  const unlockCount = merged.reduce((sum, group) => sum + group.currentUnlocks.length, 0)
  return {
    kind: POPUP_KIND_LEVEL_UP,
    payload: { groups: merged },
    autoCloseMs: Math.min(MAX_LEVEL_UP_AUTO_CLOSE_MS, getAutoCloseMs(unlockCount + merged.length - 1)),
    soundProfile: POPUP_KIND_LEVEL_UP
  }
}

function receiveLevelUps($scope, state, entries) {
  const showing = $scope.popup.visible && $scope.popup.kind === POPUP_KIND_LEVEL_UP
  const pending = state.queue.find(item => item.kind === POPUP_KIND_LEVEL_UP)
  const groups = showing ? $scope.popup.levelUp.groups : pending ? pending.payload.groups : []
  const item = buildLevelUpQueueItem(entries, groups)
  if (!item) return
  if (showing) {
    // Preserve the entrance and sound; a merge only renews the reading time.
    if (state.closeTimer) clearTimeout(state.closeTimer)
    if (state.fadeTimer) clearTimeout(state.fadeTimer)
    state.fadeTimer = null
    applyQueueItem($scope, item)
    state.closeTimer = setTimeout(() => closePopup($scope, state), item.autoCloseMs)
    $scope.$applyAsync()
  } else if (pending) {
    Object.assign(pending, item)
  } else {
    state.queue.push(item)
  }
  processQueue($scope, state)
}

function buildContractQueueItem(entry) {
  const contract = normalizeContractEntry(entry)
  if (!contract) return null

  return {
    kind: POPUP_KIND_CONTRACT,
    payload: contract,
    autoCloseMs: CONTRACT_AUTO_CLOSE_MS,
    soundProfile: POPUP_KIND_CONTRACT
  }
}

function buildRaceQueueItem(entry) {
  const race = normalizeRaceEntry(entry)
  if (!race) return null
  const lapBonus = Math.min(7000, Math.max(0, race.lapRows.length - 3) * 400)
  return {
    kind: POPUP_KIND_RACE,
    payload: race,
    autoCloseMs: RACE_COMPLETION_AUTO_CLOSE_MS + lapBonus,
    soundProfile: POPUP_KIND_CONTRACT
  }
}

// Animation: the entry sound plays now and the impact sound after a delay; timers are cleared in one place.

function clearPopupTimers(state) {
  if (state.closeTimer) {
    clearTimeout(state.closeTimer)
    state.closeTimer = null
  }
  if (state.fadeTimer) {
    clearTimeout(state.fadeTimer)
    state.fadeTimer = null
  }
  if (state.impactTimer) {
    clearTimeout(state.impactTimer)
    state.impactTimer = null
  }
}

function playSoundCombo(state, soundProfile) {
  let entryEvent = null
  let impactEvent = null
  let impactDelay = 0

  if (soundProfile === POPUP_KIND_CONTRACT) {
    entryEvent = CONTRACT_SOUND_EVENT_ENTRY
    impactEvent = CONTRACT_SOUND_EVENT_IMPACT
    impactDelay = CONTRACT_SOUND_IMPACT_DELAY_MS
  } else {
    entryEvent = LEVEL_UP_SOUND_EVENT_ENTRY
    impactEvent = LEVEL_UP_SOUND_EVENT_IMPACT
    impactDelay = LEVEL_UP_SOUND_IMPACT_DELAY_MS
  }

  bngApi.engineLua(`Engine.Audio.playOnce('AudioGui', '${entryEvent}')`)
  state.impactTimer = setTimeout(function() {
    bngApi.engineLua(`Engine.Audio.playOnce('AudioGui', '${impactEvent}')`)
    state.impactTimer = null
  }, impactDelay)
}

// Popup state: writes the shown popup's fields onto the scope object, which the template binds to.

function resetPopupState($scope) {
  $scope.popup.visible = false
  $scope.popup.closing = false
  $scope.popup.kind = null
  $scope.popup.autoCloseMs = BASE_AUTO_CLOSE_MS
  $scope.popup.levelUp = buildEmptyLevelUpState()
  $scope.popup.contract = buildEmptyContractState()
  $scope.popup.race = buildEmptyRaceState()
}

function applyQueueItem($scope, queueItem) {
  $scope.popup.kind = queueItem.kind
  $scope.popup.autoCloseMs = queueItem.autoCloseMs

  if (queueItem.kind === POPUP_KIND_CONTRACT) {
    $scope.popup.contract = queueItem.payload
    $scope.popup.race = buildEmptyRaceState()
    $scope.popup.levelUp = buildEmptyLevelUpState()
  } else if (queueItem.kind === POPUP_KIND_RACE) {
    $scope.popup.race = queueItem.payload
    $scope.popup.contract = buildEmptyContractState()
    $scope.popup.levelUp = buildEmptyLevelUpState()
  } else {
    $scope.popup.levelUp = queueItem.payload
    $scope.popup.contract = buildEmptyContractState()
    $scope.popup.race = buildEmptyRaceState()
  }

  $scope.popup.visible = true
  $scope.popup.closing = false
}

// Queue: one celebration at a time. A closed popup schedules the next one through a zero-delay timer.

function advanceQueue($scope, state) {
  state.destroyQueueAdvance = null
  if (state.queue.length <= 0) {
    state.processing = false
    return
  }

  const queueItem = state.queue.shift()
  if (!queueItem) {
    advanceQueue($scope, state)
    return
  }

  clearPopupTimers(state)
  applyQueueItem($scope, queueItem)
  playSoundCombo(state, queueItem.soundProfile)

  $scope.$applyAsync()
  state.closeTimer = setTimeout(function() {
    closePopup($scope, state)
  }, $scope.popup.autoCloseMs)
}

function processQueue($scope, state) {
  if (state.processing || state.queue.length <= 0) return
  state.processing = true
  advanceQueue($scope, state)
}

function skipLevelUpCelebrations($scope, state) {
  const remaining = []
  for (const item of state.queue) {
    if (item && item.kind !== POPUP_KIND_LEVEL_UP) {
      remaining.push(item)
    }
  }
  state.queue = remaining

  if (state.destroyQueueAdvance) {
    clearTimeout(state.destroyQueueAdvance)
    state.destroyQueueAdvance = null
  }

  const showingLevelUp = $scope.popup.visible && $scope.popup.kind === POPUP_KIND_LEVEL_UP
  if (showingLevelUp) {
    clearPopupTimers(state)
    resetPopupState($scope)
    state.processing = false
    $scope.$applyAsync()
    processQueue($scope, state)
    return
  }

  $scope.$applyAsync()
}

function closePopup($scope, state) {
  if (!$scope.popup.visible || $scope.popup.closing) return

  if (state.closeTimer) {
    clearTimeout(state.closeTimer)
    state.closeTimer = null
  }

  $scope.popup.closing = true
  $scope.$applyAsync()

  state.fadeTimer = setTimeout(function() {
    state.fadeTimer = null
    resetPopupState($scope)
    $scope.$applyAsync()

    state.destroyQueueAdvance = setTimeout(function() {
      advanceQueue($scope, state)
    }, 0)
  }, FADE_OUT_MS)
}

// UI: icon names without an svg in the game's icon set fall back to a default glyph (checked once per name).
// The probe cache belongs to one controller, so each controller starts with every icon unchecked.
function createIconUrl($scope, getIconSrc) {
  const missingIcons = {}
  return function(name, fallback) {
    if (!name || missingIcons[name] === true) return getIconSrc(fallback)
    if (missingIcons[name] === undefined) {
      missingIcons[name] = false
      const probe = new Image()
      probe.onerror = function() { missingIcons[name] = true; $scope.$evalAsync() }
      probe.src = getIconSrc(name)
    }
    return getIconSrc(name)
  }
}

// Listeners: each event turns its payload into queue items, then starts the queue if it is idle.
// The returned function detaches all four, in the order they were attached.
function registerCelebrationListeners($rootScope, $scope, state) {
  const levelUpListener = $rootScope.$on('OpenCareerLevelUpCelebration', function(_event, data) {
    const entries = Array.isArray(data && data.entries) ? data.entries : []
    if (!entries.length) return

    receiveLevelUps($scope, state, entries)
  })

  const contractListener = $rootScope.$on('OpenFreContractCelebration', function(_event, data) {
    const entries = []
    if (Array.isArray(data && data.entries)) {
      entries.push.apply(entries, data.entries)
    } else if (data && data.entry) {
      entries.push(data.entry)
    }
    if (!entries.length) return

    for (const entry of entries) {
      const queueItem = buildContractQueueItem(entry)
      if (queueItem) {
        state.queue.push(queueItem)
      }
    }

    processQueue($scope, state)
  })

  const raceCompletionListener = $rootScope.$on('OpenFreRaceCompletionCelebration', function(_event, data) {
    const entry = data && data.entry
    const queueItem = buildRaceQueueItem(entry)
    if (queueItem) {
      state.queue.push(queueItem)
      processQueue($scope, state)
    }
  })

  const skipLevelUpListener = $rootScope.$on('SkipCareerLevelUpCelebrations', function() {
    skipLevelUpCelebrations($scope, state)
  })

  return function() {
    levelUpListener()
    contractListener()
    raceCompletionListener()
    skipLevelUpListener()
  }
}

angular.module('beamng.stuff')

.controller('CelebrationPopUpController', ['$scope', '$rootScope', function($scope, $rootScope) {
  function getIconSrc(iconName) {
    if (!iconName) return ''
    return `/ui/ui-vue/src/assets/fonts/bngIcons/svg/${iconName}.svg`
  }
  const state = createCelebrationState()
  $scope.popup = buildInitialPopupState()

  $scope.getIconSrc = getIconSrc
  $scope.iconUrl = createIconUrl($scope, getIconSrc)

  const detachListeners = registerCelebrationListeners($rootScope, $scope, state)

  $scope.$on('$destroy', function() {
    detachListeners()
    clearPopupTimers(state)
    if (state.destroyQueueAdvance) {
      clearTimeout(state.destroyQueueAdvance)
      state.destroyQueueAdvance = null
    }
    state.queue = []
    state.processing = false
    resetPopupState($scope)
  })
}])

const celebrationPopUpModule = angular.module('overhaulCelebrationPopUp', ['ui.router'])

.run(['$compile', function($compile) {
  let celebrationInitAttempts = 0
  function initializeCelebrationPopUpOverlay() {
    const existingContainer = document.getElementById('celebration-popup-container')
    if (existingContainer) {
      return
    }

    const bodyElement = angular.element(document.body)
    const angularRoot = document.getElementById('angular-root')
    const injector = angularRoot && angular.element(angularRoot).injector()

    if (!injector) {
      if (++celebrationInitAttempts < 300) setTimeout(initializeCelebrationPopUpOverlay, 100)
      else reportFailure(new Error('[celebrationPopUp] #angular-root has no injector; overlay not mounted'), 'overhaulCelebrationPopUp/overhaulCelebrationPopUp overlay mount')
      return
    }

    const compileService = injector.get('$compile')
    const rootScope = injector.get('$rootScope')
    const overlayContainer = angular.element('<div id="celebration-popup-container" ng-controller="CelebrationPopUpController" ng-include="\'/ui/modModules/overhaulCelebrationPopUp/overhaulCelebrationPopUp.html\'"></div>')

    bodyElement.append(overlayContainer)
    compileService(overlayContainer)(rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeCelebrationPopUpOverlay)
  } else {
    initializeCelebrationPopUpOverlay()
  }
}])

export default celebrationPopUpModule

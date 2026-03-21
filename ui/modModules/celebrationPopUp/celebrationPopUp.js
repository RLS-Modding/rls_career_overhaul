'use strict'

const POPUP_KIND_LEVEL_UP = 'levelUp'
const POPUP_KIND_CONTRACT = 'contract'
const POPUP_KIND_RACE = 'raceComplete'

const RACE_COMPLETION_AUTO_CLOSE_MS = 5500

const BASE_AUTO_CLOSE_MS = 4000
const AUTO_CLOSE_MS_PER_UNLOCK = 1200
const CONTRACT_AUTO_CLOSE_MS = 4500
const FADE_OUT_MS = 300

const LEVEL_UP_SOUND_EVENT_ENTRY = "event:>UI>Career>EndScreen_Whoosh_Main"
const LEVEL_UP_SOUND_EVENT_IMPACT = "event:>UI>Career>EndScreen_Star_Bonus"
const LEVEL_UP_SOUND_IMPACT_DELAY_MS = 120

const CONTRACT_SOUND_EVENT_ENTRY = "event:>UI>Career>Computer"
const CONTRACT_SOUND_EVENT_IMPACT = "event:>UI>Career>Buy_01"
const CONTRACT_SOUND_IMPACT_DELAY_MS = 90

const DEFAULT_LEVEL_UP_HEADER = 'Skill: Level 1'

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

angular.module('beamng.stuff')

.controller('CelebrationPopUpController', ['$scope', '$rootScope', function($scope, $rootScope) {
  let celebrationQueue = []
  let processingCelebrationQueue = false
  let closeTimer = null
  let fadeTimer = null
  let impactTimer = null
  let destroyQueueAdvance = null

  $scope.popup = {
    visible: false,
    closing: false,
    kind: null,
    autoCloseMs: BASE_AUTO_CLOSE_MS,
    levelUp: {
      reward: {},
      levelValue: 1,
      defaultHeader: DEFAULT_LEVEL_UP_HEADER,
      headerText: DEFAULT_LEVEL_UP_HEADER,
      currentUnlocks: []
    },
    contract: buildEmptyContractState(),
    race: buildEmptyRaceState()
  }

  function resetPopupState() {
    $scope.popup.visible = false
    $scope.popup.closing = false
    $scope.popup.kind = null
    $scope.popup.autoCloseMs = BASE_AUTO_CLOSE_MS
    $scope.popup.levelUp = {
      reward: {},
      levelValue: 1,
      defaultHeader: DEFAULT_LEVEL_UP_HEADER,
      headerText: DEFAULT_LEVEL_UP_HEADER,
      currentUnlocks: []
    }
    $scope.popup.contract = buildEmptyContractState()
    $scope.popup.race = buildEmptyRaceState()
  }

  function clearPopupTimers() {
    if (closeTimer) {
      clearTimeout(closeTimer)
      closeTimer = null
    }
    if (fadeTimer) {
      clearTimeout(fadeTimer)
      fadeTimer = null
    }
    if (impactTimer) {
      clearTimeout(impactTimer)
      impactTimer = null
    }
  }

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

  function getCurrentUnlocks(reward, levelValue) {
  const levels = normalizeBranchLevels(reward && reward.branchLevels)
  const safeLevelIndex = Math.max(0, Math.min(levels.length - 1, levelValue - 1))
  const currentLevelData = levels[safeLevelIndex]
    return Array.isArray(currentLevelData && currentLevelData.unlocks) ? currentLevelData.unlocks : []
  }

  function getDefaultHeader(reward, levelValue) {
    const skillName = reward && reward.animationData && reward.animationData.name ? reward.animationData.name : 'Skill'
    return `${skillName}: Level ${levelValue}`
  }

  function getHeaderText(reward, levelValue) {
    const skillName = reward && reward.animationData && reward.animationData.name ? reward.animationData.name : 'Skill'
    let headerText = reward && reward.unlockPopupHeader ? reward.unlockPopupHeader : getDefaultHeader(reward, levelValue)

    if (skillName.endsWith(' Skill')) {
      const duplicateSkillPrefix = `${skillName} Skill:`
      if (headerText.startsWith(duplicateSkillPrefix)) {
        headerText = `${skillName}:${headerText.slice(duplicateSkillPrefix.length)}`
      }
    }

    headerText = headerText.replace(/\bSkill Skill\b/g, 'Skill')
    return headerText
  }

  function getAutoCloseMs(unlocks) {
    const unlockCount = Array.isArray(unlocks) ? unlocks.length : 0
    return BASE_AUTO_CLOSE_MS + Math.max(0, unlockCount - 1) * AUTO_CLOSE_MS_PER_UNLOCK
  }

  function getIconSrc(iconName) {
    if (!iconName) return ''
    return `/ui/ui-vue/src/assets/fonts/bngIcons/svg/${iconName}.svg`
  }

  function playSoundCombo(soundProfile) {
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
    impactTimer = setTimeout(function() {
      bngApi.engineLua(`Engine.Audio.playOnce('AudioGui', '${impactEvent}')`)
      impactTimer = null
    }, impactDelay)
  }

  function buildLevelUpQueueItem(entry) {
    const reward = normalizeLevelUpEntry(entry)
    if (!reward) return null

    const levelValue = getLevelValue(reward)
    const currentUnlocks = getCurrentUnlocks(reward, levelValue)

    return {
      kind: POPUP_KIND_LEVEL_UP,
      payload: {
        reward: reward,
        levelValue: levelValue,
        defaultHeader: getDefaultHeader(reward, levelValue),
        headerText: getHeaderText(reward, levelValue),
        currentUnlocks: currentUnlocks
      },
      autoCloseMs: getAutoCloseMs(currentUnlocks),
      soundProfile: POPUP_KIND_LEVEL_UP
    }
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

  function applyQueueItem(queueItem) {
    $scope.popup.kind = queueItem.kind
    $scope.popup.autoCloseMs = queueItem.autoCloseMs

    if (queueItem.kind === POPUP_KIND_CONTRACT) {
      $scope.popup.contract = queueItem.payload
      $scope.popup.race = buildEmptyRaceState()
      $scope.popup.levelUp = {
        reward: {},
        levelValue: 1,
        defaultHeader: DEFAULT_LEVEL_UP_HEADER,
        headerText: DEFAULT_LEVEL_UP_HEADER,
        currentUnlocks: []
      }
    } else if (queueItem.kind === POPUP_KIND_RACE) {
      $scope.popup.race = queueItem.payload
      $scope.popup.contract = buildEmptyContractState()
      $scope.popup.levelUp = {
        reward: {},
        levelValue: 1,
        defaultHeader: DEFAULT_LEVEL_UP_HEADER,
        headerText: DEFAULT_LEVEL_UP_HEADER,
        currentUnlocks: []
      }
    } else {
      $scope.popup.levelUp = queueItem.payload
      $scope.popup.contract = buildEmptyContractState()
      $scope.popup.race = buildEmptyRaceState()
    }

    $scope.popup.visible = true
    $scope.popup.closing = false
  }

  function advanceQueue() {
    destroyQueueAdvance = null
    if (celebrationQueue.length <= 0) {
      processingCelebrationQueue = false
      return
    }

    const queueItem = celebrationQueue.shift()
    if (!queueItem) {
      advanceQueue()
      return
    }

    clearPopupTimers()
    applyQueueItem(queueItem)
    playSoundCombo(queueItem.soundProfile)

    $scope.$applyAsync()
    closeTimer = setTimeout(function() {
      closePopup()
    }, $scope.popup.autoCloseMs)
  }

  function processQueue() {
    if (processingCelebrationQueue || celebrationQueue.length <= 0) return
    processingCelebrationQueue = true
    advanceQueue()
  }

  function closePopup() {
    if (!$scope.popup.visible || $scope.popup.closing) return

    if (closeTimer) {
      clearTimeout(closeTimer)
      closeTimer = null
    }

    $scope.popup.closing = true
    $scope.$applyAsync()

    fadeTimer = setTimeout(function() {
      fadeTimer = null
      resetPopupState()
      $scope.$applyAsync()

      destroyQueueAdvance = setTimeout(function() {
        advanceQueue()
      }, 0)
    }, FADE_OUT_MS)
  }

  $scope.getIconSrc = getIconSrc

  const levelUpListener = $rootScope.$on('OpenCareerLevelUpCelebration', function(_event, data) {
    const entries = Array.isArray(data && data.entries) ? data.entries : []
    if (!entries.length) return

    for (const entry of entries) {
      const queueItem = buildLevelUpQueueItem(entry)
      if (queueItem) {
        celebrationQueue.push(queueItem)
      }
    }

    processQueue()
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
        celebrationQueue.push(queueItem)
      }
    }

    processQueue()
  })

  const raceCompletionListener = $rootScope.$on('OpenFreRaceCompletionCelebration', function(_event, data) {
    const entry = data && data.entry
    const queueItem = buildRaceQueueItem(entry)
    if (queueItem) {
      celebrationQueue.push(queueItem)
      processQueue()
    }
  })

  $scope.$on('$destroy', function() {
    levelUpListener()
    contractListener()
    raceCompletionListener()
    clearPopupTimers()
    if (destroyQueueAdvance) {
      clearTimeout(destroyQueueAdvance)
      destroyQueueAdvance = null
    }
    celebrationQueue = []
    processingCelebrationQueue = false
    resetPopupState()
  })
}])

const celebrationPopUpModule = angular.module('celebrationPopUp', ['ui.router'])

.run(['$compile', function($compile) {
  function initializeCelebrationPopUpOverlay() {
    const existingContainer = document.getElementById('celebration-popup-container')
    if (existingContainer) {
      return
    }

    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()

    if (!injector) {
      setTimeout(initializeCelebrationPopUpOverlay, 100)
      return
    }

    const compileService = injector.get('$compile')
    const rootScope = injector.get('$rootScope')
    const overlayContainer = angular.element('<div id="celebration-popup-container" ng-controller="CelebrationPopUpController" ng-include="\'/ui/modModules/celebrationPopUp/celebrationPopUp.html\'"></div>')

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

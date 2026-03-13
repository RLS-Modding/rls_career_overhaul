'use strict'

const BASE_AUTO_CLOSE_MS = 4000
const AUTO_CLOSE_MS_PER_UNLOCK = 1200
const FADE_OUT_MS = 300
const LEVEL_UP_SOUND_EVENT_ENTRY = "event:>UI>Career>EndScreen_Whoosh_Main"
const LEVEL_UP_SOUND_EVENT_IMPACT = "event:>UI>Career>EndScreen_Star_Bonus"
const LEVEL_UP_SOUND_IMPACT_DELAY_MS = 120

angular.module('beamng.stuff')

.controller('LevelUpCelebrationController', ['$scope', '$rootScope', function($scope, $rootScope) {
  let levelUpQueue = []
  let processingLevelUpQueue = false
  let closeTimer = null
  let fadeTimer = null
  let impactTimer = null
  let destroyQueueAdvance = null

  $scope.popup = {
    visible: false,
    closing: false,
    reward: {},
    levelValue: 1,
    defaultHeader: 'Skill: Level 1',
    headerText: 'Skill: Level 1',
    currentUnlocks: [],
    autoCloseMs: BASE_AUTO_CLOSE_MS
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
    const level = Number(reward && reward.animationData && reward.animationData.level)
    return Number.isFinite(level) && level > 0 ? level : 1
  }

  function getCurrentUnlocks(reward, levelValue) {
    const levels = Array.isArray(reward && reward.branchLevels) ? reward.branchLevels : []
    const currentLevelData = levels[levelValue - 1]
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

  function playLevelUpSoundCombo() {
    bngApi.engineLua(`Engine.Audio.playOnce('AudioGui', '${LEVEL_UP_SOUND_EVENT_ENTRY}')`)
    impactTimer = setTimeout(function() {
      bngApi.engineLua(`Engine.Audio.playOnce('AudioGui', '${LEVEL_UP_SOUND_EVENT_IMPACT}')`)
      impactTimer = null
    }, LEVEL_UP_SOUND_IMPACT_DELAY_MS)
  }

  function advanceQueue() {
    destroyQueueAdvance = null
    if (levelUpQueue.length <= 0) {
      processingLevelUpQueue = false
      return
    }

    const reward = levelUpQueue.shift()
    if (!reward) {
      advanceQueue()
      return
    }

    const levelValue = getLevelValue(reward)
    const currentUnlocks = getCurrentUnlocks(reward, levelValue)

    clearPopupTimers()
    playLevelUpSoundCombo()

    $scope.popup.reward = reward
    $scope.popup.levelValue = levelValue
    $scope.popup.defaultHeader = getDefaultHeader(reward, levelValue)
    $scope.popup.headerText = getHeaderText(reward, levelValue)
    $scope.popup.currentUnlocks = currentUnlocks
    $scope.popup.autoCloseMs = getAutoCloseMs(currentUnlocks)
    $scope.popup.visible = true
    $scope.popup.closing = false

    $scope.$applyAsync()
    closeTimer = setTimeout(function() {
      closePopup()
    }, $scope.popup.autoCloseMs)
  }

  function processQueue() {
    if (processingLevelUpQueue || levelUpQueue.length <= 0) return
    processingLevelUpQueue = true
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
      $scope.popup.visible = false
      $scope.popup.closing = false
      $scope.popup.reward = {}
      $scope.popup.levelValue = 1
      $scope.popup.defaultHeader = 'Skill: Level 1'
      $scope.popup.headerText = 'Skill: Level 1'
      $scope.popup.currentUnlocks = []
      $scope.popup.autoCloseMs = BASE_AUTO_CLOSE_MS
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
      const normalized = normalizeLevelUpEntry(entry)
      if (normalized) {
        levelUpQueue.push(normalized)
      }
    }

    processQueue()
  })

  $scope.$on('$destroy', function() {
    levelUpListener()
    clearPopupTimers()
    if (destroyQueueAdvance) {
      clearTimeout(destroyQueueAdvance)
      destroyQueueAdvance = null
    }
    levelUpQueue = []
    processingLevelUpQueue = false
  })
}])

const levelUpCelebrationModule = angular.module('levelUpCelebration', ['ui.router'])

.run(['$rootScope', '$compile', function($rootScope, $compile) {
  function initializeLevelUpCelebrationOverlay() {
    const existingContainer = document.getElementById('level-up-celebration-container')
    if (existingContainer) {
      return
    }

    const bodyElement = angular.element(document.body)
    const injector = bodyElement.injector()

    if (!injector) {
      setTimeout(initializeLevelUpCelebrationOverlay, 100)
      return
    }

    const compileService = injector.get('$compile')
    const rootScope = injector.get('$rootScope')
    const overlayContainer = angular.element('<div id="level-up-celebration-container" ng-controller="LevelUpCelebrationController" ng-include="\'/ui/modModules/levelUpCelebration/levelUpCelebration.html\'"></div>')

    bodyElement.append(overlayContainer)
    compileService(overlayContainer)(rootScope)
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeLevelUpCelebrationOverlay)
  } else {
    setTimeout(initializeLevelUpCelebrationOverlay, 500)
  }
}])

export default levelUpCelebrationModule

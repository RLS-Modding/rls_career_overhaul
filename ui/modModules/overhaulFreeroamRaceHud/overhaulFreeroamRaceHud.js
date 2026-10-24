// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import './gameplayPopup.js'
// The stock loader imports this entry once; controller imports retain their registration order.
import './FreeroamRaceHudController.js'
import './SanctionedParkingStagingController.js'
import './DemoStagingController.js'
import './DemoCongratulationsController.js'
import './DakarCompassController.js'
import './DakarStartController.js'
import './RoadAuthorityIntroController.js'
import './RoadAuthorityClearController.js'
import './CleanupClubPromptController.js'
import './DakarFinishController.js'
import './CareerFastTravelController.js'
import './MiningHaulController.js'
import './TractorPullController.js'

const freeroamRaceHudModule = angular.module('overhaulFreeroamRaceHud', ['ui.router'])
.run(function() {
  function initializeFreeroamRaceHudOverlay() {
    const bodyElement = angular.element(document.body)
    const angularRoot = document.getElementById('angular-root')
    const injector = angularRoot && angular.element(angularRoot).injector()
    if (!injector) {
      window.setTimeout(initializeFreeroamRaceHudOverlay, 100)
      return
    }

    const $compile = injector.get('$compile')
    const $rootScope = injector.get('$rootScope')
    if (!document.getElementById('freeroam-race-hud-overlay-container')) {
      const container = angular.element(
        '<div id="freeroam-race-hud-overlay-container" ng-controller="FreeroamRaceHudController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/overhaulFreeroamRaceHud.html\'"></div>'
      )
      bodyElement.append(container)
      $compile(container)($rootScope)
    }
    if (!document.getElementById('sanctioned-parking-staging-overlay-container')) {
      const spContainer = angular.element(
        '<div id="sanctioned-parking-staging-overlay-container" ng-controller="SanctionedParkingStagingController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/sanctionedParkingStaging.html\'"></div>'
      )
      bodyElement.append(spContainer)
      $compile(spContainer)($rootScope)
    }
    if (!document.getElementById('demo-staging-overlay-container')) {
      const dmsContainer = angular.element(
        '<div id="demo-staging-overlay-container" ng-controller="DemoStagingController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/demoStaging.html\'"></div>'
      )
      bodyElement.append(dmsContainer)
      $compile(dmsContainer)($rootScope)
    }
    if (!document.getElementById('demo-congratulations-overlay-container')) {
      const dmcContainer = angular.element(
        '<div id="demo-congratulations-overlay-container" ng-controller="DemoCongratulationsController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/demoCongratulations.html\'"></div>'
      )
      bodyElement.append(dmcContainer)
      $compile(dmcContainer)($rootScope)
    }
    if (!document.getElementById('tractor-pull-overlay-container')) {
      const tractorPullContainer = angular.element(
        '<div id="tractor-pull-overlay-container" ng-controller="TractorPullController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/tractorPull.html\'"></div>'
      )
      bodyElement.append(tractorPullContainer)
      $compile(tractorPullContainer)($rootScope)
    }
    if (!document.getElementById('dakar-start-overlay-container')) {
      const dakarStartContainer = angular.element(
        '<div id="dakar-start-overlay-container" ng-controller="DakarStartController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/dakarStart.html\'"></div>'
      )
      bodyElement.append(dakarStartContainer)
      $compile(dakarStartContainer)($rootScope)
    }
    if (!document.getElementById('dakar-compass-overlay-container')) {
      const dakarCompassContainer = angular.element(
        '<div id="dakar-compass-overlay-container" ng-controller="DakarCompassController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/dakarCompass.html\'"></div>'
      )
      bodyElement.append(dakarCompassContainer)
      $compile(dakarCompassContainer)($rootScope)
    }
    if (!document.getElementById('road-authority-clear-overlay-container')) {
      const roadAuthorityClearContainer = angular.element(
        '<div id="road-authority-clear-overlay-container" ng-controller="RoadAuthorityClearController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/roadAuthorityClear.html\'"></div>'
      )
      bodyElement.append(roadAuthorityClearContainer)
      $compile(roadAuthorityClearContainer)($rootScope)
    }
    if (!document.getElementById('cleanup-club-prompt-overlay-container')) {
      const cleanupClubPromptContainer = angular.element(
        '<div id="cleanup-club-prompt-overlay-container" ng-controller="CleanupClubPromptController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/cleanupClubPrompt.html\'"></div>'
      )
      bodyElement.append(cleanupClubPromptContainer)
      $compile(cleanupClubPromptContainer)($rootScope)
    }
    if (!document.getElementById('road-authority-intro-overlay-container')) {
      const roadAuthorityIntroContainer = angular.element(
        '<div id="road-authority-intro-overlay-container" ng-controller="RoadAuthorityIntroController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/roadAuthorityIntro.html\'"></div>'
      )
      bodyElement.append(roadAuthorityIntroContainer)
      $compile(roadAuthorityIntroContainer)($rootScope)
    }
    if (!document.getElementById('dakar-finish-overlay-container')) {
      const dakarFinishContainer = angular.element(
        '<div id="dakar-finish-overlay-container" ng-controller="DakarFinishController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/dakarFinish.html\'"></div>'
      )
      bodyElement.append(dakarFinishContainer)
      $compile(dakarFinishContainer)($rootScope)
    }
    if (!document.getElementById('career-fast-travel-overlay-container')) {
      const fastTravelContainer = angular.element(
        '<div id="career-fast-travel-overlay-container" ng-controller="CareerFastTravelController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/fastTravel.html\'"></div>'
      )
      bodyElement.append(fastTravelContainer)
      $compile(fastTravelContainer)($rootScope)
    }
    if (!document.getElementById('mining-haul-overlay-container')) {
      const miningHaulContainer = angular.element(
        '<div id="mining-haul-overlay-container" ng-controller="MiningHaulController" ng-include="\'/ui/modModules/overhaulFreeroamRaceHud/miningHaul.html\'"></div>'
      )
      bodyElement.append(miningHaulContainer)
      $compile(miningHaulContainer)($rootScope)
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeFreeroamRaceHudOverlay)
  } else {
    window.setTimeout(initializeFreeroamRaceHudOverlay, 300)
  }
})

export default freeroamRaceHudModule

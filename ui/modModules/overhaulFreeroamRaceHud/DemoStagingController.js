import { luaLiteral } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/luaLiteral.js'
import { createSafeApply } from '../../modules/overhaulAngular/safeApply.js'
function computeEffectiveWinnerRepairInsurance($scope) {
  return $scope.winnerRepairInsuranceSelected === true
    && $scope.winnerRepairInsuranceAvailable === true
    && $scope.selectedMode !== 'loaner'
}

function refreshSelectedModeSummary($scope) {
  var options = Array.isArray($scope.modeOptions) ? $scope.modeOptions : []
  var selected = null
  for (var i = 0; i < options.length; i++) {
    if (options[i] && options[i].key === $scope.selectedMode) {
      selected = options[i]
      break
    }
  }
  if (!selected && options.length > 0) {
    selected = options[0]
    $scope.selectedMode = selected.key
  }
  $scope.entryFee = selected ? Math.max(0, Math.floor(Number(selected.entryFee) || 0)) : 0
  var grossPreview = selected ? Math.max(0, Math.floor(Number(selected.rewardPreview) || 0)) : 0
  if (grossPreview <= 0 && selected) {
    var basePreview = Math.max(0, Number(selected.rewardBase) || 0)
    var perAiPreview = Math.max(0, Number(selected.rewardPerAi) || 0)
    var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
    grossPreview = Math.max(0, Math.floor(basePreview + (perAiPreview * aiCount)))
  }
  $scope.rewardPreview = grossPreview
  var repairCut = 0
  if (computeEffectiveWinnerRepairInsurance($scope)) {
    var pct = Math.max(0, Math.min(100, Number($scope.winnerRepairInsurancePercent) || 0))
    repairCut = Math.max(0, Math.floor((grossPreview * pct / 100) + 0.5))
  }
  $scope.repairCutPreview = repairCut
  $scope.netRewardPreview = Math.max(0, grossPreview - repairCut)
}

// Maps one DemoStagingUi payload onto the scope. A hidden payload only clears the visible flag and the intro checkbox.
function applyDemoStagingPayload($scope, data) {
  $scope.dmsVisible = !!(data && data.visible)
  if (!data || !data.visible) {
    $scope.intro.dontShowAgain = false
    return
  }
  if (data && data.eventKey) {
    $scope.eventKey = data.eventKey
  }
  if (data && data.label) {
    $scope.eventLabel = data.label
  }
  if (data && data.phase) {
    $scope.phase = data.phase
  }
  if (data.introTitle) {
    $scope.introTitle = data.introTitle
  }
  if (data.introSubtitle) {
    $scope.introSubtitle = data.introSubtitle
  }
  if (data.introBody) {
    $scope.introBody = data.introBody
  }
  if (data && Array.isArray(data.introFeatures)) {
    $scope.introFeatures = data.introFeatures
  }
  if (data.introContinueLabel) {
    $scope.introContinueLabel = data.introContinueLabel
  }
  if (data && Array.isArray(data.modeOptions)) {
    $scope.modeOptions = data.modeOptions
  }
  if (data && data.selectedMode) {
    $scope.selectedMode = data.selectedMode
  }
  if (data && typeof data.winnerRepairInsuranceAvailable === 'boolean') {
    $scope.winnerRepairInsuranceAvailable = data.winnerRepairInsuranceAvailable
  }
  if (data && typeof data.winnerRepairInsuranceSelected === 'boolean') {
    $scope.winnerRepairInsuranceSelected = data.winnerRepairInsuranceSelected
  }
  if (data && typeof data.winnerRepairInsurancePercent === 'number') {
    $scope.winnerRepairInsurancePercent = Math.max(0, Math.min(100, Math.floor(data.winnerRepairInsurancePercent)))
  }
  if (data && typeof data.maxAi === 'number') {
    var maxAi = Math.max(0, Math.floor(data.maxAi))
    var opts = []
    for (var i = 1; i <= maxAi; i++) {
      opts.push(i)
    }
    $scope.aiOptions = opts
    var currentAiCount = Math.max(0, Math.floor(Number($scope.aiCount) || 0))
    $scope.aiCount = Math.min(currentAiCount, maxAi)
  }
  if (data && typeof data.aiCount === 'number') {
    $scope.aiCount = Math.max(0, Math.floor(data.aiCount))
  }
  var hasNoAiSlots = data && typeof data.maxAi === 'number' && Math.floor(data.maxAi) <= 0
  $scope.startEnabled = !(data && data.startEnabled === false) && !hasNoAiSlots
  if (hasNoAiSlots && !(data && data.startDisabledReason)) {
    $scope.startDisabledReason = 'No parking spots available for AI opponents.'
  } else {
    $scope.startDisabledReason = data && data.startDisabledReason ? String(data.startDisabledReason) : ''
  }
  refreshSelectedModeSummary($scope)
}

angular.module('beamng.stuff')
.controller('DemoStagingController', ['$scope', '$rootScope', function($scope, $rootScope) {
  const angularRootScope = window.globalAngularRootScope || $rootScope
  $scope.dmsVisible = false
  $scope.aiCount = 6
  $scope.aiOptions = []
  $scope.eventKey = ''
  $scope.eventLabel = 'Demolition Derby'
  $scope.startEnabled = true
  $scope.startDisabledReason = ''
  $scope.phase = 'configure'
  $scope.modeOptions = []
  $scope.selectedMode = 'loaner'
  $scope.entryFee = 0
  $scope.rewardPreview = 0
  $scope.repairCutPreview = 0
  $scope.netRewardPreview = 0
  $scope.winnerRepairInsuranceAvailable = false
  $scope.winnerRepairInsuranceSelected = false
  $scope.winnerRepairInsurancePercent = 50
  $scope.introTitle = ''
  $scope.introSubtitle = ''
  $scope.introBody = ''
  $scope.introFeatures = []
  $scope.introContinueLabel = 'Continue'
  $scope.intro = { dontShowAgain: false }

  const safeApply = createSafeApply($scope)

  $scope.setAiCount = function(n) {
    $scope.aiCount = n
    refreshSelectedModeSummary($scope)
    requestModeAvailability()
  }

  $scope.setMode = function(modeKey) {
    $scope.selectedMode = modeKey
    if (modeKey === 'loaner') {
      $scope.winnerRepairInsuranceSelected = false
    }
    refreshSelectedModeSummary($scope)
    requestModeAvailability()
  }

  $scope.toggleWinnerRepairInsurance = function() {
    $scope.winnerRepairInsuranceSelected = !$scope.winnerRepairInsuranceSelected
    refreshSelectedModeSummary($scope)
    requestModeAvailability()
  }

  function requestModeAvailability() {
    if (typeof bngApi === 'undefined' || !$scope.dmsVisible || $scope.phase !== 'configure') {
      return
    }
    var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
    var modeKey = encodeLuaString($scope.selectedMode)
    var insuranceArg = computeEffectiveWinnerRepairInsurance($scope) ? 'true' : 'false'
    bngApi.engineLua('overhaul_events_derby_derby.refreshStagingAvailability(' + modeKey + ', ' + aiCount + ', ' + insuranceArg + ')')
  }

  const encodeLuaString = value => luaLiteral(value == null ? '' : String(value))

  $scope.startEvent = function() {
    if (!$scope.startEnabled) {
      return
    }
    if (typeof bngApi !== 'undefined') {
      var aiCount = Math.max(1, Math.floor(Number($scope.aiCount) || 1))
      var eventKey = encodeLuaString($scope.eventKey)
      var modeKey = encodeLuaString($scope.selectedMode)
      if ($scope.phase === 'ready') {
        bngApi.engineLua('overhaul_events_derby_derby.beginCountdown()')
      } else {
        var insuranceArg = computeEffectiveWinnerRepairInsurance($scope) ? 'true' : 'false'
        bngApi.engineLua('overhaul_events_derby_derby.startEvent(' + aiCount + ', ' + eventKey + ', ' + modeKey + ', ' + insuranceArg + ')')
      }
    }
  }

  $scope.cancelStaging = function() {
    $scope.dmsVisible = false
    $scope.intro.dontShowAgain = false
    if (typeof bngApi !== 'undefined') {
      bngApi.engineLua('overhaul_events_derby_derby.cancelStaging()')
    }
  }

  $scope.continueIntro = function() {
    if (typeof bngApi !== 'undefined') {
      var eventKey = encodeLuaString($scope.eventKey)
      if ($scope.intro.dontShowAgain && $scope.eventKey) {
        bngApi.engineLua('if overhaul_career_guide_guide then overhaul_career_guide_guide.markDemoIntroSkipped(' + eventKey + ') end')
      }
      bngApi.engineLua('overhaul_events_derby_derby.dismissDemoIntro(false, ' + eventKey + ')')
    }
    $scope.intro.dontShowAgain = false
  }

  const dmsListener = angularRootScope.$on('DemoStagingUi', function(_evt, data) {
    safeApply(function() {
      applyDemoStagingPayload($scope, data)
    })
  })

  $scope.$on('$destroy', function() {
    dmsListener()
  })
}])

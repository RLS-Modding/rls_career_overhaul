import { ref, computed, readonly } from 'vue'
import { lua } from '@/bridge'
import { isPhoneShellVisible } from '../utils/phoneShellState'

/** @typedef {'next' | 'tap' | 'done'} PhoneTutorialAdvance} */

/**
 * @typedef {Object} PhoneTutorialStep
 * @property {string} id
 * @property {string} [appId]
 * @property {'dock' | 'homescreen' | 'in-app'} [target]
 * @property {string} [targetId]
 * @property {PhoneTutorialAdvance} advance
 * @property {string} [label]
 * @property {string} title
 * @property {string} body
 * @property {string} [cta]
 * @property {boolean} [showBinding]
 * @property {string} [route]
 */

/** @type {PhoneTutorialStep[]} */
export const PHONE_TUTORIAL_STEPS = [
  {
    id: 'app-store',
    appId: 'app-store',
    target: 'dock',
    advance: 'next',
    label: 'App Store',
    title: 'Download apps',
    body: 'The App Store is where you grab new apps for jobs, finance, vehicles, and more. Everything you install shows up on your home screen.',
  },
  {
    id: 'skills',
    appId: 'skills',
    target: 'dock',
    advance: 'next',
    label: 'Skills',
    title: 'Track your progress',
    body: 'Skills unlock jobs, features, and opportunities as you play. Check here to see what you have access to and what to work toward next.',
  },
  {
    id: 'market-watch',
    appId: 'market-watch',
    target: 'dock',
    advance: 'next',
    label: 'Market Watch',
    title: 'Follow the economy',
    body: 'Market Watch tracks prices, demand, and trends across the career economy. Use it to spot good deals and plan your next move.',
  },
  {
    id: 'settings',
    appId: 'settings',
    target: 'dock',
    advance: 'next',
    label: 'Settings',
    title: 'Make it yours',
    body: 'Adjust phone size, wallpaper, notifications, and more. Tune the phone so it fits how you play.',
  },
  {
    id: 'employment',
    appId: 'employment',
    target: 'homescreen',
    advance: 'tap',
    label: 'Employment',
    title: 'Job opportunities',
    body: 'Employment lists company jobs on this map. Apply to a yard, clock in for assigned work, and end your day from the yard when you are done.',
    cta: 'Tap Employment to continue',
  },
  {
    id: 'employment-apply',
    target: 'in-app',
    targetId: 'employment-listings',
    advance: 'next',
    route: 'phone-employment',
    label: 'Apply',
    title: 'Start working',
    body: 'Apply to a company to start assigned loads. You may only apply to jobs you have the skill level for. The work to be performed is listed along with the skill level needed on the detail screen.',
  },
  {
    id: 'vehicle-transfer',
    appId: 'vehicle-transfer',
    target: 'homescreen',
    advance: 'tap',
    label: 'CarGo',
    title: 'Car Jockey gigs',
    body: 'CarGo assigns lot-to-lot drive-offs from the nearest available vehicle. Pay settles on each drop-off.',
    cta: 'Tap CarGo to continue',
  },
  {
    id: 'vehicle-transfer-day',
    target: 'in-app',
    targetId: 'vehicle-transfer-controls',
    advance: 'next',
    route: 'phone-vehicle-transfer',
    label: 'Start day',
    title: 'Run a transfer day',
    body: 'Start day stages the nearest vehicle. After each drop-off the next one starts automatically. End day anytime to stop.',
  },
  {
    id: 'guide',
    appId: 'guide',
    target: 'homescreen',
    advance: 'tap',
    label: 'Wiki',
    title: 'Your in-game manual',
    body: 'The Wiki explains career features, systems, and what is new. Open it whenever you need a refresher.',
    cta: 'Tap Wiki to continue',
  },
  {
    id: 'guide-open',
    advance: 'done',
    route: 'phone-guide',
    title: 'Come back anytime',
    body: 'Browse the Wiki whenever you are unsure how something works. New topics get added as the career grows.',
    showBinding: true,
  },
]

const stepIndex = ref(/** @type {number | null} */ (null))
const phoneBindingLabel = ref('your phone key')
const dockReadyTick = ref(0)
const phoneVisibleTick = ref(0)
const phoneSessionVisible = ref(false)

function readPhoneSessionVisible() {
  return isPhoneShellVisible()
}

export function usePhoneTutorial() {
  const isActive = computed(() => stepIndex.value !== null)

  const currentStep = computed(() => {
    if (stepIndex.value === null) return null
    return PHONE_TUTORIAL_STEPS[stepIndex.value] ?? null
  })

  const tutorialHighlightAppId = computed(() => currentStep.value?.appId ?? null)
  const tutorialBlockLaunches = computed(() => isActive.value && phoneSessionVisible.value)
  const tutorialLaunchAppId = computed(() => {
    const step = currentStep.value
    if (step?.advance === 'tap' && step.appId) return step.appId
    return null
  })

  const tutorialTargetSelector = computed(() => {
    const step = currentStep.value
    if (!step) return null
    if (step.target === 'dock' && step.appId) {
      return `[data-tutorial-id="dock-${step.appId}"]`
    }
    if (step.target === 'homescreen' && step.appId) {
      return `[data-tutorial-id="homescreen-${step.appId}"]`
    }
    if (step.target === 'in-app' && step.targetId) {
      return `[data-tutorial-id="${step.targetId}"]`
    }
    return null
  })

  function resetTutorialState() {
    stepIndex.value = null
  }

  function startTutorial(payload) {
    stepIndex.value = 0
    const binding = payload?.binding
    if (binding && binding !== 'Not bound') {
      phoneBindingLabel.value = binding
    } else {
      phoneBindingLabel.value = 'your phone key'
    }
  }

  function advanceNext() {
    if (stepIndex.value === null) return
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (!step || step.advance !== 'next') return
    if (stepIndex.value + 1 < PHONE_TUTORIAL_STEPS.length) {
      stepIndex.value += 1
    }
  }

  function advanceAfterTap(appId) {
    if (stepIndex.value === null) return
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (step?.advance !== 'tap' || step.appId !== appId) return
    if (stepIndex.value + 1 < PHONE_TUTORIAL_STEPS.length) {
      stepIndex.value += 1
    }
  }

  function advanceAfterGuideTap() {
    advanceAfterTap('guide')
  }

  function advanceAfterEmploymentTap() {
    advanceAfterTap('employment')
  }

  function advanceAfterVehicleTransferTap() {
    advanceAfterTap('vehicle-transfer')
  }

  /** Backup if homescreen launch hook did not run before the route mounted. */
  function tryAdvanceOnRoute(routeName, tapStepId) {
    if (stepIndex.value === null) return false
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (step?.id === tapStepId) {
      stepIndex.value += 1
      return true
    }
    return step?.route === routeName
  }

  function tryAdvanceOnGuideRoute() {
    return tryAdvanceOnRoute('phone-guide', 'guide')
  }

  function tryAdvanceOnEmploymentRoute() {
    return tryAdvanceOnRoute('phone-employment', 'employment')
  }

  function tryAdvanceOnVehicleTransferRoute() {
    return tryAdvanceOnRoute('phone-vehicle-transfer', 'vehicle-transfer')
  }

  async function finishTutorial() {
    stepIndex.value = null
    try {
      await lua.overhaul_career_guide_guide?.markPhoneTutorialComplete?.()
    } catch (_) {
      // ignore bridge errors in non-career contexts
    }
  }

  function isLaunchAllowed(appId) {
    if (stepIndex.value === null) return true
    const step = currentStep.value
    if (step?.advance === 'tap' && step.appId === appId) return true
    return false
  }

  function shouldBlockPhoneBack() {
    if (!isActive.value || !phoneSessionVisible.value) return false
    const step = currentStep.value
    if (step?.id === 'vehicle-transfer-day' || step?.id === 'guide' || step?.id === 'guide-open') {
      return false
    }
    return true
  }

  function shouldBlockPhoneClose() {
    if (!isActive.value || !phoneSessionVisible.value) return false
    const step = currentStep.value
    if (step?.id === 'vehicle-transfer-day' || step?.id === 'guide' || step?.id === 'guide-open') {
      return false
    }
    return true
  }

  function notifyDockReady() {
    dockReadyTick.value++
  }

  function notifyPhoneVisible() {
    phoneSessionVisible.value = readPhoneSessionVisible()
    phoneVisibleTick.value++
  }

  function shouldShowTutorialOverlay(routeName) {
    if (stepIndex.value === null) return false
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (!step) return false
    if (step.route) {
      return routeName === step.route
    }
    return routeName === 'phone-main'
  }

  return {
    stepIndex: readonly(stepIndex),
    currentStep,
    isActive,
    phoneBindingLabel: readonly(phoneBindingLabel),
    dockReadyTick: readonly(dockReadyTick),
    phoneVisibleTick: readonly(phoneVisibleTick),
    tutorialHighlightAppId,
    tutorialBlockLaunches,
    tutorialLaunchAppId,
    tutorialTargetSelector,
    PHONE_TUTORIAL_STEPS,
    resetTutorialState,
    startTutorial,
    advanceNext,
    advanceAfterGuideTap,
    advanceAfterEmploymentTap,
    advanceAfterVehicleTransferTap,
    tryAdvanceOnGuideRoute,
    tryAdvanceOnEmploymentRoute,
    tryAdvanceOnVehicleTransferRoute,
    finishTutorial,
    notifyDockReady,
    notifyPhoneVisible,
    isLaunchAllowed,
    shouldBlockPhoneBack,
    shouldBlockPhoneClose,
    shouldShowTutorialOverlay,
  }
}

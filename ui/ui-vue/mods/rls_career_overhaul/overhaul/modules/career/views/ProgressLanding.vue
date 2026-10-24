<!-- Landing Page -->
<template>
  <ProgressView
    :skill-info="landingData.skillInfo"
    :heading-text="$t(pageHeading)"
    :breadcrumb-items="breadcrumbItems"
    :branch-style="branchStyle"
    :nav-options="navOptions"
    @breadcrumb-click="gotoHeaderItem"
    @breadcrumb-back="onBreadBack"
  >
    <template #description>
      <div class="description-text">{{ $t(pageDescription) }}</div>
    </template>

    <template #default>

      <div class="progress-content-scope">
        <div class="cards-container grid-view">
        <BranchSkillCard
          v-for="(branch, index) in BRANCHES"
          :key="branch.id"
          v-bng-sound-class="'bng_click_hover_generic'"
          :branchKey="branch.id"
          :autofocus="isAutofocusBranch(branch.id, index)"
          @ready="onBranchCardReady"
          @openBranchPage="openBranchPage"
          @mouseenter="onBranchFocus(branch)"
          @mouseleave="onBranchBlur"
          @focusin="onBranchFocus(branch)"
          @focusout="onBranchBlur"
          display-mode="row"
          :class="{ 'full-width': !isHalfBranch(branch) }" />
      </div>
      <div
        v-if="currentSkillToShow && currentSkillToShow.hasLevels && currentSkillToShow.unlockInfo && currentSkillToShow.unlockInfo.length && !currentSkillToShow.isInDevelopment"
        class="page-progress">
        <UnlockRows v-if="currentSkillToShow.hasUnlocks"
          class="stat-progress-bar bng-progress-bar progress-bar"
          :headerLeft="$ctx_t(currentSkillToShow.name)"
          :headerRight="$ctx_t(currentSkillToShow.levelLabel)"
          :value="currentSkillToShow.value"
          :max="currentSkillToShow.max"
          :min="currentSkillToShow.min"
          :maxRequiredValue="currentSkillToShow.maxRequiredValue"
          :tiers="currentSkillToShow.unlockInfo"
          :currentTier="currentSkillToShow.unlocked ? currentSkillToShow.level : -1"
          :unlocked="currentSkillToShow.unlocked"
          :progressFillColor="currentSkillToShow.accentColor"
        />
      </div>
      </div>
    </template>
  </ProgressView>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { BngCard, BngIcon, icons } from "@/common/components/base"
import { vBngSoundClass } from "@/common/directives"
import BranchSkillCard from "../components/progress/BranchSkillCard.vue"
import UnlockRows from "@/modules/career/components/progress/UnlockRows.vue"
import ProgressView from "../components/ProgressView.vue"
import { ref, onBeforeMount, onMounted, computed, onUnmounted, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import { getBranchColorStyle } from "@/utils/colorUtils"
import { $translate } from "@/services/translation"
import { useRouteDataStore } from "@/services/routeData"
import { useScopedNav } from "@/services/scopedNav/api"

const props = defineProps({
  pathId: String
})

const PROGRESS_BRANCH_SCOPE_ID = "root"
const AUTO_FOCUS_BRANCH_SELECTOR = "[bng-scoped-nav-autofocus='true']"
// Focus/container behavior for the route-managed root scope owned by LayoutMenu.
const navOptions = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
}
const routeDataStore = useRouteDataStore()
const scopedNav = useScopedNav()
const currentPathId = computed(() => routeDataStore.route?.params?.pathId ?? props.pathId)
const returnRoute = computed(() => routeDataStore.route?.params?.returnRoute)
const focusPathId = computed(() => routeDataStore.route?.params?.focusPathId)
const isPauseCareerBranchRoute = computed(() => String(routeDataStore.routeName || "").startsWith("pause.career.branch"))
const progressRootRouteName = computed(() => isPauseCareerBranchRoute.value ? "pause.career" : "overhaul.domainSelection")
const branchRouteName = computed(() => isPauseCareerBranchRoute.value ? "pause.career.branch" : "overhaul.branchPage")
const withReturnRoute = params => {
  if (!returnRoute.value) return params
  return { ...params, returnRoute: returnRoute.value }
}

function normalizeProgressBreadcrumbs(breadcrumbs) {
  if (!isPauseCareerBranchRoute.value || !Array.isArray(breadcrumbs)) return breadcrumbs
  const normalized = breadcrumbs.map(item => {
    if (item?.routeName === "overhaul.domainSelection") {
      return { ...item, routeName: "pause.career" }
    }
    if (item?.routeName === "overhaul.progressLanding" || item?.routeName === "overhaul.branchPage") {
      return { ...item, routeName: "pause.career.branch" }
    }
    return item
  })
  return normalized
}

const landingData = ref({
  heading: "Skills",
  description: "ui.career.landingPage.description",
  branches: [],
  showMilestones: true,
  showOrganizations: true
})

const fetchLandingData = async () => {
  const pathId = currentPathId.value
  landingData.value = {
    heading: "Skills",
    description: "ui.career.landingPage.description",
    branches: [],
    showMilestones: true,
    showOrganizations: true
  }
  const data = await lua.overhaul_career_progression_skillsPage.getLandingPageData(pathId)
  if (pathId !== currentPathId.value) return
  landingData.value = data

  if(data.breadcrumbs) {
    screenHeaderPath.value = normalizeProgressBreadcrumbs(data.breadcrumbs)

  }
}


const hasUnclaimedMilestones = ref(false)
onMounted(async () => {
  await fetchLandingData()
  lua.overhaul_career_progression_milestones_milestones.unclaimedMilestonesCount().then((c) => hasUnclaimedMilestones.value = c)
  focusBranchCards()
})

onBeforeMount(() => {
  lua.simTimeAuthority.pushPauseRequest('progressLanding')
})

onUnmounted(() => {
  lua.simTimeAuthority.popPauseRequest('progressLanding')
})

// Watch for canonical Lua pathId changes and refetch data when navigating between landing pages.
watch(currentPathId, async (newPathId, oldPathId) => {
  if (newPathId !== oldPathId) {
    await fetchLandingData()
    lua.overhaul_career_progression_milestones_milestones.unclaimedMilestonesCount().then((c) => hasUnclaimedMilestones.value = c)
    focusBranchCards()
  }
})

watch(focusPathId, () => {
  focusBranchCards()
})

const branchStyle = computed(() => {
  if (!landingData.value.skillInfo) {
    return {
      '--branch-accent-color': 'var(--bng-cool-gray-500-rgb)',
      '--branch-color': 'var(--bng-cool-gray-500-rgb)'
    }
  }

  return getBranchColorStyle({
    color: landingData.value.skillInfo.color,
    accentColor: landingData.value.skillInfo.accentColor
  })
})

const pageHeading = computed(() => landingData.value.branchHeading || landingData.value.heading)
const currentDescription = ref(null)
const pageDescription = computed(() =>
  currentDescription.value || landingData.value.description
)
const BRANCHES = computed(() => {
  const branches = landingData.value.branches
  if (Array.isArray(branches)) return branches
  // Lua sends an empty table as {} which the bridge deserializes to an object, not an array.
  if (branches && typeof branches === "object") return Object.values(branches)
  return []
})
const getFocusTargetBranch = () => {
  const targetBranchId = focusPathId.value || BRANCHES.value[0]?.id
  return BRANCHES.value.find(branch => branch.id === targetBranchId) || null
}
const isAutofocusBranch = (branchId, index) => {
  if (focusPathId.value) {
    return branchId === focusPathId.value
  }
  return index === 0
}

const focusBranchCards = async () => {
  await nextTick()
  const selector = focusPathId.value ? `[data-branch-id="${focusPathId.value}"]` : AUTO_FOCUS_BRANCH_SELECTOR
  scopedNav.requestScopeFocus(PROGRESS_BRANCH_SCOPE_ID, selector, {
    activeOnly: false,
    force: true,
    reason: focusPathId.value ? "career-branch-back-focus" : "career-branch-default-focus",
  })
  const focusedBranch = getFocusTargetBranch()
  if (focusedBranch) {
    onBranchFocus(focusedBranch)
  }
}

const onBranchCardReady = branchId => {
  if (branchId === getFocusTargetBranch()?.id) {
    focusBranchCards()
  }
}

const openBranchPage = branchKey => {

  lua.extensions.ui_router.navigate(branchRouteName.value, withReturnRoute({ pathId: branchKey }), null)
}



const onBranchFocus = (branch) => {
  currentDescription.value = branch.description
}

const onBranchBlur = () => {
  currentDescription.value = null
}

const isHalfBranch = (branch) => {
  const hasSkills = branch.skills && branch.skills.length > 0
  const hasDescription = branch.shortDescription
  return !hasSkills && !hasDescription
}

const currentSkillToShow = computed(() => {
  return landingData.value.skillInfo || null
})

//breadcrumbs
const screenHeaderPath = ref([
  { label: $translate.instant("ui.environment.pause"), routeName: "pause" },
  { label: landingData.value.heading, routeName: progressRootRouteName.value }
])
// Prefer router-provided breadcrumbs; fall back to the locally built trail until the store is populated.
const breadcrumbItems = computed(() => {
  const routerCrumbs = routeDataStore.breadcrumbs
  if (Array.isArray(routerCrumbs) && routerCrumbs.length) {
    return normalizeProgressBreadcrumbs(routerCrumbs)
  }
  return screenHeaderPath.value
})
const gotoHeaderItem = (item, options = {}) => {
  if (!item) return
  if (item.closeAllMenus) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  if (item.routeName && !item.abstract) {
    const shouldPassFocusPath =
      options.focusCurrentPath !== false &&
      isPauseCareerBranchRoute.value &&
      (item.routeName === "pause.career" || item.routeName === "pause.career.branch")
    if (shouldPassFocusPath && item.routeName === "pause.career" && typeof window !== "undefined") {
      window.__pauseCareerFocusPathId = currentPathId.value
    }
    const params = shouldPassFocusPath
      ? withReturnRoute({ ...(item.params || {}), focusPathId: currentPathId.value })
      : item.params
    lua.extensions.ui_router.navigate(item.routeName, params || null, null)
    return
  }
  if (item.gotoAngularState) {
    window.bngVue.gotoAngularState(item.gotoAngularState)
  }
}

const onBreadBack = () => lua.extensions.ui_router.back()

</script>

<style lang="scss" scoped>
.description-text {
  font-size: 1.2rem;
  line-height: 1.2;
  height: 3rem;
  align-content: center;
  text-align: left;
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  text-overflow: ellipsis;
}

.page-progress {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  justify-items: center;
  gap: 1rem;
  padding: 0.5rem;
  padding-bottom: 0;
}

.progress-content-scope {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  padding-top: 0.25rem;
}

.cards-container {
  flex: 0 auto;
  padding: 0 0.5rem ;
  :deep(.stat-progress-bar) {
    font-size: 1.25rem;
  }

  &.grid-view {
    display: grid;
    grid-template-columns: 1fr 1fr ;
    gap: 0.5rem;
    align-items: stretch;
    grid-auto-flow: row dense;
    grid-auto-rows: min-content;

    > * {
        grid-column: span 2;
    }
  }
}

.buttons-container {
  display: flex;
  justify-content: center;
  padding: 0.5rem;
  padding-top: 0rem;
  cursor: pointer;

  > * {
    flex: 1 1 auto;
    padding: 0.5rem;
    padding-top: 0rem;
    max-width: 32rem;
  }

  > .milestone-button {
    padding: 0;
  }

  .indicator {
    width: 0.75rem;
    height: 0.75rem;
    background-color: yellow;
    border-radius: 50%;
    position: absolute;
    top: 0.35rem;
    right: 1rem;
  }

  :deep(.content) {
    &:focus,
    &:hover {
      background-color: rgba(var(--bng-cool-gray-800-rgb), 0.9) !important;
    }
    display: flex;
    flex-direction: row;
    justify-content: center;
    align-items: center;

    .icon {
      font-size: 3rem;
      padding-right: 1rem;
    }
    .label {
      font-size: 1.5rem;
    }
  }
}
</style>

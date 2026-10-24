<!-- Milestones -->
<template>
  <LayoutMenu
    class="milestones-layout"
    nav-scope="root"
    :nav-active="false"
    :breadcrumbs="breadcrumbItems"
    :hide-breadcrumb-last-item="false"
    :heading="$translate.instant('ui.career.milestones.title')"
    :request-back="exit"
    :request-menu="exit"
    @breadcrumb-back="exit"
    @breadcrumb-click="breadcrumbClick"
  >
    <template #topbar-right>
      <CareerStatus class="milestones-career-status" ref="careerStatusRef" slim />
    </template>

    <div
      class="career-milestones-card"
      v-bng-on-ui-nav:tab_l="goPrevFilterTab"
      v-bng-on-ui-nav:tab_r="goNextFilterTab"
    >
      <Background class="career-milestones-bg" />
      <div class="career-milestones-container">
        <div v-if="!dataLoaded" class="milestones-loading">
          <BngProgressBar
            :max="100"
            :show-value-label="false"
            indeterminate
          />
          <span>{{ $translate.instant("ui.common.loading") }}</span>
        </div>
        <div v-else class="career-milestones-content">
          <div class="filters" bng-no-child-nav="true">
            <BngButton
              :accent="ACCENTS.ghost"
              class="milestones-filter-tabs-arrow"
              bng-no-nav
              tabindex="-1"
              @click.stop="goPrevFilterTab"
            >
              <BngIcon :type="icons.arrowLargeLeft" />
              <BngBinding class="milestones-filter-tabs-binding" ui-event="tab_l" controller />
            </BngButton>

            <Tabs
              ref="filterTabsRef"
              class="bng-tabs milestones-filter-tabs"
              :selectedIndex="selectedFilterIndex"
              bng-no-nav
              @change="onFilterTabChange"
            >
              <TabList />
              <div
                v-for="option in filterOptions"
                :key="option.value"
                class="milestones-filter-tab-panel"
                :tab-heading="option.label"
              />
            </Tabs>

            <BngButton
              :accent="ACCENTS.ghost"
              class="milestones-filter-tabs-arrow"
              bng-no-nav
              tabindex="-1"
              @click.stop="goNextFilterTab"
            >
              <BngBinding class="milestones-filter-tabs-binding" ui-event="tab_r" controller />
              <BngIcon :type="icons.arrowLargeRight" />
            </BngButton>
          </div>
          <div class="milestones-list-scope">
            <BngList
              ref="milestonesListRef"
              big
              immediate
              :keep-alive="500"
              class="milestones-list"
              :layout="LIST_LAYOUTS.TILES"
              :tile-size-calc="milestoneTileSizeCalc"
              no-background
              nav-scroll-enabled>
              <MilestoneCard
                tabindex="1"
                v-for="(entry, index) in entries"
                :key="entry.claimId"
                :milestone="entry"
                :bng-scoped-nav-autofocus="index === 0"
                @claim="claimMilestone" />
            </BngList>
          </div>
        </div>
      </div>
    </div>
  </LayoutMenu>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue"
import { LayoutMenu } from "@/common/layouts"
import { BngList, LIST_LAYOUTS, BngButton, BngBinding, BngIcon, BngProgressBar, ACCENTS, icons } from "@/common/components/base"
import { Background, Tabs, TabList } from "@/common/components/utility"
import { vBngOnUiNav } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useRouteDataStore } from "@/services/routeData"
import { useRouteReady } from "@/services/routeReadiness"
import { useScopedNav } from "@/services/scopedNav/api"
import { $translate } from "@/services/translation"
import CareerStatus from "../components/careerStatus.vue"
import MilestoneCard from "../components/milestones/MilestoneCard.vue"

const ROOT_SCOPE_ID = "root"
const AUTO_FOCUS_SELECTOR = "[bng-scoped-nav-autofocus]"

const { events } = useBridge()
const { requestScopeFocus } = useScopedNav()
const routeDataStore = useRouteDataStore()
const careerStatusRef = ref()
const milestonesListRef = ref()
const filterTabsRef = ref()
const dataLoaded = ref(false)
let allEntries = []
const entries = ref([])
const selectedFilterIndex = ref(0)
const filterOptions = computed(() => routeDataStore.data?.milestones?.filterOptions ?? [])

const fallbackBreadcrumbItems = computed(() => [
  { label: $translate.instant("ui.environment.pause"), routeName: "pause" },
  {
    label: $translate.instant(routeDataStore.routeName === "pause.career.milestones" ? "ui.pause.career.history" : "ui.career.landingPage.name"),
    routeName: routeDataStore.routeName === "pause.career.milestones" ? "pause.career.history" : "pause.career",
  },
  { label: $translate.instant("ui.career.milestones.title"), routeName: routeDataStore.routeName === "pause.career.milestones" ? "pause.career.milestones" : "pause.milestones" }
])
const breadcrumbItems = computed(() => routeDataStore.breadcrumbs?.length ? routeDataStore.breadcrumbs : fallbackBreadcrumbItems.value)
const milestoneTileSizeCalc = ctx => MilestoneCard.getSizeCalc()(ctx)

function sortMilestones() {
  entries.value.sort(function (a, b) {
    if (a.claimable && !b.claimable) return -1 // a is claimable, b is not, so a should come first
    if (b.claimable && !a.claimable) return 1 // b is claimable, a is not, so b should come first
    if (!a.completed && b.completed) return -1 // a is not completed, b is completed, so a should come first
    if (a.completed && !b.completed) return 1 // b is not completed, a is completed, so b should come first
    // If both are claimable or both are completed, sort by claimId
    if (a.claimId < b.claimId) return -1 // a's claimId is smaller, so it should come first
    return 1 // b's claimId is smaller or equal, so it should come first or be equal
  })
}

function getCurrentFilter() {
  return filterOptions.value[selectedFilterIndex.value]?.value ?? "general"
}

function filterEntries() {
  const currentFilter = getCurrentFilter()
  if (currentFilter == "all") {
    entries.value = allEntries.filter(e => true)
  } else {
    entries.value = allEntries.filter(e => e.filter[currentFilter])
  }
  sortMilestones()
}

async function onFilterTabChange(tab) {
  if (typeof tab?.index === "number") {
    selectedFilterIndex.value = tab.index
  }
  filterEntries()
  await focusFirstMilestoneSoon("milestones-filter-tab-change")
}

function goPrevFilterTab() {
  filterTabsRef.value?.goPrev?.()
}

function goNextFilterTab() {
  filterTabsRef.value?.goNext?.()
}

async function scrollMilestonesToStart() {
  await nextTick()
  await milestonesListRef.value?.scrollToIndex?.(0)
}

async function focusFirstMilestoneSoon(reason = "milestones-filter-tab-change") {
  await scrollMilestonesToStart()
  if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
    await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
  }
  requestScopeFocus(ROOT_SCOPE_ID, AUTO_FOCUS_SELECTOR, { reason })
}

function setup(data) {
  allEntries = data.list
  let hasClaimable = false
  data.list.forEach((x) => {if(x.claimable) hasClaimable=true})
  if (hasClaimable) {
    selectedFilterIndex.value = filterOptions.value.findIndex(o => o.value === "all")
  }
  filterEntries()
  scrollMilestonesToStart()
  dataLoaded.value = true
}

function onMilestoneClaimed({ claimId, replacementEntry }) {
  careerStatusRef.value.updateDisplay()
  const replacementId = allEntries.findIndex(item => item.claimId === claimId)

  if (replacementEntry !== undefined && replacementEntry !== null && replacementId !== -1) {
    allEntries[replacementId] = replacementEntry
    filterEntries()
    return
  }

  allEntries[replacementId].claimable = false
  filterEntries()
}

events.on("milestonesData", setup)
events.on("milestoneClaimed", onMilestoneClaimed)

onMounted(() => {
  lua.overhaul_career_progression_milestones_milestones.requestMilestones()
})

onUnmounted(() => {
  events.off("milestonesData", setup)
  events.off("milestoneClaimed", onMilestoneClaimed)
})

useRouteReady({
  async waitUntilReady() {
    if (!dataLoaded.value) {
      await new Promise(resolve => {
        const stop = watch(dataLoaded, ready => {
          if (!ready) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})

const claimMilestone = entry => lua.overhaul_career_progression_milestones_milestones.claim(entry.claimId)

const exit = async () => {
  await lua.extensions.ui_router.back()
}

async function breadcrumbClick(item) {
  if (!item) return
  if (item.closeAllMenus) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  if (item.routeName && !item.abstract) {
    await lua.extensions.ui_router.navigate(item.routeName, item.params)
  }
}
</script>

<style lang="scss" scoped>
$fontsize: 1rem;

.milestones-layout {
  display: flex;
  flex-direction: column;
  height: 100%;
  width: 100%;
  color: var(--bng-off-white);
  font-size: $fontsize;
}

.milestones-career-status {
  flex: 0 0 auto;
  background-color: rgba(var(--bng-cool-gray-900-rgb), 0.9);
  border-radius: var(--bng-corners-2);
}

.career-milestones-card {
  display: flex;
  flex: 1 1 auto;
  align-self: stretch;
  height: 100%;
  min-height: 0;
  width: 100%;
  max-width: 76rem;
  overflow: hidden;
  position: relative;
  isolation: isolate;
}

.career-milestones-bg {
  --bng-bg-enabled: var(--bng-cool-gray-900);
  --bng-bg-enabled-opacity: 0.9;
  --bng-bg-border-width: 0;
  --bng-bg-border-radius: var(--bng-corners-2);
  position: absolute;
  inset: 0;
  z-index: -1;
}

.career-milestones-container {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  height: 100%;
  border-radius: var(--bng-corners-2);
  overflow: hidden;
}

.career-milestones-content {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-height: 0;
}

.milestones-loading {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  padding: 1rem;
  color: var(--bng-cool-gray-200);
  min-height: 0;
}

.milestones-list-scope {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.milestones-list {
  flex: 1 1 auto;
  min-height: 0;
  height: 100%;
  padding: 1rem 0.25rem 1rem 0;
  scrollbar-gutter: stable;

  :deep(.list-content) {
    flex: 1 1 auto;
    overflow-y: scroll !important;
    scrollbar-gutter: stable;
  }

  :deep(.list-items) {
    padding-bottom: 1rem;
  }
}

.filters {
  flex: 0 0 auto;
  display: flex;
  flex-direction: row;
  justify-content: center;
  width: 100%;
  align-items: center;
  gap: 0.25rem;
  padding: 0.5rem 1rem;
  background-color: rgba(var(--bng-cool-gray-800-rgb), 0.35);
  border-bottom: 0.0625rem solid var(--bng-cool-gray-700);
}

.milestones-filter-tabs-arrow {
  --bng-button-margin: 0;
  --bng-button-min-width: 2.5rem;
  --bng-button-padding: 0.35rem;
  --bng-icon-size: 1.25rem;
  display: inline-flex;
  align-items: center;
  gap: 0;
  flex: 0 0 auto;
}

.milestones-filter-tabs-binding {
  pointer-events: none;
}

.milestones-filter-tabs {
  flex: 1 1 auto;
  min-width: 0;
  --tab-list-padding: 0;
  --tab-list-margin: 0;
  --tab-list-bottom-border: 0.125rem solid var(--bng-orange-500);
  --tab-list-corners: 0;
  --tab-list-justify: center;
  --tab-bg: transparent;
  --tab-content-bg: transparent;
  --bng-button-min-width: 5em;
  --bng-button-margin: 0;
  --bng-bg-border-radius: var(--bng-corners-1) var(--bng-corners-1) 0 0;
}

.milestones-filter-tab-panel {
  display: none;
}
</style>

<!-- Logbook -->
<template>
  <LayoutSingle class="logbook-layout" v-bng-blur>
    <BngScreenHeading>{{ $t("ui.career.logbook.subHeading") }}</BngScreenHeading>
    <div
      bng-ui-scope="logbook"
      class="rls-house career-logbook-wrapper"
      v-bng-on-ui-nav:back,menu="exit"
      v-bng-on-ui-nav:tab_l="sectionTabs && sectionTabs.goPrev"
      v-bng-on-ui-nav:tab_r="sectionTabs && sectionTabs.goNext">
      <div class="career-logbook-container">
        <div class="career-logbook-list">
          <Tabs ref="sectionTabs" :selected-index="selectedTabIndex" @change="tabChange" class="bng-tabs">
            <TabList>
              <template #items="{ tabs, selectTab }">
                <Button
                  v-for="tab in tabs"
                  :key="tab.index"
                  class="tab-item no-focus-frame"
                  :class="{ 'tab-active-tab': tab.active, 'no-hover': tab.active, flagged: logbookTabs[tab.index].hasNew }"
                  bng-no-nav="true"
                  @click="selectHeading(tab.index, selectTab, $event)">
                  <span>{{ tab.heading }}</span>
                </Button>
              </template>
            </TabList>
            <Tab v-for="tabDetail in logbookTabs" :key="tabDetail.id" :tab-heading="$t(tabDetail.name)">
              <div class="logbook-list-wrapper" v-bng-ui-nav-scroll>
                <p v-if="!tabDetail.entries.length" class="logbook-empty">{{ emptyTabText(tabDetail.id) }}</p>
                <div v-for="(entry, index) in tabDetail.entries" :key="entry.entryId" class="integrated-entry"
                  :class="{ expanded: selectedEntry?.entryId === entry.entryId }">
                  <LogbookActivityRow
                    v-if="tabDetail.id === 'history'"
                    :entry="entry"
                    :selected="selectedEntry?.entryId === entry.entryId"
                    v-bng-ui-nav-focus="tabDetail.entries.length - index"
                    @click="toggleExpand(entry, $event)" />
                  <button
                    v-else
                    :aria-expanded="selectedEntry?.entryId === entry.entryId"
                    type="button"
                    bng-nav-item
                    v-bng-ui-nav-focus="tabDetail.entries.length - index"
                    v-bng-sound-class="'bng_click_generic_small'"
                    class="row career-logbook-item"
                    :class="{ selected: selectedEntry !== undefined && selectedEntry.entryId == entry.entryId }"
                    @click="toggleExpand(entry, $event)">
                    <span class="row-copy">
                      <span class="career-logbook-meta">
                        <span class="caption">{{ $ctx_t(entry.cardTypeLabel) }}</span>
                        <span class="career-logbook-time" v-bng-relative-time="entry.time"></span>
                      </span>
                      <strong class="career-logbook-item-label">{{ $ctx_t(entry.title) }}</strong>
                    </span>
                    <span class="pill accent career-logbook-new" v-show="entry.isNew">{{ newLabel() }}</span>
                  </button>
                  <div v-if="selectedEntry?.entryId === entry.entryId" class="entry-content">
                    <!-- TODO - Future fix, bring these images inside the Vue code area? -->
                    <div v-if="selectedEntry.cover" class="logbook-cover-image" :style="{ backgroundImage: `url(${selectedEntry.cover})` }">
                      <h1 v-if="selectedEntry.coverText">{{ selectedEntry.coverText }}</h1>
                    </div>

                    <LogbookActivityDetails v-if="tabDetail.id === 'history' && selectedEntry.plainText" :entry="selectedEntry" />
                    <div v-else class="logbook-description">
                      <DynamicComponent v-if="selectedEntry._ready" :template="$ctx_t(selectedEntry.text)" />
                    </div>

                    <!-- only include this part if the element has a table -->
                    <div v-if="selectedEntry.tables" class="logbook-description logbook-table">
                      <table v-for="(table, keyT) in selectedEntry.tables" :key="keyT">
                        <tbody>
                          <tr>
                            <th v-for="(header, keyH) in table.headers" :key="keyH">
                              {{ header }}
                            </th>
                          </tr>
                          <tr v-for="(row, keyR) in table.rows" :key="keyR">
                            <td v-for="(data, keyD) in row" :key="keyD">
                              <RewardsPills
                                v-if="typeof data === 'object' && data !== null && data.hasOwnProperty('type') && data.type === 'rewards'"
                                :rewards="data.rewards"
                                :hideNumbers="false" />
                              <DynamicComponent v-else :template="$ctx_t(data)" />
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>

                    <!-- quest-shaped entries of older saves: their progress, read-only history (no claim, B0-07c2) -->
                    <hr v-if="selectedEntry.type === 'quest' && questProgress.length" />
                    <div v-if="selectedEntry.type === 'quest' && questProgress.length" class="logbook-description quest-status">
                      <h4>{{ $translate.instant("ui.career.logbook.milestoneStatus") }}</h4>
                      <div v-for="prog in questProgress">
                        <div class="quest-stats-wrapper">
                          <div class="quest-labels">
                            <BngIcon v-if="prog.done" class="check-icon"
                              :type="prog.failed ? icons.missionCheckboxCross : prog.done ? icons.checkboxOn : icons.checkboxOff" />
                            <div class="progress-label">{{ $ctx_t(prog.label) }}</div>

                          </div>
                          <div v-if="prog.type === 'progressBar'" class="progressbar-background">
                            <div
                              class="progressbar-fill"
                              :style="{ width: (prog.currValue > 0 ? (prog.currValue / (prog.maxValue - prog.minValue)) * 100 : 0) + '%' }"></div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </Tab>
          </Tabs>
        </div>

      </div>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { LayoutSingle } from "@/common/layouts"
import { BngScreenHeading, BngIcon, icons } from "@/common/components/base"
import { Tabs, Tab, TabList, Button, DynamicComponent } from "@/common/components/utility"
import { vBngRelativeTime, vBngBlur, vBngSoundClass, vBngOnUiNav, vBngUiNavScroll, vBngUiNavFocus } from "@/common/directives"
import { $content, $translate } from "@/services"

import { lua } from "@/bridge"
import { ref, computed, nextTick, onMounted, onUnmounted, onBeforeMount } from "vue"
import LogbookActivityDetails from "../components/LogbookActivityDetails.vue"
import LogbookActivityRow from "../components/LogbookActivityRow.vue"
import RewardsPills from "@/modules/career/components/progress/RewardsPills.vue"
import { useRouteDataStore } from "@/services/routeData"
import { setFocus } from "@/services/uiNavFocus"
import { useUINavScope } from "@/services/uiNav"
useUINavScope("logbook") // UI Nav events to fire from (or from focused element inside) element with attribute: bng-ui-scope="logbook"

const props = defineProps({
  id: String,
})

// Match stock TabList's controller focus handoff when selecting a heading.
const selectHeading = (index, selectTab, event) => {
  const button = event.currentTarget
  const hadFocusVisible = document.activeElement?.classList.contains("focus-visible")
  selectTab(index)
  if (hadFocusVisible) nextTick(() => setFocus(button))
}

const sectionTabs = ref()
const selectedTabIndex = ref(0)
const routeDataStore = useRouteDataStore()

let preselectedTab

const entryId = computed(() => (props.id !== undefined ? ("" + props.id).replace(/%/g, "/") : undefined))

const logbookTabs = ref([
  {
    id: "info",
    name: "ui.career.logbook.tabs.info",
    entries: [],
    filter: i => i.type === "info",
  },
  // {
  //   name: "Milestones",
  //   entries: [],
  //   filter: i => i.type === "quest",
  // },
  {
    id: "history",
    name: "ui.career.logbook.tabs.history",
    entries: [],
    // Old saves can hold quest-shaped entries (stock 0.39 quests); they show as history.
    filter: i => i.type === "progress" || i.type === "quest",
  },
])

const checkForNewLogEntries = () => logbookTabs.value.forEach(tab => (tab.hasNew = !!tab.entries.some(i => i.isNew)))

const newLabel = () => {
  const key = "ui.common.new"
  const translated = $translate.instant(key)
  return translated === key ? "New" : translated
}

const emptyTabText = id => {
  const key = id === "history" ? "ui.career.logbook.noHistoryEntries" : "ui.career.logbook.noInfoEntries"
  const translated = $translate.instant(key)
  // Stock English can be cached before mod locales mount. Keep this local;
  // the shared locale refresh belongs to the mod bootstrap.
  if (translated !== key) return translated
  return id === "history"
    ? "No activity recorded yet. Purchases, jobs, events and discoveries appear here as you play."
    : "No information entries available."
}

function setup(data) {
  data.forEach(entry => {
    // Older saves and generic progress entries can omit the category.
    if (!entry.cardTypeLabel || (typeof entry.cardTypeLabel === "string" && !entry.cardTypeLabel.trim())) {
      entry.cardTypeLabel = entry.type === "info" ? "Information" : entry.type === "quest" ? "Milestone" : "Activity"
    }
    if (Object.hasOwn(entry, "text") && !entry.plainText) {
      // ** TODO ** - move to Vue translate ASAP
      entry.text = $content.bbcode.parse($translate.contextTranslate(entry.text, true))
      entry._ready = true
    }
  })

  logbookTabs.value.forEach(tab => (tab.entries = data.filter(tab.filter)))
  checkForNewLogEntries()
  if (entryId.value) {
    for (let tab of logbookTabs.value) {
      for (let entry of tab.entries) {
        if ("" + entry.entryId === entryId.value) {
          toggleExpand(entry)
          preselectedTab = tab
          selectedTabIndex.value = logbookTabs.value.indexOf(tab)
          return
        }
      }
    }
  }
  tabChange({ index: selectedTabIndex.value })
}

const selectedEntry = ref()
let selectedRow

let readTimer

const collapseEntry = () => {
  clearTimeout(readTimer)
  selectedEntry.value = undefined
}

const toggleExpand = (entry, event) => {
  const row = event?.currentTarget
  const keepFocusVisible = row?.classList.contains("focus-visible") || event?.detail === 0
  const wasExpanded = selectedEntry.value?.entryId === entry.entryId
  collapseEntry()
  if (wasExpanded) {
    if (keepFocusVisible) nextTick(() => { if (row?.isConnected) setFocus(row, true, false, true) })
    return
  }
  selectedEntry.value = entry
  selectedRow = event?.currentTarget
  nextTick(() => {
    // The keyed button stays mounted, so confirm does not move controller focus.
    const expanded = document.querySelector(".integrated-entry.expanded")
    selectedRow = expanded?.querySelector("button")
    expanded?.scrollIntoView({ block: "nearest" })
    // Very long legacy articles must leave their toggle visible too.
    selectedRow?.scrollIntoView({ block: "nearest" })
    if (keepFocusVisible && row?.isConnected) setFocus(row, true, false, true)
  })
  readTimer = window.setTimeout(() => {
    entry.isNew = false
    checkForNewLogEntries()
    lua.overhaul_career_progression_logbook.setLogbookEntryRead(entry.entryId, true)
  }, 1000)
}

const tabChange = newTab => {
  const tab = logbookTabs.value[newTab.index]
  if (!tab) return
  selectedTabIndex.value = newTab.index
  const skipPreselected = tab && tab === preselectedTab
  preselectedTab = undefined
  if (skipPreselected) return
  if (!tab.entries || tab.entries.length === 0) {
    collapseEntry()
    return
  }
  collapseEntry()
  toggleExpand(tab.entries[0])
}
const questProgress = computed(() => {
  const progress = selectedEntry.value && selectedEntry.value.progress
  if (Array.isArray(progress)) return progress
  return progress && typeof progress === "object" ? Object.values(progress) : []
})

const exit = () => {
  if (selectedEntry.value) {
    collapseEntry()
    const row = selectedRow
    nextTick(() => { if (row?.isConnected) setFocus(row, true, false, true) })
    return
  }
  if (String(routeDataStore.routeName || "").startsWith("pause.career")) {
    lua.extensions.ui_router.back()
    return
  }
  setTimeout(() => window.bngVue.gotoGameState("pause"), 0)
}

onBeforeMount(() => {
  lua.simTimeAuthority.pushPauseRequest('logbook')
})

onMounted(() => {
  lua.overhaul_career_progression_logbook.getLogbook().then(setup)
})

onUnmounted(() => {
  clearTimeout(readTimer)
  lua.simTimeAuthority.popPauseRequest('logbook')
})
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// A single house list; each selected entry discloses its content in place.

hr {
  margin: 0.5em 0;
  border: none;
  border-top: 1px solid var(--line);
}

.logbook-layout {
  padding: 1em;
  --content-flow: column;
  color: #fff;
  font-size: 1rem;
}

// The custom TabList items retain the stock heading styles.
.career-logbook-list .tab-item {
  text-overflow: ellipsis;
  overflow: visible;
  --bng-bg-border-width: 0;
  --bng-button-margin: 0;
  --bng-button-min-width: 4em;
  &.tab-active-tab {
    --bng-bg-image: linear-gradient(0deg, rgba(var(--tab-bg-active-line), 1) 0.25rem, rgba(var(--tab-bg-active-line), 0.3) 0.2501rem, rgba(var(--tab-bg-active-line), 0) 1rem);
  }
}

.career-logbook-list :deep(.tab-item.flagged::after) {
  content: "";
  background: var(--bng-ter-yellow-100);
  width: 0.5em;
  height: 0.5em;
  border-radius: 100%;
  position: absolute;
  top: 0.2em;
  right: 0.2em;
}

.logbook-empty {
  padding: 1rem;
  margin: 0 0.45rem 0 0.25rem;
  background: var(--bng-cool-gray-900, #151820);
  border-radius: var(--bng-corners-1);
  line-height: 1.5;
}

.career-logbook-wrapper {
  display: flex;
  flex-direction: column;
  justify-content: center;
  flex: 1 1 auto;
  height: 1px;
  font-size: 1rem;
}

.career-logbook-wrapper > * {
  max-width: 68rem;
  width: 100%;
  flex: 0 0 auto;
}

.career-logbook-container {
  display: flex;
  flex: 0 1 auto;
  flex-direction: row;
  align-items: stretch;
  gap: 1em;
  height: 100%;
}

.career-logbook-list {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-width: 0;
  max-height: 100%;
  overflow: hidden;
  padding: var(--space-2);
  border-radius: var(--radius-control);
  background: var(--page);
  // stock Tabs read these; quiet strip, orange line under the open tab only
  :deep(.bng-tabs) {
    flex: 1 1 auto;
    min-height: 0;
    --tab-bg: transparent;
    --tab-content-bg: transparent;
    --tab-list-padding: 0.25em 0.25em 0;
    --tab-list-margin: 0 0 0.35em 0;
    --tab-list-bottom-border: 1px solid var(--line);
  }
}

// house scrollbar; the class is not set in the template so the tab markup above stays untouched
.logbook-list-wrapper {
  @extend .scroll;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  flex: 1 1 auto;
  min-height: 0;
  padding: 0.25em 0.15em 0.25em 0;
  overflow-y: auto;
}

// rows keep their own height; a short History list used to stretch each row to fill the column
.row.career-logbook-item {
  flex: 0 0 auto;
  align-items: flex-start;
  padding: 0.65em 0.85em 0.6em;
  transition: background-color 0.12s ease;
  &.selected {
    background: var(--panel-2);
  }
}

.career-logbook-meta,
.row-copy .career-logbook-meta {
  display: flex;
  align-items: baseline;
  gap: 0.75em;
  font-size: inherit;
  min-width: 0;
  color: var(--muted);
}

.career-logbook-meta .caption,
.row-copy .career-logbook-meta .caption {
  color: var(--muted);
  font-size: 0.78em;
  min-width: 0;
}

.career-logbook-time,
.row-copy .career-logbook-time {
  flex: 0 0 auto;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
}

.row-copy .career-logbook-item-label {
  font-size: 1.15em;
  font-weight: 700;
  line-height: 1.25;
  white-space: normal;
}

.career-logbook-new {
  flex: 0 0 auto;
  margin-top: 0.1em;
}

.integrated-entry {
  flex: 0 0 auto;
  min-width: 0;
  background: var(--panel);
  border-radius: var(--radius-control);
  &.expanded { background: var(--panel-2); }
}

.entry-content {
  padding: 0 1.2em 1.2em 3.75em;
  overflow-wrap: anywhere;
}

.logbook-cover-image {
  box-sizing: border-box;
  width: 100%;
  min-height: 16em;
  max-height: 50vh;
  aspect-ratio: 16 / 5;
  margin-bottom: 1.25em;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: var(--radius-panel);
  background-color: var(--photo);
  background-position: 50% 50%;
  background-size: cover;
}

.logbook-cover-image > h1 {
  font-family: "Overpass", var(--fnt-defs);
  font-weight: 500;
  line-height: 1.25em;
  font-size: 3rem;
  text-shadow: 0 0 3em var(--bng-black-o8);
}

/* Content text styles */
.logbook-plain-text {
  white-space: pre-wrap;
}

.logbook-description :deep(p) {
  font-family: var(--fnt-defs);
  margin-bottom: 1rem;
  line-height: 1.375em;
}

.logbook-description :deep(h1),
.logbook-description :deep(h2),
.logbook-description :deep(h3),
.logbook-description :deep(h4),
.logbook-description :deep(h5) {
  margin: 1em 0 1rem;
  font-family: "Overpass", var(--fnt-defs);
  font-weight: 500;
  line-height: 1.25em;
}

.logbook-description :deep(h1) {
  margin-top: 0;
  font-size: 3rem;
}

.logbook-description :deep(h2) {
  font-size: 2.441rem;
  font-weight: 600;
}

.logbook-description :deep(h3) {
  font-size: 1.953rem;
  font-weight: 600;
}

.logbook-description :deep(h4) {
  font-size: 1.5rem;
  font-weight: 700;
}

.logbook-description :deep(h5) {
  font-size: 1.25rem;
  font-weight: 700;
}

.logbook-description :deep(small),
.logbook-description :deep(.text_small) {
  font-size: 0.8rem;
}

/* List-items */
.logbook-description :deep(ul, ol) {
  padding: 0 0.5em;
  margin: 0.75em 0;
}

.logbook-description :deep(ul, ol, li) {
  position: relative;
}

.logbook-description :deep(ul > li) {
  list-style: none;
  display: list-item;
  margin-left: 1.5em;
  margin-bottom: 0.4em;
}

.logbook-description :deep(ol > li) {
  margin-left: 1.5em;
  margin-bottom: 0.25em;
}

.logbook-description :deep(ul > li::before) {
  content: "";
  display: inline-block;
  position: absolute;
  left: 0.5em;
  height: 1.2em;
  width: 1em;
  background-image: url("data:image/svg+xml,%3csvg viewBox='0 0 14 14' xmlns='http%3a%2f%2fwww.w3.org%2f2000%2fsvg'%3e%3cpath d='M5 0H14L9 14H0L5 0Z' fill='%23f60'%2f%3e%3c%2fsvg%3e");
  background-size: 0.6em;
  background-position: 50% 50%;
  background-repeat: no-repeat;
}

.logbook-description :deep(ul > li ul > li::before) {
  background-image: url("data:image/svg+xml,%3csvg viewBox='0 0 14 14' xmlns='http%3a%2f%2fwww.w3.org%2f2000%2fsvg'%3e%3cpath d='M10 0H5L0 14H5L10 0ZM14 0H12L7 14H9L14 0Z' fill='%23f60'%2f%3e%3c%2fsvg%3e");
}

/* Text props */
.logbook-description :deep(em) {
  color: var(--bng-orange-100);
}

.logbook-description :deep(code) {
  font-family: "Noto Sans Mono", var(--fnt-mono);
  font-size: 0.875em;
  display: inline-flex;
  padding: 0.25em 0.5em;
  background-color: var(--panel-2);
  border-radius: var(--radius-thumb);
  border: 1px solid var(--line);
}

.logbook-description :deep(strong) {
  font-weight: 700;
  color: var(--bng-orange-200);
}

.logbook-description:not(:last-child) {
  padding-bottom: 1.5em !important;
}

.logbook-description :deep(.quest-labels) {
  font-size: 1em;
  display: flex;
  flex-direction: row;
  padding: 0.5em 0.5em;
  z-index: 2;
  position: relative;
  align-items: flex-start;
  justify-content: flex-start;
  padding-left: 2.25em;
  overflow: visible;
  flex: 1 1 auto;
}

.logbook-description :deep(.quest-labels .progress-label) {
  flex: 1 0 auto;
  font-size: 1.2em;
  font-weight: 400;
  /* justify-self: stretch; */
}

.logbook-description :deep(.progressbar-value) {
  font-size: 1em;
  padding: 0 0.25em;
  flex: 0 0 auto;
}

.logbook-description :deep(.progressbar-background) {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  box-sizing: content-box;
  top: 0;
  z-index: 1;
  /* padding: 0.5em; */
  display: flex;
  border-radius: var(--bng-corners-1);
}

.quest-stats-wrapper {
  position: relative;
  padding: 0.25em;
  display: flex;
  flex-direction: row;
  border-radius: var(--bng-corners-1);
  margin-bottom: 0.5em;
  border: 0.125em solid var(--bng-cool-gray-800);
}

.logbook-description :deep(.progressbar-background .progressbar-fill) {
  align-self: stretch;
  background-color: rgba(255, 255, 255, 0.25);
}

.check-icon {
  position: absolute;
  width: 3em;
  height: 3em;
  top: 0.2em;
  left: 0.1em;
}

.logbook-table {
  text-align: left;
  width: 100%;
  margin-top: 1.5em;
}
.logbook-table table {
  width: 100%;
}
.logbook-table tr:nth-child(odd) {
  background-color: rgba(0, 0, 0, 0.5);
}
.logbook-table tr:nth-child(even) {
  background-color: rgba(0, 0, 0, 0.2);
}
.logbook-table th {
  background-color: rgba(0, 0, 0, 0.5);
  position: sticky;
}
</style>

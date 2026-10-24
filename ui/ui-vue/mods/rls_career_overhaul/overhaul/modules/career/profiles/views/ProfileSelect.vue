<!--
  ProfileSelect: the career save picker screen. Saves are one strip of cards, with a toolbar above it.

  Map, in reading order
    1. Screen state: the save list, the selected card, the create card and the migration step.
    2. RLS import sources: Lua scans them and answers by event. Stays here: the order of these calls is the contract.
    3. Search, sort and filter: profileSelect/useProfileFilters.js. The two dropdown menus are useDropdown instances.
    4. Strip: card focus, the open card, slides and the wheel: profileSelect/useProfileStrip.js.
    5. Open-card detail: profileSelect/useProfileHighlights.js, fed by fetchFocusedHighlights below.
    6. Load, create and migration: ordered bridge calls and their busy and preflight guards. Stays here.
    7. Lifecycle, Back and deactivate: mount and unmount wiring, and the modal guards that decide where Back goes.
  Owned here: the save list, the selection, the migration state, the dropdown containers and the strip DOM refs.

  Parts (profileSelect/)
    ProfileSelectToolbar.vue   search box, sort and filter triggers, teleported menus
    useProfileFilters.js       search, sort mode and the three filter sets
    useProfileStrip.js         focus, expanded card, track geometry, slides, wheel
    useProfileHighlights.js    the open card's money, asset value and last vehicle
    (style block)              the strip skin, inline in this file

  Contracts
    ProfileCard emits card:activate, manage:change, backup:change, load and saves:load.
    ProfileCreateCard reads validateName through provide.
    LegacyMigrationModal emits cancel, load and migrate.
-->
<template>
  <div v-bng-scoped-nav="navScope" v-bng-on-ui-nav:back,menu="onScreenNavigation" v-bng-on-ui-nav:tab_l="stripNavLabel ? previousCard : null" v-bng-on-ui-nav:tab_r="stripNavLabel ? nextCard : null" v-bng-ui-nav-label:tab_l,tab_r="stripNavLabel" :class="['profiles-container', { 'profiles-container--new': newCareer }]" @wheel="!newCareer && onWheel($event)" @deactivate="onDeactivate">
    <BngScreenHeading v-if="!newCareer" class="profiles-title" :preheadings="[$ctx_t('ui.playmodes.career')]">{{ $ctx_t("ui.career.savedProgress") }} </BngScreenHeading>

    <div :class="['profiles-panel', { 'profiles-panel--create-only': createCardOnly && !createCardActive && !newCareer }]">
      <div v-if="profilesError" class="profiles-error" role="alert">{{ profilesError }}</div>
      <!-- One toolbar row over the open card, edge to edge with it: Back on the
           left, search, sort and filter on the right, all one height. -->
      <div class="profiles-topbar">
        <HouseButton class="profiles-back" variant="quiet" binding="back" :icon="isControllerUsed ? null : icons.arrowSmallLeft"
          :disabled="migrationBusy || !!migrationReport || createCardActive || isManage || isBackup" @click="onDeactivate">Back</HouseButton>
        <!-- Search, sort and filter over nothing are three dead controls between a
             first-time player and the only button that matters. -->
        <ProfileSelectToolbar
          v-if="!newCareer && showToolbar"
          :inert="!profilesReady"
          v-model:searchQuery="searchQuery"
          :disabled="createCardActive || !profilesReady"
          :sortOptions="sortOptions"
          :sortMode="sortMode"
          :sortLabel="selectedSortLabel"
          :sortOpen="sortOpen"
          :sortStyle="sortStyle"
          :filterOpen="filterOpen"
          :filterStyle="filterStyle"
          :activeFilterCount="activeFilterCount"
          :activePaths="activePaths"
          :activeDifficulties="activeDifficulties"
          :activeChallenges="activeChallenges"
          :challengeOptions="challengeFilterOptions"
          :setSortContainer="setSortContainer"
          :setFilterContainer="setFilterContainer"
          @search-focus="onSearchFocus"
          @search-blur="onSearchBlur"
          @toggle-sort="toggleSort"
          @select-sort="selectSort"
          @close-sort="closeSort"
          @toggle-filter="toggleFilter"
          @close-filter="closeFilter"
          @toggle-path="togglePathFilter"
          @toggle-difficulty="toggleDifficultyFilter"
          @toggle-challenge="toggleChallengeFilter"
          @clear-filters="clearFilters" />
      </div>

      <ProfileCreateCard
        v-if="newCareer"
        ref="newCareerCardRef"
        v-model:profileName="newProfileName"
        v-model:active="createCardActive"
        centered
        hero
        class="profiles-new-card"
        @card:activate="value => onCardActivated(value, -1)"
        @load="onCreateSave" />

      <div v-else class="profiles-strip-shell">
        <!-- Keyed off having saves at all, not off the featured card: a search
             that momentarily matches nothing must not slide the strip sideways. -->
        <!--
          The strip does not scroll — it is a window, and the track inside it is
          moved with a transform.

          A scroll container would be vulnerable to something outside this component
          resetting its scrollLeft to the start between steps: focusing an element
          inside a scrollable box makes the browser reveal it, and the leftmost card
          would win. Each step would then animate from that hijacked position, which
          is the jump to the far left. With nothing to scroll, there is nothing to hijack.
        -->
        <div ref="stripRef" class="profiles-strip">
          <div ref="trackRef" :class="['profiles-track', { 'profiles-track--hero': !createCardOnly, 'profiles-track--create-only': createCardOnly }]">
          <!-- Carries the selected card's width rules but never animates and never
               renders, so centring has something truthful to measure. Reading the
               real card instead meant catching it mid-growth and computing targets
               from a width it only held for an instant. -->
          <div ref="probeHero" class="profile-card profile-card--hero pc-probe" aria-hidden="true" />
          <div ref="probeSmall" class="profile-card pc-probe" aria-hidden="true" />
          <ProfileCreateCard
            v-model:profileName="newProfileName"
            v-model:active="createCardActive"
            :autoExpand="createCardOnly"
            :hero="expandedIndex === -1 && (!createCardOnly || createCardActive)"
            :selected="focusedIndex === -1 && expandedIndex !== -1"
            class="profile-card"
            @focusin="followCardFocus(-1)"
            @click="focusCard(-1, { immediate: true })"
            @card:activate="value => onCardActivated(value, -1)"
            @load="onCreateSave" />
          <!-- One list. Whichever card the strip is focused on is the one that
               opens up, and it is the one held in the middle of the screen. -->
          <component
            :is="profile.pending ? ProfileLoadingCard : ProfileCard"
            v-for="(profile, index) of renderedProfiles"
            v-bng-popover="profile.incompatibleVersion ? 'tooltip-outdated-message' : null"
            v-bind="profile"
            v-bng-disabled="(isManage && selectedCard !== null && selectedCard !== index) || (isBackup && backupCardIndex !== null && backupCardIndex !== index)"
            :key="profile.id"
            :active="activeProfileId === profile.id"
            :forceCloseManage="selectedCard === -1"
            :hero="index === expandedIndex"
            :mapLabel="index === expandedIndex ? mapLabelFor(profile) : ''"
            :recentMoney="index === expandedIndex ? focusedRecentMoney : EMPTY_LIST"
            :assetValue="index === expandedIndex ? focusedHighlights.assetValue : null"
            :highlightsPending="index === expandedIndex && highlightsPending"
            :sliding="sliding"
            :selected="index === focusedIndex && index !== expandedIndex"
            class="profile-card"
            @focusin="followCardFocus(index)"
            @click="focusCard(index, { immediate: true })"
            @card:activate="value => onCardActivated(value, index)"
            @manage:change="value => onManageChange(value, index)"
            @backup:change="active => onBackupChange(active, index)"
            @load="onLoad"
            @saves:load="onLoadSave" />

          <div v-if="hasNoMatches" class="profiles-empty">
            <span class="profiles-empty-title">No saves match</span>
            <button type="button" class="profiles-empty-btn" @click="clearAllFilters">Clear search and filters</button>
          </div>
          </div>
        </div>
      </div>
    </div>
  </div>
  <BngPopoverContent name="tooltip-outdated-message">
    <template #default>
      <div class="tooltip-outdated-message">This profile was saved with an old version of the game. It can no longer be loaded.</div>
    </template>
  </BngPopoverContent>
  <LegacyMigrationModal
    v-if="migrationReport"
    :report="migrationReport"
    :busy="migrationBusy"
    :error="migrationError"
    :result="migrationResult"
    @cancel="cancelMigration"
    @load="loadMigratedCopy"
    @migrate="runMigration" />
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, provide, ref, watch } from "vue"
import { storeToRefs } from "pinia"
import useControls from "@/services/controls"
import { popupsView } from "@/services/popup"
import { useRouteReady } from "@/services/routeReadiness"
import { setFocus } from "@/services/uiNavFocus"
import { DOM_UI_NAVIGATION_EVENT } from "@/services/uiNav/constants"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services"
import { vBngDisabled, vBngPopover, vBngScopedNav, vBngOnUiNav, vBngUiNavLabel } from "@/common/directives"
import { BngPopoverContent, BngScreenHeading, icons } from "@/common/components/base"
import HouseButton from "../../components/house/HouseButton.vue"
import ProfileCard from "../components/ProfileCard.vue"
import ProfileLoadingCard from "../components/ProfileLoadingCard.vue"
import ProfileCreateCard from "../components/ProfileCreateCard.vue"
import LegacyMigrationModal from "../components/LegacyMigrationModal.vue"
import { createRlsSaveMigration, isImportSource, luaList, mergeProfileCards } from "../components/rlsSaveMigration.js"
import "../../utils/installLuaBridgeFallbacks"
import { useProfilesStore, PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { returnFocusToOpener } from "../../composables/useScreenEntryFocus"
import { useDropdown } from "../../composables/useDropdown.js"
import { acquireScope } from '../../utils/luaScopes'
import { safeLua } from '../../utils/safeLua.js'
import { useCefTyping } from '../../composables/useCefTyping.js'
import ProfileSelectToolbar from "./profileSelect/ProfileSelectToolbar.vue"
import { useProfileFilters } from "./profileSelect/useProfileFilters.js"
import { useProfileStrip } from "./profileSelect/useProfileStrip.js"
import { useProfileHighlights } from "./profileSelect/useProfileHighlights.js"

const props = defineProps({
  scopeId: { type: String, default: "career-profiles" },
  newCareer: { type: Boolean, default: false },
})

const store = useProfilesStore()
const { events } = useBridge()
const { isControllerUsed } = storeToRefs(useControls())

const profiles = ref(null)
const activeProfileId = ref(null)

const selectedCard = ref(null)
const isManage = ref(false)
const isBackup = ref(false)
const backupCardIndex = ref(null)
const newProfileName = ref(null)
const createCardActive = ref(false)
const newCareerCardRef = ref(null)

let isLoading = false
const profilesReady = ref(false)
const profilesError = ref("")
let profileListGeneration = null
let profileDetailsPending = false
/** Resolves once the first profile list is in (or has failed). */
function profilesLoaded() {
  if (profilesReady.value) return Promise.resolve()
  return new Promise(resolve => {
    const stop = watch(profilesReady, ready => {
      if (ready) { stop(); resolve() }
    })
  })
}

useRouteReady({
  async waitUntilReady() {
    // The route is usable with placeholders; starting a new save still waits
    // for both complete lists through profilesLoaded().
    await nextTick()
  },
})
const migrationReport = ref(null)
const migrationResult = ref(null)
const migrationBusy = ref(false)
const migrationError = ref("")

// LB/RB belong to this screen only while the strip is available. Releasing the
// handlers also refreshes stock hint bars that cache labels until events change.
const STRIP_NAV_LABEL = "Previous / next career"
const stripNavLabel = computed(() => !props.newCareer && profilesReady.value && !profilesError.value && hasAnyProfile.value
  && !createCardActive.value && !isManage.value && !isBackup.value
  && !migrationReport.value && !migrationBusy.value ? STRIP_NAV_LABEL : "")

// RLS saves (settings/cloud/saves/) are listed as normal cards; loading one opens the
// legacy migration step below, which copies it into Overhaul (rlsSaveMigration.js).
const importSources = ref([])
let lastProfileData = null
let importerReady = null
let screenUnmounted = false
let profilesRequest = 0

function ensureImporter() {
  if (!importerReady) importerReady = acquireScope(lua, 'profiles.saveImport').catch(error => {
    importerReady = null
    throw error
  })
  return importerReady
}

const rlsMigration = createRlsSaveMigration({
  api: {
    async preflight(id) { await ensureImporter(); return lua.overhaul_shell_saveImport.getImportPreflight(id) },
    async queue(profile, target, options) { await ensureImporter(); return lua.overhaul_shell_saveImport.queueImportSave(profile, target, options) },
    async status() { await ensureImporter(); return lua.overhaul_shell_saveImport.getImportStatus() },
  },
})

// Lua builds the RLS cards over several frames and answers with the
// OverhaulImportSourceCards event carrying our requestId (always, even on failure).
// Lua jobs outlive a closed screen and every screen numbers its requests from 1, so each
// request also carries this screen's own token and a reply must echo both.
const screenToken = `profiles-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
let importCardsRequest = 0
const pendingImportCards = new Map()

function onImportSourceCards(reply) {
  if (reply?.screen !== screenToken) return
  const resolve = pendingImportCards.get(reply.requestId)
  if (!resolve) return
  pendingImportCards.delete(reply.requestId)
  resolve(reply.cards)
}

async function fetchImportSourceCards() {
  const requestId = ++importCardsRequest
  const reply = new Promise(resolve => pendingImportCards.set(requestId, resolve))
  try {
    await lua.overhaul_shell_saveImport.getImportSourceCardsAsync(requestId, screenToken)
  } catch (error) {
    pendingImportCards.delete(requestId)
    throw error
  }
  return reply
}

// New-save name validation waits for both complete lists so an import source's
// name cannot be reused before its scan answers. Metadata renders independently.
let initialImportSources = Promise.resolve()

async function loadImportSources() {
  let cards = []
  try {
    await ensureImporter()
    cards = luaList(await fetchImportSourceCards())
  } catch (error) {
    safeLua(() => { throw error }, "ProfileSelect failed to load RLS save cards")
  }
  if (screenUnmounted) return
  importSources.value = cards
  if (profileListGeneration !== null && lastProfileData) {
    profiles.value = mergeProfileCards(lastProfileData, cards)
  }
}

/** After an import: rescan the RLS saves and redraw the list with them. */
async function refreshImportSources() {
  await loadImportSources()
  if (screenUnmounted) return
  if (lastProfileData) await onProfilesReceived(lastProfileData)
}

// Strip and card DOM refs. The probes carry the card width rules but never animate or show, so the strip can measure
// settled sizes from them.
const stripRef = ref(null)
const trackRef = ref(null)
const probeHero = ref(null)
const probeSmall = ref(null)

const {
  searchQuery, sortMode, sortOptions, selectedSortLabel, activePaths, activeDifficulties, activeChallenges,
  challengeFilterOptions, activeFilterCount, hasAnyProfile, showToolbar, filteredProfiles, hasNoMatches,
  togglePathFilter, toggleDifficultyFilter, toggleChallengeFilter, clearFilters, clearSearchAndFilters,
} = useProfileFilters({ profiles, activeProfileId })

const DEFAULT_LOADING_CARDS = Object.freeze(Array.from({ length: 3 }, (_, index) => ({ id: `pending-${index}`, pending: true })))
const renderedProfiles = computed(() => profiles.value === null && !profilesReady.value ? DEFAULT_LOADING_CARDS : filteredProfiles.value)
/** No saves at all: the create card is the whole strip, so it sits in the middle instead of at the start. */
const createCardOnly = computed(() => profilesReady.value && !hasAnyProfile.value)

// Opening one dropdown closes the other, and closing returns focus to its trigger. The toolbar hands each dropdown's
// element back through setSortContainer and setFilterContainer, so the menus can be placed under their triggers.
const sortDropdownRef = ref(null)
const sortOpen = ref(false)
const sortStyle = ref("")
const filterDropdownRef = ref(null)
const filterOpen = ref(false)
const filterStyle = ref("")

const sortDropdown = useDropdown({
  containerRef: sortDropdownRef,
  triggerSelector: ".pt-trigger",
  menuSelector: ".pt-menu:not(.pt-menu--filter)",
  open: sortOpen,
  style: sortStyle,
  gapPx: 6,
  zIndex: 2000,
  widthProperty: "min-width",
  onOpen: () => { filterOpen.value = false },
  onClose: () => returnFocusToOpener(sortDropdown.trigger),
})
const filterDropdown = useDropdown({
  containerRef: filterDropdownRef,
  triggerSelector: ".pt-trigger",
  menuSelector: ".pt-menu--filter",
  open: filterOpen,
  style: filterStyle,
  gapPx: 6,
  zIndex: 2000,
  widthProperty: "min-width",
  onOpen: () => { sortOpen.value = false },
  onClose: () => returnFocusToOpener(filterDropdown.trigger),
})
const toggleSort = sortDropdown.toggle
const closeSort = sortDropdown.close
const positionSort = sortDropdown.position
const onSortDocClick = sortDropdown.onDocumentClick
const toggleFilter = filterDropdown.toggle
const closeFilter = filterDropdown.close
const positionFilter = filterDropdown.position
const onFilterDocClick = filterDropdown.onDocumentClick

const setSortContainer = element => { sortDropdownRef.value = element }
const setFilterContainer = element => { filterDropdownRef.value = element }

function selectSort(value) {
  sortMode.value = value
  closeSort()
}

const {
  focusedIndex, expandedIndex, expandedProfile, sliding, focusCard, onWheel, onStripResize,
  dispose: disposeStrip,
} = useProfileStrip({ cards: filteredProfiles, createCardOnly, stripRef, trackRef, probeHero, probeSmall })

// Focus must reveal the card before crossfire calculates its next neighbour.
function followCardFocus(index) {
  if (focusedIndex.value !== index) focusCard(index, { animate: false, immediate: true })
}
function stepCard(direction, event) {
  event?.stopPropagation()
  if (!stripNavLabel.value) return
  const index = Math.max(-1, Math.min(filteredProfiles.value.length - 1, focusedIndex.value + direction))
  focusCard(index, { animate: false, immediate: true })
  nextTick(() => {
    const cards = trackRef.value?.querySelectorAll(':scope > .profile-card:not(.pc-probe)')
    setFocus(cards?.[index + 1], true, false)
  })
}
const previousCard = event => stepCard(-1, event)
const nextCard = event => stepCard(1, event)

/** One shared identity for "no rows": a fresh [] per card would defeat
    per-card prop equality and re-render every card on each parent render. */
const EMPTY_LIST = Object.freeze([])

const {
  focusedHighlights, focusedRecentMoney, highlightsPending, dispose: disposeHighlights,
} = useProfileHighlights({ expandedProfile, fetchHighlights: fetchFocusedHighlights })

/** The open save's detail. An RLS save answers from its import source; any other from the career profile. */
async function fetchFocusedHighlights(id) {
  return isImportSource(expandedProfile.value)
    ? await ensureImporter().then(() => lua.overhaul_shell_saveImport.getImportSourceHighlights(id, 5))
    : await lua.overhaul_career_career.getProfileHighlights(id, 5)
}

/** {id: label} from overhaul_world_maps — a level id on its own is not a label. */
const mapLabels = ref({})

function mapLabelFor(profile) {
  const level = profile?.level
  if (!level) return ""
  return mapLabels.value?.[level] || ""
}

async function loadMapLabels() {
  await safeLua(async () => {
    const maps = await lua.overhaul_world_maps.getCompatibleMaps()
    if (maps && typeof maps === "object") mapLabels.value = maps
  }, "ProfileSelect failed to load map labels")
}

function clearAllFilters() {
  clearSearchAndFilters()
  sortOpen.value = false
  filterOpen.value = false
}

/** A press outside both menus closes whichever is open. A press inside the open sort menu stops at the sort check. */
function onDropdownDocClick(event) {
  onSortDocClick(event)
  if (sortOpen.value) return
  onFilterDocClick(event)
}

const { onFocus: onSearchFocus, onBlur: onSearchBlur } = useCefTyping()

let loadPreflightPending = false
let migrationOpener = null

const onLoad = async id => {
  if (loadPreflightPending || migrationReport.value) return
  loadPreflightPending = true
  try {
    migrationError.value = ""
    const opener = document.activeElement
    const report = isImportSource(profiles.value?.find(profile => profile.id === id))
      ? await rlsMigration.preflight(id)
      : await lua.overhaul_career_career.getLegacySavePreflight(id, null)
    if (report?.requiresMigration) {
      migrationOpener = opener && opener !== document.body ? opener : null
      migrationReport.value = report
      isLoading = false
      return
    }
    isLoading = true
    if (await store.loadExistingProfile(id) === false) isLoading = false
  } catch (error) {
    isLoading = false
    throw error
  } finally {
    loadPreflightPending = false
  }
}

function onMigrationRequired(report) {
  if (!report?.requiresMigration || migrationBusy.value) return
  isLoading = false
  migrationOpener = document.activeElement
  migrationReport.value = report
  migrationResult.value = null
  migrationError.value = ""
  lua.overhaul_career_career.takePendingLegacySaveMigration()
}

async function receivePendingMigration() {
  const report = await lua.overhaul_career_career.takePendingLegacySaveMigration()
  if (report) onMigrationRequired(report)
}

function cancelMigration() {
  if (migrationBusy.value) return
  migrationReport.value = null
  migrationResult.value = null
  migrationError.value = ""
  isLoading = false
  const opener = migrationOpener
  migrationOpener = null
  returnFocusToOpener(() => (opener && document.contains(opener) ? opener : document.querySelector(".profiles-container")))
}

async function runMigration(options) {
  if (!migrationReport.value || migrationBusy.value) return
  migrationBusy.value = true
  migrationError.value = ""
  try {
    await nextTick()
    const source = migrationReport.value
    const result = source.importSource
      ? await rlsMigration.migrate(source, options)
      : await lua.overhaul_career_career.prepareLegacySaveMigration(source.profile, source.saveFolder || null, options)
    if (!result?.ok) {
      migrationError.value = result?.error || "Migration could not be prepared."
      return
    }
    migrationResult.value = result
    if (source.importSource) await refreshImportSources()
    await lua.overhaul_career_career.sendAllCareerProfilesData()
  } catch (error) {
    migrationError.value = error?.message || "Migration failed unexpectedly."
  } finally {
    migrationBusy.value = false
  }
}

async function loadMigratedCopy() {
  if (!migrationResult.value || migrationBusy.value) return
  const source = migrationReport.value
  const result = migrationResult.value
  migrationBusy.value = true
  try {
    isLoading = true
    await store.startMigrationLoadingScreen()
    migrationReport.value = null
    const loaded = await store.loadPreparedMigration(result.targetProfile, result.targetSaveFolder || null)
    if (loaded === false) throw new Error("The migrated copy was created, but Career did not start.")
  } catch (error) {
    isLoading = false
    await store.stopMigrationLoadingScreen()
    migrationReport.value = source
    migrationError.value = error?.message || "The migrated copy could not be loaded."
    store.showMigrationError(migrationError.value)
  } finally {
    migrationBusy.value = false
  }
}

/** Picking a save now happens inside the card, so this just loads the chosen one. */
const onLoadSave = async (profileId, saveFolderName) => {
  if (!profileId || !saveFolderName || loadPreflightPending || migrationReport.value) return
  loadPreflightPending = true
  try {
    const report = await lua.overhaul_career_career.getLegacySavePreflight(profileId, saveFolderName)
    if (report?.requiresMigration) {
      migrationOpener = document.activeElement
      migrationReport.value = report
      migrationError.value = ""
      return
    }
    isLoading = true
    if (await store.loadProfileSave(profileId, saveFolderName) === false) isLoading = false
  } catch (error) {
    isLoading = false
    throw error
  } finally {
    loadPreflightPending = false
  }
}

// A Start pressed while the lists are still coming in (they are built over a few frames
// after the screen opens) waits for them. Closing the form, Back to the mode picker or
// leaving the screen meanwhile cancels it. Once submitted, the start owns loading
// until the bridge answers; closing the form cannot cancel a career already starting.
let pendingStart = null

function cancelPendingStart() {
  if (!pendingStart || pendingStart.submitted) return
  pendingStart = null
  isLoading = false
}

const onCreateSave = async (profileName, tutorialChecked, difficultyMode, challengeId, cheatsMode, startingMap, experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled, employmentApprenticeship, xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile, sandboxXpProfile) => {
  if (pendingStart || isLoading) return
  const start = {}
  pendingStart = start
  isLoading = true
  try {
    await profilesLoaded()
    if (pendingStart !== start) return
    // The card checked the name against the profiles loaded when it was typed.
    if (screenUnmounted || isProfileNameTaken(profileName)) {
      isLoading = false
      return
    }
    start.submitted = true
    if (await store.loadProfile(profileName, tutorialChecked, true, difficultyMode, challengeId, cheatsMode, startingMap, experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled, xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile, sandboxXpProfile, employmentApprenticeship) === false) isLoading = false
  } catch (error) {
    isLoading = false
    throw error
  } finally {
    if (pendingStart === start) pendingStart = null
  }
}

function onCardActivated(active, index) {
  if (active) {
    selectedCard.value = index
    if (index === -1) {
      // Setting up happens on the card, so make sure it is the selected one and
      // therefore at full size — otherwise the form opens in a 22em column.
      if (!props.newCareer && focusedIndex.value !== -1) focusCard(-1, { immediate: true })
      newProfileName.value = getNewName()
    } else {
      createCardActive.value = false
    }
  } else {
    selectedCard.value = null
    if (index === -1) cancelPendingStart()
  }
}

function onManageChange(active, index) {
  isManage.value = active
}

function onBackupChange(active, index) {
  isBackup.value = active
  backupCardIndex.value = active ? index : null
}

onMounted(() => {
  events.on("allCareerProfiles", onProfilesReceived)
  events.on("allCareerProfilesList", onProfileList)
  events.on("allCareerProfilesBatch", onProfileBatch)
  events.on("legacySaveMigrationRequired", onMigrationRequired)
  events.on("OverhaulSaveImportProgress", rlsMigration.handleStatus)
  events.on("OverhaulImportSourceCards", onImportSourceCards)
  events.on("allCareerProfilesFailed", onProfilesFailed)
  receivePendingMigration()
  // Import cards join when ready; they cannot hold the Overhaul placeholders.
  initialImportSources = loadImportSources()
  lua.overhaul_career_career.sendAllCareerProfilesDataAsync().catch(onProfilesFailed)
  loadMapLabels()
  safeLua(() => acquireScope(lua, 'profiles.challengeModes'), "ProfileSelect failed to acquire the challenge scope")
  document.addEventListener("mousedown", onDropdownDocClick)
  document.addEventListener(DOM_UI_NAVIGATION_EVENT, onScreenNavigation, true)
  window.addEventListener("resize", positionSort)
  window.addEventListener("resize", positionFilter)
  window.addEventListener("resize", onStripResize)
})

onBeforeUnmount(() => {
  screenUnmounted = true
  cancelPendingStart()
  profilesRequest++
  rlsMigration.dispose()
  events.off("allCareerProfiles", onProfilesReceived)
  events.off("allCareerProfilesList", onProfileList)
  events.off("allCareerProfilesBatch", onProfileBatch)
  events.off("legacySaveMigrationRequired", onMigrationRequired)
  events.off("OverhaulSaveImportProgress", rlsMigration.handleStatus)
  events.off("OverhaulImportSourceCards", onImportSourceCards)
  events.off("allCareerProfilesFailed", onProfilesFailed)
  pendingImportCards.clear()
  document.removeEventListener("mousedown", onDropdownDocClick)
  document.removeEventListener(DOM_UI_NAVIGATION_EVENT, onScreenNavigation, true)
  window.removeEventListener("resize", positionSort)
  window.removeEventListener("resize", positionFilter)
  window.removeEventListener("resize", onStripResize)
  disposeStrip()
  disposeHighlights()
})

provide("validateName", validateName)

// Stock dispatch resolves the inner card scope before bubbling DOM events.
// Handle screen-level shoulders at the same boundary as the setup Back guard.
function onScreenNavigation(event) {
  const { name, value } = event.detail || {}
  if (popupsView.popups || popupsView.activities) return true
  if (!props.newCareer && (name === "tab_l" || name === "tab_r")) {
    if (!event.target?.closest?.(".profiles-container") || isAnyModalOpen() || isManage.value || isBackup.value) return
    event.stopImmediatePropagation()
    if (value) stepCard(name === "tab_l" ? -1 : 1, event)
    return
  }
  if (props.newCareer) onNewCareerNavigation(event)
  else if ((name === "back" || name === "menu") && !createCardActive.value
    && !isManage.value && !isBackup.value && !isAnyModalOpen()) {
    if (event.target && event.target !== document.body && !event.target.closest?.(".profiles-container")) return true
    // The root directive registers the remappable stock actions. Consume both edges
    // while mounted; the stock router ignores releases after this unmounts.
    event.stopImmediatePropagation()
    event.preventDefault()
    if (value !== 0 && value !== false) onDeactivate()
    return
  }
  return true // Leave inner card/modal handlers and the stock fallback in charge.
}

function onNewCareerNavigation(event) {
  const { name, value } = event.detail || {}
  if (name !== "back" && name !== "menu") return
  if (migrationReport.value || newCareerCardRef.value?.isModalOpen()) return
  // The setup unmounts on press. Keep the release here too, otherwise the
  // router receives half of the same gesture and leaves the restored picker.
  event.stopImmediatePropagation()
  event.preventDefault()
  if (value === 0 || value === false) return
  if (createCardActive.value) newCareerCardRef.value?.backToPicker()
  else navigateToMainMenu()
}

/**
 * Anything with its own escape semantics. `.css-start-screen` is no longer an
 * overlay — it is the create card's inline form — but Back there must close the
 * form rather than leave the screen, so it still belongs on this list.
 */
function isAnyModalOpen() {
  if (popupsView.popups || popupsView.activities || migrationReport.value || migrationBusy.value) return true
  const selectors = ['.ccm-overlay', '.cdm-overlay', '.lmm-backdrop', '.css-start-screen', '.css-start-dropdown-menu', '.css-sandbox-advanced-overlay', '.pt-menu']
  for (const sel of selectors) {
    const el = document.querySelector(sel)
    if (!el) continue
    const style = window.getComputedStyle(el)
    if (style.display !== 'none' && style.visibility !== 'hidden') return true
  }
  return false
}

const navigateToMainMenu = async () => {
  if (isAnyModalOpen()) return
  let active = !!activeProfileId.value
  try {
    active = !!(await lua.overhaul_career_career.isActive())
  } catch (error) {
    safeLua(() => { throw error }, "ProfileSelect failed to read the career state")
  }
  lua.extensions.ui_router.navigate(active ? "pause" : "menu", null, null)
}

const onDeactivate = (event) => {
  if (event?.detail?.force) return
  if (createCardActive.value) return
  if (isManage.value) return
  if (isBackup.value) return
  if (isAnyModalOpen()) return

  // Load in progress (or just finished underneath us): leave to play, don't
  // swallow ESC into a stuck selector and don't route to careerPause.
  if (isLoading) {
    isLoading = false
    safeLua(() => lua.extensions.ui_router.navigate("play"), "ProfileSelect failed to route to play")
    return
  }
  if (event?.detail?.reason === "descendant-scope-activation") return
  navigateToMainMenu()
}

// Route-managed scopes send unguarded B presses to the Lua router.
const navScope = {
  scopeId: props.scopeId,
  activateOnMount: props.newCareer,
  ...(props.newCareer ? { autoFocusDelay: 0, preferAutoFocus: true } : {}),
  canDeactivate: () => {
    onDeactivate()
    return false
  },
}

/** The profile list could not be built: stop waiting, as a failed bridge call does. */
function onProfilesFailed() {
  profilesError.value = "Profiles could not be loaded. Please reopen this screen to try again."
  profileDetailsPending = false
  lastProfileData = lastProfileData?.filter(profile => !profile.pending) || null
  profiles.value = profiles.value?.filter(profile => !profile.pending) || null
  profilesReady.value = true
}

function onProfileList(reply) {
  if (screenUnmounted || !reply || (profileListGeneration !== null && reply.generation < profileListGeneration)) return
  profileListGeneration = reply.generation
  profileDetailsPending = true
  profilesError.value = ""
  lastProfileData = luaList(reply.profiles)
  activeProfileId.value = reply.activeProfileId || null
  profiles.value = mergeProfileCards(lastProfileData, importSources.value)
}

function onProfileBatch(reply) {
  if (screenUnmounted || reply?.generation !== profileListGeneration) return
  const completed = new Map(luaList(reply.profiles).map(profile => [profile.id, profile]))
  lastProfileData = lastProfileData.map(profile => completed.get(profile.id) || profile)
  profiles.value = profiles.value?.map(profile => completed.get(profile.id) || profile) || null
}

async function onProfilesReceived(data) {
  const request = ++profilesRequest
  const preserveSelection = profileDetailsPending
  profileDetailsPending = false
  lastProfileData = luaList(data)
  try {
    await initialImportSources
    if (screenUnmounted || request !== profilesRequest) return
    const cards = mergeProfileCards(lastProfileData, importSources.value)
    const nextProfiles = cards ? await updateActiveProfile(cards, request) : null
    if (screenUnmounted || request !== profilesRequest) return
    if (!preserveSelection) selectedCard.value = null
    if (!nextProfiles) activeProfileId.value = null
    profiles.value = nextProfiles
  } finally {
    profilesReady.value = true
  }
}

async function updateActiveProfile(data, request) {
  const currentSave = await lua.overhaul_career_career.sendCurrentProfileData()
  if (screenUnmounted || request !== profilesRequest) return data
  activeProfileId.value = currentSave?.id || null
  data.sort((a, b) => new Date(b.date) - new Date(a.date))

  if (currentSave) {
    activeProfileId.value = currentSave.id
    let current = data.find(x => x.id === currentSave.id)
    if (!current) current = currentSave
    data = data.filter(x => x.id !== currentSave.id)
    data.splice(0, 0, current)
  }

  return data
}

function sanitizeProfileFolderName(name) {
  const sanitized = String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
  return sanitized || "profile"
}

function isProfileNameTaken(name) {
  if (!profiles.value || !name) return false
  const trimmed = String(name).trim()
  const lower = trimmed.toLowerCase()
  const sanitized = sanitizeProfileFolderName(trimmed)

  return profiles.value.some(profile => {
    const id = profile?.id != null ? String(profile.id) : ""
    const displayName = profile?.displayName != null ? String(profile.displayName) : ""
    if (id && id.toLowerCase() === lower) return true
    if (displayName && displayName.toLowerCase() === lower) return true
    // .39 saveSystem strips non-alphanumeric for the on-disk folder id
    if (id && sanitizeProfileFolderName(id) === sanitized) return true
    if (displayName && sanitizeProfileFolderName(displayName) === sanitized) return true
    return false
  })
}

function validateName(newName) {
  if (!newName) return "Save name cannot be empty"
  if (newName.length > PROFILE_NAME_MAX_LENGTH) return "Save name cannot be longer than 100 characters"
  const invalidChars = /[<>:"/\\|?*]/
  if (invalidChars.test(newName)) return "Save name cannot contain invalid characters"
  if (isProfileNameTaken(newName)) return "Save name already exists"
  return null
}

function getNewName() {
  const prefix = $translate.contextTranslate("ui.career.profile")
  for (let i = 1; i < 1e3; i++) {
    const id = `${prefix} ${i}`
    if (!isProfileNameTaken(id)) return id
  }
  return `${prefix} 1`
}
</script>

<style lang="scss" scoped>
@use "@/styles/rls_career_overhaul/modules/career/styles/overhaulFocus.scss" as focus;
@use "@/styles/modules/mixins" as *;

// Look of the save strip and its cards. ProfileSelect.vue uses this file inside its scoped block, so every rule
// here stays scoped to that view and still reaches the card roots the view renders.

/* Full-bleed: the strip's own 50% has to be the middle of the screen for the
   featured card to land there. */
.profiles-strip-shell {
  position: relative;
  z-index: 1;

  &::before {
    content: "";
    position: absolute;
    top: -6em;
    right: 0;
    bottom: -6em;
    left: 0;
    background: linear-gradient(
      180deg,
      rgba(11, 15, 25, 0) 0%,
      rgba(11, 15, 25, 0.05) 2%,
      rgba(11, 15, 25, 0.2) 6%,
      rgba(11, 15, 25, 0.5) 18%,
      rgba(11, 15, 25, 0.5) 82%,
      rgba(11, 15, 25, 0.2) 94%,
      rgba(11, 15, 25, 0.05) 98%,
      rgba(11, 15, 25, 0) 100%
    );
    pointer-events: none;
    z-index: 0;
  }
}

/* A window. It has nothing to scroll, so nothing outside this component can
   scroll it — the track inside is moved instead. */
/**
 * `clip`, not `hidden`. Hidden still makes a scroll container — one that nothing
 * can drag but the browser can still scroll itself, which is precisely how
 * focusing a card off to the left kept yanking the strip to the start. Clip
 * creates no scroll container, so there is no scroll position to hijack.
 */
.profiles-strip {
  overflow: clip;
  position: relative;
  z-index: 1;
}

.profiles-track {
  display: flex;
  gap: calc-ui-rem(1);
  padding: 0.25em calc-ui-rem(6) 0.5em calc-ui-rem(6);
  align-items: center;
  position: relative;
  width: max-content;
}

.profiles-empty {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  gap: 0.75em;
  height: calc-ui-rem(28);
  padding: 0 1.5em;
}

.profiles-error {
  padding: 0.75em 1em;
  color: var(--bng-cool-gray-100, #f1f5f9);
  background: var(--bng-cool-gray-900, #111827);
  border-left: 3px solid var(--bng-orange-b400, #ff6600);
}

.profiles-empty-title {
  font-size: 1.1em;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.75);
  white-space: nowrap;
}

.profiles-empty-btn {
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: 8px;
  padding: 0.5em 1em;
  background: rgba(5, 8, 15, 0.7);
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;

  &:hover {
    border-color: rgba(255, 122, 26, 0.6);
    background: rgba(255, 122, 26, 0.08);
  }
}

/**
 * Runway at both ends rather than spacer elements, so the first and last cards
 * can each be scrolled into the middle of the screen like any other.
 *
 * 11rem is half an unselected card — the widest gap any card needs to reach the
 * centre. A selected card is wider and so needs less. The resting position is
 * not scroll zero any more; the strip centres the first save on load.
 */
.profiles-track--hero {
  padding-left: max(#{calc-ui-rem(1.5)}, calc(50vw - #{calc-ui-rem(11)}));
  padding-right: max(#{calc-ui-rem(4)}, calc(50vw - #{calc-ui-rem(11)}));

  /* Held at the selected card's full height, plus this track's own vertical
     padding — the box is border-box, so the padding has to be in the figure.
     Without it the track is only as tall as its tallest child, and mid-step both
     the outgoing and incoming cards are part-way between the two sizes, so the
     strip shrank and the centred panel above it — search box and all — dropped
     and came back. */
  min-height: calc(#{calc-ui-rem(31)} + 0.75em);
}

/* No saves: the create card is alone, so the track fills the window and centres
   it. The strip does not slide here, so nothing fights the centring. */
.profiles-track--create-only {
  width: 100%;
  justify-content: center;
}

/**
 * Every card in the strip is exactly this size, whatever it is showing.
 *
 * 180ms against the scroll's 220ms: the cards must finish growing before the
 * scroll lands, so the strip's final width is settled when the last frame sets
 * the exact position. Centring never measures these mid-flight — it works from
 * the settled widths — so the two can run together.
 */
.profile-card {
  height: calc-ui-rem(28);
  min-height: calc-ui-rem(28);
  max-height: calc-ui-rem(28);
  width: calc-ui-rem(22);
  min-width: calc-ui-rem(22);
  flex: 0 0 auto;
  /* Hundreds of these exist and all but a handful are off screen. Without this
     every one of them is laid out and painted on each step, which starved the
     animation of frames. The intrinsic size matches the real one, so nothing
     shifts when a card comes into view. */
  content-visibility: auto;
  contain-intrinsic-size: calc-ui-rem(22) calc-ui-rem(28);

  /**
   * The size change is not animated, deliberately.
   *
   * A selected card is not a wider version of an unselected one — it is a
   * different layout, artwork beside a panel instead of artwork above a drawer.
   * The layout switches the instant the class does, so while the width was
   * still growing the panel column did not fit and the artwork column was
   * squeezed to nothing, spilling the name and chips across the panel. There is
   * no in-between worth showing. The slide carries the movement instead.
   */
}

/* Measured, never seen: out of flow so it adds nothing to the strip's length. */
.pc-probe {
  position: absolute;
  top: 0;
  left: 0;
  visibility: hidden;
  pointer-events: none;
  height: 0 !important;
  min-height: 0 !important;
  max-height: 0 !important;
}

/* The one card that is always on screen — never skip its rendering. */
/* Browsing: the selection is marked, not opened. */
.profile-card--selected {
  box-shadow: 0 0 0 2px #ff7a1a;
}

.profile-card--hero {
  content-visibility: visible;
  contain-intrinsic-size: auto;
  height: calc-ui-rem(31);
  min-height: calc-ui-rem(31);
  max-height: calc-ui-rem(31);
  width: calc-ui-rem(50);
  min-width: calc-ui-rem(50);
}

.profiles-container {
  font-size: calc-ui-rem();
  margin: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  height: 100%;
  width: 100%;

  .profiles-title {
    font-size: calc-ui-rem() !important;
    :deep(.header) {
      padding: calc-ui-rem(0.5) calc-ui-rem(0.75) calc-ui-rem(0.5) calc-ui-rem(0.5) !important;
    }
  }
}

.profiles-title {
  position: absolute;
  top: calc-ui-rem(-6);
  left: calc-ui-rem(2);
}

/* The toolbar row spans exactly the open card below it (50 rem wide, centred),
   so Back lines up with the card's left edge and Filter with its right edge.
   Every control in the row reads its height from here. */
.profiles-topbar {
  --profiles-control-height: #{calc-ui-rem(2.1)};
  position: relative;
  z-index: 2;
  display: flex;
  align-items: center;
  gap: 0.75em;
  width: calc-ui-rem(50);
  max-width: calc(100% - #{calc-ui-rem(3)});
  margin: 0 auto 0.6em;
}

/* House button, toolbar skin: same plate, border, radius and type size as the
   search field and the sort and filter triggers next to it. Focus keeps the
   house ring from HouseButton. */
.profiles-back.btn {
  height: var(--profiles-control-height);
  padding: 0 0.85em 0 0.7em;
  gap: 0.4em;
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  background: rgba(5, 8, 15, 0.7);
  color: #fff;
  font-size: 0.82em;
  font-weight: 600;

  &:hover:not(:disabled) {
    border-color: rgba(71, 85, 105, 0.8);
    background: rgba(15, 20, 32, 0.85);
  }
}

.profiles-panel {
  display: flex;
  flex-direction: column;
  position: relative;
  isolation: isolate;
  width: 100%;
  padding: 2.75em 0;
}

/* Same rule as the open card: the row is as wide as the lone create card, so
   Back sits on its left edge. */
.profiles-panel--create-only .profiles-topbar {
  width: calc-ui-rem(22);
}

.tooltip-outdated-message {
  padding: calc-ui-rem(0.5);
  max-width: calc-ui-rem(16);
}

/* The dedicated route has no carousel geometry: both steps share one surface,
   so asynchronous save lists cannot move the player away from their choice. */
.profiles-container--new {
  .profiles-panel {
    align-items: center;
    padding: calc-ui-rem(2) calc-ui-rem(4.5);
  }

  .profiles-new-card {
    width: min(#{calc-ui-rem(56)}, 100%);
    height: min(#{calc-ui-rem(34)}, calc(100vh - #{calc-ui-rem(10)}));
    max-height: none;
    min-width: 0;
    min-height: calc-ui-rem(28);
  }

  .profiles-error {
    margin-bottom: 0.75em;
  }

  /* Same rule as the strip: the row is as wide as the one card under it. */
  .profiles-topbar {
    width: min(#{calc-ui-rem(56)}, 100%);
    max-width: none;
  }
}
.profile-card.focus-visible {
  @include focus.overhaul-focus((
    transform 0.22s ease-out,
    border-color 150ms ease,
    height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    min-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    max-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s,
    min-width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s
  ));
}
</style>

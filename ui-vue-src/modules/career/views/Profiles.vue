<template>
  <div v-bng-scoped-nav="{ activateOnMount: true }" class="profiles-container" @deactivate="onDeactivate">
    <BngScreenHeading class="profiles-title" :preheadings="[$ctx_t('ui.playmodes.career')]">{{ $ctx_t("ui.career.savedProgress") }} </BngScreenHeading>
    <BackAside v-bng-on-ui-nav:back,menu="navigateToMainMenu" class="profiles-back" @click="navigateToMainMenu" />

    <div class="profiles-panel">
      <div class="profiles-toolbar">
        <div class="pt-search">
          <input
            v-model="searchQuery"
            class="pt-input"
            placeholder="Search profiles..."
            @focus="onSearchFocus"
            @blur="onSearchBlur" />
        </div>

        <div class="pt-controls">
          <div ref="sortDropdownRef" class="pt-dropdown">
            <button type="button" class="pt-trigger" @click.stop="toggleSort" @mousedown.stop>
              <span>{{ selectedSortLabel }}</span>
              <span class="pt-chevron">&#x25BE;</span>
            </button>
            <teleport to="body">
              <div v-if="sortOpen" class="pt-menu" :style="sortStyle" @click.stop @mousedown.stop>
                <div
                  v-for="opt in sortOptions"
                  :key="opt.value"
                  class="pt-option"
                  :class="{ 'pt-option--active': opt.value === sortMode }"
                  @click.stop="selectSort(opt.value)"
                  @mousedown.stop>
                  {{ opt.label }}
                </div>
              </div>
            </teleport>
          </div>

          <div ref="filterDropdownRef" class="pt-dropdown">
            <button type="button" class="pt-trigger" @click.stop="toggleFilter" @mousedown.stop>
              <span>Filter{{ activeFilterCount > 0 ? ` (${activeFilterCount})` : '' }}</span>
              <span class="pt-chevron">&#x25BE;</span>
            </button>
            <teleport to="body">
              <div v-if="filterOpen" class="pt-menu pt-menu--filter" :style="filterStyle" @click.stop @mousedown.stop>
                <div class="pt-filter-group">
                  <div class="pt-filter-heading">Difficulty</div>
                  <label v-for="d in difficultyFilterOptions" :key="d" class="pt-check">
                    <input type="checkbox" :checked="activeDifficulties.has(d)" @change="toggleDifficultyFilter(d)" />
                    <span>{{ d }}</span>
                  </label>
                </div>
                <div v-if="challengeFilterOptions.length" class="pt-filter-sep" />
                <div v-if="challengeFilterOptions.length" class="pt-filter-group">
                  <div class="pt-filter-heading">Challenge</div>
                  <label v-for="c in challengeFilterOptions" :key="c" class="pt-check">
                    <input type="checkbox" :checked="activeChallenges.has(c)" @change="toggleChallengeFilter(c)" />
                    <span>{{ c }}</span>
                  </label>
                </div>
                <div v-if="activeFilterCount > 0" class="pt-filter-sep" />
                <button v-if="activeFilterCount > 0" class="pt-clear-btn" @click.stop="clearFilters" @mousedown.stop>Clear All</button>
              </div>
            </teleport>
          </div>
        </div>
      </div>

      <div class="profiles-strip-shell">
        <div ref="stripRef" class="profiles-strip" @wheel="onWheel">
          <ProfileCreateCard
            v-model:profileName="newProfileName"
            v-model:active="createCardActive"
            class="profile-card"
            @card:activate="value => onCardActivated(value, -1)"
            @load="onCreateSave" />
          <ProfileCard
            v-for="(profile, index) of filteredProfiles"
            v-bng-popover="profile.incompatibleVersion ? 'tooltip-outdated-message' : null"
            v-bind="profile"
            v-bng-disabled="(isManage && selectedCard !== null && selectedCard !== index) || (isBackup && backupCardIndex !== null && backupCardIndex !== index)"
            :key="profile.id"
            :active="activeProfileId === profile.id"
            :forceCloseManage="selectedCard === -1"
            class="profile-card"
            @card:activate="value => onCardActivated(value, index)"
            @manage:change="value => onManageChange(value, index)"
            @backup:change="active => onBackupChange(active, index)"
            @load="onLoad" />
        </div>
      </div>
    </div>
  </div>
  <BngPopoverContent name="tooltip-outdated-message">
    <template #default>
      <div class="tooltip-outdated-message">This profile was saved with an old version of the game. It can no longer be loaded.</div>
    </template>
  </BngPopoverContent>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, provide, ref, reactive } from "vue"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services"
import { vBngDisabled, vBngPopover, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { BngPopoverContent, BngScreenHeading } from "@/common/components/base"
import BackAside from "../../mainmenu/components/BackAside.vue"
import ProfileCard from "../components/profiles/ProfileCard.vue"
import ProfileCreateCard from "../components/profiles/ProfileCreateCard.vue"
import { useProfilesStore, PROFILE_NAME_MAX_LENGTH } from "../stores/profilesStore"

const store = useProfilesStore()
const { events } = useBridge()

const profiles = ref(null)
const activeProfileId = ref(null)

const selectedCard = ref(null)
const isManage = ref(false)
const isBackup = ref(false)
const backupCardIndex = ref(null)
const newProfileName = ref(null)
const createCardActive = ref(false)

let isLoading = false

const stripRef = ref(null)

const searchQuery = ref("")
const sortMode = ref("lastPlayed")
const activeDifficulties = reactive(new Set())
const activeChallenges = reactive(new Set())

const sortOptions = [
  { value: "lastPlayed", label: "Last Played" },
  { value: "moneyDesc", label: "Money (High to Low)" },
  { value: "moneyAsc", label: "Money (Low to High)" },
  { value: "skillDesc", label: "Top Skill (High to Low)" },
  { value: "skillAsc", label: "Top Skill (Low to High)" },
]
const selectedSortLabel = computed(() => sortOptions.find(o => o.value === sortMode.value)?.label || "Last Played")

const sortDropdownRef = ref(null)
const sortOpen = ref(false)
const sortStyle = ref("")

const filterDropdownRef = ref(null)
const filterOpen = ref(false)
const filterStyle = ref("")

const difficultyFilterOptions = ["Freeroam+", "Casual", "Standard", "Hard", "Hardcore"]

const challengeFilterOptions = computed(() => {
  if (!profiles.value) return []
  const names = new Set()
  for (const p of profiles.value) {
    const ch = p.activeChallenge
    if (!ch) continue
    const name = typeof ch === "string" ? ch : ch.name
    if (name) names.add(name)
  }
  return [...names].sort()
})

const activeFilterCount = computed(() => activeDifficulties.size + activeChallenges.size)

function getProfileDifficulty(p) {
  if (p.cheatsMode) return "Freeroam+"
  const m = typeof p.difficultyMode === "string" ? p.difficultyMode.toLowerCase() : "normal"
  const map = { easy: "Casual", normal: "Standard", hard: "Hard", hardcore: "Hardcore" }
  return map[m] || "Standard"
}

function getProfileChallengeName(p) {
  if (!p.activeChallenge) return null
  return typeof p.activeChallenge === "string" ? p.activeChallenge : p.activeChallenge.name || null
}

function getTopSkillLevel(p) {
  if (!p.freSkills || !p.freSkills.length) return 0
  return Math.max(...p.freSkills.map(s => Number(s.level) || 0))
}

const filteredProfiles = computed(() => {
  if (!profiles.value) return []
  let list = [...profiles.value]

  const q = searchQuery.value.trim().toLowerCase()
  if (q) list = list.filter(p => p.id.toLowerCase().includes(q))

  if (activeDifficulties.size > 0) {
    list = list.filter(p => activeDifficulties.has(getProfileDifficulty(p)))
  }

  if (activeChallenges.size > 0) {
    list = list.filter(p => {
      const name = getProfileChallengeName(p)
      return name && activeChallenges.has(name)
    })
  }

  const activeId = activeProfileId.value
  const active = activeId ? list.find(p => p.id === activeId) : null
  let rest = active ? list.filter(p => p.id !== activeId) : list

  switch (sortMode.value) {
    case "moneyDesc":
      rest.sort((a, b) => (b.money?.value || 0) - (a.money?.value || 0))
      break
    case "moneyAsc":
      rest.sort((a, b) => (a.money?.value || 0) - (b.money?.value || 0))
      break
    case "skillDesc":
      rest.sort((a, b) => getTopSkillLevel(b) - getTopSkillLevel(a))
      break
    case "skillAsc":
      rest.sort((a, b) => getTopSkillLevel(a) - getTopSkillLevel(b))
      break
    default:
      rest.sort((a, b) => new Date(b.date) - new Date(a.date))
  }

  return active ? [active, ...rest] : rest
})

function toggleSort() {
  sortOpen.value = !sortOpen.value
  filterOpen.value = false
  if (sortOpen.value) nextTick(positionSort)
}

function positionSort() {
  if (!sortDropdownRef.value) return
  const trigger = sortDropdownRef.value.querySelector(".pt-trigger")
  if (!trigger) return
  const r = trigger.getBoundingClientRect()
  sortStyle.value = `position:fixed;z-index:2000;top:${r.bottom + 6}px;left:${r.left}px;min-width:${r.width}px;`
}

function selectSort(val) {
  sortMode.value = val
  sortOpen.value = false
}

function toggleFilter() {
  filterOpen.value = !filterOpen.value
  sortOpen.value = false
  if (filterOpen.value) nextTick(positionFilter)
}

function positionFilter() {
  if (!filterDropdownRef.value) return
  const trigger = filterDropdownRef.value.querySelector(".pt-trigger")
  if (!trigger) return
  const r = trigger.getBoundingClientRect()
  filterStyle.value = `position:fixed;z-index:2000;top:${r.bottom + 6}px;left:${r.left}px;min-width:${r.width}px;`
}

function toggleDifficultyFilter(d) {
  if (activeDifficulties.has(d)) activeDifficulties.delete(d)
  else activeDifficulties.add(d)
}

function toggleChallengeFilter(c) {
  if (activeChallenges.has(c)) activeChallenges.delete(c)
  else activeChallenges.add(c)
}

function clearFilters() {
  activeDifficulties.clear()
  activeChallenges.clear()
}

function onDropdownDocClick(e) {
  if (sortOpen.value) {
    const menu = document.querySelector(".pt-menu:not(.pt-menu--filter)")
    const trigger = sortDropdownRef.value?.querySelector(".pt-trigger")
    if (menu && menu.contains(e.target)) return
    if (trigger && trigger.contains(e.target)) return
    sortOpen.value = false
  }
  if (filterOpen.value) {
    const menu = document.querySelector(".pt-menu--filter")
    const trigger = filterDropdownRef.value?.querySelector(".pt-trigger")
    if (menu && menu.contains(e.target)) return
    if (trigger && trigger.contains(e.target)) return
    filterOpen.value = false
  }
}

function onSearchFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}
function onSearchBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function onWheel(evt) {
  if (evt.deltaY !== 0 && stripRef.value) {
    stripRef.value.scrollBy({ left: evt.deltaY, behavior: "instant" })
  }
}

const onLoad = async id => {
  isLoading = true
  await store.loadProfile(id)
}

const onCreateSave = async (profileName, tutorialChecked, difficultyMode, challengeId, cheatsMode, startingMap) => {
  isLoading = true
  await store.loadProfile(profileName, tutorialChecked, true, difficultyMode, challengeId, cheatsMode, startingMap)
}

function onCardActivated(active, index) {
  if (active) {
    selectedCard.value = index
    if (index === -1) {
      newProfileName.value = getNewName()
    } else {
      createCardActive.value = false
    }
  } else {
    selectedCard.value = null
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
  events.on("allCareerSaveSlots", onProfilesReceived)
  lua.career_career.sendAllCareerSaveSlotsData()
  document.addEventListener("mousedown", onDropdownDocClick)
  window.addEventListener("resize", positionSort)
  window.addEventListener("resize", positionFilter)
})

onBeforeUnmount(() => {
  events.off("allCareerSaveSlots", onProfilesReceived)
  document.removeEventListener("mousedown", onDropdownDocClick)
  window.removeEventListener("resize", positionSort)
  window.removeEventListener("resize", positionFilter)
})

provide("validateName", validateName)

function isAnyModalOpen() {
  const selectors = ['.ccm-overlay', '.cdm-overlay', '.pcc-mode-content', '.pcc-map-content', '.pt-menu']
  for (const sel of selectors) {
    const el = document.querySelector(sel)
    if (!el) continue
    const style = window.getComputedStyle(el)
    if (style.display !== 'none' && style.visibility !== 'hidden') return true
  }
  return false
}

const navigateToMainMenu = () => {
  if (isAnyModalOpen()) return
  if (activeProfileId.value) {
    window.bngVue.gotoAngularState("menu.careerPause")
  } else {
    window.bngVue.gotoGameState("menu.mainmenu")
  }
}

const onDeactivate = (event) => {
  if (event?.detail?.force) return
  if (createCardActive.value) return
  if (isBackup.value) return
  if (isAnyModalOpen()) return

  if (isLoading) {
    isLoading = false
  } else {
    navigateToMainMenu()
  }
}

async function onProfilesReceived(data) {
  selectedCard.value = null
  activeProfileId.value = null
  profiles.value = data && data.length > 0 ? await updateActiveProfile(data) : null
}

async function updateActiveProfile(data) {
  const currentSave = await lua.career_career.sendCurrentSaveSlotData()
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

function validateName(newName) {
  if (!newName) return "Save name cannot be empty"
  if (newName.length > PROFILE_NAME_MAX_LENGTH) return "Save name cannot be longer than 100 characters"
  const invalidChars = /[<>:"/\\|?*]/
  if (invalidChars.test(newName)) return "Save name cannot contain invalid characters"
  if (profiles.value && profiles.value.find(profile => profile.id.toLowerCase() === newName.toLowerCase())) return "Save name already exists"
  return null
}

function getNewName() {
  const prefix = $translate.contextTranslate("ui.career.profile")
  let id
  for (let i = 1; i < 1e3; i++) {
    id = `${prefix} ${i}`
    if (!profiles.value || !profiles.value.find(profile => profile.id === id)) break
  }
  return id
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

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

.profiles-back {
  top: calc-ui-rem() !important;
  bottom: calc-ui-rem() !important;
}

.profiles-panel {
  display: flex;
  flex-direction: column;
  position: relative;
  isolation: isolate;
  width: 100%;
  padding: 2.75em 0;
}

.profiles-toolbar {
  display: flex;
  align-items: center;
  gap: 0.75em;
  padding: 0 1.5em 0.6em calc-ui-rem(6);
  flex-shrink: 0;
  position: relative;
  z-index: 2;
}

.profiles-strip-shell {
  padding-left: calc-ui-rem(6);
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

.pt-search {
  flex: 1 1 auto;
  max-width: 20em;
}

.pt-input {
  width: 100%;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  outline: none;

  &::placeholder { color: rgba(255, 255, 255, 0.35); }
  &:focus { border-color: rgba(148, 163, 184, 0.5); }
}

.pt-controls {
  display: flex;
  gap: 0.5em;
  flex-shrink: 0;
}

.pt-dropdown { position: relative; }

.pt-trigger {
  display: flex;
  align-items: center;
  gap: 0.5em;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  cursor: pointer;
  white-space: nowrap;

  &:hover { border-color: rgba(71, 85, 105, 0.8); }
}

.pt-chevron { opacity: 0.5; font-size: 0.9em; }

.pt-menu {
  background: rgba(10, 14, 24, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  font-size: calc-ui-rem();
}

.pt-option {
  padding: 0.4em 0.6em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  font-size: 0.82em;
  white-space: nowrap;

  &:hover { background: rgba(30, 41, 59, 0.6); }
  &.pt-option--active { background: rgba(59, 130, 246, 0.2); color: #60a5fa; }
}

.pt-menu--filter {
  min-width: 14em;
  max-height: 28em;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

.pt-filter-group { padding: 0.25em 0.35em; }
.pt-filter-heading {
  font-size: 0.72em;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.45);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.25em 0.25em 0.35em;
}

.pt-check {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.3em 0.25em;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.82em;
  color: #fff;

  &:hover { background: rgba(30, 41, 59, 0.5); }

  input[type="checkbox"] {
    accent-color: #ff7a1a;
    width: 1em;
    height: 1em;
    cursor: pointer;
  }
}

.pt-filter-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.35);
  margin: 0.25em 0.35em;
}

.pt-clear-btn {
  display: block;
  width: calc(100% - 0.5em);
  margin: 0.25em auto;
  padding: 0.35em;
  border: 0;
  border-radius: 6px;
  background: rgba(239, 68, 68, 0.15);
  color: #f87171;
  font-size: 0.78em;
  font-weight: 600;
  cursor: pointer;

  &:hover { background: rgba(239, 68, 68, 0.25); }
}

.profiles-strip {
  display: flex;
  gap: calc-ui-rem(1);
  padding: 0.25em 0 0.5em 0;
  overflow-x: auto;
  overflow-y: hidden;
  align-items: center;
  position: relative;
  z-index: 1;

  scrollbar-width: thin;
  scrollbar-color: #0b0f19 transparent;

  &::-webkit-scrollbar { height: 10px; }
  &::-webkit-scrollbar-track {
    background: transparent;
  }
  &::-webkit-scrollbar-thumb {
    background: #0b0f19;
    border-radius: 10px;
  }
  &::-webkit-scrollbar-thumb:hover {
    background: #1e2533;
  }
}

.profile-card {
  height: calc-ui-rem(28);
  width: calc-ui-rem(22);
  min-width: calc-ui-rem(22);
}

.tooltip-outdated-message {
  padding: calc-ui-rem(0.5);
  max-width: calc-ui-rem(16);
}
</style>

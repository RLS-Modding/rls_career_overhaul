<template>
  <div
    v-bng-scoped-nav="{ activated: isActive, autoFocusDelay: 0 }"
    v-bng-sound-class="'bng_hover_generic'"
    :class="['pcc', { 'pcc--active': isActive }]"
    @activate="() => setActive(true)"
    @deactivate="onDeactivate">

    <div v-if="!isActive" bng-nav-item class="pcc-cover" @click.stop="setActive(true)">
      <div class="pcc-plus">+</div>
    </div>

    <template v-else>
      <div v-bng-on-ui-nav:menu="onMenu" class="pcc-form">
        <div class="pcc-fields">
          <div class="pcc-field">
            <label class="pcc-label">Profile Name</label>
            <div :class="['pcc-input-wrap', { 'pcc-input-wrap--error': nameError }]">
              <input
                v-bng-text-input
                v-model="profileName"
                :maxlength="PROFILE_NAME_MAX_LENGTH"
                class="pcc-input"
                @input="validateFn(profileName)"
                @focus="onInputFocus"
                @blur="onInputBlur"
                @keydown.enter="onEnter" />
            </div>
            <span v-if="nameError" class="pcc-input-error">{{ nameError }}</span>
          </div>

          <div class="pcc-field">
            <label class="pcc-label">Mode</label>
            <div ref="modeDropdownRef" class="pcc-dropdown">
              <button
                type="button"
                class="pcc-mode-trigger"
                :disabled="challengeId !== null"
                @click.stop="toggleModeDropdown"
                @mousedown.stop>
                <span>{{ selectedModeLabel }}</span>
                <span class="pcc-chevron">&#x25BE;</span>
              </button>
              <teleport to="body">
                <div
                  v-if="modeDropdownOpen"
                  class="pcc-mode-content"
                  :style="modeDropdownStyle"
                  @click.stop
                  @mousedown.stop>
                  <div
                    v-for="opt in modeOptions"
                    :key="opt.value"
                    class="pcc-mode-option"
                    :class="{ 'pcc-mode-selected': opt.value === selectedMode }"
                    @click.stop="selectMode(opt.value)"
                    @mousedown.stop>
                    {{ opt.label }}
                  </div>
                </div>
              </teleport>
            </div>
          </div>

          <ChallengeDropdown
            ref="challengeDropdownRef"
            v-model="challengeId"
            :disabled="selectedMode !== 'normal'" />

          <div v-if="hasOtherMaps" class="pcc-field">
            <label class="pcc-label">Starting Map</label>
            <div ref="mapDropdownRef" class="pcc-dropdown">
              <button
                type="button"
                class="pcc-map-trigger"
                :disabled="isMapDisabled"
                @click.stop="toggleMapDropdown"
                @mousedown.stop>
                <span>{{ selectedMapLabel }}</span>
                <span class="pcc-chevron">&#x25BE;</span>
              </button>
              <teleport to="body">
                <div
                  v-if="mapDropdownOpen"
                  class="pcc-map-content"
                  :style="mapDropdownStyle"
                  @click.stop
                  @mousedown.stop>
                  <div
                    v-if="selectedMap"
                    class="pcc-map-option"
                    @click.stop="clearMap"
                    @mousedown.stop>
                    Default (West Coast USA)
                  </div>
                  <div v-if="selectedMap" class="pcc-map-sep" />
                  <div
                    v-for="map in mapOptions"
                    :key="map.id"
                    class="pcc-map-option"
                    :class="{ 'pcc-map-selected': map.id === selectedMap }"
                    @click.stop="selectMap(map)"
                    @mousedown.stop>
                    {{ map.name }}
                  </div>
                </div>
              </teleport>
            </div>
          </div>
        </div>

        <div class="pcc-btns">
          <button ref="cancelButton" class="pcc-btn pcc-btn--secondary" @click="closeCard">Cancel</button>
          <button ref="startButton" class="pcc-btn pcc-btn--primary" :disabled="nameError !== null" @click="load">Start Game</button>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { inject, nextTick, ref, watch, computed, onMounted, onBeforeUnmount } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngSoundClass, vBngTextInput } from "@/common/directives"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { setFocus } from "@/services/uiNavFocus"
import { lua } from "@/bridge"
import ChallengeDropdown from "./ChallengeDropdown.vue"

const emit = defineEmits(["card:activate", "load"])

const profileName = defineModel("profileName", { required: true })
const isActive = defineModel("active", { type: Boolean, default: false })

const difficultyMode = ref("easy")
const cheatsMode = ref(false)

const modeOptions = [
  { value: "freeroam", label: "Freeroam+" },
  { value: "easy", label: "Casual" },
  { value: "normal", label: "Standard" },
  { value: "hard", label: "Hard" },
  { value: "hardcore", label: "Hardcore" },
]
const selectedMode = computed(() => cheatsMode.value ? "freeroam" : difficultyMode.value)
const selectedModeLabel = computed(() => modeOptions.find(o => o.value === selectedMode.value)?.label || "Casual")

const validateName = inject("validateName")
const nameError = ref(null)
const startButton = ref(null)
const cancelButton = ref(null)
const challengeDropdownRef = ref(null)

const validateFn = name => {
  const res = validateName(name)
  nameError.value = res || null
  return !res
}

const challengeId = ref(null)
const selectedChallenge = ref(null)
const selectedMap = ref(null)
const mapOptions = ref([])
const hasOtherMaps = ref(false)

const mapDropdownRef = ref(null)
const mapDropdownOpen = ref(false)
const mapDropdownStyle = ref("")

const modeDropdownRef = ref(null)
const modeDropdownOpen = ref(false)
const modeDropdownStyle = ref("")

const isMapDisabled = computed(() => {
  if (selectedMode.value === "hardcore") return true
  if (!selectedChallenge.value) return false
  return selectedChallenge.value.map !== null && selectedChallenge.value.map !== undefined
})

const selectedMapLabel = computed(() => {
  if (!selectedMap.value) return "Default (West Coast USA)"
  const map = mapOptions.value.find(m => m.id === selectedMap.value)
  return map ? map.name : "Default (West Coast USA)"
})

function selectMode(value) {
  if (value === "freeroam") {
    cheatsMode.value = true
    difficultyMode.value = "easy"
  } else {
    cheatsMode.value = false
    difficultyMode.value = value
    if (value === "hardcore") {
      selectedMap.value = null
      mapDropdownOpen.value = false
    }
  }
  modeDropdownOpen.value = false
}

function toggleModeDropdown() {
  if (challengeId.value !== null) return
  modeDropdownOpen.value = !modeDropdownOpen.value
  if (modeDropdownOpen.value) nextTick(positionModeDropdown)
}

function positionModeDropdown() {
  if (!modeDropdownRef.value) return
  const trigger = modeDropdownRef.value.querySelector(".pcc-mode-trigger")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  modeDropdownStyle.value = `position:fixed;z-index:2000;top:${rect.bottom + 8}px;left:${rect.left}px;width:${rect.width}px;`
}

function onModeDocClick(e) {
  if (!modeDropdownOpen.value) return
  const dropdown = document.querySelector(".pcc-mode-content")
  const trigger = modeDropdownRef.value?.querySelector(".pcc-mode-trigger")
  if (dropdown && dropdown.contains(e.target)) return
  if (trigger && trigger.contains(e.target)) return
  modeDropdownOpen.value = false
}

function toggleMapDropdown() {
  if (isMapDisabled.value) return
  mapDropdownOpen.value = !mapDropdownOpen.value
  if (mapDropdownOpen.value) nextTick(positionMapDropdown)
}

function positionMapDropdown() {
  if (!mapDropdownRef.value) return
  const trigger = mapDropdownRef.value.querySelector(".pcc-map-trigger")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  mapDropdownStyle.value = `position:fixed;z-index:2000;top:${rect.bottom + 8}px;left:${rect.left}px;width:${rect.width}px;`
}

function onMapDocClick(e) {
  if (!mapDropdownOpen.value) return
  const dropdown = document.querySelector(".pcc-map-content")
  const trigger = mapDropdownRef.value?.querySelector(".pcc-map-trigger")
  if (dropdown && dropdown.contains(e.target)) return
  if (trigger && trigger.contains(e.target)) return
  mapDropdownOpen.value = false
}

function selectMap(map) {
  selectedMap.value = map.id
  mapDropdownOpen.value = false
}

function clearMap() {
  selectedMap.value = null
  mapDropdownOpen.value = false
}

onMounted(async () => {
  try {
    const maps = await lua.overhaul_maps.getMapsExcludingWestCoast()
    if (maps && Object.keys(maps).length > 0) {
      hasOtherMaps.value = true
      mapOptions.value = Object.entries(maps)
        .map(([key, value]) => ({ id: key, name: value }))
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
    }
  } catch (error) {
    console.error("Failed to load maps:", error)
    hasOtherMaps.value = false
  }
  document.addEventListener("mousedown", onMapDocClick)
  document.addEventListener("mousedown", onModeDocClick)
  window.addEventListener("resize", positionMapDropdown)
  window.addEventListener("resize", positionModeDropdown)
  window.addEventListener("scroll", positionMapDropdown, true)
  window.addEventListener("scroll", positionModeDropdown, true)
})

onBeforeUnmount(() => {
  document.removeEventListener("mousedown", onMapDocClick)
  document.removeEventListener("mousedown", onModeDocClick)
  window.removeEventListener("resize", positionMapDropdown)
  window.removeEventListener("resize", positionModeDropdown)
  window.removeEventListener("scroll", positionMapDropdown, true)
  window.removeEventListener("scroll", positionModeDropdown, true)
})

watch(cheatsMode, newVal => {
  if (newVal && challengeId.value !== null) challengeId.value = null
  if (newVal && difficultyMode.value !== "normal" && difficultyMode.value !== "easy") difficultyMode.value = "normal"
})

watch(challengeId, async newVal => {
  if (newVal !== null && cheatsMode.value) cheatsMode.value = false
  if (newVal !== null && difficultyMode.value !== "normal") difficultyMode.value = "normal"
  if (newVal) {
    try {
      const list = await lua.career_challengeModes.getChallengeOptionsForCareerCreation()
      const safeList = Array.isArray(list) ? list : []
      const challenge = safeList.find(c => c.id === newVal)
      selectedChallenge.value = challenge || null
      if (challenge && challenge.map) {
        selectedMap.value = challenge.map
      } else {
        selectedMap.value = null
      }
    } catch (error) {
      console.error("Failed to fetch challenge:", error)
      selectedChallenge.value = null
      selectedMap.value = null
    }
  } else {
    selectedChallenge.value = null
    selectedMap.value = null
  }
})

watch(difficultyMode, newVal => {
  if (newVal !== "normal" && challengeId.value !== null) challengeId.value = null
  if (newVal !== "normal" && cheatsMode.value) cheatsMode.value = false
  if (newVal === "hardcore") {
    selectedMap.value = null
    mapDropdownOpen.value = false
  }
})

const load = () => emit("load", profileName.value, false, difficultyMode.value, challengeId.value, cheatsMode.value, selectedMap.value)

function isModalOpen() {
  if (challengeDropdownRef.value && (challengeDropdownRef.value.createOpen || challengeDropdownRef.value.detailOpen)) return true
  return false
}

function onDeactivate() {
  if (isModalOpen()) return
  setActive(false)
}

function setActive(value) {
  if (value === false && isModalOpen()) return
  if (isActive.value !== value) {
    isActive.value = value
    emit("card:activate", value)
  }
}

function onInputFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onInputBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function onEnter(event) {
  event.preventDefault()
  const focusButton = nameError.value ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value))
}

function onMenu() {
  if (isModalOpen()) return
  setActive(false)
}

function closeCard() {
  if (isActive.value) {
    isActive.value = false
    emit("card:activate", false)
  }
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.pcc {
  position: relative;
  display: flex;
  flex-direction: column;
  height: 100%;
  font-size: calc-ui-rem();
  color: #fff;
  border-radius: calc-ui-rem(1);
  overflow: hidden;
  background: #0b0f19;
}

.pcc-cover {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 1;
  cursor: pointer;
}

.pcc-plus {
  font-size: 8em;
  font-weight: 300;
  line-height: 1;
  color: rgba(255, 255, 255, 0.15);
  user-select: none;
}

.pcc-form {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  padding: 1em;
}

.pcc-fields {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  flex: 1;
  min-height: 0;
  overflow-y: auto;

  :deep(.cd-trigger) {
    border-radius: 8px;
    padding: 0.5em 0.7em;
  }

  :deep(.cd-icon) {
    width: 1.15em;
    height: 1.15em;
  }

  :deep(.cd-name),
  :deep(.cd-placeholder) {
    font-size: inherit;
  }
}

.pcc-field {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.pcc-label {
  font-weight: 600;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.65);
  padding-left: 0.1em;
}

.pcc-input-wrap {
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.1em 0.5em;

  &:focus-within { border-color: rgba(148, 163, 184, 0.5); }
  &.pcc-input-wrap--error { border-color: rgba(239, 68, 68, 0.6); }
}

.pcc-input {
  width: 100%;
  background: none;
  border: 0;
  outline: none;
  color: #fff;
  font-size: 0.88em;
  font-family: inherit;
}

.pcc-input-error {
  font-size: 0.72em;
  color: #f87171;
  padding-left: 0.15em;
}

.pcc-dropdown { position: relative; }

.pcc-mode-trigger,
.pcc-map-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  color: #fff;
  padding: 0.5em 0.7em;
  font-size: 0.88em;
  cursor: pointer;

  &:disabled { opacity: 0.4; cursor: not-allowed; }
  &:hover:not(:disabled) { border-color: rgba(71, 85, 105, 0.8); }
}

.pcc-chevron { opacity: 0.6; }

.pcc-mode-content,
.pcc-map-content {
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  font-size: calc-ui-rem();
}

.pcc-map-content {
  max-height: 28em;
  overflow: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

.pcc-map-content::-webkit-scrollbar { width: 10px; }
.pcc-map-content::-webkit-scrollbar-track { background: rgba(100, 116, 139, 0.2); border-radius: 10px; }
.pcc-map-content::-webkit-scrollbar-thumb {
  background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
  border-radius: 10px;
  border: 2px solid rgba(15, 23, 42, 0.98);
}

.pcc-mode-option,
.pcc-map-option {
  padding: 0.45em 0.55em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  font-size: 0.88em;

  &:hover { background: rgba(30, 41, 59, 0.6); }
}

.pcc-mode-selected,
.pcc-map-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.pcc-map-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.4);
  margin: 0.2em 0;
}

.pcc-btns {
  display: flex;
  gap: 0.5em;
  padding-top: 0.75em;
  margin-top: auto;
}

.pcc-btn {
  flex: 1 1 0;
  border: 0;
  border-radius: 8px;
  padding: 0.45em 0;
  font-size: 0.88em;
  font-weight: 500;
  cursor: pointer;

  &:hover { filter: brightness(1.1); }
  &:active { filter: brightness(0.95); }
  &:disabled { opacity: 0.4; cursor: not-allowed; filter: none; }
}

.pcc-btn--primary {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;
  flex: 2 1 0;
}

.pcc-btn--secondary {
  background: #374151;
  color: #f3f4f6;
}
</style>

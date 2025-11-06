<template>
  <BngCard
    v-bng-scoped-nav="{ activated: isActive }"
    v-bng-blur
    v-bng-sound-class="'bng_hover_generic'"
    :hideFooter="true"
    class="profile-create-card"
    @activate="() => setActive(true)"
    @deactivate="() => setActive(false)">
    <div v-bng-on-ui-nav:menu="onMenu" :class="{ 'create-active': isActive }" class="create-content-container">
      <div v-if="isActive" class="active-content">
        <div class="content-sections">
          <BngInput
            v-model="profileName"
            :maxlength="PROFILE_NAME_MAX_LENGTH"
            :validate="validateFn"
            :errorMessage="nameError"
            externalLabel="Profile Name"
            @keydown.enter="onEnter" />

          <div class="section">
            <ChallengeDropdown ref="challengeDropdownRef" v-model="challengeId" :disabled="cheatsMode" />
          </div>

          <div v-if="hasOtherMaps" class="section">
            <div class="map-dropdown" ref="mapDropdownRef">
              <button 
                type="button" 
                class="map-dropdown-trigger" 
                :disabled="isMapDisabled"
                @click.stop="toggleMapDropdown"
                @mousedown.stop
              >
                <div class="map-dropdown-left">
                  <div class="map-dropdown-icon" :class="selectedMap ? 'map-dropdown-icon-selected' : 'map-dropdown-icon-default'" />
                  <div class="map-dropdown-label" :class="{ 'map-dropdown-placeholder': !selectedMap }">{{ selectedMapLabel }}</div>
                </div>
                <span class="map-dropdown-chevron">▾</span>
              </button>
              <teleport to="body">
                <div 
                  v-if="mapDropdownOpen" 
                  class="map-dropdown-content" 
                  :style="mapDropdownStyle"
                  @click.stop
                  @mousedown.stop
                >
                  <div 
                    v-if="selectedMap"
                    class="map-dropdown-option"
                    @click.stop="clearMap"
                    @mousedown.stop
                  >
                    Default (West Coast USA)
                  </div>
                  <div v-if="selectedMap" class="map-dropdown-sep"></div>
                  <div 
                    v-for="map in mapOptions" 
                    :key="map.id"
                    class="map-dropdown-option"
                    :class="{ 'map-dropdown-selected': map.id === selectedMap }"
                    @click.stop="selectMap(map)"
                    @mousedown.stop
                  >
                    {{ map.name }}
                  </div>
                </div>
              </teleport>
            </div>
          </div>

          <div class="section">
            <div class="modes-section">
              <div class="modes-header">
                <div class="modes-label">Modes</div>
              </div>
              <div class="modes-content">
                <div class="mode-item">
                  <div class="mode-left">
                    <div class="title-icon title-icon-red" />
                    <div class="mode-title">Hardcore</div>
                  </div>
                  <div class="mode-right">
                    <BngSwitch v-model="hardcoreMode" label-before :inline="false" :disabled="cheatsMode"> </BngSwitch>
                  </div>
                </div>

                <div class="mode-item">
                  <div class="mode-left">
                    <div class="title-icon title-icon-green" />
                    <div class="mode-title">Freeroam+</div>
                  </div>
                  <div class="mode-right">
                    <BngSwitch v-model="cheatsMode" label-before :inline="false" :disabled="challengeId !== null || hardcoreMode"> </BngSwitch>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="card-buttons">
          <button ref="startButton" class="modern-btn modern-primary" :disabled="nameError !== null" @click="load">Start Game</button>
          <button ref="cancelButton" class="modern-btn modern-cancel" @click="closeCard">Cancel</button>
        </div>
      </div>
      <div v-if="!isActive" class="create-content-cover" @click="setActive(true)">
        <div class="cover-plus-container">
          <div class="cover-plus-button">+</div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { inject, nextTick, ref, watch, computed, onMounted, onBeforeUnmount } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngBlur, vBngSoundClass } from "@/common/directives"
import { BngButton, BngCard, BngInput, BngSwitch, LABEL_ALIGNMENTS } from "@/common/components/base"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { setFocus } from "@/services/uiNavFocus"
import { lua } from "@/bridge"
import ChallengeDropdown from "./ChallengeDropdown.vue"

const emit = defineEmits(["card:activate", "load"])

const profileName = defineModel("profileName", { required: true })
const hardcoreMode = ref(false)
const cheatsMode = ref(false)
const isActive = ref(false)

const validateName = inject("validateName")
const nameError = ref(null)

const startButton = ref(null)
const cancelButton = ref(null)
const challengeDropdownRef = ref(null)

const validateFn = name => {
  const res = validateName(name)
  if (!res) {
    nameError.value = null
  } else {
    nameError.value = res
  }

  return !res
}

const challengeId = ref(null)
const selectedMap = ref(null)
const mapOptions = ref([])
const hasOtherMaps = ref(false)
const mapDropdownRef = ref(null)
const mapDropdownOpen = ref(false)
const mapDropdownStyle = ref('')

const selectedChallenge = ref(null)

const isMapDisabled = computed(() => {
  if (!selectedChallenge.value) return false
  return selectedChallenge.value.map !== null && selectedChallenge.value.map !== undefined
})

const selectedMapLabel = computed(() => {
  if (!selectedMap.value) return 'Select Map'
  const map = mapOptions.value.find(m => m.id === selectedMap.value)
  return map ? map.name : 'Select Map'
})

function toggleMapDropdown() {
  if (isMapDisabled.value) return
  mapDropdownOpen.value = !mapDropdownOpen.value
  if (mapDropdownOpen.value) {
    nextTick(positionMapDropdown)
  }
}

function positionMapDropdown() {
  if (!mapDropdownRef.value) return
  const trigger = mapDropdownRef.value.querySelector('.map-dropdown-trigger')
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const width = rect.width
  const margin = 8
  const left = rect.left
  const top = rect.bottom + margin
  mapDropdownStyle.value = `position:fixed;z-index:2000;top:${top}px;left:${left}px;width:${width}px;`
}

function onMapDocClick(e) {
  if (!mapDropdownOpen.value) return
  const dropdown = document.querySelector('.map-dropdown-content')
  const trigger = mapDropdownRef.value?.querySelector('.map-dropdown-trigger')
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
      mapOptions.value = Object.entries(maps).map(([key, value]) => ({
        id: key,
        name: value
      }))
    }
  } catch (error) {
    console.error('Failed to load maps:', error)
    hasOtherMaps.value = false
  }
  document.addEventListener('mousedown', onMapDocClick)
  window.addEventListener('resize', positionMapDropdown)
  window.addEventListener('scroll', positionMapDropdown, true)
})

onBeforeUnmount(() => {
  document.removeEventListener('mousedown', onMapDocClick)
  window.removeEventListener('resize', positionMapDropdown)
  window.removeEventListener('scroll', positionMapDropdown, true)
})

watch(cheatsMode, (newVal) => {
  if (newVal && challengeId.value !== null) {
    challengeId.value = null
  }
  if (newVal && hardcoreMode.value) {
    hardcoreMode.value = false
  }
})

watch(hardcoreMode, (newVal) => {
  if (newVal && cheatsMode.value) {
    cheatsMode.value = false
  }
})

watch(challengeId, async (newVal) => {
  if (newVal !== null && cheatsMode.value) {
    cheatsMode.value = false
  }
  
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
      console.error('Failed to fetch challenge:', error)
      selectedChallenge.value = null
      selectedMap.value = null
    }
  } else {
    selectedChallenge.value = null
    selectedMap.value = null
  }
})

const load = () => emit("load", profileName.value, false, hardcoreMode.value, challengeId.value, cheatsMode.value, selectedMap.value)

function setActive(value) {
  if (value === false) {
    const creator = document.querySelector('.ccm-overlay')
    const detailer = document.querySelector('.cdm-overlay')
    if (creator || detailer) {
      return
    }
  }
  console.log('[ProfileCreateCard] setActive:', value)
  isActive.value = value
  emit("card:activate", value)
}

function onEnter(event) {
  event.preventDefault()
  const focusButton = nameError.value ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value))
}

function onMenu() {
  setActive(false)
}

function closeCard() {
  console.log('[ProfileCreateCard] closeCard called')
  isActive.value = false
  emit("card:activate", false)
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profile-create-card {
  font-size: calc-ui-rem();
  color: white;

  :deep(.card-cnt) {
    border-radius: calc-ui-rem(1) !important;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    display: flex;
    flex-direction: column;
    height: 100%;
  }
}


.create-content-container {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  padding: 1.25em;
  gap: 1em;

  &.create-active {
    background: linear-gradient(180deg, rgba(17,24,39,0.95), rgba(17,24,39,0.9));
  }
}

.active-content {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  gap: 0.75em;
}

.content-sections {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
}

.section { 
  display: flex; 
  flex-direction: column; 
  gap: 0; 
  width: 100%;
  flex-shrink: 0;
  
  :deep(.cd-name),
  :deep(.cd-placeholder) {
    font-size: inherit !important;
  }
  
  :deep(.cd-icon) {
    width: 1.25em;
    height: 1.25em;
    aspect-ratio: 1;
  }
  
  :deep(.cd-trigger) {
    padding: 0.75em;
    font-size: inherit;
  }
  
  :deep(.cd-left) {
    gap: 0.75em;
  }
}

.title-icon { 
  width: 1.75em; 
  height: 1.75em; 
  border-radius: 6px; 
  flex-shrink: 0;
  aspect-ratio: 1;
}
.title-icon-red { background: rgba(248, 113, 113, 0.3); }
.title-icon-green { background: rgba(34, 197, 94, 0.3); }

.modes-section {
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  padding: 0.75em;
  width: 100%;
}

.modes-header {
  margin-bottom: 0.5em;
}

.modes-label {
  color: #fff;
  font-weight: 600;
}

.modes-content {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.mode-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.125em 0;
}

.mode-left {
  display: flex;
  align-items: center;
  gap: 0.65em;
}

.mode-right {
  display: flex;
  align-items: center;
}

.mode-item .title-icon {
  width: 1.25em;
  height: 1.25em;
  border-radius: 6px;
  flex-shrink: 0;
  aspect-ratio: 1;
}

.mode-title {
  color: #fff;
  font-weight: 600;
  font-size: 0.85em;
}

.card-buttons {
  display: flex;
  gap: 0.75em;
  justify-content: center;
  padding-top: 1em;
  border-top: 1px solid rgba(100, 116, 139, 0.2);
  margin-top: auto;
}

.modern-btn { 
  border: 0 !important; 
  border-radius: 10px !important; 
  padding: 0.5em 1em !important; 
  box-shadow: 0 6px 16px rgba(0,0,0,0.25) !important; 
  transition: transform 0.08s ease, box-shadow 0.12s ease, filter 0.12s ease; 
  font-size: calc-ui-rem() !important;
  font-weight: 500;
  cursor: pointer;
}
.modern-primary { 
  background-image: linear-gradient(90deg, #ff7a1a, #e85f00) !important; 
  color: #fff !important; 
  flex: 2 1 0%;
  &:hover { filter: brightness(1.05); transform: translateY(-1px); box-shadow: 0 8px 20px rgba(0,0,0,0.35) !important; }
  &:active { transform: translateY(0); filter: brightness(0.98); }
  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    transform: none !important;
  }
}
.modern-cancel { 
  background: rgba(55,65,81,0.85) !important; 
  border: 1px solid rgba(156,163,175,0.4) !important; 
  color: #f3f4f6 !important; 
  flex: 1 1 0%;
  &:hover { 
    filter: brightness(1.1); 
    transform: translateY(-1px); 
    box-shadow: 0 8px 20px rgba(0,0,0,0.3) !important; 
    background: rgba(55,65,81,0.95) !important;
  }
  &:active { transform: translateY(0); filter: brightness(0.98); }
}

.hc-card { 
  display: flex; 
  align-items: center; 
  justify-content: space-between; 
  padding: 0.875em; 
  background: rgba(30,41,59,0.6); 
  border: 1px solid rgba(100,116,139,0.35); 
  border-radius: 12px; 
}
.hc-left { 
  display: flex; 
  align-items: center; 
  gap: 0.65em; 
}
.hc-card .title-icon { 
  width: 1.75em; 
  height: 1.75em; 
  border-radius: 6px; 
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06); 
  flex-shrink: 0;
  aspect-ratio: 1;
}
.hc-card .title-icon-red { background: rgba(148, 63, 63, 0.75); }
.hc-card .title-icon-green { background: rgba(34, 197, 94, 0.75); }
.hc-texts { 
  display: flex; 
  flex-direction: column; 
}
.hc-title { 
  color: #fff; 
  font-weight: 600; 
  font-size: 0.95em;
}
.hc-right { 
  display: flex; 
  align-items: center; 
}

.map-dropdown {
  position: relative;
  width: 100%;
}

.map-dropdown-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  color: #fff;
  padding: 0.75em;
  border-radius: 10px;
  cursor: pointer;
  transition: background 0.2s ease, border-color 0.2s ease;
  font-size: inherit;
  
  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
  
  &:hover:not(:disabled) {
    background: rgba(30, 41, 59, 1);
    border-color: rgba(71, 85, 105, 0.7);
  }
}

.map-dropdown-left {
  display: flex;
  gap: 0.75em;
  align-items: center;
}

.map-dropdown-icon {
  width: 1.25em;
  height: 1.25em;
  border-radius: 6px;
  flex-shrink: 0;
  aspect-ratio: 1;
}

.map-dropdown-icon-default {
  background: rgba(59, 130, 246, 0.2);
}

.map-dropdown-icon-selected {
  background: rgba(59, 130, 246, 0.25);
}

.map-dropdown-label {
  color: #fff;
  font-weight: 600;
}

.map-dropdown-label.map-dropdown-placeholder {
  color: #e5e7eb;
  font-weight: normal;
}

.map-dropdown-chevron {
  opacity: 0.8;
}

.map-dropdown-content {
  position: fixed;
  background: rgba(15, 23, 42, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.6);
  border-radius: 10px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  max-height: 28em;
  overflow: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
  z-index: 2000;
  font-size: calc-ui-rem();
}

.map-dropdown-content::-webkit-scrollbar { width: 10px; }
.map-dropdown-content::-webkit-scrollbar-track { background: rgba(100, 116, 139, 0.2); border-radius: 10px; }
.map-dropdown-content::-webkit-scrollbar-thumb {
  background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
  border-radius: 10px;
  border: 2px solid rgba(15, 23, 42, 0.98);
}
.map-dropdown-content::-webkit-scrollbar-thumb:hover {
  background-image: linear-gradient(180deg, #ff8a2a, #f86f10);
}

.map-dropdown-option {
  padding: 0.5em;
  border-radius: 8px;
  cursor: pointer;
  color: #fff;
  font-size: 0.9em;
  transition: background 0.2s ease;
  
  &:hover {
    background: rgba(30, 41, 59, 0.6);
  }
}

.map-dropdown-option.map-dropdown-selected {
  background: rgba(59, 130, 246, 0.2);
  color: #60a5fa;
}

.map-dropdown-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.5);
  margin: 0.25em 0;
}

.create-content-cover {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  padding: 1em 0;
  flex: 1 0.0001 auto;
  border-radius: var(--bng-corners-1) var(--bng-corners-1) 0 0;
  overflow: hidden;

  > .cover-plus-container {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;

    > .cover-plus-button {
      font-weight: 500;
      font-size: 10em;
      line-height: 1em;
      background-color: transparent;
      flex: 0 0 auto;
      text-align: center;
      color: rgba(255,255,255,0.25);
    }
  }
}
</style>

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
      <div v-show="isActive" class="active-content">
        <div class="content-sections">
          <BngInput
            v-model="profileName"
            :maxlength="PROFILE_NAME_MAX_LENGTH"
            :validate="validateFn"
            :errorMessage="nameError"
            externalLabel="Profile Name"
            @keydown.enter="onEnter" />

          <div class="section">
            <div class="section-title-row">
              <div class="title-icon title-icon-orange" />
              <div class="title-label">Challenge Mode</div>
            </div>
            <ChallengeDropdown ref="challengeDropdownRef" v-model="challengeId" :disabled="cheatsMode" />
          </div>

          <div class="hc-card">
            <div class="hc-left">
              <div class="title-icon title-icon-red" />
              <div class="hc-texts">
                <div class="hc-title">Hardcore</div>
              </div>
            </div>
            <div class="hc-right">
              <BngSwitch v-model="hardcoreMode" label-before :inline="false" :disabled="cheatsMode"> </BngSwitch>
            </div>
          </div>

          <div class="hc-card">
            <div class="hc-left">
              <div class="title-icon title-icon-green" />
              <div class="hc-texts">
                <div class="hc-title">Cheats</div>
              </div>
            </div>
            <div class="hc-right">
              <BngSwitch v-model="cheatsMode" label-before :inline="false" :disabled="challengeId !== null || hardcoreMode"> </BngSwitch>
            </div>
          </div>
        </div>

        <div class="card-buttons">
          <button ref="startButton" class="modern-btn modern-primary" :disabled="nameError !== null" @click="load">Start Game</button>
          <button ref="cancelButton" class="modern-btn modern-cancel" @click="closeCard">Cancel</button>
        </div>
      </div>
      <div v-show="!isActive" class="create-content-cover" @click="setActive(true)">
        <div class="cover-plus-container">
          <div class="cover-plus-button">+</div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { inject, nextTick, ref, watch } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngBlur, vBngSoundClass } from "@/common/directives"
import { BngButton, BngCard, BngInput, BngSwitch, LABEL_ALIGNMENTS } from "@/common/components/base"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { setFocus } from "@/services/uiNavFocus"
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

watch(challengeId, (newVal) => {
  if (newVal !== null && cheatsMode.value) {
    cheatsMode.value = false
  }
})

const load = () => emit("load", profileName.value, false, hardcoreMode.value, challengeId.value, cheatsMode.value)

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
  gap: 1em;
}

.content-sections {
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.section { 
  display: flex; 
  flex-direction: column; 
  gap: 1em; 
}
.section-title-row { 
  display: flex; 
  align-items: center; 
  gap: 0.6em; 
}
.title-icon { 
  width: 20px; 
  height: 20px; 
  border-radius: 6px; 
  flex-shrink: 0;
}
.title-icon-orange { background: rgba(251, 146, 60, 0.3); }
.title-icon-red { background: rgba(248, 113, 113, 0.3); }
.title-icon-green { background: rgba(34, 197, 94, 0.3); }
.title-label { color: #fff; font-weight: 600; font-size: 0.95em; }

.card-buttons {
  display: flex;
  gap: 0.75em;
  justify-content: center;
  padding-top: 1.5em;
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
  width: 22px; 
  height: 22px; 
  border-radius: 6px; 
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06); 
  flex-shrink: 0;
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

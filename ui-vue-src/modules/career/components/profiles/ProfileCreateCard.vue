<template>
  <BngCard
    v-bng-blur
    v-bng-sound-class="'bng_hover_generic'"
    :hideFooter="true"
    :footerStyles="cardFooterStyles"
    class="profile-create-card">
    <div :class="{ 'create-active': isActive }" class="create-content-container">
      <template v-if="isActive">
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

        <div class="actions-row">
          <button ref="startButton" class="modern-btn modern-primary" :disabled="nameError !== null" @click="load">Start Game</button>
          <button ref="cancelButton" class="modern-btn modern-cancel" @click="cancel">Cancel</button>
        </div>
        
      </template>
      <div v-else class="create-content-cover" @click="activateCard">
        <div class="cover-plus-container">
          <div class="cover-plus-button">+</div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script>
const cardFooterStyles = {
  "background-color": "hsla(217, 22%, 12%, 1)",
}
</script>

<script setup>
import { inject, nextTick, ref, computed, watch } from "vue"
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

// TODO: seems hacky but will be updated when input validation has been improved
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
  isActive.value = value
  emit("card:activate", value)
}

function cancel(event) {
  event.preventDefault()
  event.stopPropagation()
  setActive(false)
}

function activateCard(event) {
  event.stopPropagation()
  setActive(true)
}

function onOutsideClick(event) {
  // Only close if clicking outside the card bounds
  if (!event.target.closest('.profile-create-card')) {
    setActive(false)
  }
}

function onEnter(event) {
  event.preventDefault()
  const focusButton = nameError.value ? cancelButton : startButton
  if (focusButton.value) {
    const el = focusButton.value.$el || focusButton.value
    nextTick(() => setFocus(el))
  }
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profile-create-card {
  font-size: calc-ui-rem();
  color: white;

  // temp
  :deep(.card-cnt) {
    border-radius: calc-ui-rem(1) !important;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    display: flex;
    flex-direction: column;
    height: 100%;
  }
  :deep(.bng-button) {
    font-size: calc-ui-rem() !important;
    line-height: calc-ui-rem(1.5) !important;
    margin: calc-ui-rem(0.25) !important;
    &, .background {
      border-radius: calc-ui-rem(0.25) !important;
    }
  }
  :deep(.start-btn-modern) {
    background-image: linear-gradient(90deg, #e96c21, #c85012);
    border: 0 !important;
  }
}


.create-content-container {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  padding: 1em 1.25em 1.25em;
  gap: 1em;

  &.create-active {
    background: linear-gradient(180deg, rgba(17,24,39,0.95), rgba(17,24,39,0.9));
  }
}
.modern-row { display: grid; grid-template-columns: 1fr 1fr; gap: 1em; align-items: start; }
.modern-col { display: flex; flex-direction: column; gap: 0.5em; }

.section { display: flex; flex-direction: column; gap: 0.75em; }
.section-title-row { display: flex; align-items: center; gap: 0.6em; }
.title-icon { width: 18px; height: 18px; border-radius: 6px; }
.title-icon-orange { background: rgba(251, 146, 60, 0.3); }
.title-icon-red { background: rgba(248, 113, 113, 0.3); }
.title-icon-green { background: rgba(34, 197, 94, 0.3); }
.title-label { color: #fff; font-weight: 600; }

.actions-row {
  display:flex;
  gap: 0.75em;
  justify-content: center;
  margin-top: auto;
}

.modern-btn { 
  border: 0 !important; 
  border-radius: 10px !important; 
  padding: 0.45em 0.8em !important; 
  box-shadow: 0 6px 16px rgba(0,0,0,0.25) !important; 
  transition: transform 0.08s ease, box-shadow 0.12s ease, filter 0.12s ease; 
}
.modern-primary { 
  background-image: linear-gradient(90deg, #ff7a1a, #e85f00) !important; 
  color: #fff !important; 
  flex: 2 1 0%;
  &:hover { filter: brightness(1.05); transform: translateY(-1px); box-shadow: 0 8px 20px rgba(0,0,0,0.35) !important; }
  &:active { transform: translateY(0); filter: brightness(0.98); }
}
.modern-cancel { 
  background: rgba(55,65,81,0.75) !important; 
  border: 1px solid rgba(156,163,175,0.4) !important; 
  color: #f3f4f6 !important; 
  flex: 1 1 0%;
  &:hover { filter: brightness(1.06); transform: translateY(-1px); box-shadow: 0 8px 20px rgba(0,0,0,0.3) !important; }
  &:active { transform: translateY(0); filter: brightness(0.98); }
}

.hc-card { display: flex; align-items: center; justify-content: space-between; padding: 0.75em; background: rgba(30,41,59,0.6); border: 1px solid rgba(100,116,139,0.35); border-radius: 14px; }
.hc-left { display: flex; align-items: center; gap: 0.6em; }
.hc-card .title-icon { width: 22px; height: 22px; border-radius: 6px; box-shadow: inset 0 0 0 1px rgba(255,255,255,0.06); }
.hc-card .title-icon-red { background: rgba(148, 63, 63, 0.75); }
.hc-card .title-icon-green { background: rgba(34, 197, 94, 0.75); }
.hc-texts { display: flex; flex-direction: column; }
.hc-title { color: #fff; font-weight: 600; }
.hc-sub { color: #94a3b8; font-size: 0.9em; }
.hc-right { display:flex; align-items:center; }

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

.tutorial-desc {
  padding-top: 1.5em;
  text-align: left;
  color: var(--bng-cool-gray-400);
  margin-top: auto;
  padding-top: 0;

  &.checked {
    color: #fff !important;
  }
}

.challenge-mode {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}
.challenge-panel {
  background: rgba(30, 41, 59, 0.6);
  border: 1px solid rgba(100, 116, 139, 0.3);
  border-radius: calc-ui-rem(0.5);
  padding: 0.75em;
}
.challenge-options {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
}
.challenge-desc {
  color: var(--bng-cool-gray-300);
}
.challenge-custom {
  margin-top: 0.5em;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.5em;
}
</style>

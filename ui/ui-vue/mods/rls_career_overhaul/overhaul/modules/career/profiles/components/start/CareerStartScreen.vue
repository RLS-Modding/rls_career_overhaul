<template>
  <div
    class="css-start-screen career-start-screen"
    v-bng-scoped-nav="{ activateOnMount: true, autoFocusDelay: 0, canDeactivate: () => false }"
    v-bng-on-ui-nav:menu="onMenu"
    @click.stop
    @mousedown.stop
    @keydown.stop
    v-bng-on-ui-nav:back="() => returnToPickerOnBack && onBack()"
    @wheel.stop>
    <div class="css-start-screen-inner career-start-screen__inner">
      <div class="career-start-screen__header">
        <button
          bng-nav-item
          type="button"
          class="career-start-screen__back"
          aria-label="Back to the path picker"
          @click="$emit('back')">‹</button>
        <h2 class="career-start-screen__title">{{ modeLabel }}</h2>

        <!-- The name sits on the title row: it is one field, and the header had
             the width going spare while the settings below wanted the height. -->
        <div class="career-start-screen__name">
          <div data-focus-field :class="['career-start-screen__input-wrap', { 'career-start-screen__input-wrap--error': nameError }]">
            <!-- v-bng-text-input owns CEF typing for the name field; parents must not add focus calls. -->
            <input
              bng-nav-item
              v-bng-text-input
              :value="profileName"
              :maxlength="profileNameMaxLength"
              class="career-start-screen__input"
              aria-label="Profile name"
              placeholder="Profile name..."
              @input="onNameInput"
              @keydown.enter.prevent="$emit('enter')" />
          </div>
        </div>
      </div>

      <p v-if="nameError || configError" class="career-start-screen__error career-start-screen__error--header">
        {{ nameError || configError }}
      </p>

      <div class="career-start-screen__body">
        <section class="career-start-screen__panel" :aria-label="`${modeLabel} settings`">
          <div class="career-start-screen__panel-body">
            <div v-if="mode === 'story'" class="start-panel start-panel--story">
              <!-- The screen is already titled Story and the picker already reads "Select
                   Story"; a "Story" label and a "Story mode" heading made it four. -->
              <div class="start-panel-picker">
                <ChallengeDropdown ref="storyDropdownRef" v-model="storyChallengeId" story-labels preload inline />
              </div>

              <p :class="['start-panel-briefing', { 'start-panel-briefing--empty': !storyChallengeId }]">
                {{ storyBriefingText }}
              </p>

              <div class="start-panel-toggles">
                <StartToggle v-model="storyPoliceEnabled" label="Police" />
                <StartToggle v-model="storyMaintenanceEnabled" label="Maintenance" />
                <StartToggle v-if="APPRENTICESHIP_CHOICE_ENABLED" v-model="storyEmploymentApprenticeship" label="Employment" />
              </div>
            </div>
            <CustomPanel v-else-if="mode === 'custom'" ref="panelRef" />
            <!-- Not compact any more: the card is wide enough to hold the map,
                 garage and toggles outright, so they no longer fold into a
                 popover the player has to open. -->
            <CareerPanel v-else ref="panelRef" @name-hint="$emit('name-hint', $event)" />
          </div>
        </section>
      </div>

      <div class="career-start-screen__footer">
        <button
          bng-nav-item
          type="button"
          class="career-start-screen__btn career-start-screen__btn--primary"
          :disabled="!!nameError"
          @click="onStartClick">
          Start {{ mode === "story" ? "Story" : "Career" }}
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from "vue"
import { lua } from "@/bridge"
import { vBngOnUiNav, vBngScopedNav, vBngTextInput } from "@/common/directives"
import { PROFILE_NAME_MAX_LENGTH } from "../../../stores/profilesStore"
import { getCareerStartModeLabel } from "./careerStartModes.js"
import { APPRENTICESHIP_CHOICE_ENABLED, STORY_MIGRATION_TITLE_KEY } from "./careerStartConfig.js"
import ChallengeDropdown from "../ChallengeDropdown.vue"
import CareerPanel from "./CareerPanel.vue"
import CustomPanel from "./CustomPanel.vue"
import StartToggle from "./shared/StartToggle.vue"

const props = defineProps({
  mode: { type: String, required: true },
  profileName: { type: String, default: "" },
  nameError: { type: String, default: null },
  returnToPickerOnBack: { type: Boolean, default: false },
})

const emit = defineEmits(["update:profileName", "cancel", "back", "start", "enter", "menu", "name-hint"])

const profileNameMaxLength = PROFILE_NAME_MAX_LENGTH
const panelRef = ref(null)
const configError = ref(null)

const MODE_TITLES = { career: "New Career", story: "Story", custom: "Custom Career" }

const modeLabel = computed(() => {
  if (props.mode === "story" && !localStorage.getItem(STORY_MIGRATION_TITLE_KEY)) {
    return "Story (Challenge)"
  }
  return MODE_TITLES[props.mode] || getCareerStartModeLabel(props.mode)
})

const STORY_MODE_HINT = "Pick a story to see what it asks of you."

// The story section exists only in story mode, so its choices start fresh each time that mode opens.
const storyChallengeId = ref(null)
const storyDropdownRef = ref(null)
const storyPoliceEnabled = ref(true)
const storyMaintenanceEnabled = ref(false)
const storyEmploymentApprenticeship = ref(true)
const storyChallengeMeta = ref(null)

const storyBriefingText = computed(() => {
  if (!storyChallengeId.value) return STORY_MODE_HINT
  const description = storyChallengeMeta.value?.description?.trim()
  return description || "This story has no description."
})

async function loadStoryChallengeMeta(id) {
  if (!id) {
    storyChallengeMeta.value = null
    return
  }
  try {
    storyChallengeMeta.value = await lua.overhaul_career_challengeModes.getSingleChallengeForUI(id)
  } catch (_) {
    storyChallengeMeta.value = null
  }
}

watch(storyChallengeId, loadStoryChallengeMeta, { immediate: true })

function resetStorySection() {
  storyChallengeId.value = null
  storyPoliceEnabled.value = true
  storyMaintenanceEnabled.value = false
  storyEmploymentApprenticeship.value = true
  storyChallengeMeta.value = null
}

function getStoryStartConfig() {
  if (!storyChallengeId.value) {
    return { valid: false, error: "Select a story to continue." }
  }
  return {
    valid: true,
    challengeId: storyChallengeId.value,
    policeEnabled: storyPoliceEnabled.value,
    maintenanceEnabled: storyMaintenanceEnabled.value,
    employmentApprenticeship: storyEmploymentApprenticeship.value,
  }
}

watch(() => props.mode, mode => {
  configError.value = null
  if (mode !== "story") resetStorySection()
})

function onNameInput(event) {
  emit("update:profileName", event.target.value)
}

function getPanelConfig() {
  if (props.mode === "story") return getStoryStartConfig()
  return panelRef.value?.getStartConfig?.() ?? { valid: true }
}

function onStartClick() {
  configError.value = null
  const panelConfig = getPanelConfig()
  if (!panelConfig.valid) {
    configError.value = panelConfig.error || "Check your settings before starting."
    return
  }
  if (props.mode === "story") {
    localStorage.setItem(STORY_MIGRATION_TITLE_KEY, "1")
  }
  emit("start", { mode: props.mode, panelConfig })
}

function onMenu() {
  if (isModalOpen()) return
  emit("menu")
}

function onBack() {
  if (!isModalOpen()) emit("back")
}

function isModalOpen() {
  if (panelRef.value?.isAdvancedOpen?.()) return true
  if (panelRef.value?.isModalOpen?.()) return true
  if (storyDropdownRef.value?.isModalOpen?.() === true) return true
  return !!document.querySelector(".css-start-dropdown-menu, .css-sandbox-advanced-overlay, .cd-content.cd-inline, .cd-content.cd-fixed, .ccm-overlay, .cdm-overlay")
}

defineExpose({
  isModalOpen,
  getSelectedMode: () => props.mode,
  getPanelConfig,
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

/* Story section. Nested under its root class so the rules do not reach the
   .start-panel roots of CareerPanel and CustomPanel, which carry this screen's scope id too. */
.start-panel--story {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
  min-height: 0;
  flex: 1;
  height: 100%;

  .start-panel-picker {
    position: relative;
    z-index: 2;
  }

  /* Clamped rather than scrolled: a scrollbar inside a card this size is a worse
     answer than an honest truncation, and the story itself carries the full text.
     The briefing owns the space between the picker and the toggles, so before a
     story is chosen the prompt sits in the middle of it rather than clinging to
     the top of an empty area. */
  .start-panel-briefing {
    margin: 0;
    font-size: 0.84em;
    line-height: 1.45;
    color: rgba(255, 255, 255, 0.78);
    display: -webkit-box;
    -webkit-line-clamp: 5;
    line-clamp: 5;
    -webkit-box-orient: vertical;
    overflow: hidden;
    flex: 1 1 auto;
  }

  /* Only the empty prompt is centred; a real briefing keeps -webkit-box so the
     line clamp still truncates on line boundaries. */
  .start-panel-briefing--empty {
    display: flex;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: rgba(255, 255, 255, 0.45);
    font-style: italic;
  }

  .start-panel-toggles {
    display: flex;
    flex-direction: column;
    gap: 0.35em;
    margin-top: auto;
    padding-top: 0.4em;
    border-top: 1px solid rgba(71, 85, 105, 0.3);
  }
}

/* Fills the create card. Sized by the card, not by the viewport.
   Positioned so the advanced editor can cover exactly this and no more. */
.career-start-screen__inner {
  position: relative;
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #0b0f19;
  overflow: hidden;
}

.career-start-screen__header {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0.5em 0.85em 0.4em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.25);
  flex-wrap: wrap;
}

.career-start-screen__back {
  flex: 0 0 auto;
  width: 1.6em;
  height: 1.6em;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 0;
  border-radius: 6px;
  background: #374151;
  color: #f3f4f6;
  font-size: 1em;
  line-height: 1;
  font-family: inherit;
  cursor: pointer;

  &:hover {
    background: #4b5563;
  }
}

.career-start-screen__title {
  margin: 0;
  font-size: 1.05em;
  font-weight: 700;
  color: #fff;
}

.career-start-screen__error--header {
  margin: 0.35em 0 0;
}

.career-start-screen__name {
  flex: 1 1 16em;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.career-start-screen__input-wrap {
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  padding: 0.2em 0.7em;

  &:focus-within {
    border-color: rgba(224, 107, 50, 0.35);
  }

  &--error {
    border-color: rgba(239, 68, 68, 0.6);
  }
}

.career-start-screen__input {
  width: 100%;
  background: none;
  border: 0;
  outline: none;
  color: #fff;
  font-size: 0.95em;
  font-family: inherit;
  padding: 0.35em 0;
}

.career-start-screen__error {
  font-size: 0.75em;
  color: #f87171;
}

.career-start-screen__body {
  padding: 0.45em 0.85em 0.55em;
  min-height: 0;
  flex: 1;
  overflow: hidden;
}

.career-start-screen__panel {
  display: flex;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
  height: 100%;
  overflow: hidden;
}

.career-start-screen__panel-body {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  /* Card width is fixed; nothing inside may push it sideways. */
  overflow-x: hidden;
  padding: 0 0.15em 0 0;
  display: flex;
  flex-direction: column;

  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

.career-start-screen__footer {
  display: flex;
  gap: 0.5em;
  padding: 0.5em 0.85em 0.75em;
  border-top: 1px solid rgba(71, 85, 105, 0.25);
}

.career-start-screen__btn {
  flex: 1 1 0;
  border: 0;
  border-radius: 10px;
  padding: 0.65em 0;
  font-size: 0.92em;
  font-weight: 600;
  cursor: pointer;

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

.career-start-screen__btn--primary {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;
  flex: 2 1 0;

  &:hover:not(:disabled) {
    filter: brightness(1.08);
  }
}
</style>

<style lang="scss">
/* Default: lives inside the create card — no backdrop, no z-index stack. */
.css-start-screen {
  display: flex;
  flex: 1 1 auto;
  width: 100%;
  min-height: 0;
}

/* Custom only: too many controls for a 22em column, so it gets the room back. */
</style>

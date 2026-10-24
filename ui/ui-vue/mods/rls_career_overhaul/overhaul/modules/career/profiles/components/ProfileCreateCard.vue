<!--
  Map of components/ProfileCreateCard.vue
  Create card owns its editable name and exposes activation and confirmation to the profile strip.
  Read props and model state, name validation and input handlers, then lifecycle and scoped skin.
  Profile creation remains a parent action; the card reports the chosen name.
-->
<template>
  <div
    v-bng-scoped-nav="{ disabled: centered, autoFocusDelay: 0, canDeactivate, canBubbleEvent }"
    v-bng-sound-class="'bng_hover_generic'"
    :class="['pcc', { 'pcc--active': overlayOpen, 'pcc--picker': showModePicker, 'pcc--hero': hero, 'pcc--centered': centered, 'profile-card--hero': hero, 'profile-card--selected': selected }]"
    @activate="onRootActivate"
    @deactivate="onRootDeactivate">

    <Transition :name="centered ? 'pcc-step' : undefined" :css="centered" :appear="centered" @before-leave="onStepLeave" @after-enter="onStepEntered">
      <div
        v-if="!overlayOpen"
        key="picker"
        :bng-nav-item="centered ? null : ''"
        class="pcc-cover"
        @click="hovered = true"
        @mouseenter="hovered = true"
        @mouseleave="onCoverMouseLeave">
        <transition name="pcc-reveal" mode="out-in">
          <div v-if="!showModePicker" key="plus" class="pcc-plus">+</div>
          <div v-else key="picker" class="pcc-picker">
            <!-- Full-bleed art with the copy sitting on it, the same shape as a
                 profile card — no inner panel, so the two read as one family. -->
            <div class="pcc-hero" :style="{ backgroundImage: coverPreview ? `url(${encodeURI(coverPreview)})` : 'linear-gradient(135deg, #182435, #0b0f19)' }">
              <div class="pcc-hero-scrim" />
              <div class="pcc-hero-text">
                <div v-if="descriptionTagline" class="pcc-desc-tagline">{{ descriptionTagline }}</div>
                <div class="pcc-desc-title">{{ descriptionTitle }}</div>
                <p class="pcc-desc-body">{{ descriptionText }}</p>
              </div>
            </div>
            <div class="pcc-mode-btns" @mouseleave="hoveredModeId = null">
              <div v-if="hero" class="pcc-panel-title">Choose a path</div>
              <button
                v-for="mode in CAREER_START_MODES"
                :key="mode.id"
                bng-nav-item
                :bng-scoped-nav-autofocus="centered && mode.id === 'career' ? '' : null"
                type="button"
                class="pcc-mode-btn"
                @mouseenter="hoveredModeId = mode.id"
                @focus="hoveredModeId = mode.id"
                @click.stop="openMode(mode.id)"
                @mousedown.stop>
                <span>{{ mode.label }}</span>
                <span v-if="centered" class="pcc-mode-description">{{ mode.description }}</span>
              </button>
            </div>
          </div>
        </transition>
      </div>

      <!-- Set up on the card itself. Custom used to be lifted out to a dialog of
           its own because it did not fit a 22em column; a selected card is 50em
           wide, so it does. -->
      <CareerStartScreen
        v-else
        key="setup"
        ref="startScreenRef"
        :return-to-picker-on-back="centered"
        :mode="selectedMode"
        :profile-name="profileName"
        :name-error="nameError"
        @name-hint="onNameHint"
        @update:profile-name="onProfileNameUpdate"
        @enter="onEnter"
        @back="backToPicker"
        @cancel="closeOverlay"
        @menu="closeOverlay"
        @start="onStart" />
    </Transition>
  </div>
</template>

<script setup>
import { computed, inject, nextTick, ref, watch } from "vue"
import { vBngScopedNav, vBngSoundClass } from "@/common/directives"
import CareerStartScreen from "./start/CareerStartScreen.vue"
import {
  CAREER_START_MODES,
  CREATE_CARD_DEFAULT_DESCRIPTION,
  getCareerStartMode,
  getCareerStartModeDescription,
  getCareerStartModeLabel,
  getCareerStartModePreview,
} from "./start/careerStartModes.js"
import { buildCareerStartParams } from "./start/careerStartConfig.js"
import { useMapCatalog } from "./start/useStartMaps.js"

const props = defineProps({
  /** First run: with no saves to browse, the card leads with its three paths
      instead of a bare "+" the player has to hover to understand. */
  autoExpand: { type: Boolean, default: false },
  /** Centred in the strip: presents at full size like a selected save. */
  hero: { type: Boolean, default: false },
  /** Ringed while browsing, before anything has expanded. */
  selected: { type: Boolean, default: false },
  /** The New Career route keeps picker and setup at the same screen anchor. */
  centered: { type: Boolean, default: false },
})

const emit = defineEmits(["card:activate", "load"])

const profileName = defineModel("profileName", { required: true })
const overlayOpen = defineModel("active", { type: Boolean, default: false })

const validateName = inject("validateName")
const nameError = ref(null)
const startScreenRef = ref(null)
const selectedMode = ref("career")
const hovered = ref(false)
const navFocused = ref(false)
const hoveredModeId = ref(null)

/** Being the selection is reason enough to show the paths — no hover needed. */
const showModePicker = computed(
  () => (hovered.value || navFocused.value || props.autoExpand || props.hero || props.centered) && !overlayOpen.value
)

const descriptionTitle = computed(() => {
  if (hoveredModeId.value) return getCareerStartModeLabel(hoveredModeId.value)
  return "New Career"
})

const descriptionTagline = computed(() => {
  if (!hoveredModeId.value) return null
  return getCareerStartMode(hoveredModeId.value)?.tagline || null
})

const descriptionText = computed(() => {
  if (hoveredModeId.value) return getCareerStartModeDescription(hoveredModeId.value)
  // In big mode the paths are in the panel to the right, not below the copy.
  if (props.hero) return "Pick a path to set up your new career."
  return CREATE_CARD_DEFAULT_DESCRIPTION
})

const { defaultMap } = useMapCatalog()
const coverPreview = computed(() => getCareerStartModePreview(hoveredModeId.value, defaultMap.value))

const validateFn = name => {
  const res = validateName(name)
  nameError.value = res || null
  return !res
}

/** Once the player types, the suggestion stops touching the field. */
const nameTouched = ref(false)

function onProfileNameUpdate(value) {
  nameTouched.value = true
  profileName.value = value
  validateFn(value)
}

/**
 * Names the save after the choice — "Standard", "Hardcore 2" — instead of
 * "Profile 216". Still one click to accept, and the list stays readable rather
 * than becoming a column of identical auto-numbered names.
 */
function onNameHint(hint) {
  if (!hint || nameTouched.value) return
  const suggestion = firstFreeName(hint)
  if (!suggestion) return
  profileName.value = suggestion
  validateFn(suggestion)
}

function firstFreeName(base) {
  if (!validateName(base)) return base
  for (let i = 2; i < 1e3; i++) {
    const candidate = `${base} ${i}`
    if (!validateName(candidate)) return candidate
  }
  return null
}

function openMode(modeId) {
  selectedMode.value = modeId
  overlayOpen.value = true
  emit("card:activate", true)
}

function onStepLeave(element) {
  // A fading step must stop accepting navigation while its replacement opens.
  if (props.centered) element.inert = true
}

function onStepEntered(element) {
  if (!props.centered) return
  element.querySelector('.pcc-mode-btn, .career-start-screen__back')?.focus({ preventScroll: true })
}

/**
 * The name is regenerated by the parent in response to card:activate, so validate
 * once it has landed. Without this the previous session's error survives the close
 * and leaves Start Game disabled under a name that is perfectly valid.
 */
watch(overlayOpen, isOpen => {
  if (isOpen) nextTick(() => validateFn(profileName.value))
  else {
    nameError.value = null
    nameTouched.value = false
  }
})

/** Collect panel config and map to legacy create params. */
function onStart(payload) {
  if (!validateFn(profileName.value)) return

  const mode = payload?.mode || selectedMode.value
  const panelConfig = payload?.panelConfig || startScreenRef.value?.getPanelConfig?.() || { valid: true }
  if (!panelConfig.valid) return

  const params = buildCareerStartParams(mode, panelConfig)

  emit(
    "load",
    profileName.value,
    false,
    params.difficultyMode,
    params.challengeId,
    params.cheatsMode,
    params.startingMap,
    params.experimentalMaintenanceEnabled,
    params.startingGarageMode,
    params.startingGarageId,
    params.policeEnabled,
    params.employmentApprenticeship,
    params.xpMultiplier,
    params.economyMultiplier,
    params.startingCash,
    params.careerStartMode,
    params.sandboxEconomyProfile,
    params.sandboxXpProfile
  )
}

function isModalOpen() {
  return startScreenRef.value?.isModalOpen?.() === true
}

const canDeactivate = () => !overlayOpen.value
const canBubbleEvent = event => !overlayOpen.value && ["tab_l", "tab_r"].includes(event.detail.name)

function onRootActivate() {
  if (!overlayOpen.value) navFocused.value = true
}

function onRootDeactivate() {
  if (overlayOpen.value) return
  if (isModalOpen()) return
  navFocused.value = false
  hovered.value = false
  hoveredModeId.value = null
}

function onCoverMouseLeave() {
  hovered.value = false
  hoveredModeId.value = null
}

function onEnter() {
  if (!nameError.value) onStart({ mode: selectedMode.value, panelConfig: startScreenRef.value?.getPanelConfig?.() })
}

function closeOverlay() {
  if (overlayOpen.value) {
    overlayOpen.value = false
    navFocused.value = false
    hovered.value = false
    hoveredModeId.value = null
    emit("card:activate", false)
  }
}

/** Back is one step, not an exit: the form collapses to the picker it came from. */
function backToPicker() {
  if (!overlayOpen.value) return
  overlayOpen.value = false
  hoveredModeId.value = null
  hovered.value = true
  emit("card:activate", false)
}

defineExpose({ backToPicker, isModalOpen })
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.pcc {
  position: relative;
  display: flex;
  flex-direction: column;
  /* Height comes from .profile-card. A percentage here resolves against an
     auto-height flex line and lets the card shrink to its content. */
  flex: 0 0 auto;
  min-height: 0;
  font-size: calc-ui-rem();
  color: #fff;
  border-radius: calc-ui-rem(1);
  overflow: hidden;
  background: #0b0f19;
  border: 1px solid rgba(71, 85, 105, 0.35);
  transition:
    transform 0.22s ease-out,
    border-color 150ms ease,
    box-shadow 150ms ease;

  &:not(.pcc--active):hover {
    transform: translateY(-3px);
  }
}

/**
 * Big mode, matching a selected save: artwork on the left at exactly an
 * unselected card's width, the paths in a panel that opens out to the right.
 * The column split and the two-phase timing are the profile card's, so the two
 * behave as one carousel rather than one card that grows and one that does not.
 */
.pcc--hero {
  display: grid;
  grid-template-rows: minmax(0, 1fr);
  grid-template-columns: calc-ui-rem(22) minmax(0, 1fr);

  transition:
    transform 0.22s ease-out,
    height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    min-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    max-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s,
    min-width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s;

  /* It is the anchor of the strip — it should not drift under the cursor. */
  &:not(.pcc--active):hover {
    transform: none;
  }

  .pcc-cover {
    display: contents;
  }

  .pcc-picker {
    display: contents;
  }

  .pcc-hero {
    grid-column: 1;
    grid-row: 1;
  }

  /* Laid out at its final width from the first frame, so the growing column
     reveals it rather than reflowing it. */
  .pcc-mode-btns {
    grid-column: 2;
    grid-row: 1;
    width: calc-ui-rem(28);
    justify-content: center;
    gap: 0.55em;
    padding: 1.1em 1.2em;
  }

  .pcc-mode-btn {
    font-size: 1.05em;
    padding: 0.6em 0.7em;
  }

  .pcc-panel-title {
    margin-bottom: 0.5em;
    font-size: 0.68em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.45);
  }

  .pcc-desc-title {
    font-size: 1.9em;
  }

  .pcc-desc-body {
    font-size: 0.85em;
  }
}

/* Setting up takes the whole card — the artwork/panel split is for the picker. */
.pcc--hero.pcc--active {
  grid-template-columns: minmax(0, 1fr);
}

/* Configuring in place: the card is the surface being operated, so it says so. */
.pcc--active {
  border-color: rgba(255, 122, 26, 0.55);
  box-shadow:
    inset 0 0 0 1px rgba(255, 122, 26, 0.12),
    0 10px 28px rgba(0, 0, 0, 0.45);
}

.pcc--picker {
  border-color: rgba(96, 165, 250, 0.45);
  box-shadow:
    inset 0 0 0 1px rgba(96, 165, 250, 0.12),
    0 8px 24px rgba(0, 0, 0, 0.35);
  transform: translateY(-3px);
}

.pcc-cover {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 1;
  min-height: 0;
  cursor: pointer;
  /* No padding: the hero runs to the card's own rounded, clipped edge. */
  padding: 0;
}

.pcc-plus {
  font-size: 8em;
  font-weight: 300;
  line-height: 1;
  color: rgba(255, 255, 255, 0.15);
  user-select: none;
}

.pcc-reveal-enter-active,
.pcc-reveal-leave-active {
  transition: opacity 0.2s ease, transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
}

.pcc-reveal-enter-from,
.pcc-reveal-leave-to {
  opacity: 0;
  transform: scale(0.98);
}

.pcc-picker {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
}

.pcc-hero {
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  align-items: flex-end;
  background-size: cover;
  background-position: center;
}

.pcc-hero-scrim {
  position: absolute;
  inset: 0;
  background: linear-gradient(
    180deg,
    rgba(11, 15, 25, 0.1) 0%,
    rgba(11, 15, 25, 0.5) 45%,
    rgba(11, 15, 25, 0.93) 100%
  );
  pointer-events: none;
}

.pcc-hero-text {
  position: relative;
  z-index: 1;
  width: 100%;
  padding: 0 1em 0.85em;
  display: flex;
  flex-direction: column;
  gap: 0.15em;
}

.pcc-desc-tagline {
  font-size: 0.68em;
  font-weight: 800;
  letter-spacing: 0.11em;
  text-transform: uppercase;
  color: #ff9647;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.6);
}

.pcc-desc-title {
  font-size: 1.6em;
  font-weight: 900;
  letter-spacing: 0.01em;
  color: #fff;
  line-height: 1.12;
  font-family: "Overpass", var(--fnt-defs);
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.55);
}

.pcc-desc-body {
  margin: 0.15em 0 0;
  font-size: 0.78em;
  line-height: 1.4;
  color: rgba(255, 255, 255, 0.78);
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.5);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.pcc-mode-btns {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  padding: 0.45em 0.5em 0.5em;
  background: #0b0f19;
}

/* Borderless and solid, same family as the profile card's buttons. The border
   was doing the work a background should, which made the stack look like a form. */
.pcc-mode-btn {
  width: 100%;
  border: 0;
  border-radius: 8px;
  padding: 0.42em 0.6em;
  background: #374151;
  color: #f3f4f6;
  font-family: inherit;
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.2;
  text-align: center;
  cursor: pointer;
  transition:
    background 0.12s ease,
    box-shadow 0.12s ease,
    transform 0.06s ease;

  &:hover,
  &.focus-visible {
    background: linear-gradient(90deg, #ff7a1a, #e85f00);
    color: #fff;
    box-shadow: 0 0 0 1px rgba(255, 168, 102, 0.75);
  }

  &.focus-visible {
    outline: 2px solid #ff7a1a;
    outline-offset: 2px;
  }

  &:active {
    background: linear-gradient(90deg, #d95f00, #b34c00);
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }
}

/* Keep layout settled before either step enters; only the composited surface
   moves, rather than resizing the form and reflowing controls mid-animation. */
.pcc--centered {
  grid-template-columns: minmax(0, 1fr);
  transition: none;
  transform: none;

  .pcc-cover {
    display: grid;
    grid-template-columns: minmax(0, 0.85fr) minmax(0, 1.15fr);
    align-items: stretch;
  }

  .pcc-cover,
  .career-start-screen {
    grid-area: 1 / 1;
    min-width: 0;
    width: 100%;
    height: 100%;
  }

  .pcc-mode-btns {
    width: auto;
    min-width: 0;
    gap: 0.8em;
    padding: 1.5em;
  }

  .pcc-mode-btn {
    display: flex;
    flex-direction: column;
    gap: 0.45em;
    padding: 1em;
    text-align: left;
  }

  .pcc-mode-description {
    font-size: 0.78em;
    line-height: 1.45;
    font-weight: 400;
    color: rgba(255, 255, 255, 0.85);
  }

  .pcc-step-enter-active,
  .pcc-step-leave-active {
    transition: transform 280ms ease-out, opacity 280ms ease-out;
  }

  .pcc-step-leave-active {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }

  .pcc-step-enter-from,
  .pcc-step-leave-to {
    opacity: 0;
    transform: scale(0.96);
  }
}

@media (prefers-reduced-motion: reduce) {
  .pcc--centered .pcc-step-enter-active,
  .pcc--centered .pcc-step-leave-active {
    transition: opacity 280ms ease-out;
  }

  .pcc--centered .pcc-step-enter-from,
  .pcc--centered .pcc-step-leave-to {
    transform: none;
  }
}

</style>

<!--
  Map of components/start/SandboxAdvancedModal.vue
  Sandbox options owns the temporary advanced settings and reports changes to its parent.
  Read field definitions and derived labels, option updates, then the scoped modal skin.
  The parent owns the final career-start configuration.
-->
<template>
  <!-- The profile carousel translates and clips its cards. Teleporting keeps
       this page above that stacking context instead of mounting invisibly
       behind the card's overflow boundary. -->
  <Teleport to="body">
    <div
      v-if="open"
      v-bng-scoped-nav="{ activateOnMount: true, autoFocusDelay: 0 }"
      v-bng-on-ui-nav:back,menu="onCloseNav"
      class="css-sandbox-advanced-overlay"
      @click.self="$emit('close')">
      <div class="sandbox-advanced-modal" @click.stop @mousedown.stop>
        <!-- Title, search and close on one row. Stacked they cost 132px of a
             496px card, which is most of what the activity list needs. -->
        <header class="sandbox-advanced-header" data-focus-host>
        <h3>Advanced</h3>
        <input
          v-model="searchQuery"
          v-bng-text-input
          type="search"
          class="sandbox-advanced-search"
          placeholder="Search activities..." />
        <button type="button" class="sandbox-advanced-close" @click="$emit('close')">×</button>
      </header>

      <div class="sandbox-advanced-body">
        <section
          v-for="section in filteredSections"
          :key="section.id"
          class="sandbox-advanced-section">
          <button
            type="button"
            class="sandbox-advanced-section-toggle"
            @click="toggleSection(section.id)">
            <span class="sandbox-advanced-section-chevron" :class="{ open: isSectionOpen(section.id) }">›</span>
            <span>{{ section.label }}</span>
          </button>

          <div v-show="isSectionOpen(section.id)" class="sandbox-advanced-section-body">
            <div
              v-for="child in section.children"
              :key="child.id"
              class="sandbox-advanced-activity">
              <div class="sandbox-advanced-activity-header">
                <span class="sandbox-advanced-activity-title">{{ child.label }}</span>
                <button
                  v-if="child.expandable?.length"
                  type="button"
                  class="sandbox-advanced-expand"
                  @click="toggleExpand(child.id)">
                  {{ isExpanded(child.id) ? "Hide pay details" : "Pay details" }}
                </button>
              </div>

              <div class="sandbox-advanced-activity-sliders">
                <StartSlider
                  :model-value="getPayUmbrellaValue(child.id)"
                  label="Pay"
                  :min="SANDBOX_ECONOMY_MIN"
                  :max="SANDBOX_ECONOMY_MAX"
                  :step="SANDBOX_ECONOMY_STEP"
                  :standard-value="SANDBOX_ECONOMY_DEFAULT"
                  :format="(v) => formatPercentLabel(v, child.id)"
                  @update:model-value="(v) => setPayUmbrellaValue(child.id, v)" />
                <StartSlider
                  :model-value="getXpUmbrellaValue(child.id)"
                  label="XP"
                  :min="SANDBOX_XP_MIN"
                  :max="SANDBOX_XP_MAX"
                  :step="SANDBOX_XP_STEP"
                  :standard-value="SANDBOX_XP_DEFAULT"
                  :format="(v) => formatPercentLabel(v, child.id)"
                  @update:model-value="(v) => setXpUmbrellaValue(child.id, v)" />
              </div>

              <div v-if="child.expandable?.length && isExpanded(child.id)" class="sandbox-advanced-expand-panel">
                <div class="sandbox-advanced-expand-header">
                  <span class="sandbox-advanced-expand-title">Pay by job type</span>
                  <button
                    type="button"
                    class="sandbox-advanced-info-btn"
                    v-bng-tooltip:top="payDetailsInfoTooltip"
                    aria-label="How pay details and inherit work">
                    ?
                  </button>
                </div>
                <div
                  v-for="item in child.expandable"
                  :key="item.id"
                  class="sandbox-advanced-expand-row">
                  <StartSlider
                    :model-value="getPayExpandedValue(item.id, child.id)"
                    :label="item.label"
                    :standard-value="getPayUmbrellaValue(child.id)"
                    :min="SANDBOX_ECONOMY_MIN"
                    :max="SANDBOX_ECONOMY_MAX"
                    :step="SANDBOX_ECONOMY_STEP"
                    :format="(v) => formatPercentLabel(v, child.id)"
                    @update:model-value="(v) => setPayExpandedValue(item.id, child.id, v)" />
                </div>
              </div>
            </div>
          </div>
        </section>

        <p v-if="filteredSections.length === 0" class="sandbox-advanced-empty">
          No activities match your search.
        </p>
      </div>

      <footer class="sandbox-advanced-footer">
        <button type="button" class="sandbox-advanced-done" @click="$emit('close')">Done</button>
      </footer>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { computed, reactive, ref, watch } from "vue"
import { vBngOnUiNav, vBngScopedNav, vBngTextInput } from "@/common/directives"
import { vBngTooltip } from "@/common/directives"
import StartSlider from "./shared/StartSlider.vue"
import {
  SANDBOX_ECONOMY_DEFAULT,
  SANDBOX_ECONOMY_MAX,
  SANDBOX_ECONOMY_MIN,
  SANDBOX_ECONOMY_SECTIONS,
  SANDBOX_ECONOMY_STEP,
  clampRelative,
  isDefaultRelative,
} from "./sandboxEconomyManifest.js"
import {
  SANDBOX_XP_DEFAULT,
  SANDBOX_XP_MAX,
  SANDBOX_XP_MIN,
  SANDBOX_XP_STEP,
} from "./sandboxXpManifest.js"

const props = defineProps({
  open: { type: Boolean, default: false },
  economyMultiplier: { type: Number, default: 1 },
  xpMultiplier: { type: Number, default: 1 },
  policeEnabled: { type: Boolean, default: true },
  modelValue: { type: Object, default: () => ({ umbrellas: {}, expanded: {} }) },
  xpProfile: { type: Object, default: () => ({ umbrellas: {} }) },
})

const emit = defineEmits(["update:modelValue", "update:xpProfile", "close"])

const payDetailsInfoTooltip = {
  text:
    "Pay only — XP uses the Logistics XP slider above.[br][br]" +
    "At Inherit, a job type uses the same pay % as Logistics.[br][br]" +
    "Move a slider to set that job type on its own.",
  isBBCode: true,
  style: {
    "max-width": "24em",
  },
}

const searchQuery = ref("")
const openSections = reactive({})
const expandedRows = reactive({})
let navCloseReadyAt = 0

const localPayProfile = ref(clonePayProfile(props.modelValue))
const localXpProfile = ref(cloneXpProfile(props.xpProfile))

watch(
  () => props.modelValue,
  (value) => {
    localPayProfile.value = clonePayProfile(value)
  },
  { deep: true }
)

watch(
  () => props.xpProfile,
  (value) => {
    localXpProfile.value = cloneXpProfile(value)
  },
  { deep: true }
)

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      // Activating a nested BeamNG nav scope can replay the action that opened
      // it. Ignore that pulse or the modal closes in the same frame it mounts.
      navCloseReadyAt = Date.now() + 250
      localPayProfile.value = clonePayProfile(props.modelValue)
      localXpProfile.value = cloneXpProfile(props.xpProfile)
      for (const section of SANDBOX_ECONOMY_SECTIONS) {
        if (openSections[section.id] === undefined) {
          openSections[section.id] = true
        }
      }
    }
  }
)

function onCloseNav() {
  if (Date.now() < navCloseReadyAt) return
  emit("close")
}

function clonePayProfile(value) {
  const src = value && typeof value === "object" ? value : {}
  return {
    umbrellas: { ...(src.umbrellas || {}) },
    expanded: { ...(src.expanded || {}) },
  }
}

function cloneXpProfile(value) {
  const src = value && typeof value === "object" ? value : {}
  return {
    umbrellas: { ...(src.umbrellas || {}) },
  }
}

function syncPayProfile() {
  emit("update:modelValue", clonePayProfile(localPayProfile.value))
}

function syncXpProfile() {
  emit("update:xpProfile", cloneXpProfile(localXpProfile.value))
}

function isSectionOpen(sectionId) {
  return openSections[sectionId] !== false
}

function toggleSection(sectionId) {
  openSections[sectionId] = !isSectionOpen(sectionId)
}

function isExpanded(childId) {
  return expandedRows[childId] === true
}

function toggleExpand(childId) {
  expandedRows[childId] = !isExpanded(childId)
}

function getPayUmbrellaValue(umbrellaId) {
  const value = localPayProfile.value.umbrellas?.[umbrellaId]
  return typeof value === "number" ? clampRelative(value) : SANDBOX_ECONOMY_DEFAULT
}

function setPayUmbrellaValue(umbrellaId, value) {
  const clamped = clampRelative(value)
  if (!localPayProfile.value.umbrellas) {
    localPayProfile.value.umbrellas = {}
  }
  if (isDefaultRelative(clamped)) {
    delete localPayProfile.value.umbrellas[umbrellaId]
  } else {
    localPayProfile.value.umbrellas[umbrellaId] = clamped
  }
  syncPayProfile()
}

function getPayExpandedValue(economyKey, parentUmbrellaId) {
  const explicit = localPayProfile.value.expanded?.[economyKey]
  if (typeof explicit === "number") {
    return clampRelative(explicit)
  }
  return getPayUmbrellaValue(parentUmbrellaId)
}

function setPayExpandedValue(economyKey, parentUmbrellaId, value) {
  const clamped = clampRelative(value)
  const inherited = getPayUmbrellaValue(parentUmbrellaId)
  if (!localPayProfile.value.expanded) {
    localPayProfile.value.expanded = {}
  }
  if (Math.abs(clamped - inherited) < 0.001) {
    delete localPayProfile.value.expanded[economyKey]
  } else {
    localPayProfile.value.expanded[economyKey] = clamped
  }
  syncPayProfile()
}

function getXpUmbrellaValue(umbrellaId) {
  const value = localXpProfile.value.umbrellas?.[umbrellaId]
  return typeof value === "number" ? clampRelative(value) : SANDBOX_XP_DEFAULT
}

function setXpUmbrellaValue(umbrellaId, value) {
  const clamped = clampRelative(value)
  if (!localXpProfile.value.umbrellas) {
    localXpProfile.value.umbrellas = {}
  }
  if (isDefaultRelative(clamped)) {
    delete localXpProfile.value.umbrellas[umbrellaId]
  } else {
    localXpProfile.value.umbrellas[umbrellaId] = clamped
  }
  syncXpProfile()
}

function formatPercentLabel(value, umbrellaId) {
  if (umbrellaId === "police" && !props.policeEnabled) {
    return "Disabled (police off)"
  }
  return `${Math.round(Number(value) * 100)}%`
}

const filteredSections = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) {
    return SANDBOX_ECONOMY_SECTIONS
  }

  return SANDBOX_ECONOMY_SECTIONS.map((section) => {
    // A section-name hit keeps all of its children: searching "race" should reach
    // Racing & Events rather than reporting no matches while it sits on screen.
    if (section.label.toLowerCase().includes(q)) return section

    const children = (section.children || []).filter((child) => {
      if (child.label.toLowerCase().includes(q)) return true
      return (child.expandable || []).some((item) => item.label.toLowerCase().includes(q))
    })
    if (children.length === 0) return null
    return { ...section, children }
  }).filter(Boolean)
})
</script>

<style lang="scss" scoped>
.sandbox-advanced-modal {
  width: min(50em, calc(100vw - 2em));
  height: min(31em, calc(100vh - 2em));
  display: flex;
  flex-direction: column;
  background: #0b0f19;
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: 16px;
  box-shadow: 0 24px 60px rgba(0, 0, 0, 0.65);
  overflow: hidden;
}

.sandbox-advanced-header {
  display: flex;
  align-items: center;
  gap: 0.7em;
  padding: 0.5em 0.8em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.35);

  h3 {
    flex: 0 0 auto;
    margin: 0;
    font-size: 1em;
    color: #fff;
  }
}


.sandbox-advanced-close {
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.6);
  font-size: 1.5em;
  line-height: 1;
  cursor: pointer;
  padding: 0 0.2em;

  &:hover {
    color: #fff;
  }
}


.sandbox-advanced-search {
  flex: 1 1 auto;
  min-width: 0;
  box-sizing: border-box;
  background: rgba(30, 41, 59, 0.9);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 10px;
  color: #fff;
  padding: 0.4em 0.7em;
  font-size: 0.85em;
  font-family: inherit;
  outline: none;

  &:focus {
    border-color: rgba(148, 163, 184, 0.5);
  }
}

.sandbox-advanced-body {
  flex: 1 1 auto;
  overflow: auto;
  padding: 0.5em 1.25em 1em;
}

.sandbox-advanced-section + .sandbox-advanced-section {
  margin-top: 0.5em;
}

.sandbox-advanced-section-toggle {
  /**
   * A heading, not a card. A filled rounded box at every section made the list
   * read as tiles of equal weight, when these are just the divisions between
   * groups of activities. Small, quiet, ruled underneath.
   */
  width: 100%;
  display: flex;
  align-items: center;
  gap: 0.4em;
  border: 0;
  border-bottom: 1px solid rgba(71, 85, 105, 0.4);
  border-radius: 0;
  background: none;
  color: rgba(255, 255, 255, 0.62);
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  text-align: left;
  padding: 0.4em 0.1em 0.32em;
  cursor: pointer;

  &:hover {
    color: rgba(255, 255, 255, 0.8);
    border-bottom-color: rgba(148, 163, 184, 0.6);
  }
}

.sandbox-advanced-section-chevron {
  display: inline-block;
  font-size: 1.2em;
  line-height: 1;
  transition: transform 0.15s ease;
  transform: rotate(0deg);

  &.open {
    transform: rotate(90deg);
  }
}

.sandbox-advanced-section-body {
  padding: 0.65em 0.15em 0.25em;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.sandbox-advanced-activity {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  padding: 0.55em 0 0.65em;

  & + & {
    border-top: 1px solid rgba(71, 85, 105, 0.22);
  }
}

.sandbox-advanced-activity-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75em;
  padding-right: 0.35em;
}

.sandbox-advanced-activity-title {
  /* Was the largest text on the page while its own section heading was the
     smallest, which read as backwards. Sits between the heading above it and
     the slider labels below. */
  font-size: 0.82em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.85);
  letter-spacing: 0.01em;
}

.sandbox-advanced-activity-sliders {
  /* Pay and XP side by side. Stacked, one activity cost two full slider rows
     and only a handful fitted on the card at a time. */
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.3em 1.4em;
  margin-left: 1.15em;
  margin-right: 0.75em;
  max-width: calc(100% - 1.9em);

  :deep(.start-slider) {
    gap: 0.32em;
  }

  :deep(.start-slider-header) {
    min-height: 1em;
  }

  :deep(.start-slider-label) {
    font-size: 0.78em;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.58);
  }

  :deep(.start-slider-value) {
    font-size: 0.74em;
  }

  :deep(.start-slider-scale) {
    font-size: 0.66em;
    color: rgba(255, 255, 255, 0.38);
  }

  /* Smaller sliders for a dense list — set once, and the thumb, rail and
     baseline tick all follow. */
  :deep(.start-slider-track) {
    --thumb-size: 0.8em;
    --rail-height: 0.32em;
  }

  :deep(.start-slider-baseline-marker) {
    height: 0.6em;
  }
}

.sandbox-advanced-expand {
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: 8px;
  background: rgba(15, 23, 42, 0.9);
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.78em;
  padding: 0.45em 0.65em;
  cursor: pointer;
  white-space: nowrap;
  flex-shrink: 0;

  &:hover {
    border-color: rgba(224, 107, 50, 0.35);
    color: #fff;
  }
}

.sandbox-advanced-expand-panel {
  margin-top: 0.15em;
  margin-left: 1.15em;
  margin-right: 0.75em;
  max-width: calc(100% - 1.9em);
  padding-left: 0.85em;
  border-left: 2px solid rgba(71, 85, 105, 0.45);
  display: flex;
  flex-direction: column;
  gap: 0.65em;

  :deep(.start-slider-label) {
    font-size: 0.76em;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.55);
  }

  :deep(.start-slider-scale) {
    font-size: 0.64em;
  }
}

.sandbox-advanced-expand-header {
  display: flex;
  align-items: center;
  gap: 0.45em;
  margin-bottom: 0.15em;
  padding: 0.55em 0.7em;
  border-radius: 8px;
  background: rgba(30, 41, 59, 0.55);
}

.sandbox-advanced-expand-title {
  font-size: 0.85em;
  font-weight: 600;
  color: #fff;
  letter-spacing: 0.02em;
  text-transform: uppercase;
}

.sandbox-advanced-info-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1.35em;
  height: 1.35em;
  padding: 0;
  border: 1px solid rgba(71, 85, 105, 0.65);
  border-radius: 50%;
  background: rgba(15, 23, 42, 0.9);
  color: rgba(255, 255, 255, 0.65);
  font-size: 0.78em;
  font-weight: 700;
  font-family: inherit;
  line-height: 1;
  cursor: pointer;

  &:hover,
  &.focus-visible {
    border-color: rgba(224, 107, 50, 0.45);
    color: #fff;
    outline: none;
  }
}

.sandbox-advanced-empty {
  margin: 1em 0;
  text-align: center;
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.9em;
}

.sandbox-advanced-footer {
  padding: 0.4em 0.8em 0.5em;
  border-top: 1px solid rgba(71, 85, 105, 0.35);
  display: flex;
  justify-content: flex-end;
}

.sandbox-advanced-done {
  border: 0;
  border-radius: 7px;
  padding: 0.32em 0.9em;
  background: #ff7a1a;
  color: #fff;
  font-size: 0.85em;
  font-weight: 600;
  cursor: pointer;

  &:hover {
    background: #ff9647;
  }
}
</style>

<style lang="scss">
.css-sandbox-advanced-overlay {
  position: fixed;
  inset: 0;
  z-index: 2200;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.72);
  backdrop-filter: blur(4px);
}
</style>

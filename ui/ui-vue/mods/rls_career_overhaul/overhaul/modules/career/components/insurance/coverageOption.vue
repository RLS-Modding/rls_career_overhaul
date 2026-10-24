<template>
  <div class="coverage-options" :class="{ 'in-row': coverageOption.choiceType === 'toggle' }">
    <InsurancePerkNotice v-if="coverageOption.perkText && showPerkMode === 'deportedLabel'" :perkText="coverageOption.perkText" />
    <div v-if="!dontShowName" class="coverage-option-name">{{ coverageOption.name }}</div>
    <div class="choices" v-if="coverageOption.choiceType === 'multiple'" :class="{ 'main-only': onlyShowMainText }">
      <Button
        class="choice"
        :class="{ 'selected': choice.id === changedCoverageOptions[coverageOption.key], 'current': choice.id === getSelectedValueId(), 'disabled': choice.disabled }"
        v-for="choice in coverageOption.choices"
        :key="choice"
        :disabled="choice.disabled"
        :tab-index="-1"
        :nav-item="false"
        @click="() => onChoiceClick(coverageOption, choice)"
      >
        <div class="choice-label">
          {{ choice.choiceText }}
        </div>

        <div  v-if="!onlyShowMainText">
          <div v-if="choice.secondaryText" class="choice-secondary-text">
            {{ choice.secondaryText }}
          </div>
          <div v-else class="choice-price">
            <BngUnit :money="choice.premiumInfluence" />
          </div>
        </div>
      </Button>
    </div>
    <div v-else-if="coverageOption.choiceType === 'toggle'" class="toggle-container">
      <div class="toggle-price">
        <BngUnit :money="getTogglePrice(coverageOption)" />
      </div>
      <HouseSwitch class="toggle-switch"
        :model-value="getToggleValue(coverageOption)"
        @update:modelValue="(newValue) => onToggleChange(coverageOption, newValue)"
      />
    </div>
  </div>
</template>

<script setup>
import InsurancePerkNotice from "./insurancePerkNotice.vue"
import { BngUnit } from "@/common/components/base"
import { Button } from "@/common/components/utility"
import { HouseSwitch } from "../house/index.js"
import { watch } from "vue"
import "./insuranceStyle.css"

const props = defineProps({
  coverageOption: {
    type: Object,
    required: true,
  },
  changedCoverageOptions: {
    type: Object,
    required: false,
    default: () => ({}),
  },
  onlyShowMainText: {
    type: Boolean,
    default: false,
  },
  simpleSelect: {
    type: Boolean,
  },
  modelValue: {
    type: Number,
    required: false,
  },
  showPerkMode: {
    type: String,
    default: "deportedLabel",
  },
  dontShowName: {
    type: Boolean,
    default: false,
  }
})

const emit = defineEmits(["choiceClick", "toggleChange", "update:modelValue"])

// Watch for changes in coverageOption.choices and reset modelValue if it's out of bounds
watch(() => props.coverageOption?.choices, (newChoices) => {
  if (props.modelValue !== undefined && props.modelValue !== null && newChoices) {
    const maxValidId = newChoices.length
    if (props.modelValue > maxValidId) {
      emit("update:modelValue", 1)
    }
  }
}, { immediate: true })

const getSelectedValueId = () => {
  if (props.modelValue !== undefined && props.modelValue !== null) {
    return Math.min(props.modelValue, props.coverageOption.choices.length)
  }
  return props.changedCoverageOptions[props.coverageOption.key]
}

const getToggleValue = (coverageOption) => {
  const selectedValueId = props.changedCoverageOptions[coverageOption.key] ?? coverageOption.currentValueId
  const trueChoiceIndex = coverageOption.choices.findIndex(choice => choice.value === true)
  return selectedValueId === trueChoiceIndex + 1
}

const getTogglePrice = (coverageOption) => {
  const selectedValueId = props.changedCoverageOptions[coverageOption.key] ?? coverageOption.currentValueId
  const selectedChoice = coverageOption.choices[selectedValueId - 1]
  return selectedChoice?.premiumInfluence || 0
}

const onToggleChange = (coverageOption, newValue) => {
  emit("toggleChange", coverageOption, newValue)
}

const onChoiceClick = (coverageOption, choice) => {
  if (choice.disabled) return
  if (props.simpleSelect) {
    coverageOption.currentValueId = choice.id
  }

  // If modelValue is provided, emit update:modelValue for v-model support
  if (props.modelValue !== undefined && props.modelValue !== null) {
    emit("update:modelValue", choice.id)
  }

  emit("choiceClick", coverageOption, choice)
}
</script>

<style scoped lang="scss">
/* RLS house: a labelled row of equal-width choices (Style Guide .seg). The picked choice is the
   brighter panel with accent-soft text; no orange fills, no green/orange borders. Fixed height so
   choices with and without a second line match. Also used by the (vanilla) repair screen, so the
   tokens carry literal fallbacks. */
.coverage-options {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-width: 0;

  &.in-row {
    flex-direction: row;
    align-items: center;
    justify-content: space-between;
    gap: 0.8em;
    min-height: 2.4em;
  }
}

.coverage-option-name {
  font-weight: 700;
  line-height: 1.2;
}

.choices {
  display: flex;
  flex-direction: row;
  gap: 0.4em;
}

.choice {
  --bng-content-flow: column;
  --bng-content-align: center;
  --bng-content-justify: center;
  --bng-button-min-width: 0;
  --bng-button-max-width: none;
  --bng-button-margin: 0;
  --bng-button-padding: 0.4em;
  --bng-button-padding-top: 0.6em;
  --bng-button-padding-bottom: 0.45em;
  --bng-bg-border-radius: var(--radius-control, 0.6em);
  --bng-bg-border-width: 0;
  --bng-bg-enabled: rgba(255, 255, 255, 0.06);
  --bng-bg-hover: rgba(255, 255, 255, 0.1);
  --bng-bg-active: rgba(255, 255, 255, 0.1);
  --bng-bg-focus: rgba(255, 255, 255, 0.1);
  --bng-bg-disabled: rgba(255, 255, 255, 0.06);
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-focus-opacity: 1;
  --bng-bg-disabled-opacity: 1;
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-bg-border-focus: transparent;
  --bng-bg-border-disabled: transparent;
  --bng-button-text-enabled-color: var(--muted, rgba(255, 255, 255, 0.72));
  --bng-button-text-hover-color: #fff;
  --bng-button-text-focus-color: #fff;
  --bng-button-text-active-color: #fff;

  flex: 1 1 0;
  position: relative;
  min-width: 0;
  min-height: 3.5em;
  font-size: 1em;
  line-height: 1.2;
  // controller (.focus-visible) and keyboard focus: the house ring from the surrounding .rls-house,
  // in place of the game's ::before frame
  &.focus-visible {
    outline: none;
    box-shadow: var(--focus, 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px #ff6600);
  }
  &.focus-visible::before {
    display: none !important;
  }
  display: flex;
  flex-direction: column;
  gap: 0.15em;
  justify-content: center;
  align-items: center;
  text-align: center;

  &.current {
    --bng-bg-enabled: rgba(255, 255, 255, 0.1);
    --bng-bg-hover: rgba(255, 255, 255, 0.14);
    --bng-bg-focus: rgba(255, 255, 255, 0.14);
    --bng-bg-active: rgba(255, 255, 255, 0.14);
    --bng-button-text-enabled-color: var(--accent-soft, #ffb27a);
    --bng-button-text-hover-color: var(--accent-soft, #ffb27a);
    --bng-button-text-focus-color: var(--accent-soft, #ffb27a);
    --bng-button-text-active-color: var(--accent-soft, #ffb27a);
  }

  &.disabled {
    opacity: 0.45;
  }
}

.choices.main-only .choice {
  min-height: 2.6em;
}

.choice-label {
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.choice-price,
.choice-secondary-text {
  font-size: 0.82em;
  font-weight: 600;
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-variant-numeric: tabular-nums;
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }
}

.toggle-container {
  flex: 0 0 auto;
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.8em;
}

.toggle-price {
  min-width: 4.5em;
  text-align: right;
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.88em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  :deep(.info-item) {
    --paddings: 0;
    --units-icon-color: currentColor;
  }
}
</style>

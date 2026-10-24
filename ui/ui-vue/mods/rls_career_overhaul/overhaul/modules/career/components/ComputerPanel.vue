<template>
  <div class="computer-panel" :class="{ 'panel-active-controller': showActiveStyle, 'panel-inactive-controller': showInactiveStyle }">
    <slot v-if="hasHeading" name="heading">
      <div class="heading-container">
        <span v-if="showHintStart" class="heading-hint">
          <BngIcon v-if="headingHintStartIcon" :type="headingHintStartIcon" />
          <BngBinding v-if="headingHintStartBindingEvent" :ui-event="headingHintStartBindingEvent" controller />
        </span>

        <BngCardHeading :type="headingType" :outline="headingOutline" class="heading">
          <slot name="heading-content">{{ heading }}</slot>
        </BngCardHeading>

        <span v-if="showHintEnd" class="heading-hint">
          <BngIcon v-if="headingHintEndIcon" :type="headingHintEndIcon" />
          <BngBinding v-if="headingHintEndBindingEvent" :ui-event="headingHintEndBindingEvent" controller />
        </span>
      </div>
    </slot>

    <div class="panel-content">
      <slot></slot>
    </div>

    <div v-if="hasFooter" class="footer-container">
      <slot name="footer"></slot>
    </div>
  </div>
</template>

<script setup>
import { useSlots, computed } from "vue"
import { storeToRefs } from "pinia"
import { BngCardHeading, BngIcon, BngBinding } from "@/common/components/base"
import useControls from "@/services/controls"

const props = defineProps({
  heading: String,
  headingType: {
    type: String,
    default: "line",
  },
  headingOutline: Boolean,
  active: {
    type: Boolean,
    default: true,
  },
  forceHideHints: Boolean,
  headingHintStartIcon: String,
  headingHintStartBindingEvent: String,
  headingHintEndIcon: String,
  headingHintEndBindingEvent: String,
})

const slots = useSlots()

const { isControllerUsed } = storeToRefs(useControls())

const hasFooter = computed(() => slots.footer)

const hasHeadingHintStart = computed(() => Boolean(props.headingHintStartIcon || props.headingHintStartBindingEvent))
const hasHeadingHintEnd = computed(() => Boolean(props.headingHintEndIcon || props.headingHintEndBindingEvent))

const hintsVisible = computed(() => isControllerUsed.value && !props.active && !props.forceHideHints)

const showHintStart = computed(() => hintsVisible.value && hasHeadingHintStart.value)
const showHintEnd = computed(() => hintsVisible.value && hasHeadingHintEnd.value && !hasHeadingHintStart.value)

const showActiveStyle = computed(() => isControllerUsed.value && props.active)

const showInactiveStyle = computed(() => isControllerUsed.value && !props.active)

const hasHeading = computed(() => Boolean(props.heading || slots.heading || slots["heading-content"] || showHintStart.value || showHintEnd.value))
</script>

<style lang="scss" scoped>
.computer-panel {
  --bg-opacity: 0.6;
  font-size: 1rem;
  font-family: "Overpass", var(--fnt-defs);
  padding: 0;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  position: relative;
  border-radius: var(--bng-corners-2);
  height: var(--bng-card-height, fit-content);
  background-color: rgba(0, 0, 0, 0.9);
  color: var(--bng-off-white);
  overflow: hidden;
  border-bottom: 0.35em solid var(--bng-orange-400);

  > .heading-container {
    display: flex;
    align-items: center;
    padding: 0.5em;
  }

  .heading {
    flex: 1 1 auto;
    margin: 0;
  }

  .heading-hint {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.25em;
  }

  > .panel-content {
    position: relative;
    display: flex;
    flex-direction: column;
    flex-wrap: nowrap;
    height: inherit;
    gap: var(--bng-card-content-gap, 0);
    padding: var(--bng-card-content-padding, 0);
    flex: 0 1 auto;
    border-top-left-radius: var(--bng-corners-2);
    border-top-right-radius: var(--bng-corners-2);
    overflow: hidden;
  }

  > :last-child {
    overflow: hidden;
    border-bottom-left-radius: var(--bng-corners-2);
    border-bottom-right-radius: var(--bng-corners-2);
  }

  > .footer-container {
    display: flex;
    justify-content: flex-end;
    padding: 0.5em;
    margin-top: auto;
    flex: 0 0 auto;

    position: relative;

    & :first-child:last-child {
      flex: 1 1 auto;
      justify-content: center;
      max-width: unset;
    }
  }

  :deep(.content) {
    padding: 0.5em 0.75em;
  }

  &.panel-active-controller {
    .heading {
      color: var(--bng-orange-400);
    }
  }

  &.panel-inactive-controller {
    font-weight: 600;
    background-color: rgba(0, 0, 0, 0.8);
    border-bottom-color: var(--bng-cool-gray-500);

    :deep(.heading::before) {
      background: var(--bng-cool-gray-500);
    }

    :deep(.heading) {
      font-weight: 600;
    }
  }
}
</style>

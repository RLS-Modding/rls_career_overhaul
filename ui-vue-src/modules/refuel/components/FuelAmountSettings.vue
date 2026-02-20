<template>
  <div class="amount">
    <BngButton class="top-up" accent="text"><BngBinding class="controller" ui-event="focus_u" deviceMask="xinput" />Top-up</BngButton>
    <div class="slider-labels">
      <span>{{ `${minSlider}${unitLabel}` }}</span>
      <span>{{ `${maxSlider}${unitLabel}` }}</span>
    </div>
    <BngSlider :min="minSlider" :max="maxSlider" @valueChanged="() => {}" />
    <div class="amount-value">
      <BngButton :accent="ACCENTS.text" class="empty"><BngBinding class="controller" ui-event="focus_l" deviceMask="xinput" /></BngButton>
      <BngInput class="value" suffix="L" initial-value="1234567"></BngInput>
      <BngButton :accent="ACCENTS.text" class="empty"><BngBinding class="controller" ui-event="focus_r" deviceMask="xinput" /></BngButton>
    </div>
  </div>
</template>

<script setup>
import { BngButton, ACCENTS, BngInput, BngSlider, BngBinding } from "@/common/components/base"

const props = defineProps({
  minSlider: {
    type: Number,
    default: 23,
  },
  maxSlider: {
    type: Number,
    default: 80,
  },
  unitLabel: String,
})
</script>

<style scoped lang="scss">
.amount {
  display: flex;
  flex-direction: column;
  align-items: center;

  & .slider-labels {
    display: flex;
    justify-content: space-between;
    width: 100%;
    margin-bottom: 0.5em;
  }

  & .amount-value {
    flex-direction: row;
    display: flex;
    margin: 0.5em 0;
    justify-content: center;

    & > :not(:last-child) {
      margin-right: 0.5em;
    }

    & .value {
      width: 32%;
    }
  }
}
</style>

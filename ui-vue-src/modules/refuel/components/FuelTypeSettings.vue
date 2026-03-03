<template>
  <div class="fuel-type">
    <BngButton class="arrow empty" :accent="ACCENTS.text" data-testid="previous-btn" :icon="icons.arrowLargeLeft" @click="emit('previousClick')">
      <BngBinding class="controller" ui-event="tab_l" deviceMask="xinput" />
    </BngButton>
    <BngPillFilters :options="fuelOptions" />
    <BngButton class="arrow empty" :accent="ACCENTS.text" data-testid="next-btn" :iconRight="icons.arrowLargeRight" @click="emit('nextClick')">
      <BngBinding class="controller" ui-event="tab_r" deviceMask="xinput" />
    </BngButton>
  </div>
</template>

<script setup>
import { BngButton, ACCENTS, BngPillFilters, BngBinding } from "@/common/components/base"
import { icons } from "@/common/components/base/bngIcon.vue"

defineProps({
  fuelOptions: {
    type: Array,
    required: true,
  },
})

const emit = defineEmits(["previousClick", "nextClick", "fuelTypeSelect"])
</script>

<style scoped lang="scss">
.fuel-type {
  display: flex;
  justify-content: space-between;
  align-items: center;

  & > :not(:last-child) {
    margin-right: 0.2em;
  }
}

.arrow:deep(.bngicon) {
  min-width: 1.5em;
  min-height: 1.5em;
}

.arrow:deep(.bngicon:not(.bng-binding-icon)) {
  width: 0.65em;
  min-width: 0;
  min-height: 0;
  height: 0.75em;
}
</style>

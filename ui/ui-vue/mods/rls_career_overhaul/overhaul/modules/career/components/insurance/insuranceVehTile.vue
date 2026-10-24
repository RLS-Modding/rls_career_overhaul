<template>
  <div class="vehicle-item">
    <div class="left">
      <div class="vehicle-thumbnail-wrapper">
        <img :src="vehicle.thumbnail" alt="" class="vehicle-thumbnail" />
      </div>
      <div class="name-value-wrapper">
        <div class="vehicle-name" :title="vehicle.name">{{ vehicle.name }}</div>
        <div class="vehicle-value"><BngUnit class="money-value" :money="vehicle.initialValue" /></div>
        <slot name="extra-info"></slot>
      </div>
    </div>
    <div class="right">
      <slot name="rightContent"></slot>
    </div>
  </div>
</template>

<script setup>
import { BngUnit } from "@/common/components/base"

const props = defineProps({
  vehicle: {
    type: Object,
    required: true,
  },
})
</script>

<style scoped lang="scss">
/* RLS house vehicle row: 16:9 thumb, name first, its value in money gold under it, the row's action
   on the right. Fixed height so a list of these keeps one rhythm. Also used by the (vanilla) repair
   screen, so tokens carry literal fallbacks. */
.vehicle-item {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  gap: 0.8em;
  min-width: 0;
  max-width: 100%;
  min-height: 4.6em;
  padding: 0.55em 0.75em 0.55em 0.55em;
  border-radius: var(--radius-panel, 0.5em);
  background: var(--panel, rgba(255, 255, 255, 0.06));
  color: #fff;
}

.left {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.75em;
}

.vehicle-thumbnail-wrapper {
  flex: 0 0 auto;
  width: 6em;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb, 0.35em);
  overflow: hidden;
  background: var(--photo, rgba(0, 0, 0, 0.35));
}

.vehicle-thumbnail {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.name-value-wrapper {
  min-width: 0;
  display: grid;
  gap: 0.12em;
}

.vehicle-name {
  font-size: 1.05em;
  font-weight: 800;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.vehicle-value {
  font-size: 0.9em;
  line-height: 1.2;
}

.money-value {
  color: var(--money, #fde68a);
  font-variant-numeric: tabular-nums;
  --units-icon-color: currentColor;
  --paddings: 0;
  padding: 0;
}

.right {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-end;
  align-items: center;
}
</style>

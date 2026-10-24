<template>
  <div class="discard-groups">
    <div class="quick-select">
      <HouseButton compact variant="quiet" @click="selectAll(true)">All</HouseButton>
      <HouseButton compact variant="quiet" @click="selectAll(false)">None</HouseButton>
    </div>
    <div v-for="group in groups" :key="group.id" class="discard-group">
      <div class="caption"><strong>{{ group.name }}</strong><small>Vehicle: {{ group.vehicleName }}</small><small>Container: {{ group.containerName }}</small></div>
      <div class="amount-controls" tabindex="0" bng-nav-item bng-no-child-nav="true" role="slider"
        :aria-label="`Discard ${group.name} from ${group.vehicleName}, ${group.containerName}`" :aria-valuemin="0" :aria-valuemax="group.amount" :aria-valuenow="amount(group)"
        v-bng-on-ui-nav:focus_l,focus_r,focus_u,focus_d.focusRequired="event => quantityNav(group, event)"
        @click="focusAmountRow"
        @keydown.up.prevent.stop="moveFocus($event, -1)" @keydown.down.prevent.stop="moveFocus($event, 1)"
        @keydown.left.prevent.stop="step(group, -1)" @keydown.right.prevent.stop="step(group, 1)">
        <HouseButton compact variant="quiet" :icon="icons.minus" :navItem="false" :tabindex="-1" :disabled="!amount(group)" :aria-label="`Discard less ${group.name}`" @click="step(group, -1)" />
        <HouseSlider bng-no-nav class="slider" :min="0" :max="group.amount" :step="1" :modelValue="amount(group)" @update:modelValue="value => update(group, value)" />
        <HouseButton compact variant="quiet" :icon="icons.plus" :navItem="false" :tabindex="-1" :disabled="amount(group) >= group.amount" :aria-label="`Discard more ${group.name}`" @click="step(group, 1)" />
        <div class="amount"><strong>{{ amount(group) }}</strong><span> / {{ group.amount }} {{ group.unit }}</span></div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { icons } from "@/common/components/base"
import HouseButton from "../house/HouseButton.vue"
import HouseSlider from "../house/HouseSlider.vue"
import { vBngOnUiNav } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
const props = defineProps({ groups: Array, modelValue: Object })
const emit = defineEmits(["update:modelValue"])
const amount = group => props.modelValue[group.id] || 0
function update(group, value) {
  emit("update:modelValue", { ...props.modelValue, [group.id]: Math.min(group.amount, Math.max(0, Number(value) || 0)) })
}
const step = (group, delta) => update(group, amount(group) + delta)
function focusAmountRow(event) {
  if (!event.target.closest("input, button")) setFocus(event.currentTarget, true, false, true)
}
function moveFocus(event, direction) {
  const row = event.target.closest(".amount-controls")
  const group = row.closest(".discard-group")
  const sibling = direction < 0 ? group.previousElementSibling : group.nextElementSibling
  const target = sibling?.querySelector(".amount-controls") || (direction < 0
    ? row.closest(".discard-groups").querySelector(".quick-select button")
    : row.closest(".discard-card").querySelector(".actions button"))
  if (target) setFocus(target, true, false, true)
  target?.scrollIntoView({ block: "nearest" })
}
function quantityNav(group, event) {
  event?.stopPropagation()
  if (!event?.detail?.value) return
  const direction = event.detail.name
  if (direction === "focus_u" || direction === "focus_d") moveFocus(event, direction === "focus_u" ? -1 : 1)
  else step(group, direction === "focus_l" ? -1 : 1)
}
function selectAll(selected) {
  emit("update:modelValue", Object.fromEntries(props.groups.map(group => [group.id, selected ? group.amount : 0])))
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.discard-groups { max-height: 45vh; overflow-y: auto; }
.quick-select { display: flex; justify-content: flex-end; gap: var(--space-1); margin-bottom: var(--space-2); }
.discard-group + .discard-group { border-top: 1px solid var(--line); padding-top: var(--space-3); margin-top: var(--space-3); }
.caption { display: flex; flex-direction: column; gap: var(--space-1); margin-bottom: var(--space-2); }
small { color: var(--muted); }
.amount-controls { display: flex; align-items: center; gap: var(--space-2); padding-inline-end: var(--space-2); }
.amount-controls.focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: var(--radius-control); }
.slider { flex: 1; min-width: 4em; }
.amount { flex-shrink: 0; min-width: 6.5em; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.amount strong { font-size: 1.15em; font-weight: 800; }
.amount span { color: var(--faint); }
</style>

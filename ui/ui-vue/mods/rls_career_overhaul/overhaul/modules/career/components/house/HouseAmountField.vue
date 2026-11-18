<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="house-amount-field rls-house">
    <label :id="`${id}-label`" :for="allowText ? `${id}-input` : undefined">{{ label }}</label>
    <div class="amount-stepper">
      <HouseButton :aria-label="`Decrease ${label}`" :aria-disabled="atMin" :disabled="disabled" @click="change(-step)">−</HouseButton>
      <div v-if="allowText" class="amount-text" :class="{ 'amount-money': money }">
        <MoneyAmount v-if="money" class="amount-currency" aria-hidden="true" />
        <input :id="`${id}-input`" class="field" bng-nav-item :aria-labelledby="`${id}-label`"
          type="number" :value="modelValue" :min="min" :max="max" :step="step" :disabled="disabled"
          v-bng-text-input @change="commit" />
      </div>
      <output v-else :aria-labelledby="`${id}-label`" aria-live="polite" :class="{ money }"><MoneyAmount v-if="money">{{ modelValue }}</MoneyAmount><template v-else>{{ modelValue }}</template></output>
      <HouseButton :aria-label="`Increase ${label}`" :aria-disabled="atMax" :disabled="disabled" @click="change(step)">+</HouseButton>
    </div>
    <div v-if="presets.length" class="amount-presets" :aria-label="`${label} presets`">
      <HouseButton v-for="preset in presets" :key="preset" :disabled="disabled" @click="set(preset)">{{ preset }}</HouseButton>
    </div>
    <p v-if="atMin || atMax" role="status">{{ atMin ? `Minimum ${min}` : `Maximum ${max}` }}</p>
  </div>
</template>
<script setup>
import { computed, nextTick } from "vue"
import { uniqueId } from "@/services/uniqueId"
import { vBngTextInput } from "@/common/directives"
import HouseButton from "./HouseButton.vue"
import MoneyAmount from "../MoneyAmount.vue"
import { amountValue } from "../../utils/amountValue.js"
const props = defineProps({
  modelValue: { type: Number, default: 0 }, label: { type: String, default: "Amount" },
  min: { type: Number, default: 0 }, max: { type: Number, default: Number.MAX_SAFE_INTEGER },
  step: { type: Number, default: 1 }, presets: { type: Array, default: () => [] }, allowText: Boolean, disabled: Boolean, money: Boolean,
})
const emit = defineEmits(["update:modelValue"])
const id = uniqueId("house-amount")
const atMin = computed(() => props.modelValue <= props.min)
const atMax = computed(() => props.modelValue >= props.max)
const set = value => {
  if (props.disabled) return
  const amount = amountValue(value, props)
  if (amount !== null) emit("update:modelValue", amount)
}
const change = delta => set(props.modelValue + delta)
const commit = async event => {
  const input = event.target
  set(input.value)
  await nextTick()
  // A no-op clamp does not rerender the field; show the accepted value.
  input.value = String(props.modelValue)
}
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.house-amount-field { display: grid; gap: .6em; }
.amount-stepper, .amount-presets { display: flex; align-items: center; gap: .5em; }
.amount-presets { flex-wrap: wrap; }
.amount-stepper > :deep(.house-button) { flex-shrink: 0; }
output { min-width: 5em; text-align: center; font-variant-numeric: tabular-nums; }
.amount-text { position: relative; flex: 0 1 9em; width: 9em; min-width: 0; }
.field { font-weight: 700; font-variant-numeric: tabular-nums; caret-color: var(--accent); }
.field:focus { outline: none; box-shadow: var(--focus); }
.amount-money .field { padding-left: 2.1em; color: var(--money); }
.amount-currency { position: absolute; left: .8em; top: 50%; transform: translateY(-50%); color: var(--money); pointer-events: none; }
.amount-text:has(input:disabled) .amount-currency { opacity: .45; }
p { margin: 0; }
</style>

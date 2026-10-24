<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="house-amount-field">
    <span :id="`${id}-label`">{{ label }}</span>
    <div class="amount-stepper">
      <HouseButton :aria-label="`Decrease ${label}`" :aria-disabled="atMin" @click="change(-step)">−</HouseButton>
      <output :aria-labelledby="`${id}-label`" aria-live="polite">{{ modelValue }}</output>
      <HouseButton :aria-label="`Increase ${label}`" :aria-disabled="atMax" @click="change(step)">+</HouseButton>
    </div>
    <div v-if="presets.length" class="amount-presets" :aria-label="`${label} presets`">
      <HouseButton v-for="preset in presets" :key="preset" @click="set(preset)">{{ preset }}</HouseButton>
    </div>
    <label v-if="allowText" class="amount-text">Type {{ label }} (keyboard)
      <input type="number" :value="modelValue" :min="min" :max="max" :step="step"
        v-bng-text-input @change="set($event.target.value)" />
    </label>
    <p v-if="atMin || atMax" role="status">{{ atMin ? `Minimum ${min}` : `Maximum ${max}` }}</p>
  </div>
</template>
<script setup>
import { computed } from "vue"
import { uniqueId } from "@/services/uniqueId"
import { vBngTextInput } from "@/common/directives"
import HouseButton from "./HouseButton.vue"
import { amountValue } from "../../utils/amountValue.js"
const props = defineProps({
  modelValue: { type: Number, default: 0 }, label: { type: String, default: "Amount" },
  min: { type: Number, default: 0 }, max: { type: Number, default: Number.MAX_SAFE_INTEGER },
  step: { type: Number, default: 1 }, presets: { type: Array, default: () => [] }, allowText: Boolean,
})
const emit = defineEmits(["update:modelValue"])
const id = uniqueId("house-amount")
const atMin = computed(() => props.modelValue <= props.min)
const atMax = computed(() => props.modelValue >= props.max)
const set = value => {
  const amount = amountValue(value, props)
  if (amount !== null) emit("update:modelValue", amount)
}
const change = delta => set(props.modelValue + delta)
</script>
<style scoped>
.house-amount-field { display: grid; gap: .6em; }
.amount-stepper, .amount-presets { display: flex; align-items: center; gap: .5em; flex-wrap: wrap; }
output { min-width: 5em; text-align: center; font-variant-numeric: tabular-nums; }
.amount-text { display: grid; gap: .3em; }
p { margin: 0; }
</style>

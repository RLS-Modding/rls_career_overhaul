<template>
  <div class="modal amount-prompt">
    <h3>{{ title }}</h3>
    <p v-if="message">{{ message }}</p>
    <HouseAmountField v-model="amount" v-bind="field" />
    <div class="actions">
      <HouseButton variant="quiet" bng-scoped-nav-autofocus @click="emit('return', false)">Cancel</HouseButton>
      <HouseButton variant="primary" @click="emit('return', amount)">{{ confirmLabel }}</HouseButton>
    </div>
  </div>
</template>
<script setup>
import { ref } from "vue"
import { amountValue } from "../../utils/amountValue.js"
import HouseAmountField from "./HouseAmountField.vue"
import HouseButton from "./HouseButton.vue"
const props = defineProps({ title: String, message: String, defaultValue: { type: Number, default: 0 },
  field: { type: Object, default: () => ({}) }, confirmLabel: { type: String, default: "Continue" } })
const emit = defineEmits(["return"])
const amount = ref(amountValue(props.defaultValue, props.field) ?? props.field.min ?? 0)
</script>
<style scoped>
.amount-prompt { width: min(28em, 90vw); padding: 1.5em; color: white; background: #1a1a1c; }
.actions { display: flex; justify-content: flex-end; gap: .6em; margin-top: 1em; }
</style>

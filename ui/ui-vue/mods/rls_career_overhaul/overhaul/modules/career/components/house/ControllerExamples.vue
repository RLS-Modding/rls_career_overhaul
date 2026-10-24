<template>
  <section ref="root" class="group controller-examples" aria-label="Controller controls">
    <h2>Controller controls</h2>
    <HouseTabs v-model="tab" :tabs="tabs" label="Controller examples">
      <div v-if="tab === 'values'" class="examples-grid">
        <HouseAmountField v-model="amount" label="Sample amount" :min="0" :max="1000" :step="50" :presets="[0, 250, 1000]" allow-text />
        <div>
          <p>Volume: {{ volume }}</p>
          <HouseSlider v-model="volume" :min="0" :max="100" :step="5" aria-label="Sample volume" />
          <HouseAccordion id="controller-example-notes" v-model="expanded" title="Controller notes">
            <p>Use the right stick to scroll. B returns from the screen.</p>
          </HouseAccordion>
        </div>
      </div>
      <div v-else class="examples-grid">
        <div>
          <HouseButton data-fk="amount-prompt" @click="editAmount">Choose amount</HouseButton>
          <p>Chosen amount: {{ amount }}</p>
          <HouseButton data-fk="destructive" variant="danger" @click="confirmReset">Reset sample</HouseButton>
        </div>
        <div>
          <HouseButton data-fk="refresh" :aria-disabled="busy" @click="refresh">Refresh sample</HouseButton>
          <HouseActionHint ui-event="ok" label="Refresh" :reason="busy ? 'Refreshing…' : `Revision ${revision}`" />
          <HouseActionHint ui-event="ok" label="confirm a hold action" hold />
        </div>
      </div>
    </HouseTabs>
  </section>
</template>
<script setup>
// Interactive house-kit examples, isolated from gameplay and saves.
import { ref } from "vue"
import HouseButton from "./HouseButton.vue"
import HouseTabs from "./HouseTabs.vue"
import HouseAmountField from "./HouseAmountField.vue"
import HouseSlider from "./HouseSlider.vue"
import HouseAccordion from "./HouseAccordion.vue"
import HouseActionHint from "./HouseActionHint.vue"
import { openHouseAmountPrompt, openHouseConfirmation } from "./index.js"
import { useActionFocus } from "../../composables/useActionFocus.js"
const root = ref(null), tab = ref('values'), amount = ref(100), volume = ref(50), expanded = ref(false), revision = ref(0)
const tabs = [{ id: 'values', label: 'Values' }, { id: 'actions', label: 'Actions' }]
const { busy, run } = useActionFocus(root)
const editAmount = async () => {
  const chosen = await openHouseAmountPrompt('Choose with the stepper or presets.', 'Sample amount', {
    defaultValue: amount.value, field: { min: 0, max: 1000, step: 50, presets: [0, 250, 1000], allowText: true },
  })
  if (chosen !== false) amount.value = chosen
}
const confirmReset = async () => {
  if (await openHouseConfirmation('Reset sample?', 'Only these fictional example values change.', [
    { label: 'Cancel', value: false, extras: { cancel: true } },
    { label: 'Reset', value: true, extras: { destructive: true } },
  ])) amount.value = 0
}
const refresh = () => run(async () => {
  await new Promise(resolve => setTimeout(resolve, 400))
  revision.value++
})
</script>
<style scoped>
.examples-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 2em; padding: 1em 0; }
.controller-examples { padding: 1.2em; border: 1px solid #7d858f; border-radius: .5em; }
</style>

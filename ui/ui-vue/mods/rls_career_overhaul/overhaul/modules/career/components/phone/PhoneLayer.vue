<template>
  <div class="phone-layer" role="dialog" aria-modal="true" :aria-label="label" v-bng-scoped-nav="scope">
    <slot />
  </div>
</template>
<script setup>
import { computed, inject, onBeforeUnmount } from 'vue'
import { vBngScopedNav } from '@/common/directives'
import { uniqueId } from '@/services/uniqueId'
import { returnFocusToOpener } from '../../composables/useScreenEntryFocus.js'

const props = defineProps({ label: { type: String, required: true }, active: { type: Boolean, default: undefined } })
const emit = defineEmits(['close'])
const layers = inject(Symbol.for('overhaul.phoneLayers'), null)
const opener = document.activeElement
const dispose = layers?.push(() => emit('close'), opener)
const scopeId = uniqueId('phone-layer')
const scope = computed(() => ({
  scopeId, activateOnMount: true,
  activated: props.active, bubbleWhitelistEvents: ['menu'],
  trapPolicy: 'always', preferAutoFocus: true,
  canDeactivate() {
    if (layers) layers.back()
    else emit('close')
    return false
  },
}))
onBeforeUnmount(() => {
  if (dispose) dispose()
  else returnFocusToOpener(() => opener)
})
</script>

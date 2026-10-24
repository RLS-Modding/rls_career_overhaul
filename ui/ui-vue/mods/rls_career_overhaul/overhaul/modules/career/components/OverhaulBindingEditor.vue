<template>
  <section class="binding-editor" aria-label="Edit control" aria-live="polite">
    <template v-if="model.capturing.value">
      <h3>Listening…</h3>
      <p>Press and release a key or button on any connected device.</p>
      <button type="button" @pointerdown.prevent="model.cancel" @click="model.cancel">Cancel capture</button>
    </template>
    <template v-else-if="model.pending.value">
      <h3>{{ model.pending.value.kind === 'reset' ? 'Restore defaults?' : 'Save binding?' }}</h3>
      <dl v-if="model.pending.value.binding" class="binding-facts">
        <dt>Device</dt><dd>{{ model.pending.value.binding.devname }}</dd>
        <dt>Control</dt><dd>{{ model.pending.value.binding.control }}</dd>
      </dl>
      <template v-if="model.pending.value.conflicts.length">
        <p>This control is already used. Replacing removes these bindings:</p>
        <ul><li v-for="(conflict, index) in model.pending.value.conflicts" :key="index">
          {{ $t(conflict.title || model.controls.getActionDetails(conflict.action)?.title || conflict.action) }}
          <span v-if="conflict.locked"> (protected)</span>
        </li></ul>
      </template>
      <p v-else-if="model.pending.value.kind === 'reset'">Restore only the selected Overhaul actions on connected devices.</p>
      <div class="editor-buttons">
        <button type="button" :disabled="model.saving.value" @click="model.cancel">Cancel</button>
        <button type="button" :disabled="model.saving.value || model.pending.value.conflicts.some(c => c.locked)" @click="save">
          {{ model.pending.value.conflicts.length ? 'Replace and save' : 'Save' }}
        </button>
      </div>
    </template>
    <p v-if="model.error.value" role="alert">{{ model.error.value }}</p>
  </section>
</template>

<script setup>
const props = defineProps({ model: { type: Object, required: true } })
const emit = defineEmits(['saved'])
async function save() {
  if (await props.model.apply()) emit('saved')
}
</script>

<style scoped lang="scss">
// House style: dark panel, orange primary action, orange focus ring with a dark gap.
.binding-editor { padding: 14px; border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 10px; background: rgba(0, 0, 0, 0.28); color: #f2f2f2; text-align: left; }
h3 { margin: 0 0 8px; font-size: 16px; color: #ff9f43; }
li { overflow-wrap: anywhere; }
p, li { font-size: 13px; line-height: 1.5; color: #d0d0d0; }
.binding-facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 12px; margin: 0 0 12px; font-size: 13px; line-height: 1.4; }
.binding-facts dt { align-self: center; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: #9a9a9a; }
.binding-facts dd { margin: 0; font-weight: 600; color: #f2f2f2; overflow-wrap: anywhere; }
.editor-buttons { display: flex; flex-wrap: wrap; gap: 8px; }
button { position: relative; padding: 9px 16px; border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 6px; background: rgba(255, 255, 255, 0.07); color: #fff; font-weight: 600; cursor: pointer; }
button:hover:not(:disabled) { background: rgba(255, 255, 255, 0.12); }
.editor-buttons button:last-child { border: 0; background: linear-gradient(145deg, #ff8c00, #ffb347); color: #1b1b1b; }
.editor-buttons button:last-child:hover:not(:disabled) { background: linear-gradient(145deg, #ff9f1a, #ffc36b); }
button.focus-visible { outline: none; box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600); }
button.focus-visible::before { display: none !important; }
button:disabled { opacity: .5; }
</style>

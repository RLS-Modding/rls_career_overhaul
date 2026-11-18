<!-- Copyright (C) RLS Modding. SPDX-License-Identifier: AGPL-3.0-only
     Additional permission: licenses/RLS-BeamNG-Permission.txt
     Remove / Restore and Delete for one blueprint in the Engine Workshop sales row.
     Busy controls stay focusable (aria-disabled + guarded handlers, as useActionFocus expects), so
     controller focus is not dropped while the request runs. -->
<template>
  <div class="blueprint-controls" :class="{ removed: blueprint.removed }">
    <p v-if="blueprint.removed && !confirming" class="blueprint-note">Production and sales are paused. History and awareness are kept.</p>
    <div v-if="!confirming" class="blueprint-actions">
      <HouseButton class="blueprint-remove" compact :variant="blueprint.removed ? 'neutral' : 'quiet'" :aria-disabled="busy || submitting" :data-fk="`removeBlueprint-${blueprint.id}`" @click="setRemoved">{{ blueprint.removed ? 'Restore' : 'Remove' }}</HouseButton>
      <HouseButton ref="deleteButton" compact variant="quiet-danger" :aria-disabled="busy || submitting" :data-fk="`deleteBlueprint-${blueprint.id}`" @click="requestDelete">Delete</HouseButton>
    </div>
    <section v-else class="blueprint-confirm" v-bng-scoped-nav="confirmScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="onBack" role="group" :aria-label="`Delete ${blueprint.name}`" @keydown.esc.stop.prevent="cancelDelete">
      <p class="blueprint-question">Delete <strong>{{ blueprint.name }}</strong> permanently?</p>
      <p class="blueprint-consequence">Awareness and sales history are erased. Engines already built keep working.</p>
      <div class="blueprint-actions confirm">
        <HouseButton ref="cancelButton" compact bng-scoped-nav-autofocus :aria-disabled="busy || submitting" @click="cancelDelete">Cancel</HouseButton>
        <HouseButton compact variant="danger" :aria-disabled="busy || submitting" :data-fk="`confirmDeleteBlueprint-${blueprint.id}`" @click="confirmDelete">Delete permanently</HouseButton>
      </div>
    </section>
    <p v-if="error" class="blueprint-blocked" role="status">{{ error }}</p>
  </div>
</template>

<script setup>
import { nextTick, ref, watch } from 'vue'
import { vBngOnUiNav, vBngScopedNav } from '@/common/directives'
import { bcModalScope, vBcModalFocus } from '../../bcModalNav'
import { HouseButton } from '../../../house/index.js'

const props = defineProps({ blueprint: Object, busy: Boolean, perform: Function })
const confirming = ref(false), submitting = ref(false), error = ref('')
const cancelButton = ref(null), deleteButton = ref(null)
const confirmScope = bcModalScope('blueprint-delete')
let confirmedName = ''
function focus(control) { (control?.$el || control)?.focus?.() }
async function requestDelete() {
  if (props.busy || submitting.value) return
  error.value = props.blueprint.deleteBlockedReason || ''
  if (error.value) return
  confirmedName = props.blueprint.name
  confirming.value = true
  await nextTick()
  focus(cancelButton.value)
}
async function cancelDelete() {
  if (submitting.value) return
  confirming.value = false
  await nextTick()
  focus(deleteButton.value)
}
function onBack() { cancelDelete(); return false }
async function setRemoved() {
  if (props.busy || submitting.value) return
  submitting.value = true
  error.value = ''
  try { await props.perform('setBlueprintRemoved', props.blueprint.id, !props.blueprint.removed) }
  finally { submitting.value = false }
}
async function confirmDelete() {
  if (!confirming.value || props.busy || submitting.value) return
  submitting.value = true
  try {
    const result = await props.perform('deleteBlueprint', props.blueprint.id, confirmedName)
    confirming.value = false
    if (result?.success) return
    // The confirmation closes with the reason in its place; focus goes back to Delete like Cancel does.
    error.value = result?.message || 'The blueprint could not be deleted. Try again.'
    await nextTick()
    focus(deleteButton.value)
  } finally { submitting.value = false }
}
watch([() => props.blueprint.id, () => props.blueprint.name], () => { confirming.value = false; error.value = '' })
watch(() => props.blueprint.deleteBlockedReason, (reason, previous) => {
  if (error.value === previous) error.value = reason || ''
})
</script>

<style scoped lang="scss">
/* Colours and radii are the house tokens inherited from the .rls-house root of the business computer. */
.blueprint-controls {
  display: grid;
  gap: 0.5em;
  min-width: 0;
  // a rule sets these apart from the price and listing buttons above; a removed row has nothing above
  &:not(.removed) {
    margin-top: 0.15em;
    padding-top: 0.6em;
    border-top: 1px solid var(--line);
  }
}
p { margin: 0; }

.blueprint-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45em;
  // same split as the business sale dialog: the safe choice left, the destructive one right
  &.confirm { justify-content: space-between; margin-top: 0.3em; }
}
// the quiet button has no box at rest, so its label lines up with the column edge instead of floating in
.blueprint-remove.btn-quiet { margin-left: -0.95em; }

.blueprint-note,
.blueprint-consequence {
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.35;
}

/* The confirmation takes over the Delete button's own tint and outline, so it reads as that button opened. */
.blueprint-confirm {
  display: grid;
  gap: 0.3em;
  padding: 0.75em 0.85em 0.8em;
  border-radius: var(--radius-panel);
  background: rgba(185, 28, 28, 0.2);
  box-shadow: inset 0 0 0 1px rgba(248, 113, 113, 0.45);
  animation: blueprint-reveal 0.14s ease-out;
}
.blueprint-question {
  font-weight: 700;
  line-height: 1.3;
  overflow-wrap: anywhere;
  strong { font-weight: 800; }
}

/* Blocked or failed delete: the house warning notice, with the backend's own next step as its text. */
.blueprint-blocked {
  padding: 0.7em 0.85em 0.6em;
  border-radius: var(--radius-panel);
  background: rgba(251, 191, 36, 0.14);
  color: var(--money);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.35;
  animation: blueprint-reveal 0.14s ease-out;
}

@keyframes blueprint-reveal {
  from { opacity: 0; transform: translateY(-0.25em); }
}
@media (prefers-reduced-motion: reduce) {
  .blueprint-confirm, .blueprint-blocked { animation: none; }
}
</style>

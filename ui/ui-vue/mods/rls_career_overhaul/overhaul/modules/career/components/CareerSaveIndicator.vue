<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <Teleport to="body">
    <Transition name="career-save">
      <div v-if="state" class="career-save-indicator" role="status" aria-live="polite">
        <span class="career-save-symbol" aria-hidden="true">{{ state === "saved" ? "✓" : "·" }}</span>
        <span>{{ labels[state] }}</span>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { ref, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { createSaveStatus } from "../utils/saveStatus.js"

const state = ref("")
const labels = { saving: "Saving…", saved: "Saved", deferred: "Saving when stopped" }
const { events } = useBridge()
const status = createSaveStatus(value => { state.value = value })
events.on("OverhaulSaveStatus", status.receive)
onBeforeUnmount(() => {
  events.off("OverhaulSaveStatus", status.receive)
  status.dispose()
})
</script>

<style scoped>
.career-save-indicator {
  position: fixed;
  left: calc(var(--safezone, 0rem) + 1.25rem);
  bottom: calc(var(--safezone, 0rem) + 3.5rem);
  z-index: 10000;
  display: flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.375rem 0.625rem;
  border-radius: var(--bng-corners-1, 0.25rem);
  background: rgba(21, 24, 32, 0.9);
  color: var(--bng-off-white, #ebebeb);
  font: 0.75rem var(--fnt-defs, "Noto Sans", sans-serif);
  pointer-events: none;
  contain: layout paint;
}
.career-save-symbol { color: var(--bng-orange-b400, #ff6600); }
.career-save-enter-active, .career-save-leave-active {
  transition: opacity 150ms cubic-bezier(0.23, 1, 0.32, 1);
}
.career-save-enter-from, .career-save-leave-to { opacity: 0; }
@media (prefers-reduced-motion: reduce) {
  .career-save-enter-active, .career-save-leave-active { transition: none; }
}
</style>

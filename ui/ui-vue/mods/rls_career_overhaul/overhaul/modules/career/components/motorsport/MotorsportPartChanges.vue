<!-- "See changes" button and its popup: which installed parts differ from the registered car, as a slot tree. roster.lua supplies the changes. -->
<template>
  <div v-if="changes.length" class="part-changes">
    <HouseButton data-fk="see-part-changes" compact :icon="icons.listIndented" :disabled="disabled" @click="open = true">See changes</HouseButton>
    <EntryOverlayPopup :active="open" @cancel="open = false" @leave="open = false">
      <div v-if="open" class="parts-backdrop">
        <section class="rls-house rls-house-card parts-popup" aria-label="Parts changed">
          <header>
            <h2 class="ms-title">Parts changed</h2>
            <p class="ms-caption"><strong v-if="carName" class="ms-body">{{ carName }}.</strong> {{ context === 'inspection' ? 'Restore the registered parts in the garage, then inspect again.' : 'Restore the registered parts in the garage to start your pass.' }} Tuning and paint changes are allowed.</p>
          </header>
          <main class="tree scroll" v-bng-ui-nav-scroll.force>
            <div v-for="row in rows" :key="row.key" class="tree-row" :class="{ nested: row.depth > 0 }" :style="{ '--depth': Math.min(row.depth, 3) }">
              <div v-if="row.change" class="change-row">
                <span class="row-copy">
                  <strong class="truncate" :title="row.change.slotLabel">{{ row.change.slotLabel }}</strong>
                  <span class="part-names">
                    <span v-if="row.change.registered" class="part-name"><span class="ms-meta">Registered:</span> <strong>{{ row.change.registered.label }}</strong></span>
                    <span v-if="row.change.current" class="part-name"><span class="ms-meta">Now:</span> <strong>{{ row.change.current.label }}</strong></span>
                  </span>
                </span>
                <span class="pill ms-tone-blocked">{{ labels[row.change.kind] }}</span>
              </div>
              <div v-else class="group-label ms-meta truncate" :title="row.label">{{ row.label }}</div>
            </div>
          </main>
          <footer class="ms-foot"><HouseButton class="ms-foot-end" data-fk="close-part-changes" @click="open = false">Close</HouseButton></footer>
        </section>
      </div>
    </EntryOverlayPopup>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import { icons } from '@/common/components/base'
import { vBngUiNavScroll } from '@/common/directives'
import EntryOverlayPopup from '../EntryOverlayPopup.vue'
import { HouseButton } from '../house/index.js'
const props = defineProps({ changes: { type: Array, default: () => [] }, carName: { type: String, default: '' }, context: { type: String, default: 'pass' }, disabled: Boolean })
const open = ref(false)
const labels = { swapped: 'Swapped', added: 'Added', removed: 'Removed' }
// Ancestors (root excluded, outermost first) become group rows; each change sits under its parent slots.
const rows = computed(() => {
  const root = { children: new Map() }
  for (const change of props.changes) {
    let parent = root
    for (const ancestor of Array.isArray(change.ancestors) ? change.ancestors : []) {
      if (!parent.children.has(ancestor.slot)) parent.children.set(ancestor.slot, { label: ancestor.label, children: new Map() })
      parent = parent.children.get(ancestor.slot)
    }
    if (!parent.children.has(change.slot)) parent.children.set(change.slot, { children: new Map() })
    parent.children.get(change.slot).change = change
  }
  const result = []
  const visit = (node, depth, path) => {
    for (const [slot, child] of node.children) {
      const key = `${path}/${slot}`
      result.push({ ...child, depth, key })
      visit(child, depth + 1, key)
    }
  }
  visit(root, 0, '')
  return result
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/motorsport.scss" as ms;
.part-changes { margin-top: var(--space-2, .5em); }
.parts-backdrop { position: fixed; inset: 0; display: grid; place-items: center; padding: 1.5rem; background: rgba(0, 0, 0, 0.6); pointer-events: auto; }
.parts-popup { @include ms.ms-scale-overlay; display: flex; flex-direction: column; width: min(34em, 100%); max-height: min(60vh, 40em); box-sizing: border-box; overflow: hidden; background: var(--page); border-radius: var(--radius-panel); box-shadow: inset 0 0 0 1px rgba(255, 255, 255, .07), 0 1.2em 3em rgba(0, 0, 0, 0.55); }
.parts-popup > * { padding-left: calc(var(--ms-pad) * 1.4); padding-right: calc(var(--ms-pad) * 1.4); }
// A plain title, then what to do about it. The rows carry the colour.
header { display: grid; gap: .35em; padding-top: .9em; padding-bottom: .8em; border-bottom: 1px solid var(--line); }
.parts-popup .pill { flex: none; white-space: nowrap; font-size: max(12px, .74em); }
.tree { flex: 1 1 auto; min-height: 0; overflow-y: auto; overscroll-behavior: contain; display: grid; align-content: start; gap: .25em; padding-top: .8em; padding-bottom: .8em; }
.tree-row { margin-left: calc(var(--depth) * .9em); }
.tree-row.nested { border-left: 1px solid var(--line); padding-left: .5em; }
.change-row { display: flex; align-items: center; gap: .6em; padding: .5em .65em; background: var(--panel); border-radius: var(--radius-tile); }
.row-copy { min-width: 0; flex: 1; display: grid; gap: .15em; }
.row-copy > strong { font-size: 1em; }
.part-names { display: grid; gap: .2em; min-width: 0; font-size: .9em; color: var(--muted); }
.part-name { overflow-wrap: anywhere; }
.part-name strong { color: #fff; font-weight: 600; }
.group-label { padding: .35em .2em .1em; }
.truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
footer { padding-top: .7em; padding-bottom: .8em; border-top: 1px solid var(--line); }
</style>

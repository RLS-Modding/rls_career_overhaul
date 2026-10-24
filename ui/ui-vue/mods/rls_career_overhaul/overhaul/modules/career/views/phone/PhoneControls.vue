<template>
  <div class="phone-controls">
    <!-- The status bar already names the app, so the header is only the intro line. -->
    <header><p>Your shortcuts, on every device. Changes also appear in Options → Controls.</p></header>
    <div v-if="editing" class="editor-page" bng-nav-scroll>
      <OverhaulBindingEditor :model="bindings" />
    </div>
    <main v-else bng-nav-scroll>
      <div class="tools">
        <button type="button" @click="openStockControls">Open game Controls</button>
        <button type="button" :disabled="!snapshot" @click="bindings.reset()">Reset all Overhaul controls</button>
      </div>
      <p class="device-note">Select a shortcut to change or clear it. Add a binding for another device. Unassigned controller shortcuts need a free button.</p>
      <section v-for="group in groups" :key="group.name" class="action-group">
        <h2>{{ group.name }}</h2>
        <article v-for="action in group.actions" :key="action.key" class="action-card">
          <h3>{{ action.title }}</h3><p>{{ action.desc }}</p>
          <div class="device-summary">
            <span>Keyboard <BngBinding v-if="devicesFor(action.key, 'keyboard').length" :action="action.key" :device="devicesFor(action.key, 'keyboard')" :use-last-device="false" track-ignore /><em v-else>Unbound</em></span>
            <span>Controller <BngBinding v-if="devicesFor(action.key, 'controller').length" :action="action.key" :device="devicesFor(action.key, 'controller')" :use-last-device="false" track-ignore /><em v-else>Unbound</em></span>
          </div>
          <div v-for="binding in bindings.controls.getAllBindingsForAction(action.key)" :key="binding.devname + binding.control" class="binding-row">
            <button type="button" :disabled="binding.locked" @click="bindings.capture(action.key, binding)">
              <span>{{ deviceLabel(binding.devname) }}</span><strong>{{ binding.control }}</strong>
            </button>
            <button type="button" :disabled="binding.locked" :aria-label="'Clear ' + action.title + ' on ' + binding.devname" @click="bindings.clear(binding)">Clear</button>
            <small v-if="bindings.controls.bindingConflicts(binding.devname, binding.control, action.key).length" class="conflict">Shared control — select to resolve</small>
          </div>
          <div class="action-buttons">
            <button type="button" @click="bindings.capture(action.key)">Add binding</button>
            <button type="button" :disabled="!snapshot" @click="bindings.reset(action.key)">Reset</button>
          </div>
        </article>
      </section>
      <p v-if="!groups.length" role="status">Loading input actions…</p>
    </main>
    <p v-if="error && !editing" role="alert">{{ error }}</p>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { BngBinding } from '@/common/components/base'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { useOverhaulBindings } from '../../composables/useOverhaulBindings'
import OverhaulBindingEditor from '../../components/OverhaulBindingEditor.vue'

const router = useRouter()
const bindings = useOverhaulBindings()
const { groups, snapshot, error } = bindings
const editing = computed(() => bindings.capturing.value || !!bindings.pending.value)
usePhoneScreen({ title: 'Controls', onBack: () => {
  if (!editing.value) return false
  if (!bindings.saving.value) bindings.cancel()
  return true
} })
const deviceLabel = name => name.startsWith('keyboard') ? 'Keyboard' : name.startsWith('mouse') ? 'Mouse' : name.startsWith('xinput') ? 'Controller' : name
function devicesFor(action, kind) {
  return [...new Set(bindings.controls.getAllBindingsForAction(action)
    .filter(binding => kind === 'keyboard' ? binding.devname.startsWith('keyboard') : !/^(keyboard|mouse|wheel)/.test(binding.devname))
    .map(binding => binding.devname))]
}
async function openStockControls() {
  await lua.overhaul_phone_phone.closePhone()
  // Stock has a Controls category route, but no action-group filter parameter.
  router.push({ name: 'options', params: { category: 'controls' } })
}
</script>

<style scoped>
.phone-controls { height: 100%; display: flex; flex-direction: column; background: #0c1422; color: #f1f5f9; }
header { padding: calc(var(--phone-status-bar-height) + var(--phone-status-bar-content-gap)) 18px 12px; background: linear-gradient(135deg, #223855, #132237); }
header p { margin: 0; font-size: 12px; line-height: 1.5; color: #c5d2e2; }
main, .editor-page { min-height: 0; overflow-y: auto; padding: 14px; flex: 1; }
.tools, .action-buttons { display: flex; flex-wrap: wrap; gap: 7px; }
.device-note { font-size: 11px; line-height: 1.5; color: #a7b9ce; }
h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 1.6px; margin: 20px 2px 9px; color: #93c5fd; }
.action-card { padding: 13px; margin-bottom: 9px; background: #162337; border: 1px solid #2d415c; border-radius: 13px; }
h3 { margin: 0; font-size: 15px; }
.action-card p { font-size: 11px; line-height: 1.5; color: #bbcade; }
.device-summary { display: grid; gap: 6px; margin: 10px 0; font-size: 11px; }
.device-summary > span { display: flex; justify-content: space-between; align-items: center; }
.binding-row { display: flex; flex-wrap: wrap; gap: 5px; margin-bottom: 6px; }
.binding-row > button:first-child { flex: 1; display: flex; justify-content: space-between; gap: 8px; }
button { position: relative; min-height: 34px; padding: 8px 10px; border-radius: 8px; border: 1px solid #3f5a7b; background: #223751; color: #edf5ff; font: inherit; font-size: 11px; cursor: pointer; }
button:disabled { opacity: .4; cursor: default; }
.action-buttons { margin-top: 10px; }
.conflict { width: 100%; font-size: 10px; color: #fbbf24; }
</style>

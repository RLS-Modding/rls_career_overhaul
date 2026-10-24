// The stock controls store owns capture and edits. The hook snapshot supplies
// device defaults for an action-only reset, which stock does not expose in JS.
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import useControls from '@/services/controls'
import { useEvents } from '@/services/events'
import { lua } from '@/bridge'
import { overhaulActions, actionGroups, planReset } from '../utils/overhaulBindings'

export const overhaulBindingBusy = ref(false)
let editorOwner = null

export function useOverhaulBindings() {
  const owner = {}
  function claim() {
    if (editorOwner && editorOwner !== owner) return false
    editorOwner = owner
    overhaulBindingBusy.value = true
    return true
  }
  function release() {
    if (editorOwner !== owner) return
    editorOwner = null
    overhaulBindingBusy.value = false
  }
  const controls = useControls()
  const events = useEvents()
  const snapshot = ref(null)
  const capturing = ref(false)
  const pending = ref(null)
  const error = ref('')
  const saving = ref(false)
  const actions = computed(() => overhaulActions(controls.categoriesList))
  const groups = computed(() => actionGroups(actions.value))
  let generation = 0
  let disposed = false

  const receive = data => { snapshot.value = data }
  onMounted(() => {
    events.on('InputBindingsChanged', receive)
    lua.extensions.core_input_bindings.notifyUI('Overhaul controls opened')
  })
  onUnmounted(() => { disposed = true; cancel(); events.off('InputBindingsChanged', receive) })

  function cancel() {
    generation++
    if (capturing.value) controls.cancelCaptureBinding()
    capturing.value = false
    pending.value = null
    release()
  }

  async function capture(action, oldBinding = null, expectedDevice = null) {
    if (capturing.value || saving.value || !claim()) return
    error.value = ''
    pending.value = null
    capturing.value = true
    const current = ++generation
    await nextTick()
    if (disposed || current !== generation) return
    // Stock capture consumes a complete press/release, modifiers and axes,
    // and disables gameplay while it listens. Escape can itself be rebound.
    controls.captureBinding(true, action).then(result => {
      if (disposed || current !== generation) return
      capturing.value = false
      if (expectedDevice && result.devName !== expectedDevice) {
        release()
        error.value = 'Use the controller you selected, or choose Later.'
        return
      }
      const binding = { ...controls.defaultBindingEntry(action, result.control), action, control: result.control, devname: result.devName }
      if (controls.isAxis(result.devName, result.control)) {
        release()
        error.value = 'Choose a key or button for this digital action.'
        return
      }
      pending.value = { kind: 'binding', binding, oldBinding,
        conflicts: controls.bindingConflicts(result.devName, result.control, action) }
    }, () => { if (current === generation) { capturing.value = false; release() } })
  }

  const resetConflicts = plan => plan.conflicts.map(binding => ({ ...binding,
    locked: controls.isBindingLocked(binding.devname, binding.action) }))
  const conflictKey = conflicts => JSON.stringify(conflicts.map(binding =>
    [binding.devname || '', binding.control, binding.action, !!binding.locked].join(':')).sort())

  function reset(action = null) {
    if (!snapshot.value || saving.value || !claim()) return
    const names = action ? [action] : actions.value.map(entry => entry.key)
    const plan = planReset(snapshot.value.bindings, snapshot.value.defaultBindings, names)
    pending.value = { kind: 'reset', names, conflicts: resetConflicts(plan) }
  }

  async function apply() {
    const change = pending.value
    if (!change || saving.value) return false
    const latest = change.kind === 'reset'
      ? resetConflicts(planReset(snapshot.value.bindings, snapshot.value.defaultBindings, change.names))
      : controls.bindingConflicts(change.binding.devname, change.binding.control, change.binding.action)
    if (conflictKey(latest) !== conflictKey(change.conflicts)) {
      pending.value = { ...change, conflicts: latest }
      error.value = 'Bindings changed. Review the updated conflicts before saving.'
      return false
    }
    if (latest.some(binding => binding.locked)) {
      error.value = 'A protected binding uses this control. Choose another control.'
      return false
    }
    saving.value = true
    error.value = ''
    try {
      if (change.kind === 'reset') {
        const plan = planReset(snapshot.value.bindings, snapshot.value.defaultBindings, change.names, true)
        for (const device of plan.devices) await lua.extensions.core_input_bindings.saveBindingsToDisk(device.contents)
      } else {
        const { binding, oldBinding, conflicts } = change
        if (oldBinding) controls.updateBinding({ ...binding, oldDevname: oldBinding.devname, oldControl: oldBinding.control })
        else if (!controls.getBinding(binding.devname, binding.control, binding.action)) controls.addNewBinding(binding)
        if (conflicts.length) controls.deleteBindings(conflicts.map(entry => ({ ...entry, devname: binding.devname })))
      }
      pending.value = null
      release()
      return true
    } catch (cause) {
      error.value = 'Could not save the binding. ' + String(cause?.message || cause)
      return false
    } finally { saving.value = false }
  }

  function clear(binding) {
    controls.deleteBinding(binding)
  }

  return { controls, actions, groups, snapshot, capturing, pending, error, saving, capture, cancel, reset, apply, clear }
}

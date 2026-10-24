<template></template>

<script setup>
import { watch, onBeforeUnmount } from 'vue'
import useControls from '@/services/controls'
import { setFocus } from '@/services/uiNavFocus'
import { installPhoneFocus } from '../../utils/phoneFocus.js'

const props = defineProps({ root: { type: Object, default: null } })
const controls = useControls()
let navigation
const selections = new Map()
const keyOf = element => element.dataset.appId || element.dataset.fk
function remember(event) {
  if (event.target.closest('.phone-layer')) return
  const element = event.target.closest('[data-app-id], [data-fk]')
  const route = element?.closest('[data-phone-route]')?.dataset.phoneRoute
  if (route) selections.set(route, keyOf(element))
}
function focusEntry(element) {
  if (element.closest('.phone-layer')) { setFocus(element); return }
  const screen = element.closest('[data-phone-route]')
  const key = selections.get(screen?.dataset.phoneRoute)
  const previous = key && [...screen.querySelectorAll('[data-app-id], [data-fk]')].find(candidate =>
    keyOf(candidate) === key && candidate.getAttribute('bng-no-nav') === 'false')
  setFocus(previous || element)
}
watch(() => props.root, root => {
  navigation?.dispose()
  navigation = root ? installPhoneFocus(root, { focus: focusEntry, controller: () => controls.isControllerUsed }) : null
}, { flush: 'post' })
watch(() => props.root, (root, previous) => {
  previous?.removeEventListener('focusin', remember)
  root?.addEventListener('focusin', remember)
})
watch(() => controls.isControllerUsed, () => navigation?.refresh())
onBeforeUnmount(() => { props.root?.removeEventListener('focusin', remember); navigation?.dispose() })
</script>

<style>
/* The shared Overhaul stylesheet owns the phone's ring too. */
</style>

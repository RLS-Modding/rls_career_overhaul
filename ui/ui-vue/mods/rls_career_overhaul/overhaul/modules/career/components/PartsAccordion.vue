<template>
  <div class="bng-accordion-container" v-bng-disabled="disabled"><slot /></div>
</template>

<script setup>
import { watch, provide, inject } from "vue"
import { vBngDisabled } from "@/common/directives"

// Own only the container contract; stock AccordionItem retains rendering and navigation.
const props = defineProps({
  singular: Boolean, expanded: Boolean, disabled: Boolean, animated: Boolean,
  selectable: [Boolean, Object], selected: Boolean, provideParent: Boolean,
})
const emit = defineEmits(["selected"])
const items = new Set()
let counter = 0
let selection = null

function toggle(item = null, expanded = null) {
  if (props.singular && !item && expanded) item = items.values().next().value
  for (const entry of items) {
    entry.expandedActual = item && entry !== item
      ? (props.singular ? false : entry.expandedActual)
      : (typeof expanded === "boolean" ? expanded : !entry.expandedActual)
  }
}
function select(item = null, selected = null) {
  if (!selection) return
  const changed = []
  for (const entry of items) {
    const value = item && entry !== item
      ? (selection.multi ? entry.selected : false)
      : (typeof selected === "boolean" ? selected : selection.multi ? !entry.selected : true)
    if (entry.selected !== value) { entry.selected = value; changed.push(entry) }
  }
  if (changed.length) emit("selected", changed)
}
watch(() => props.singular, value => {
  if (value) toggle([...items].find(item => item.expandedActual), true)
})
watch(() => props.expanded, value => toggle(null, value))
for (const key of ["disabled", "animated"]) watch(() => props[key], value => {
  for (const item of items) item[key] = value
})
watch(() => props.selectable, value => {
  selection = value ? { multi: false, ...(typeof value === "object" ? value : {}) } : null
  for (const item of items) item.selectable = selection
}, { immediate: true })
watch(() => props.selected, value => select(null, value))

provide("accordion-item-register", item => {
  item.id = counter++
  if (props.expanded) item.expandedActual = true
  if (props.disabled) item.disabled = true
  if (props.animated) item.animated = true
  if (selection) item.selectable = selection
  items.add(item)
  // Options are initialized synchronously, including the non-selectable case.
  if (props.singular && item.expandedActual) toggle(item, true)
  if (item.selected) select(item, true)
})
provide("accordion-item-unregister", item => items.delete(item))
provide("accordion-item-toggle", toggle)
provide("accordion-item-select", select)
provide("accordion-item-childSelect", callback => {
  watch(() => props.selected, value => selection?.multi && callback(null, value))
})
if (props.provideParent) inject("accordion-item-childSelect")(select)
</script>

<style scoped>
.bng-accordion-container {
  position: relative;
  display: flex;
  flex-direction: column;
  height: auto;
  max-height: 100%;
  padding: 0 0.5rem;
}
</style>

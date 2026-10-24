<template>
  <div class="house-tabs" v-bng-on-ui-nav:tab_l="previous" v-bng-on-ui-nav:tab_r="next">
    <span><BngBinding ui-event="tab_l" /> Previous tab</span>
    <div role="tablist" :aria-label="label">
      <button v-for="tab in tabs" :key="tab.id" type="button" role="tab"
        :aria-selected="modelValue === tab.id" :aria-disabled="!!tab.disabled"
        @click="select(tab)">{{ tab.label }}<span v-if="tab.disabled"> — {{ tab.reason || 'Unavailable' }}</span></button>
    </div>
    <span><BngBinding ui-event="tab_r" /> Next tab</span>
    <div v-if="$slots.default" class="tab-content"><slot /></div>
  </div>
</template>
<script setup>
import { BngBinding } from "@/common/components/base"
import { vBngOnUiNav } from "@/common/directives"
import { nextTab } from "../../utils/controllerTabs.js"
const props = defineProps({ modelValue: [String, Number], tabs: { type: Array, required: true }, label: { type: String, default: "Sections" } })
const emit = defineEmits(["update:modelValue"])
const select = tab => { if (!tab.disabled) emit("update:modelValue", tab.id) }
const move = (direction, event) => {
  event?.stopPropagation()
  const tab = nextTab(props.tabs, props.modelValue, direction)
  if (tab) select(tab)
}
const previous = event => move(-1, event)
const next = event => move(1, event)
</script>
<style scoped>
.house-tabs { display: flex; align-items: center; gap: .6em; flex-wrap: wrap; }
[role="tablist"] { display: flex; gap: .4em; }
button { padding: .5em .8em; color: white; background: #242428; border: 1px solid #888; }
button[aria-selected="true"] { border-color: #ff6600; background: #3e3028; }
.tab-content { flex-basis: 100%; min-width: 0; }
</style>

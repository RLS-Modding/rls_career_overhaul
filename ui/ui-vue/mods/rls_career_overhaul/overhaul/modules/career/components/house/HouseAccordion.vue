<template>
  <section class="house-accordion">
    <HouseButton :aria-expanded="modelValue" :aria-controls="id" @click="emit('update:modelValue', !modelValue)">
      {{ title }} {{ modelValue ? '−' : '+' }}
    </HouseButton>
    <div v-if="modelValue" :id="id" v-bng-ui-nav-scroll class="accordion-body"><slot /></div>
  </section>
</template>
<script setup>
import { vBngUiNavScroll } from "@/common/directives"
import HouseButton from "./HouseButton.vue"
defineProps({ modelValue: Boolean, title: String, id: { type: String, required: true } })
const emit = defineEmits(["update:modelValue"])
</script>
<style scoped>
.accordion-body { overflow: auto; max-height: 50vh; padding: .5em; }
</style>

<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ComputerWrapper :title="definition?.label || ''" close @back="back">
    <component v-if="component" :is="component" :computer-function="definition" :computer-id="context.computerId" :inventory-id="context.inventoryId" :call-lua="callModLua" />
    <div v-else-if="failed" class="computer-function-message">This function is not available.</div>
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, shallowRef, watch, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { loadRuntimeComponent } from '../utils/runtimeComponent.js'
import ComputerWrapper from './ComputerWrapper.vue'
import { ensureComputerFunctions, computerFunctionDefinition } from '../utils/computerFunctionCatalog.js'
import { callModLua } from '../utils/installLuaBridgeFallbacks'

const props = defineProps({ functionId: String })
const definition = ref(null)
const context = ref({})
const component = shallowRef(null)
const failed = ref(false)
let generation = 0
const back = () => lua.extensions.ui_router.navigate('overhaul.computer')
async function load(id) {
  const token = ++generation
  component.value = null
  failed.value = false
  try {
    await ensureComputerFunctions()
    if (token !== generation) return
    definition.value = computerFunctionDefinition(id) || null
    if (!definition.value?.component) { failed.value = true; return }
    const current = await callModLua('overhaul_career_garage_computer.getFunctionContext')
    if (token !== generation) return
    context.value = current?.functionId === id ? current : {}
    const loaded = await loadRuntimeComponent(definition.value.component)
    if (token !== generation) return
    component.value = loaded
  } catch (err) {
    if (token === generation) { failed.value = true; reportUiFailure(err, "[computerFunctionHost] page load failed (ComputerFunctionHost)") }
  }
}
watch(() => props.functionId, load, { immediate: true })
onUnmounted(() => { generation++ })
</script>

<style scoped>
.computer-function-message { padding: 2em; }
</style>

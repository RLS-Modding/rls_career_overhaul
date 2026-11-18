<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ComputerWrapper :title="definition?.label || ''" close :before-navigate="canNavigate" :breadcrumb-filter="isScreenCrumb" @back="back">
    <component v-if="component" :is="component" :computer-function="definition" :computer-id="context.computerId" :inventory-id="context.inventoryId" :call-lua="callModLua" />
    <div v-else-if="failed" class="computer-function-message">This screen is not available right now.</div>
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, shallowRef, watch, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { loadRuntimeComponent } from '../utils/runtimeComponent.js'
import ComputerWrapper from './ComputerWrapper.vue'
import { ensureComputerFunctions, computerFunctionDefinition, COMPUTER_FUNCTION_ROUTE_GROUP } from '../utils/computerFunctionCatalog.js'
import { callModLua } from '../utils/installLuaBridgeFallbacks'

const props = defineProps({ functionId: String })
const definition = ref(null)
const context = ref({})
const component = shallowRef(null)
const failed = ref(false)
let generation = 0
// The route group has no screen and no title, so the trail would show its raw name ("function") as a dead link.
const isScreenCrumb = crumb => crumb?.routeName !== COMPUTER_FUNCTION_ROUTE_GROUP
const canNavigate = async () => !definition.value?.navigation?.canLeave || (await callModLua(definition.value.navigation.canLeave)) === true
const back = () => definition.value?.navigation?.back
  ? callModLua(definition.value.navigation.back, context.value.computerId)
  : lua.extensions.ui_router.navigate('overhaul.computer')
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

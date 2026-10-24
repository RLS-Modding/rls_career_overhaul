<template>
  <div class="phone-app-host" :data-phone-app="appId">
    <component v-if="state === 'ready' && component" :is="component" :key="appId" :app="app" :call-lua="callModLua" />
    <div v-else-if="state === 'loading'" class="phone-app-host__message" role="status">Loading...</div>
    <PhoneAppNotice v-else-if="state === 'locked'" :title="lockedTitle" :message="lockedMessage" />
    <PhoneAppNotice v-else-if="state === 'missing'" :icon="icons.info" message="This app is not available." />
    <PhoneAppNotice v-else :icon="icons.danger" message="This app could not be loaded.">
      <button type="button" class="primary" @click="load(appId)">Try again</button>
    </PhoneAppNotice>
  </div>
</template>

<script>
// Hosted apps prepare per navigation, including static route props. The guard
// holds the old screen for 300 ms; committed hosts consume that exact result.
// Permission is never cached and the module graph owns add-on reload freshness.
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { appPageFile, ensurePhoneApps, getPhoneApps } from '../../utils/phoneAppCatalog'
import { usePhoneApps, DEFAULT_SKILL_LOCKED_MESSAGE } from '../../utils/phoneAppRegistry'
import { loadRuntimeComponent, resetRuntimeComponent } from '../../utils/runtimeComponent.js'
import { reportUiFailure } from '../../utils/safeLua'

let pendingPreparation = null

export function resolveAppId(to) {
  const props = to.matched.at(-1)?.props.default
  return props === true ? to.params.appId : props?.appId || ''
}

export async function prepareApp(appId) {
  let timer
  let app = null
  let pending = null
  let file = null
  let expired = false
  const work = (async () => {
    await ensurePhoneApps()
    app = getPhoneApps().find(entry => entry.id === appId && appPageFile(entry)) || null
    if (!app) return { appId, app, component: null, state: 'missing' }
    if (!(await usePhoneApps().isAppUsageUnlocked(appId, lua))) return { appId, app, component: null, state: 'locked' }
    if (expired) return
    file = appPageFile(app)
    pending = loadRuntimeComponent(file)
    const component = await pending
    return { appId, app, component, state: 'ready' }
  })()
  try {
    return await Promise.race([work, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Phone app '${appId}' preparation timed out`)), 2500)
    })])
  } catch (error) {
    expired = true
    if (pending) resetRuntimeComponent(file, pending)
    reportUiFailure(error, `Load phone app '${appId}' (PhoneAppHost)`)
    return { appId, app, component: null, state: 'error' }
  } finally { clearTimeout(timer) }
}

export async function prepareNavigation(to) {
  pendingPreparation?.dispose()
  const entry = { fullPath: to.fullPath, appId: resolveAppId(to), result: null, promise: null, dispose: () => {} }
  entry.promise = prepareApp(entry.appId).then(result => {
    if (pendingPreparation === entry) entry.result = result
    return result
  })
  pendingPreparation = entry
  // Vue Router runs guards in the app injection context, so this binding also
  // covers a cancelled first entry, before a host or shell has mounted.
  const router = useRouter()
  let expiry
  const remove = router.afterEach((target, _, failure) => {
    if ((failure || target.fullPath !== to.fullPath) && pendingPreparation === entry) pendingPreparation = null
    entry.dispose()
  })
  entry.dispose = () => { remove(); clearTimeout(expiry) }
  expiry = setTimeout(() => { if (pendingPreparation === entry) pendingPreparation = null; entry.dispose() }, 3000)
  let timer
  await Promise.race([entry.promise, new Promise(resolve => { timer = setTimeout(resolve, 300) })])
  clearTimeout(timer)
}

function takePrepared(fullPath, appId) {
  const entry = pendingPreparation
  if (!entry || entry.fullPath !== fullPath || entry.appId !== appId) return null
  pendingPreparation = null
  entry.dispose()
  return entry
}
</script>

<script setup>
import { computed, onUnmounted, ref, shallowRef, watch } from 'vue'
import { useRoute } from 'vue-router'
import { icons } from '@/common/components/base'
import PhoneAppNotice from '../../components/phone/PhoneAppNotice.vue'
import { callModLua } from '../../utils/installLuaBridgeFallbacks'

defineOptions({ beforeRouteEnter: prepareNavigation, beforeRouteUpdate: prepareNavigation })
const props = defineProps({ appId: { type: String, default: '' } })
const route = useRoute()
// Screen keys use route names, so a leaving instance still sees global commits
// but must leave the incoming host's prepared result for its own setup.
const routeName = route.name
const app = ref(null)
const component = shallowRef(null)
const state = ref('loading')
const lockedMessage = computed(() => app.value?.lockedMessage || DEFAULT_SKILL_LOCKED_MESSAGE)
const lockedTitle = computed(() => app.value?.name ? `${app.value.name} is locked` : '')
let generation = 0
function apply(result) {
  app.value = result.app
  component.value = result.component
  state.value = result.state
}
async function load(appId, entry = null) {
  const token = ++generation
  if (entry?.result) { apply(entry.result); return }
  component.value = null
  state.value = 'loading'
  const result = await (entry?.promise || prepareApp(appId))
  if (token === generation) apply(result)
}
// The committed route is the preparation key even when appId stays the same.
// Derive its ID from that same record, before Vue updates the reused host props.
watch(() => route.fullPath, () => {
  if (route.name !== routeName) { generation++; return }
  const appId = resolveAppId(route)
  const entry = takePrepared(route.fullPath, appId)
  if (entry || generation === 0) load(appId, entry)
}, { immediate: true, flush: 'sync' })
onUnmounted(() => { generation++ })
</script>

<style scoped>
.phone-app-host { position: relative; width: 100%; height: 100%; overflow: auto; background: #15171d; }
.phone-app-host__message { padding: 4em 1.25em; text-align: center; color: rgba(255,255,255,.75); }
</style>

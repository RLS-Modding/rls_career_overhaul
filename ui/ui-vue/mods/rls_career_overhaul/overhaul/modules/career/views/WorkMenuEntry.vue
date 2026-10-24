<!-- Hand-off screen while the Job Broker opens (cargo overview / my cargo). House card; same calls. -->
<template>
  <div class="work-entry rls-house" v-bng-scoped-nav="navScope" v-bng-on-ui-nav:back,menu="back">
    <main class="entry-card">
      <span class="caption">Job Broker</span>
      <h1>{{ failed ? "Dispatch unavailable" : "Opening work…" }}</h1>
      <p v-if="failed" class="hint">Return and try again.</p>
      <HouseButton ref="backBtn" :variant="failed ? 'primary' : 'quiet'" binding="back" @click="back">Back</HouseButton>
    </main>
  </div>
</template>
<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { onMounted, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { vBngOnUiNav, vBngScopedNav } from '@/common/directives'
import { HouseButton } from '../components/house/index.js'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
const props = defineProps({ facilityId: String, parkingSpotPath: String })
const failed = ref(false)
const backBtn = ref(null)
// One B press can reach both the scope guard and the UI-nav binding.
let leaving = false
const back = () => {
  if (leaving) return
  leaving = true
  setTimeout(() => (leaving = false), 300)
  lua.guihooks.trigger('ChangeState', { state: 'play' })
}
const navScope = {
  scopeId: 'root',
  activateOnMount: true,
  canDeactivate: () => {
    back()
    return false
  },
}
watch(failed, isFailed => { if (isFailed) refocusIfLost(() => backBtn.value?.$el) }, { flush: 'post' })
onMounted(async () => {
  try {
    if (props.facilityId) await lua.overhaul_career_logistics_cargoScreen.enterCargoOverviewScreen(props.facilityId, props.parkingSpotPath || null)
    else await lua.overhaul_career_logistics_cargoScreen.enterMyCargo()
  } catch (error) {
    failed.value = true
    reportUiFailure(error, "[work-entry] dispatch failed (WorkMenuEntry)")
  }
})
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.work-entry {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  color: #fff;
  background: rgba(5, 8, 10, 0.55);
}
.entry-card {
  display: grid;
  justify-items: start;
  gap: 0.5em;
  min-width: 20em;
  padding: 1.1em 1.2em 1em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.95);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  h1 {
    margin: 0;
    font-size: 1.35em;
    font-weight: 800;
  }
  .hint {
    margin: 0;
  }
  .house-button {
    margin-top: 0.4em;
    justify-self: end;
  }
}
</style>

<template>
  <EntryOverlayPopup :active="open" :can-cancel="true" @cancel="onContinue" @leave="close">
    <transition name="rt-promo-fade">
      <div
        v-if="open"
        class="rt-promo-overlay"
        role="dialog"
        aria-modal="true"
      >
        <RacingTeamPromoPanel
          :title="title"
          :body="body"
          :image-url="imageUrl"
          >
          <button
            v-if="continueHandler"
            type="button"
            class="btn btn-primary"
            bng-nav-item
            bng-scoped-nav-autofocus
            @click="onContinue"
          >
            <BngBinding class="btn-glyph" ui-event="ok" controller track-ignore />
            {{ continueLabel }}
          </button>
        </RacingTeamPromoPanel>
      </div>
    </transition>
  </EntryOverlayPopup>
</template>

<script setup>
import EntryOverlayPopup from "./EntryOverlayPopup.vue"
import { safeLua } from "../utils/safeLua.js"

import { ref, computed, onMounted, onBeforeUnmount, watch } from "vue"
import { useRoute } from "vue-router"
import { useBridge, lua } from "@/bridge"
import { BngBinding } from "@/common/components/base"
import RacingTeamPromoPanel from "./RacingTeamPromoPanel.vue"

const bridge = useBridge()
const route = useRoute()
const open = ref(false)
const payload = ref(null)

const kind = computed(() => (payload.value && payload.value.kind) || "")
const title = computed(() => (payload.value && payload.value.title) || "")
const body = computed(() => (payload.value && payload.value.body) || "")
const imageUrl = computed(() => (payload.value && payload.value.imageUrl) || "")
const continueLabel = computed(() => (payload.value && payload.value.continueLabel) || "Continue")

const businessIdStr = computed(() => {
  const b = payload.value && payload.value.businessId
  return b != null && b !== "" ? String(b) : null
})


const close = () => {
  if (open.value && businessIdStr.value && (kind.value === "league2_welcome" || kind.value === "career_finale")) {
    safeLua(lua.overhaul_career_business_racingTeam_racingTeam.racingTeamMilestoneSplashOpen(businessIdStr.value, kind.value, false), "RacingTeamMilestoneSplash: close")
  }
  open.value = false
  payload.value = null
}

const normalizeMilestonePayload = raw => {
  if (!raw || typeof raw !== "object") return null
  if (Array.isArray(raw) && raw.length > 0) {
    const first = raw[0]
    if (first && typeof first === "object" && !Array.isArray(first)) {
      return first
    }
    return null
  }
  return raw
}

const onMilestone = (...args) => {
  const raw = args.length > 0 ? args[0] : null
  const data = normalizeMilestonePayload(raw)
  if (!data || typeof data !== "object") return
  close()
  payload.value = data
  open.value = true
  if (businessIdStr.value && (kind.value === "league2_welcome" || kind.value === "career_finale")) {
    safeLua(lua.overhaul_career_business_racingTeam_racingTeam.racingTeamMilestoneSplashOpen(businessIdStr.value, kind.value, true), "RacingTeamMilestoneSplash: onMilestone")
  }
}

const onPurchaseContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  await safeLua(() => lua.overhaul_career_business_manager.perform({type: "racingTeam", id: bid}, "racingTeamMilestonePurchaseContinue", {}), "RacingTeamMilestoneSplash: onPurchaseContinue")
  close()
}

const onCareerFinaleContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  await safeLua(() => lua.overhaul_career_business_manager.perform({type: "racingTeam", id: bid}, "racingTeamMilestoneCareerFinaleContinue", {}), "RacingTeamMilestoneSplash: onCareerFinaleContinue")
  close()
}

const onLeague2WelcomeContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  await safeLua(() => lua.overhaul_career_business_manager.perform({type: "racingTeam", id: bid}, "racingTeamMilestoneLeague2WelcomeContinue", {}), "RacingTeamMilestoneSplash: onLeague2WelcomeContinue")
  close()
}

// the one action per splash kind (unknown kinds show no button, as before)
const continueHandler = computed(() => ({
  purchase: onPurchaseContinue,
  league2_welcome: onLeague2WelcomeContinue,
  race_unlock: close,
  career_finale: onCareerFinaleContinue,
}[kind.value] || null))
let continuing = false
const onContinue = async () => {
  // B, Start and A can all land here; run the Lua continue once. An unknown kind just closes.
  if (continuing || !open.value) return
  continuing = true
  try {
    await (continueHandler.value || close)()
  } finally {
    continuing = false
  }
}

onMounted(() => {
  bridge.events.on("RacingTeamMilestoneSplashShow", onMilestone)
})
watch(() => route.fullPath, close)

onBeforeUnmount(() => {
  close()
  bridge.events.off("RacingTeamMilestoneSplashShow", onMilestone)
})
</script>

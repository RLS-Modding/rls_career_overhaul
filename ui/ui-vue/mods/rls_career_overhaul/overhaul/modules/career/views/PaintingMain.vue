<!-- RLS override of the vanilla PaintingMain.vue. The session owner chooses the return computer.
     The painting panel sits top-left under the screen heading; its cart moves into the ComputerWrapper side
     column (like Tuning) as the house-styled PaintShoppingCart, fed by the state Painting.vue exposes. -->
<template>
  <ComputerWrapper :path="[$translate.instant('ui.career.shared.pathPainting')]" :title="$translate.instant('ui.career.shared.pathPainting')" back @back="close">
    <div class="painting-main-panel" v-bng-scoped-nav="{ scopeId: 'career-painting', preferAutoFocus: true }"
      v-bng-on-ui-nav:tab_l="onTabLeft" v-bng-on-ui-nav:tab_r="onTabRight" v-bng-on-ui-nav:context="switchToCart">
      <Painting ref="paintingRef" :active="isPaintingActive" @ready="isPaintingReady = true" />
    </div>

    <template #side>
      <PaintShoppingCart
        v-if="paintingCart"
        :active="isCartActive"
        :show-hint="hasCartNavigableItems"
        v-bng-scoped-nav="{ scopeId: 'career-painting-cart' }"
        v-bng-on-ui-nav:context="switchToPainting"
        :changed-paint="paintingCart.changedPaint"
        :rows="paintingCart.rows"
        :total-price="paintingCart.totalPrice"
        :can-pay="paintingCart.canPay"
        @reset-paint="onResetPaint"
        @apply="() => paintingRef?.apply()" />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { useScreenEntry } from "../composables/useScreenEntryFocus"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { useScopedNav } from "@/services/scopedNav/api"
import { useRouteReady } from "@/services/routeReadiness"
import { ref, computed, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import ComputerWrapper from "./ComputerWrapper.vue"
import Painting from "../components/painting/Painting.vue"
import PaintShoppingCart from "../components/painting/PaintShoppingCart.vue"
import { $translate } from "@/services/translation"

const enterScreen = useScreenEntry()


const close = () => lua.overhaul_career_parts_painting.close()

const isPaintingReady = ref(false)

// cart state exposed by Painting.vue (display wiring only; the cart logic stays in Painting.vue)
const paintingRef = ref(null)
const paintingCart = computed(() => paintingRef.value?.cart || null)
const { requestScopeFocus, switchScope, current } = useScopedNav()
const isPaintingActive = computed(() => current.value?.id === "career-painting")
const isCartActive = computed(() => current.value?.id === "career-painting-cart")
const hasCartNavigableItems = computed(() => !!paintingCart.value?.changedPaint)
const switchToCart = () => { if (hasCartNavigableItems.value) switchScope("career-painting-cart") }
const switchToPainting = () => switchScope("career-painting")
const onTabLeft = () => { paintingRef.value?.goPrevTab(); nextTick(() => requestScopeFocus("career-painting")) }
const onTabRight = () => { paintingRef.value?.goNextTab(); nextTick(() => requestScopeFocus("career-painting")) }
const onResetPaint = index => {
  paintingRef.value?.resetPaint(index)
  if (!hasCartNavigableItems.value) switchToPainting()
}

useRouteReady({
  onReady: () => enterScreen("career-painting"),
  async waitUntilReady() {
    if (!isPaintingReady.value) {
      await new Promise(resolve => {
        const stop = watch(isPaintingReady, ready => {
          if (!ready) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})

</script>

<style scoped lang="scss">
.painting-main-panel { height: 100%; min-height: 0; max-width: 100%; }
</style>

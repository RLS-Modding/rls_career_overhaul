<template>
  <ComputerWrapper :title="$translate.instant('ui.career.shared.pathParts')" @back="backWithinParts">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'part-shopping-categories', trapPolicy: 'always', canDeactivate: onPartsBack }"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      class="part-shopping-panel rls-house"
      tabindex="-1"
      :active="isPartShoppingActive"
    >
      <template #heading>
        <PartNavigation :label="panelHeading" :can-back="!isShoppingUnavailable && activePanel !== 'categories'" :active="isPartShoppingActive" @back="backWithinParts" />
      </template>
      <!-- Keep panels mounted so each level restores its scroll position on back. -->
      <div v-if="isShoppingUnavailable" class="unavailable-shopping" role="status">
        <p v-if="isDisplayMissing">Part customization is unavailable. Use Back to leave this screen.</p>
        <p v-else>Part customization is unavailable for this vehicle. Your shopping session is retained.</p>
        <p v-if="!isDisplayMissing && !partShoppingStore.partShoppingData.shoppingCart">The retained cart and catalog cannot be displayed.</p>
        <BngButton v-if="isDisplayMissing" @click="close">Back</BngButton>
        <template v-else>
          <BngButton @click="confirmCancel">Discard and leave</BngButton>
          <BngButton v-if="cartData.items.length" @click="confirmSaveForLater">Save for later and leave</BngButton>
        </template>
      </div>
      <div v-else class="panel-stack">
        <Categories
          v-show="activePanel === 'categories'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
        <SlotList
          ref="slotList"
          v-show="activePanel === 'slots'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
        <PartsList
          ref="partsList"
          v-show="activePanel === 'parts'"
          class="panel-layer"
          :cancel="confirmCancel"
        />
      </div>
    </ComputerPanel>
    <template #side>
      <ShoppingCart
        v-if="!isShoppingUnavailable"
        v-bng-scoped-nav="{ scopeId: 'part-shopping-cart' }"
        :active="isCartActive"
        :partShoppingData="partShoppingStore.partShoppingData"
        :cart-data="cartData"
        :player-money="partShoppingStore.partShoppingData.playerMoney"
        :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
        :show-save-for-later="true"
        :restore-in-progress="!!partShoppingStore.partShoppingData.restoreInProgress"
        :restore-progress="partShoppingStore.partShoppingData.restoreProgress || { current: 0, total: 0 }"
        v-bng-on-ui-nav:context="switchToCategories"
        @apply="applyShopping"
        @cancel="confirmCancel"
        @save-for-later="confirmSaveForLater"
        @remove-item="removeCartItem"
      />
      <div v-else-if="partShoppingStore.partShoppingData.shoppingCart" class="unavailable-shopping">
        <p>Retained cart (editing and purchase unavailable)</p>
        <ul><li v-for="item in cartData.items" :key="item.key">{{ item.name }} — {{ units.beamBucks(item.price) }}</li></ul>
      </div>
    </template>

    <!-- Tabs are shown in infobar because they are tracked events by crossfire.
     This is a hack to prevent them from displaying in the infobar -->
    <BngBinding v-show="false" ui-event="tab_l" controller />
    <BngBinding v-show="false" ui-event="tab_r" controller />
  </ComputerWrapper>
</template>

<script setup>
import { useRouteReady } from "@/services/routeReadiness"
import { computed, ref, watch, nextTick, onBeforeMount, onUnmounted } from "vue"
import { BngBinding, BngButton, ACCENTS } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { useScopedNav } from "@/services/scopedNav/api"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { useBridge } from "@/bridge"

import { $translate } from "@/services/translation"
import { useUINavBlocker } from "@/services/uiNavTracker"

import { usePartShoppingStore } from "../stores/partShoppingStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import ShoppingCart from "../components/ShoppingCart.vue"
import Categories from "../components/partShopping/Categories.vue"
import SlotList from "../components/partShopping/SlotList.vue"
import PartNavigation from "../components/partShopping/PartNavigation.vue"
import PartsList from "../components/partShopping/PartsList.vue"
import { callModLua } from "../utils/installLuaBridgeFallbacks"
import { openHouseConfirmation } from "../components/house/index.js"

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const partShoppingStore = usePartShoppingStore()
const { events, lua, units } = useBridge()
const isShoppingUnavailable = computed(() => !!partShoppingStore.partShoppingData?.unavailableReason)
const isDisplayMissing = computed(() => partShoppingStore.partShoppingData?.unavailableReason === "shopping-display-unavailable")

const { switchScope, current } = useScopedNav()

const isCartActive = computed(() => current.value?.id === "part-shopping-cart")
const isPartShoppingActive = computed(() => current.value?.id === "part-shopping-categories")

// The cart scope is not rendered while the display is unavailable, so the context button has nowhere to go.
const switchToCart = () => {
  if (isShoppingUnavailable.value) return
  switchScope("part-shopping-cart")
}
const switchToCategories = () => switchScope("part-shopping-categories")

const CANCEL_MESSAGE = $translate.instant("ui.career.shared.cancelShoppingMessage")
const SAVE_FOR_LATER_MESSAGE = "Leave part customization?<br />Your build will be saved for later. The vehicle will return to its current installed state."
const CONFIRM_BUTTONS = [
  { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true, destructive: true } },
]
const SAVE_FOR_LATER_BUTTONS = [
  { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
]

const confirmCancel = async () => {
  if (isDisplayMissing.value) {
    callModLua("overhaul_career_parts_partShopping.requestExit")
    return
  }
  const cart = partShoppingStore.partShoppingData?.shoppingCart
  const hasItems = cart && cart.partsInList && cart.partsInList.length > 0

  if (!hasItems && !isShoppingUnavailable.value) {
    discardShopping()
    return
  }

  if (await openHouseConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    discardShopping()
  }
}

const confirmSaveForLater = async () => {
  const cart = partShoppingStore.partShoppingData?.shoppingCart
  const hasItems = cart && cart.partsInList && cart.partsInList.length > 0
  if (!hasItems && !isShoppingUnavailable.value) return

  if (await openHouseConfirmation(null, SAVE_FOR_LATER_MESSAGE, SAVE_FOR_LATER_BUTTONS)) {
    saveCartForLater()
  }
}

const getPartName = (item) => {
  return item.description.description + (item.partId ? ` (${$translate.instant("ui.career.partShopping.inventory")})` : "")
}

const cartData = computed(() => {
  const cart = partShoppingStore.partShoppingData ? partShoppingStore.partShoppingData.shoppingCart : null
  const res = { total: 0, taxes: 0, items: [] }
  if (cart) {
    res.total = cart.total
    res.taxes = cart.taxes
    if (Array.isArray(cart.partsInList)) {
      res.items = cart.partsInList.map(item => ({
        key: item.containingSlot,
        name: getPartName(item),
        price: item.finalValue,
        extraInfo: item.partCondition?.odometer ? $translate.instant("ui.career.shared.mileagePrefix") + units.buildString("length", item.partCondition.odometer, 0) : undefined,
        removeShow: !!item.sourcePart,
        removeDisabled: !!partShoppingStore.partShoppingData.tutorialPartNames,
        containingSlot: item.containingSlot,
      }))
    }
  }
  return res
})

const applyShopping = () => {
  if (isShoppingUnavailable.value) return
  return lua.overhaul_career_parts_partShopping.applyShopping()
}
const cancelShopping = () => lua.overhaul_career_parts_partShopping.cancelShopping()
const discardShopping = () => callModLua("overhaul_career_parts_partShopping.discardShopping")
const saveCartForLater = () => callModLua("overhaul_career_parts_partShopping.saveCartForLater")
const removeCartItem = (item) => {
  if (isShoppingUnavailable.value) return
  return lua.overhaul_career_parts_partShopping.removePartBySlot(item.containingSlot)
}

// Shopping data arrives from Lua after mount. Delay the manual routeMounted ack
// and scope activation until the data is present and rendered so the categories
// autofocus target lands on a navigable entry.
const isShoppingReady = computed(() => isShoppingUnavailable.value || !!partShoppingStore.partShoppingData?.partTree)

// The backend prepares which panel the active route shows; render it directly.
const activePanel = computed(() => partShoppingStore.activePanel)
// Route changes can reactivate the outer root scope. Keep B and D-pad input
// in the catalog once its destination panel is ready, including the first load.
watch([activePanel, isShoppingReady], ([, ready]) => {
  if (ready) nextTick(switchToCategories)
}, { immediate: true })

const slotList = ref(null)
const partsList = ref(null)
const backWithinParts = () => {
  const list = activePanel.value === "slots" ? slotList.value : activePanel.value === "parts" ? partsList.value : null
  if (!isShoppingUnavailable.value && list?.clearSearch()) return
  close()
}
// Stock scoped Back asks this guard before changing routes or deactivating focus.
const onPartsBack = event => {
  event?.stopPropagation()
  backWithinParts()
  return false
}

const panelHeading = computed(() => {
  if (activePanel.value === "categories") return $translate.instant("ui.career.shared.categories")
  if (activePanel.value === "slots") return $translate.instant("ui.career.partShopping.allParts")
  if (partShoppingStore.category === "cargo") return $translate.instant("ui.career.partShopping.cargo")
  const firstPart = partShoppingStore.filteredParts[0]
  const slotName = partShoppingStore.slot?.split("/").filter(Boolean).pop()
  return partShoppingStore.partShoppingData.slotsNiceName?.[firstPart?.containingSlot] || partShoppingStore.partShoppingData.slotsNiceName?.[slotName] || slotName || $translate.instant("ui.career.partShopping.allParts")
})

useRouteReady({
  async waitUntilReady() {
    if (!isShoppingReady.value) {
      await new Promise(resolve => {
        const stop = watch(isShoppingReady, ready => {
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

const start = () => {
  partShoppingStore.requestInitialData()
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
}

const kill = () => {
  partShoppingStore.cancelShopping()
  getUINavServiceInstance().clearFilteredEvents()
  partShoppingStore.$dispose()
}

const close = () => lua.extensions.ui_router.back()

onBeforeMount(() => {
  start()
  events.on("partShoppingRequestExit", confirmCancel)
})
onUnmounted(() => {
  events.off("partShoppingRequestExit", confirmCancel)
  kill()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Root is ComputerPanel: `.part-shopping-panel.computer-panel` outranks its scoped surface.
// .rls-house on the panel also hands the house tokens down to Categories / SlotList / PartsList.
.part-shopping-panel.computer-panel {
  // resolution-scaled em like the cart beside it (rem text went tiny at 2560x1440 next to a scaled cart)
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(30em, 100%);
  height: 100%;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  // Same fill as the cart: a thinner fill turned the catalog light grey over bright garages
  // while the pad was on the cart. The grey heading bar is the inactive cue.
  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.92);
    :deep(.heading::before) {
      background: rgba(255, 255, 255, 0.3);
    }
  }
}

.panel-stack {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.unavailable-shopping {
  padding: 1em;
  color: #fff;
}

.panel-layer {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.md-content {
  display: block;
  flex-direction: column;
  position: relative;
  width: 100%;
  text-align: center;
  height: 100%;
  overflow-y: hidden;
}

.profileStatus {
  border-radius: var(--bng-corners-2);
  position: absolute;
  top: 0;
  right: 0;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}
</style>

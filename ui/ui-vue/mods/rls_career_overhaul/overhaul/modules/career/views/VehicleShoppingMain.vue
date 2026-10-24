<!-- RLS Vehicle Shopping computer shell, house style. Same store, route and Lua flow as before; the vanilla
     orange-underlined tab strip is a quiet segmented toggle (tab_l / tab_r still switch it), sitting top-left
     under the screen heading. Only the active tab is mounted, as with the old Tabs component. -->
<template>
  <ComputerWrapper
    :path="[vehicleShoppingStore.vehicleShoppingData.currentSellerNiceName || ('Vehicle Marketplace')]"
    :title="headerTitle"
    back @back="close"
  >
    <template #status>
      <span v-if="racingTeamBizId" class="status-note">
        Team funds <span class="status-money"><BngIcon :type="icons.beamCurrency" />{{ teamBalanceText }}</span>
      </span>
      <span v-else class="status-note">
        Free slots <b>{{ vehicleShoppingStore ? vehicleShoppingStore.vehicleShoppingData.numberOfFreeSlots : 0 }}</b>
      </span>
    </template>

    <!-- The Lua route's targetScope is "vehicle-shopping" (as in vanilla): the router calls
         activateRouteTargetScope() after mount, and until a scope with that id registers the scoped-nav
         coordinator holds a pending activation that blocks every focus request, so the pad did nothing on
         this screen. LB / RB live in here too: ui_nav events bubble up from the focused element, and the
         layout's own tab_l / tab_r handler (no tabs there) stops them before they reach the wrapper. -->
    <div
      class="shop"
      v-bng-scoped-nav="{ scopeId: 'vehicle-shopping', activateOnMount: true, preferAutoFocus: true, canDeactivate: shopBack }"
      v-bng-on-ui-nav:tab_l,tab_r="processTabInput">
      <div v-if="tabs.length > 1" class="shop-tabs rls-house">
        <BngBinding class="tab-hint" ui-event="tab_l" controller />
        <div class="seg bar" role="tablist" v-bng-blur="1">
          <button
            v-for="(tab, index) in tabs"
            :key="tab"
            type="button"
            role="tab"
            bng-no-nav="true"
            :aria-selected="index === activeIndex"
            :class="{ active: index === activeIndex }"
            v-bng-sound-class="'bng_click_hover_generic'"
            @click="selectTab(index)"
          >
            {{ tab }}
          </button>
        </div>
        <BngBinding class="tab-hint" ui-event="tab_r" controller />
      </div>

      <div v-if="activeTabName === buyVehicleTitle" class="buying-tab-content">
        <VehicleList v-if="loaded" />
        <div v-else class="loading-card rls-house" v-bng-blur="1">
          <span class="hint">Please wait...</span>
        </div>
      </div>
      <div v-else-if="activeTabName" class="marketplace-tab-content">
        <VehicleMarketplace :racing-team-business-id="racingTeamBizId" />
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { $translate } from "@/services/translation"
import { useRouteReady } from "@/services/routeReadiness"
import { useScopedNav } from "@/services/scopedNav/api"
import { ref, onMounted, onUnmounted, nextTick, computed, watch } from "vue"
import { BngBinding, BngIcon, icons } from "@/common/components/base"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"
import { closeShopDetail } from "../components/vehicleShopping/useShopVehicle"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import VehicleMarketplace from "../components/vehicleShopping/VehicleMarketplace.vue"
import { lua } from "@/bridge"
import { useComputerStore } from "../stores/computerStore"
import { vBngOnUiNav } from "@/common/directives"
import { useRouter, useRoute } from "vue-router"
import { vBngBlur, vBngSoundClass, vBngScopedNav } from "@/common/directives"
import { refocusIfLost } from "../composables/useScreenEntryFocus"

const buyVehicleTitle = $translate.instant('ui.career.vehicleShopping.buyVehicles')
const sellVehicleTitle = $translate.instant('ui.career.vehicleShopping.sellVehicles')

const computerStore = useComputerStore()
const vehicleShoppingStore = useVehicleShoppingStore()

const selectedTab = ref(0)
const selectedSellerId = ref("")

const router = useRouter()
const route = useRoute()

const loaded = ref(false)

const racingTeamBizId = computed(() => {
  const q = route.query.rtBiz
  if (q !== undefined && q !== null && String(q) !== "") return String(q)
  return String(vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessId || "")
})

const teamBalanceText = computed(() => {
  const raw = vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessMoney
  const n = Number(raw)
  if (!Number.isFinite(n)) return "—"
  return n.toLocaleString()
})

const tabs = computed(() => {
  let tabs = []
  const canBuy = vehicleShoppingStore.vehicleShoppingData.buyingAvailable ?? (props.buyingAvailable === 'true')
  const canUseMarketplace = vehicleShoppingStore.vehicleShoppingData.marketplaceAvailable ?? (props.marketplaceAvailable === 'true')
  if (canBuy) {
    tabs.push(buyVehicleTitle)
  }
  if (canUseMarketplace) {
    tabs.push(sellVehicleTitle)
  }
  return tabs
})

const props = defineProps({
  screenTag: {
    type: String,
    default: "",
  },
  buyingAvailable: {
    type: String,
    default: "true",
  },
  marketplaceAvailable: {
    type: String,
    default: "true",
  },
  selectedSellerId: {
    type: String,
    default: "",
  },
})

const processTabInput = (event) => {
  if (event.detail.name === "tab_l") {
    selectedTab.value = (selectedTab.value - 1 + tabs.value.length) % tabs.value.length
  } else if (event.detail.name === "tab_r") {
    selectedTab.value = (selectedTab.value + 1) % tabs.value.length
  }
}

// The old Tabs component kept showing its last valid tab when selectedTab went out of range
// (e.g. -1 from an unavailable screenTag); mirror that by falling back to the first tab.
const activeIndex = computed(() => {
  const i = selectedTab.value
  return i >= 0 && i < tabs.value.length ? i : 0
})
const activeTabName = computed(() => tabs.value[activeIndex.value])

const selectTab = index => {
  if (index < 0 || index >= tabs.value.length) return
  selectedTab.value = index
}

// Was the Tabs @change handler: it fired on every tab switch (click or tab_l / tab_r).
const onTabsChange = () => {
  if (selectedTab.value === tabs.value.indexOf(buyVehicleTitle)) {
    selectedSellerId.value = ""
  }
}
watch(selectedTab, onTabsChange)

const headerTitle = computed(() => {
  switch (tabs.value[selectedTab.value]) {
    case buyVehicleTitle:
      return buyVehicleTitle
    case sellVehicleTitle:
      return sellVehicleTitle
    default:
      return $translate.instant("ui.career.vehicleShopping.availableVehicles")
  }
})

const updateRouteScreenTag = () => {
  if (route.name === "overhaul.computer.vehicleShopping.vehicles") return
  const isSelling = selectedTab.value === tabs.value.indexOf(sellVehicleTitle)
  const screenTag = isSelling ? "marketplace" : "buying"
  const q = { ...route.query }
  router.replace({
    name: "overhaul.computer.vehicleShopping",
    params: {
      screenTag,
      buyingAvailable: props.buyingAvailable,
      marketplaceAvailable: props.marketplaceAvailable,
      selectedSellerId: selectedSellerId.value,
    },
    query: q,
  })
}

watch(selectedTab, () => {
  updateRouteScreenTag()
})

// Controller: LB / RB swap the whole tab body (only the active tab is mounted), which drops focus; land
// on the new tab's first item (never its search box)
const firstTabItem = () =>
  document.querySelector(".shop .main-content, .shop .marketplace-tab-content")
    ?.querySelector('[bng-nav-item]:not([bng-no-nav="true"]):not([disabled]), button:not([disabled]):not([bng-no-nav="true"])')
watch(selectedTab, (tab, prev) => {
  if (prev === undefined) return
  // the tab body loads its data after mounting; try again once it has rendered
  refocusIfLost(firstTabItem, { force: true })
  setTimeout(() => refocusIfLost(firstTabItem), 600)
}, { flush: "post" })

const setSelectedSellerId = (sellerId) => {
  selectedSellerId.value = sellerId
  vehicleShoppingStore.setSelectedSellerId(selectedSellerId.value)
}


const start = () => {
  nextTick(async () => {
    try {
      sessionStorage.removeItem("rtVehicleShop")
    } catch (e) { reportUiFailure(e, "start (VehicleShoppingMain)") }
    if (route.query.rtBiz !== undefined && route.query.rtBiz !== null && String(route.query.rtBiz) !== "") {
      try {
        await lua.overhaul_career_market_vehicleShopping.setRtBiz(String(route.query.rtBiz))
      } catch (_e) { reportUiFailure(_e, "start (VehicleShoppingMain)") }
    }
    await vehicleShoppingStore.requestVehicleShoppingData()
    loaded.value = true
    if (vehicleShoppingStore.vehicleShoppingData.currentSeller) {
      setSelectedSellerId(vehicleShoppingStore.vehicleShoppingData.currentSeller)
    } else {
      setSelectedSellerId(vehicleShoppingStore.vehicleShoppingData.selectedSellerId || props.selectedSellerId)
    }

    const screenTag = props.screenTag || vehicleShoppingStore.vehicleShoppingData.screenTag || ""
    if (screenTag == "buying") {
      selectedTab.value = tabs.value.indexOf(buyVehicleTitle)
    } else if (screenTag == "marketplace") {
      selectedTab.value = tabs.value.indexOf(sellVehicleTitle)
    } else {
      selectedTab.value = 0
    }
    updateRouteScreenTag()
  })
}

const kill = async () => {
  const name = route.name
  if (name === "overhaul.computer.vehicleShopping" || (typeof name === "string" && name.startsWith("overhaul.computer.vehicleShopping."))) return
  await lua.overhaul_career_market_vehicleShopping.onShoppingMenuClosed()
  vehicleShoppingStore.$dispose()
}

const close = () => {
  // Back on the detail page returns to the list first
  if (closeShopDetail()) return
  lua.extensions.ui_router.back()
}
// B inside the active scope: same as the wrapper's back (detail page first), instead of the scope
// deactivating and parking focus on the shop frame
const shopBack = () => {
  close()
  return false
}

onMounted(start)
onUnmounted(kill)
useRouteReady({
  onReady: () => useScopedNav().activateScope('vehicle-shopping'),
  async waitUntilReady() {
    if (!loaded.value) {
      await new Promise(resolve => {
        const stop = watch(loaded, ready => {
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
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* career status chip add-on: short and faint */
.status-note {
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.88em;
  font-weight: 600;
  b {
    margin-left: 0.2em;
    color: rgba(255, 255, 255, 0.85);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}
.status-money {
  margin-left: 0.2em;
  color: #fde68a;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-icon) {
    display: inline-block;
    margin-right: 0.15em;
    font-size: 0.95em;
    line-height: 1;
    vertical-align: -0.1em;
    color: inherit;
  }
}

/* shell: top-left under the screen heading, tab toggle then the active tab */
.shop {
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  height: 100%;
  min-height: 0;
  max-width: 80rem;
}

.shop-tabs.rls-house {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  color: #fff;
}
.tab-hint {
  flex: 0 0 auto;
}
.shop-tabs .seg.bar {
  width: min(24em, 100%);
  background: rgba(21, 21, 23, 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  button {
    padding: 0.62em 1em 0.46em;
    white-space: nowrap;
  }
}

.buying-tab-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  :deep(.bng-card) {
    --bg-opacity: 0.0;
  }
}

.marketplace-tab-content {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}

.loading-card.rls-house {
  align-self: flex-start;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  padding: 1.1em 1.3em 0.95em;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.92);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  .hint {
    font-size: 0.95em;
  }
}
</style>

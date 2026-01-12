<template>
  <ComputerWrapper
    :path="[vehicleShoppingStore.vehicleShoppingData.currentSellerNiceName || ('Vehicle Marketplace')]"
    :title="headerTitle"
    bng-ui-scope="vehicleShopping"
    v-bng-on-ui-nav:tab_l,tab_r="processTabInput"
    back @back="close"
  >
    <template #status>
      Free Inventory Slots: {{ vehicleShoppingStore ? vehicleShoppingStore.vehicleShoppingData.numberOfFreeSlots : 0 }}
    </template>

    <div class="flex-container">
      <div class="content" v-bng-blur="1"> <!-- content -->
        <Tabs class="bng-tabs" :class="{ 'single-tab': tabs.length === 1 }" :selectedIndex="selectedTab" @change="onTabsChange">
          <TabList />

          <div v-for="tab in tabs" :key="tab" :tab-heading="tab" :class="tab === buyVehicleTitle ? 'buying-tab-content' : 'marketplace-tab-content'">
            <template v-if="tab === buyVehicleTitle">
              <VehicleList v-if="loaded" />
              <BngCard v-else>
                <BngCardHeading style="color: #fff;">Please wait...</BngCardHeading>
              </BngCard>
            </template>
            <VehicleMarketplace v-else />
          </div>
        </Tabs>
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted, onUnmounted, nextTick, computed, watch } from "vue"
import { BngCard, BngCardHeading } from "@/common/components/base"
import { Tabs, Tab, TabList } from "@/common/components/utility"
import { useVehicleShoppingStore } from "../stores/vehicleShoppingStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import VehicleList from "../components/vehicleShopping/VehicleList.vue"
import VehicleMarketplace from "../components/vehicleShopping/VehicleMarketplace.vue"
import { lua } from "@/bridge"
import { useComputerStore } from "../stores/computerStore"
import { vBngOnUiNav } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useRouter } from "vue-router"
import { vBngBlur } from "@/common/directives"

useUINavScope("vehicleShopping")

const buyVehicleTitle = 'Buy Vehicles'
const sellVehicleTitle = 'Sell Vehicles'

const computerStore = useComputerStore()
const vehicleShoppingStore = useVehicleShoppingStore()

const selectedTab = ref(0)
const selectedSellerId = ref("")

const router = useRouter()

const loaded = ref(false)


const tabs = computed(() => {
  let tabs = []
  if (props.buyingAvailable === 'true') {
    tabs.push(buyVehicleTitle)
  }
  if (props.marketplaceAvailable === 'true') {
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

const onTabsChange = (tab, old) => {
  const idx = tabs.value.indexOf((tab && tab.heading) ? tab.heading : "")
  if (idx !== -1) selectedTab.value = idx
  if (selectedTab.value === tabs.value.indexOf(buyVehicleTitle)) {
    selectedSellerId.value = ""
  }
}

const headerTitle = computed(() => {
  switch (tabs.value[selectedTab.value]) {
    case buyVehicleTitle:
      return "Buy Vehicles"
    case sellVehicleTitle:
      return "Sell Vehicles"
    default:
      return "Available Vehicles"
  }
})

const updateRouteScreenTag = () => {
  const isSelling = selectedTab.value === tabs.value.indexOf(sellVehicleTitle)
  const screenTag = isSelling ? "marketplace" : "buying"
  router.replace({
    name: "vehicleShopping",
    params: {
      screenTag,
      buyingAvailable: props.buyingAvailable,
      marketplaceAvailable: props.marketplaceAvailable,
      selectedSellerId: selectedSellerId.value,
    },
  })
}

watch(selectedTab, () => {
  updateRouteScreenTag()
})

const setSelectedSellerId = (sellerId) => {
  selectedSellerId.value = sellerId
  vehicleShoppingStore.setSelectedSellerId(selectedSellerId.value)
}


const start = () => {
  nextTick(async () => {
    await vehicleShoppingStore.requestVehicleShoppingData()
    loaded.value = true
    if (vehicleShoppingStore.vehicleShoppingData.currentSeller) {
      setSelectedSellerId(vehicleShoppingStore.vehicleShoppingData.currentSeller)
    } else {
      setSelectedSellerId(props.selectedSellerId)
    }

    if (props.screenTag == "buying") {
      selectedTab.value = tabs.value.indexOf(buyVehicleTitle)
    } else if (props.screenTag == "marketplace") {
      selectedTab.value = tabs.value.indexOf(sellVehicleTitle)
    } else {
      selectedTab.value = 0
    }
    updateRouteScreenTag()
  })
}

const kill = async () => {
  await lua.career_modules_vehicleShopping.onShoppingMenuClosed()
  vehicleShoppingStore.$dispose()
}

const close = () => {
  if (!vehicleShoppingStore.vehicleShoppingData.currentSeller && selectedTab.value === tabs.value.indexOf(buyVehicleTitle) && selectedSellerId.value) {
    selectedSellerId.value = ""
  } else {
    router.back()
  }
}

onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.active-tab {
  background-color: var(--bng-accents);
  color: white;
}

.flex-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  max-width: 80rem;
}

.tabs {
  flex-shrink: 0;
}

.content {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.content :deep(.bng-tabs) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  --tab-bg: var(--bng-black-o8, 0.5);
  --tab-content-bg: var(--bng-black-o8, 0.5);
  --tab-list-corners: var(--bng-corners-2);
  --tab-content-corners: var(--bng-corners-2);
  .tab-list {
    >* {
      flex: 1 auto;
      max-width: none;
      background-color: rgba(var(--bng-cool-gray-400-rgb), 0.1);
    }
  }
}

.content :deep(.tab-container) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.content :deep(.tab-content) {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
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
  padding: 0.5em;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
}

/* Hide tab list when there's only one tab */
:deep(.single-tab .tab-list) {
  display: none;
}

</style>

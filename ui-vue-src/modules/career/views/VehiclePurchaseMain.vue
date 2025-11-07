<template>
  <!-- TODO - remove inline styling? -->
  <div style="padding: 50px">
    <BngCard v-if="vehiclePurchaseStore.vehicleInfo.niceName" bng-ui-scope="vehiclePurchase" class="purchaseScreen">
      <BngCardHeading type="ribbon" style="text-align: left">Purchase</BngCardHeading>
      <table>
        <tr>
          <th class="article"></th>
          <th class="price">Price</th>
        </tr>
        <tr>
          <td class="article">
            <div v-if="!vehiclePurchaseStore.locationSelectionEnabled" style="font-weight: bold">
              {{ vehiclePurchaseStore.vehicleInfo.sellerName }} ({{ units.buildString("length", vehiclePurchaseStore.vehicleInfo.distance, 0) }})
            </div>
            <div>{{ vehiclePurchaseStore.vehicleInfo.year }} {{ vehiclePurchaseStore.vehicleInfo.niceName }}</div>
            <div>({{ units.buildString("length", vehiclePurchaseStore.vehicleInfo.Mileage, 0) }})</div>
          </td>
          <td class="price">{{ units.beamBucks(vehiclePurchaseStore.vehicleInfo.Value) }}</td>
        </tr>
        <tr>
          <td class="article category">Dealership Fees</td>
          <td class="price category">{{ units.beamBucks(vehiclePurchaseStore.vehicleInfo.fees) }}</td>
        </tr>
        <tr v-if="vehiclePurchaseStore.tradeInVehicleInfo.niceName">
          <td class="article">Trade-in: {{ vehiclePurchaseStore.tradeInVehicleInfo.niceName }}</td>
          <td class="price">{{ units.beamBucks(-vehiclePurchaseStore.tradeInVehicleInfo.Value) }}</td>
        </tr>

        <tr>
          <td class="article category">Insurance Policy</td>
          <td class="price category">
            <BngPopoverMenu name="purchasePolicyPicker">
              <div class="policyPicker">
                <div class="policyItem" v-for="p in purchasePoliciesFiltered" :key="p.id" @click="selectedPolicyId = p.id; hidePurchasePicker()">
                  <div class="pName">{{ p.id === 0 ? 'No Insurance' : p.name }}</div>
                  <div class="pMeta">{{ p.id === 0 ? 'Private repairs only' : units.beamBucks(p.premium) + ' per renewal' }}</div>
                </div>
              </div>
            </BngPopoverMenu>
            <BngButton class="policyBtn" :accent="ACCENTS.menu" v-bng-popover:bottom-start.click="'purchasePolicyPicker'">
              <span class="btnLabel">{{ selectedPolicyName }}</span>
            </BngButton>
          </td>
        </tr>

        <tr>
          <th class="article category">Subtotal</th>
          <th class="price category">
            {{
              units.beamBucks(
                vehiclePurchaseStore.finalPackagePrice -
                  vehiclePurchaseStore.prices.taxes -
                  (vehiclePurchaseStore.buyCustomLicensePlate ? vehiclePurchaseStore.prices.customLicensePlate : 0)
              )
            }}
          </th>
        </tr>

        <tr>
          <td class="article category">Sales Tax (7%)</td>
          <td class="price category">{{ units.beamBucks(vehiclePurchaseStore.prices.taxes) }}</td>
        </tr>

        <tr v-if="selectedPolicyId > 0">
          <td class="article insuranceArticle">{{ selectedPolicyName }} insurance</td>
          <td class="price insuranceArticle">{{ units.beamBucks(selectedPolicyPrice) }}</td>
        </tr>

        <tr v-if="vehiclePurchaseStore.buyCustomLicensePlate">
          <td class="article">Custom License Plate</td>
          <td class="price">{{ units.beamBucks(vehiclePurchaseStore.prices.customLicensePlate) }}</td>
        </tr>

        <tr>
          <th class="article highlightCategory">Total</th>
          <th class="price highlightCategory">{{ units.beamBucks(vehiclePurchaseStore.finalPackagePrice) }}</th>
        </tr>

        <tr v-if="!canAffordPurchase" class="moneyWarning">
          <td class="article highlightCategory">Additional funds required</td>
          <td class="price highlightCategory">
            {{ units.beamBucks(vehiclePurchaseStore.finalPackagePrice - vehiclePurchaseStore.playerMoney) }}
          </td>
        </tr>

        <tr v-if="vehiclePurchaseStore.locationSelectionEnabled">
          <td class="article">
            <div v-if="!vehiclePurchaseStore.ownsRequiredInsurance && !vehiclePurchaseStore.buyRequiredInsurance">
              This vehicle will be delivered to your garage
            </div>
            <div v-else>
              <BngSwitch :disabled="vehiclePurchaseStore.forceNoDelivery" v-model="vehiclePurchaseStore.makeDelivery">
                Deliver this vehicle to your garage?
              </BngSwitch>
            </div>
          </td>
        </tr>

        <tr>
          <td class="article">
            <BngSwitch v-model="vehiclePurchaseStore.buyCustomLicensePlate"> Personalize license plate </BngSwitch>
          </td>
        </tr>
      </table>

      <div style="padding: 1em;" v-if="vehiclePurchaseStore.buyCustomLicensePlate">
        <BngInput style="background-color: rgb(82, 82, 82);" v-model="vehiclePurchaseStore.customLicensePlateText" maxlength="10" floatingLabel="Custom License Plate" :validate="isLicensePlateTextValid" />
      </div>

      <template #buttons>
        <BngButton v-bng-on-ui-nav:back,menu.asMouse @click="cancel" :accent="ACCENTS.attention">Cancel</BngButton>

        <BngButton
          v-if="vehiclePurchaseStore.tradeInEnabled && vehiclePurchaseStore.tradeInVehicleInfo.niceName"
          @click="removeTradeInVehicle"
          :accent="ACCENTS.attention"
          >Remove Trade-In</BngButton
        >


        <BngButton v-if="vehiclePurchaseStore.vehId" @click="startTestDrive" :accent="ACCENTS.secondary" :disabled="vehiclePurchaseStore.alreadyDidTestDrive">Test Drive</BngButton>

        <div v-bng-tooltip:top="tradeInButtonMessage">
          <BngButton :disabled="!vehiclePurchaseStore.tradeInEnabled || !hasVehicle" accent="secondary" @click="chooseTradeInVehicle"
            >Choose Trade-In</BngButton
          >
        </div>

        <BngButton
          :disabled="
            !canAffordPurchase ||
            !vehicleFitsInventory ||
            (vehiclePurchaseStore.forceTradeIn && !vehiclePurchaseStore.tradeInVehicleInfo.niceName) ||
            vehiclePurchaseStore.buyCustomLicensePlate && !licensePlateTextValid
          "
          show-hold
          v-bng-on-ui-nav:ok.asMouse.focusRequired
          v-bng-click="{
            holdCallback: buy,
            holdDelay: 500,
            repeatInterval: 0,
          }">
          <div v-if="!canAffordPurchase">Insufficient Funds</div>
          <div v-else-if="!vehicleFitsInventory">No free inventory slots</div>
          <div v-else>Purchase</div>
        </BngButton>
      </template>
      <CareerStatus class="profileStatus" />
    </BngCard>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from "vue"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngSwitch, BngInput, BngPopoverMenu } from "@/common/components/base"
import { useVehiclePurchaseStore } from "../stores/vehiclePurchaseStore"
import { lua, useBridge } from "@/bridge"
import { vBngClick, vBngTooltip, vBngPopover } from "@/common/directives"
import { CareerStatus } from "@/modules/career/components"
import { vBngOnUiNav } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useInsurancePoliciesStore } from "../stores/insurancePoliciesStore"
import { usePopover } from "@/services/popover"
useUINavScope("vehiclePurchase")

const { units } = useBridge()
const popover = usePopover()

const hasVehicle = ref(false)
const licensePlateTextValid = ref(true)
// Proxy to store so totals stay in sync
const selectedPolicyId = computed({
  get: () => vehiclePurchaseStore.selectedPolicyId,
  set: v => vehiclePurchaseStore.setSelectedPolicyId(v)
})

const vehiclePurchaseStore = useVehiclePurchaseStore()
const insurancePoliciesStore = useInsurancePoliciesStore()

const canAffordPurchase = computed(() => {
  if (vehiclePurchaseStore.cheatsMode) return true
  return vehiclePurchaseStore.finalPackagePrice <= vehiclePurchaseStore.playerMoney
})

const isLicensePlateTextValid = (text) => {
  lua.career_modules_inventory.isLicensePlateValid(text).then(valid => {
    licensePlateTextValid.value = valid
  })
  return licensePlateTextValid.value
}

const selectedPolicy = computed(() => {
  if (!selectedPolicyId.value) return null
  return (insurancePoliciesStore.policiesData || []).find(p => p.id === selectedPolicyId.value) || null
})

const selectedPolicyName = computed(() => selectedPolicy.value ? selectedPolicy.value.name : "No Insurance")
const selectedPolicyPrice = computed(() => selectedPolicy.value ? (selectedPolicy.value.premium || selectedPolicy.value.initialBuyPrice || 0) : 0)

// Only policies applicable to the current vehicle
const purchasePoliciesFiltered = computed(() => {
  const info = vehiclePurchaseStore.vehicleInfo || {}
  const invLike = { Value: info.Value, BodyStyle: info.BodyStyle, aggregates: info.aggregates, role: info.role, population: info.Population }
  // Reuse backend function through minimal proxy call: since we don't have invId here, mirror logic in frontend
  const allow = []
  allow.push(0)
  const isPolice = invLike.role === 'police'
  if (isPolice) allow.push(4)
  const body = invLike.BodyStyle || (invLike.aggregates && invLike.aggregates['Body Style'])
  if (body && (body['Bus'] || body['Van'] || body['Semi Truck'])) allow.push(3)
  if (invLike.Value && invLike.Value > 80000) {
    allow.push(2)
  } else {
    allow.push(1)
  }
  return (insurancePoliciesStore.policiesData || []).filter(p => allow.includes(p.id))
})

const tradeInButtonMessage = computed(() => {
  if (!vehiclePurchaseStore.tradeInEnabled) return "Trade in only possible in person at a dealership"

  return !hasVehicle.value ? "You don't own any vehicles" : undefined
})

const vehicleFitsInventory = computed(() => {
  if (vehiclePurchaseStore.vehicleInfo.takesNoInventorySpace) return true

  return vehiclePurchaseStore.inventoryHasFreeSlot || (vehiclePurchaseStore.tradeInVehicleInfo.niceName && !vehiclePurchaseStore.tradeInVehicleInfo.takesNoInventorySpace)
})

watch(() => vehiclePurchaseStore.vehicleInfo, (info) => {
  if (info && info.requiredInsurance && typeof info.requiredInsurance.id === 'number') {
    selectedPolicyId.value = info.requiredInsurance.id
  } else {
    selectedPolicyId.value = 0
  }
}, { immediate: true })

vehiclePurchaseStore.inventoryIsEmpty().then(empty => {
  hasVehicle.value = !empty
})

const buy = () => buyVehicle(!vehiclePurchaseStore.locationSelectionEnabled || vehiclePurchaseStore.makeDelivery)

const cancel = () => {
  vehiclePurchaseStore.cancel()
}

const startTestDrive = () => {
  vehiclePurchaseStore.startTestDrive()
}

const chooseTradeInVehicle = () => {
  vehiclePurchaseStore.chooseTradeInVehicle()
}

const removeTradeInVehicle = () => {
  vehiclePurchaseStore.removeTradeInVehicle()
}

const buyVehicle = _makeDelivery => {
  vehiclePurchaseStore.buyVehicle(_makeDelivery, selectedPolicyId.value)
}

const togglePurchasePicker = () => popover.toggle("purchasePolicyPicker")
const hidePurchasePicker = () => popover.hide("purchasePolicyPicker")

const start = () => {
  vehiclePurchaseStore.requestPurchaseData()
  insurancePoliciesStore.requestInitialData()
}

const kill = () => {
  vehiclePurchaseStore.$dispose()
}
onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.purchaseScreen {
  width: 700px;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}

.policyPicker { display:flex; flex-direction: column; min-width: 280px; }
.policyItem { padding: 8px 10px; cursor: pointer; }
.policyItem:hover { background: rgba(255,255,255,0.08); }
.policyItem .pName { font-weight: 700; }
.policyItem .pMeta { font-size: 0.9em; color: #ccc; }

.policyBtn { width: 100%; justify-content: flex-end; text-align: right; }
.policyBtn .btnLabel { margin-left: auto; }

.purchaseScreen {
  :deep(.buttons) {
    overflow: visible !important;
  }
}

.highlightCategory {
  padding-top: 5px;
  font-size: 1.3em;
}

.moneyWarning {
  color: rgb(245, 29, 29);
}

.insuranceArticle {
  color: rgb(255, 183, 0);
}

.category {
  padding-top: 20px;
}

.price {
  text-align: right;
  padding-right: 70px;
}

.article {
  text-align: left;
  padding-left: 70px;
}

.profileStatus {
  position: absolute;
  top: 0;
  right: 0;
  color: white;
  border-radius: var(--bng-corners-2);
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}
</style>

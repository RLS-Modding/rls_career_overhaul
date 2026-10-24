<template>
  <LayoutSingle class="purchase-layout" v-bng-scoped-nav="{ scopeId: 'root', activateOnMount: false }">
    <!-- Sizing: em off one resolution-scaled font-size, so the card keeps the same share of the screen at 720p..4K.
         The card is capped to the layout height; the body scrolls and the footer (Test Drive / Purchase) stays put. -->
    <div v-if="vehiclePurchaseStore.vehicleInfo.niceName" class="purchase-shell rls-house rls-house-card">
      <!-- controller: the route's target scope (as in vanilla), entry on the buy button; Start does what the
           Close button's glyph says (Back is the router's purchase-aware cancel) -->
      <BngCard
        bng-ui-scope="vehiclePurchase"
        class="purchase-screen"
        v-bng-scoped-nav="{ scopeId: 'vehicle-purchase', activateOnMount: true, preferAutoFocus: true }"
        v-bng-on-ui-nav:menu="cancel"
        v-bng-blur="1">
        <div class="header-row">
          <BngCardHeading type="ribbon">
            Purchase Information
            <div class="header-seller-info">
              Purchasing from: {{ vehiclePurchaseStore.vehicleInfo.sellerName }}
            </div>
          </BngCardHeading>
          <BngButton class="close-button" @click="cancel" :accent="ACCENTS.attention" bng-no-nav="true" tabindex="-1">
            <BngBinding ui-event="menu" controller  />
            <BngIcon
              type="xmarkBold"
                :color="'var(--bng-cool-gray-100)'"
              />

          </BngButton>
        </div>

        <div class="purchase-body scroll" v-bng-ui-nav-scroll>
          <!-- 1. the car -->
          <section class="panel vehicle-head">
            <div class="vehicle-copy">
              <strong class="vehicle-name">{{ vehiclePurchaseStore.vehicleInfo.year }} {{ vehiclePurchaseStore.vehicleInfo.niceName }}</strong>
              <span class="sub-info">{{ formatMileage(vehiclePurchaseStore.vehicleInfo.Mileage) }}</span>
            </div>
            <div class="price">
              <div class="current-price-line">
                <span v-if="vehiclePurchaseStore.vehicleInfo.originalSellValue" class="old-price">
                  <BngUnit :money="vehiclePurchaseStore.vehicleInfo.originalSellValue" />
                </span>
                <BngUnit class="money vehicle-price" :money="vehiclePurchaseStore.vehicleInfo.valueAdjusted || vehiclePurchaseStore.vehicleInfo.Value" />
              </div>
              <div class="sub-info" v-if="!vehiclePurchaseStore.vehicleInfo.hideMarketValue">
                Est. Market:
                <BngUnit class="money" :money="vehiclePurchaseStore.vehicleInfo.marketValueAdjusted || vehiclePurchaseStore.vehicleInfo.marketValue" />
              </div>
            </div>
          </section>

          <!-- 2. your choices: each row says what it is, what it is set to, and what you can do -->
          <section v-if="!isCarMeetPurchase" class="purchase-options">
            <span class="caption">Purchase options</span>
            <div class="sheet">
              <div class="lines">
                <template v-if="vehiclePurchaseStore.garageDeliveryAllowed && vehiclePurchaseStore.deliveryGarages.length">
                  <div class="line option">
                    <HouseSwitch row :disabled="vehiclePurchaseStore.forceNoDelivery" v-model="vehiclePurchaseStore.makeDelivery">
                      Deliver to an owned garage
                    </HouseSwitch>
                  </div>
                  <div v-if="vehiclePurchaseStore.makeDelivery" class="line option">
                    <span class="opt-label">Garage</span>
                    <HouseMenu
                      class="opt-menu"
                      v-model="vehiclePurchaseStore.selectedGarageId"
                      :items="deliveryGarageOptions"
                      @change="selectDeliveryGarage" />
                  </div>
                </template>

                <div class="line option">
                  <span class="opt-copy">
                    <span class="opt-label">Insurance</span>
                    <span class="opt-value">{{ insuranceName }}</span>
                  </span>
                  <HouseButton compact @click="chooseInsurance">Change</HouseButton>
                </div>

                <div class="line option">
                  <span class="opt-copy">
                    <span class="opt-label">Trade-in</span>
                    <span class="opt-value">{{ vehiclePurchaseStore.tradeInVehicleInfo.niceName || "None" }}</span>
                    <span v-if="tradeInButtonMessage" class="sub-info">{{ tradeInButtonMessage }}</span>
                  </span>
                  <span class="opt-actions">
                    <HouseButton
                      v-if="vehiclePurchaseStore.tradeInEnabled && vehiclePurchaseStore.tradeInVehicleInfo.niceName"
                      compact variant="quiet-danger" @click="removeTradeInVehicle">Remove</HouseButton>
                    <HouseButton compact v-bng-tooltip:top="tradeInButtonMessage"
                      :disabled="!vehiclePurchaseStore.tradeInEnabled || !hasVehicle" @click="chooseTradeInVehicle">
                      {{ vehiclePurchaseStore.tradeInVehicleInfo.niceName ? "Change" : "Choose" }}
                    </HouseButton>
                  </span>
                </div>

                <div class="line option">
                  <span class="opt-copy">
                    <span class="opt-label">Price</span>
                    <span class="opt-value">{{ vehiclePurchaseStore.vehicleInfo.negotiationPossible ? "Open to offers" : "Fixed price" }}</span>
                  </span>
                  <HouseButton compact :disabled="!vehiclePurchaseStore.vehicleInfo.negotiationPossible" @click="negotiatePrice">Negotiate</HouseButton>
                </div>
              </div>
            </div>

            <div v-if="vehiclePurchaseStore.garageDeliveryAllowed && vehiclePurchaseStore.deliveryGarages.length && vehiclePurchaseStore.deliveryQuote?.disabled" class="notice bad">
              {{ vehiclePurchaseStore.deliveryQuote.reason }}
            </div>
            <div v-else-if="vehiclePurchaseStore.garageDeliveryAllowed && vehiclePurchaseStore.deliveryGarages.length && !vehiclePurchaseStore.makeDelivery" class="notice">
              Without delivery, collect it at Freight Pickup. It reserves a garage slot while awaiting collection.
            </div>
            <div v-else-if="vehiclePurchaseStore.garageDeliveryAllowed && !vehiclePurchaseStore.deliveryGarages.length" class="notice bad">
              No owned garage has free capacity for delivery.
            </div>
            <div v-else-if="!vehiclePurchaseStore.garageDeliveryAllowed && (vehiclePurchaseStore.vehicleInfo.salesChannel === 'factory' || vehiclePurchaseStore.vehicleInfo.salesChannel === 'remanufactured')" class="notice">
              Freight pickup is required until this dealer reaches reputation level 2. Orders awaiting collection reserve garage slots.
            </div>
            <div v-if="!vehiclePurchaseStore.racingTeamVehicleShop && !vehicleFitsInventory" class="notice bad">
              No free garage space. Vehicles awaiting freight pickup also reserve garage space. Sell a vehicle or buy or rent more storage.
            </div>
            <div v-if="!vehiclePurchaseStore.freightAvailable && !vehiclePurchaseStore.makeDelivery" class="notice bad">
              {{ vehiclePurchaseStore.freightUnavailableReason }}
            </div>
          </section>

          <!-- 3. what it adds up to -->
          <section class="breakdown">
            <span class="caption">Cost breakdown</span>
            <div class="sheet">
              <div class="lines">
                <div v-if="vehiclePurchaseStore.insuranceOptions.insuranceId > 0" class="line">
                  <span class="label">Insurance</span>
                  <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.insuranceOptions.priceMoney" /></span>
                </div>
                <div class="line">
                  <span class="label">Dealership fees</span>
                  <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.vehicleInfo.fees" /></span>
                </div>
                <div v-if="vehiclePurchaseStore.tradeInVehicleInfo.niceName" class="line credit">
                  <span class="label">Trade-in credit</span>
                  <span class="price"><BngUnit class="money" :money="-vehiclePurchaseStore.tradeInVehicleInfo.Value" /></span>
                </div>
                <div class="line subtotal">
                  <span class="label">Subtotal</span>
                  <span class="price">
                    <BngUnit class="money" :money="vehiclePurchaseStore.finalPackagePrice
                      - vehiclePurchaseStore.prices.taxes
                      - (vehiclePurchaseStore.buyCustomLicensePlate ? vehiclePurchaseStore.prices.customLicensePlate : 0)
                      - (vehiclePurchaseStore.makeDelivery && vehiclePurchaseStore.deliveryQuote && !vehiclePurchaseStore.deliveryQuote.disabled ? vehiclePurchaseStore.deliveryQuote.finalPrice : 0)" />
                  </span>
                </div>
                <div class="line">
                  <span class="label">Sales tax (7%)</span>
                  <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.prices.taxes" /></span>
                </div>
                <div v-if="vehiclePurchaseStore.buyCustomLicensePlate" class="line">
                  <span class="label">Custom license plate</span>
                  <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.prices.customLicensePlate" /></span>
                </div>
                <div v-if="vehiclePurchaseStore.makeDelivery && vehiclePurchaseStore.deliveryQuote && !vehiclePurchaseStore.deliveryQuote.disabled" class="line">
                  <span class="label">
                    Garage delivery
                    <span class="sub-info">
                      {{ formatDistance(vehiclePurchaseStore.deliveryQuote.roadDistance) }},
                      ETA {{ formatEta(vehiclePurchaseStore.deliveryQuote.etaSeconds) }}
                      <span v-if="vehiclePurchaseStore.deliveryQuote.discount > 0">
                        ({{ Math.round(vehiclePurchaseStore.deliveryQuote.discount * 100) }}% loyalty discount)
                      </span>
                    </span>
                  </span>
                  <span class="price">
                    <BngUnit
                      v-if="vehiclePurchaseStore.deliveryQuote.discount > 0"
                      class="old-price"
                      :money="vehiclePurchaseStore.deliveryQuote.fullPrice"
                    />
                    <BngUnit class="money" :money="vehiclePurchaseStore.deliveryQuote.finalPrice" />
                  </span>
                </div>
              </div>
            </div>
          </section>
        </div>

        <template #buttons>
          <!-- 4. the total, right above the button that pays it -->
          <div class="footer-total">
            <div class="total-line">
              <span class="label">Total</span>
              <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.finalPackagePrice" /></span>
            </div>
            <div class="balance-line">
              <span class="label">{{ vehiclePurchaseStore.racingTeamVehicleShop ? "Team account" : "Your cash" }}</span>
              <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.racingTeamVehicleShop ? vehiclePurchaseStore.racingTeamBusinessMoney : vehiclePurchaseStore.playerMoney" /></span>
            </div>
            <div v-if="vehiclePurchaseStore.testDriveDamageFee > 0" class="notice bad test-drive-damage-warning">
              <span class="label"><BngIcon type="danger" /> {{ $translate.instant("ui.career.vehiclePurchase.testDriveDamageWarning") }}</span>
              <span class="price"><BngUnit class="money" :money="vehiclePurchaseStore.testDriveDamageFee" /></span>
            </div>
            <div v-if="vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney" class="notice bad funds-warning">
              <span class="label"><BngIcon type="danger" /> {{ vehiclePurchaseStore.racingTeamVehicleShop ? "Additional team funds required" : "Additional funds required" }}</span>
              <span class="price">
                <BngUnit class="money" :money="(vehiclePurchaseStore.finalPackagePrice - vehiclePurchaseStore.spendableMoney)" />
              </span>
              <HouseButton v-if="!vehiclePurchaseStore.racingTeamVehicleShop" compact @click="financePurchase">Get a loan</HouseButton>
            </div>
          </div>

          <div class="button-group">
            <HouseButton v-if="!isCarMeetPurchase" :disabled="vehiclePurchaseStore.purchaseType !== 'inspect' || vehiclePurchaseStore.alreadyDidTestDrive"
              v-bng-tooltip:top="testDriveButtonMessage"
              @click="startTestDrive">Test Drive</HouseButton>

            <HouseButton
              class="buy-button"
              variant="primary"
              bng-scoped-nav-autofocus
              :disabled="
                vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney ||
                !vehicleFitsInventory ||
                (vehiclePurchaseStore.forceTradeIn && !vehiclePurchaseStore.tradeInVehicleInfo.niceName) ||
                (vehiclePurchaseStore.buyCustomLicensePlate && !licensePlateTextValid) ||
                (vehiclePurchaseStore.makeDelivery && (!vehiclePurchaseStore.selectedGarageId || !vehiclePurchaseStore.deliveryQuote || vehiclePurchaseStore.deliveryQuote.disabled)) ||
                (!vehiclePurchaseStore.makeDelivery && !vehiclePurchaseStore.freightAvailable)
              "
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-bng-click="{
                holdCallback: buy,
                holdDelay: 1000,
                repeatInterval: 0,
              }">
              <template v-if="vehiclePurchaseStore.finalPackagePrice > vehiclePurchaseStore.spendableMoney">{{ vehiclePurchaseStore.racingTeamVehicleShop ? "Insufficient team funds" : "Insufficient Funds" }}</template>
              <template v-else-if="!vehicleFitsInventory">No free inventory slots</template>
              <template v-else><BngBinding ui-event="ok" /> Hold to {{ purchaseActionLabel }}</template>
            </HouseButton>
          </div>
          <p v-if="!isCarMeetPurchase" class="sub-info">{{ testDriveButtonMessage }}</p>
        </template>

      </BngCard>
    </div>
    <div class="right-side">
      <BngCard class="status-container">
        <CareerStatus class="profile-status" />
      </BngCard>
      <TaskList
        class="task-list"
        :header="store.header"
        :tasks="store.tasks" />
    </div>
  </LayoutSingle>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue"
import { useRouteReady } from "@/services/routeReadiness"
import { useScopedNav } from "@/services/scopedNav/api"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngSwitch, BngDropdown, BngInput, BngUnit, BngIcon, BngBinding } from "@/common/components/base"
import { useVehiclePurchaseStore } from "../stores/vehiclePurchaseStore"
import { lua, useBridge } from "@/bridge"
import { bigLengthUnit, formatOdometer } from "../utils/units"
import { vBngClick, vBngTooltip } from "@/common/directives"
import { LayoutSingle } from "@/common/layouts"
import CareerStatus from "../components/careerStatus.vue"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"
import { vBngOnUiNav, vBngBlur, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useTasksStore } from "@/services/tasklistStore"
import TaskList from "@/modules/tasks/components/TaskList.vue"
import { HouseButton, HouseSwitch, HouseMenu } from "../components/house/index.js"
import PurchaseFinancing from '../components/vehicleShopping/PurchaseFinancing.vue'
import { openOverhaulPopup } from '../utils/openOverhaulPopup.js'
import { refocusIfLost } from '../composables/useScreenEntryFocus.js'
useUINavScope("vehiclePurchase")
import useControls from "@/services/controls"
import { storeToRefs } from "pinia"

const Controls = useControls()
const { showIfController } = storeToRefs(Controls)

const { units } = useBridge()

const hasVehicle = ref(false)
const licensePlateTextValid = ref(true)

const vehiclePurchaseStore = useVehiclePurchaseStore()
let financingPopup = null
const financePurchase = async () => {
  if (financingPopup) return
  financingPopup = openOverhaulPopup(PurchaseFinancing, {
    shortfall: Math.ceil(vehiclePurchaseStore.finalPackagePrice - vehiclePurchaseStore.spendableMoney),
  })
  try {
    if (await financingPopup.promise) {
      vehiclePurchaseStore.playerMoney = await lua.overhaul_career_economy_playerAttributes.getAttributeValue('money')
      refocusIfLost(() => document.querySelector('.purchase-screen .buy-button:not([disabled])') || document.querySelector('.purchase-screen button:not([disabled]):not([bng-no-nav="true"])'))
    }
  } finally { financingPopup = null }
}
const store = useTasksStore()

const insuranceName = computed(() => {
  const opts = vehiclePurchaseStore.insuranceOptions || {}
  if (!(opts.insuranceId > 0)) return "None"
  return $translate.instant(opts.name || (opts.spendingReason || "").match(/"(.+)"/)?.[1] || "Insured")
})

const isCarMeetPurchase = computed(() => vehiclePurchaseStore.vehicleInfo.source === "carMeet")
const isOnlinePurchase = computed(() =>
  vehiclePurchaseStore.vehicleInfo.salesChannel === "factory" ||
  vehiclePurchaseStore.vehicleInfo.salesChannel === "remanufactured"
)
const purchaseActionLabel = computed(() => {
  if (vehiclePurchaseStore.racingTeamVehicleShop) return "Purchase for Team"
  if (isOnlinePurchase.value && !vehiclePurchaseStore.makeDelivery) return "Order for Pickup"
  if (isOnlinePurchase.value && vehiclePurchaseStore.makeDelivery) return "Purchase & Deliver"
  return "Purchase"
})
const deliveryGarageOptions = computed(() =>
  vehiclePurchaseStore.deliveryGarages.map(garage => ({
    value: String(garage.id),
    label: `${garage.name} (${garage.freeSlots} free)`
  }))
)

const isLicensePlateTextValid = (text) => {
  lua.overhaul_career_garage_inventory.isLicensePlateValid(text).then(valid => {
    licensePlateTextValid.value = valid
  })
  return licensePlateTextValid.value
}

// odometer in metres, shown in the player's length unit
const formatMileage = mileageMeters => formatOdometer(units, mileageMeters)

const tradeInButtonMessage = computed(() => {
  if (!vehiclePurchaseStore.tradeInEnabled) return "Trade in only possible in person at a dealership"

  return !hasVehicle.value ? "You don't own any vehicles" : undefined
})

const testDriveButtonMessage = computed(() => {
  if (vehiclePurchaseStore.purchaseType !== 'inspect') return "Test drive only available for inspect purchases"
  if (vehiclePurchaseStore.alreadyDidTestDrive) return "You have already done a test drive"
  return "You will be charged 50% of repair costs for any damage caused"
})

const vehicleFitsInventory = computed(() => {
  if (vehiclePurchaseStore.vehicleInfo.takesNoInventorySpace) return true

  return vehiclePurchaseStore.inventoryHasFreeSlot
})

vehiclePurchaseStore.inventoryIsEmpty().then(empty => {
  hasVehicle.value = !empty
})

const buy = () => buyVehicle(vehiclePurchaseStore.makeDelivery)

const cancel = () => {
  lua.extensions.ui_router.back()
}

const startTestDrive = () => {
  vehiclePurchaseStore.startTestDrive()
}

const chooseTradeInVehicle = () => {
  vehiclePurchaseStore.chooseTradeInVehicle()
}

const chooseInsurance = () => {
  lua.overhaul_career_repair_insurance.openChooseInsuranceScreen("purchase", {
    purchaseType: vehiclePurchaseStore.purchaseType,
    shopId: vehiclePurchaseStore.vehicleInfo.shopId,
    insuranceId: vehiclePurchaseStore.insuranceOptions.insuranceId,
  })
}

const negotiatePrice = () => {
  lua.overhaul_career_market_marketplace.startNegotiateSellingOffer(vehiclePurchaseStore.vehicleInfo.shopId)
}

const removeTradeInVehicle = () => {
  vehiclePurchaseStore.removeTradeInVehicle()
}

const buyVehicle = _makeDelivery => {
  vehiclePurchaseStore.buyVehicle(_makeDelivery)
}

const selectDeliveryGarage = async garageId => {
  await vehiclePurchaseStore.requestDeliveryQuote(garageId)
}

// road distance in metres, in the player's length unit (km / mi, one decimal)
const formatDistance = meters => {
  const { perMetre, unit } = bigLengthUnit(units)
  const v = Math.max(0, Number(meters) || 0) * perMetre
  return v < 0.1 ? `<0.1 ${unit}` : formatOdometer(units, meters, 1)
}

const formatEta = seconds => {
  const value = Math.max(0, Math.round(Number(seconds) || 0))
  if (value < 60) return `${value}s`
  return `${Math.ceil(value / 60)} min`
}

const start = () => {
  vehiclePurchaseStore.requestPurchaseData()
}

// Runtime routes target the layout root; activate checkout after the mount acknowledgement.
useRouteReady({
  async waitUntilReady() {
    if (!vehiclePurchaseStore.vehicleInfo.niceName) {
      await new Promise(resolve => {
        const stop = watch(() => vehiclePurchaseStore.vehicleInfo.niceName, name => {
          if (!name) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
  },
  onReady: () => useScopedNav().activateScope('vehicle-purchase'),
})

const kill = async () => {
  financingPopup?.return(false)
  await lua.overhaul_career_market_inspectVehicle.onPurchaseMenuClosed()
  vehiclePurchaseStore.$dispose()
}
onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Layout
.purchase-layout {
  --content-flow: row nowrap;
  --content-max-width: unset;
  --safezone-sides: 1rem;
  --safezone-top: 1rem;
}

/* One resolution-scaled font-size (from .rls-house-card); the shell never grows past the layout height,
   so at 720p the body scrolls and the footer stays on screen. */
.purchase-shell {
  flex: 0 0 auto;
  width: min(38em, 100%);
  min-width: 0;
  max-height: 100%;
  min-height: 0;
  align-self: flex-start;
  display: flex;
}

.purchase-shell > .purchase-screen {
  --bng-card-height: auto;
  --bg-opacity: 0.9;
  --bng-icon-color: currentColor;
  font-size: inherit;
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  max-height: 100%;
  color: #fff;
  border-radius: var(--radius-control);
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  :deep(.card-cnt) {
    flex: 1 1 auto;
    min-height: 0;
    border-radius: var(--radius-control) var(--radius-control) 0 0;
  }

  // Footer: neutral near-black, never the vanilla blue-grey band
  :deep(.footer-container) {
    display: flex;
    flex-direction: column;
    flex: 0 0 auto;
    padding: var(--space-2) var(--inset) var(--inset);
    background-color: rgba(var(--bng-off-black-rgb), var(--bg-opacity, 0.9));
    border-top: 0;
  }
}

.right-side {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  justify-self: flex-end;
}

// Header
.header-row {
  flex: 0 0 auto;
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: flex-start;
  gap: var(--space-3);
  padding-right: var(--inset);

  :deep(.card-heading) {
    flex: 1 1 auto;
    min-width: 0;
    font-size: 1.45em;
    line-height: 1.3;
  }

  .header-seller-info {
    margin-top: 0.1em;
    font-size: 0.55em;
    font-style: normal;
    font-weight: 600;
    color: var(--faint);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

.close-button {
  --bng-button-margin: 0;
  cursor: pointer;
  flex: 0 0 auto;
  height: 2.4em;
  min-width: 4.5em;
  display: flex;
  gap: var(--space-2);
  align-items: center;
  justify-content: center;
  margin-top: var(--space-4) !important;
}

// Scrolling body
.purchase-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  overscroll-behavior: contain;
  padding: 0.1em calc(var(--inset) - 0.5em) var(--inset) var(--inset); // right side leaves room for the stable scrollbar gutter
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}

// Shared label / price columns
.label {
  flex: 1 1 auto;
  min-width: 0;
  text-align: left;
}

.price {
  flex: 0 0 auto;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  min-width: 0;
  color: var(--money);
  font-variant-numeric: tabular-nums;
  :deep(.info-item) {
    padding: 0;
  }
  :deep(.value-label) {
    font-weight: 700;
  }
  .old-price {
    font-size: 0.85em;
    color: var(--faint);
    :deep(.value-label) {
      font-weight: 600;
      text-decoration: line-through;
    }
  }
  .current-price-line {
    display: flex;
    gap: var(--space-2);
    align-items: baseline;
  }
}

.sub-info {
  display: block;
  margin-top: 0.15em;
  font-size: 0.82em;
  font-weight: 600;
  color: var(--faint);
  --bng-icon-color: var(--faint);
  :deep(.value-label) {
    font-weight: 600;
  }
  .money,
  :deep(.money) {
    color: var(--money);
  }
}

// 1. The car
.vehicle-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: var(--space-4);
  .vehicle-copy {
    flex: 1 1 auto;
    min-width: 0;
    display: grid;
    gap: 0.1em;
  }
  .vehicle-name {
    font-size: 1.15em;
    font-weight: 800;
    line-height: 1.2;
  }
  .vehicle-price {
    font-size: 1.15em;
  }
  .price .sub-info {
    text-align: right;
  }
}

// 2 + 3. Captioned sections holding one sheet each
.purchase-options,
.breakdown {
  display: grid;
  gap: var(--space-2);
}

// Option rows: what it is / what it's set to on the left, its action on the right
.line.option {
  align-items: center;
  min-height: 3em;
  padding-top: 0.45em;
  padding-bottom: 0.35em;
}
.opt-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.1em;
}
.opt-label {
  flex: 0 0 auto;
  font-weight: 700;
  line-height: 1.2;
}
.opt-value {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
}
.opt-actions {
  flex: 0 0 auto;
  display: flex;
  gap: var(--space-1);
}
.opt-menu {
  flex: 0 1 17em;
  min-width: 0;

  :deep(.menu-list) {
    position: static;
    width: 100%;
    margin-top: 0.45em;
  }

  :deep(.menu-item) {
    white-space: normal;
    overflow-wrap: anywhere;
  }
}
.line.option > :deep(.house-switch.switch-row) {
  font-weight: 700;
}

.sheet .line:not(.option) {
  align-items: flex-start;
  .label {
    font-weight: 600;
  }
  &.subtotal .label {
    font-weight: 800;
  }
  &.credit .price {
    color: var(--ok-ink);
  }
}

// 4. Total, pinned in the footer right above Purchase
.footer-total {
  display: grid;
  gap: 0.15em;
  margin-bottom: var(--space-3);
}
.total-line,
.balance-line {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: var(--space-4);
  padding: 0 0.15em;
}
.total-line {
  font-size: 1.35em;
  font-weight: 900;
  .price :deep(.value-label) {
    font-weight: 900;
  }
}
.balance-line {
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
}
.funds-warning {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: var(--space-4);
  margin-top: var(--space-2);
  --bng-icon-color: var(--bad);
  .label {
    display: flex;
    align-items: center;
    gap: var(--space-1);
  }
}

// Vanilla buttons left here (header close) are sized in rem; follow the card's em instead
.purchase-shell .bng-button {
  font-size: 1em;
  line-height: 1.5em;
}

// Footer buttons
.button-group {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  width: 100%;
  gap: var(--space-2);
  > * {
    flex: 1 1 0;
    min-width: 0;
  }
  > .buy-button {
    flex-grow: 1.6;
  }
}

// Status sidebar
.status-container {
  color: white;
  align-self: flex-end;
  flex: 0 0 auto;
  .status-add {
    text-align: center;
    padding: 0.25rem 0.5rem;
  }
}

.profile-status {
  background-color: rgba(0, 0, 0, 0.7);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }
}

.task-list {
  width: 33rem;
  align-self: flex-end;
}
</style>

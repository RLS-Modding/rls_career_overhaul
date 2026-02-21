<template>
  <BngCard :class="'vehicle-card row'">
    <div class="cover-container">
      <AspectRatio class="cover" :ratio="'16:9'" :external-image="vehicle.preview"> </AspectRatio>
      <div v-if="vehicle.soldViewCounter > 0" class="sold-overlay">SOLD</div>
    </div>
    <div class="car-details">
      <div class="car-value">
        <div class="car-name" :class="{ 'sold': vehicle.soldViewCounter > 0 }">
          <h3 class="name">{{ vehicle.year }} {{ vehicle.Name }}  {{ vehicle.soldViewCounter > 0 ? ' (Sold)' : '' }}</h3>
          <div class="brand">{{ vehicle.Brand }}</div>
        </div>
        <div class="main-data">
          <BngPropVal
            class="prop-small"
            :iconColor="'var(--bng-cool-gray-300)'"
            :iconType="icons.bus"
            :valueLabel="units.buildString('length', vehicle.Mileage, 0)" />
          <BngPropVal
            class="prop-small"
            style="flex: 1 0 auto"
            :iconColor="'var(--bng-cool-gray-300)'"
            :iconType="icons.bus"
            :valueLabel="vehicle.Drivetrain" />
          <div v-if="vehicle.soldFor" class="price">
            <div class="was">Was: <BngUnit :money="adjustedValue" /></div>
            <div class="sold">Sold for: <BngUnit class="car-price" :money="vehicle.soldFor" /></div>
            <div class="delta" :class="soldDeltaClass">{{ soldDeltaPrefix }}{{ soldPercent.toFixed(1) }}% from asking</div>
              <div v-if="vehicle.marketValue" class="market">Market: <BngUnit :money="vehicle.marketValueAdjusted || vehicle.marketValue" /></div>
          </div>
          <div v-else class="price">
            <div v-if="!hasInsufficientFunds"><BngUnit class="car-price" :money="adjustedValue" />*</div>
            <div v-else style="color: rgb(245, 29, 29)"><BngUnit class="car-price" :money="adjustedValue" />* Insufficient Funds</div>
              <div v-if="vehicle.marketValue" class="market">Market: <BngUnit :money="vehicle.marketValueAdjusted || vehicle.marketValue" /></div>
            </div>
          </div>
      </div>
      <div class="car-data">
        <BngPropVal v-if="vehicle.Power != undefined" :iconType="icons.powerGauge04" :keyLabel="'Power:'" :valueLabel="units.buildString('power', vehicle.Power, 0)" />
        <BngPropVal v-if="vehicle.Mileage != undefined" :iconType="icons.odometer" :keyLabel="'Mileage:'" :valueLabel="units.buildString('length', vehicle.Mileage, 0)" />
        <BngPropVal v-if="vehicle.Transmission != undefined" :iconType="getAttributeIcon(vehicle, 'Transmission')" :keyLabel="'Transmission:'" :valueLabel="vehicle.Transmission" />
        <BngPropVal v-if="vehicle['Fuel Type'] != undefined" :iconType="getAttributeIcon(vehicle, 'Fuel Type')" :keyLabel="'Fuel type:'" :valueLabel="vehicle['Fuel Type']" />
        <BngPropVal v-if="vehicle.Drivetrain != undefined" :iconType="getAttributeIcon(vehicle, 'Drivetrain')" :keyLabel="'Drivetrain:'" :valueLabel="vehicle.Drivetrain" />
        <BngPropVal v-if="vehicle.Weight != undefined" :iconType="icons.weight" :keyLabel="'Weight:'" :valueLabel="units.buildString('weight', vehicle.Weight, 0)" />
      </div>
    </div>
    <template #buttons>
      <div style="width: 100%">
        <BngPropVal style="float: left" v-if="!vehicleShoppingData.currentSeller" :keyLabel="'Seller:'" :valueLabel="vehicle.sellerName" />
        <BngPropVal
          style="float: left"
          v-if="!vehicleShoppingData.currentSeller"
          :keyLabel="'Distance:'"
          :valueLabel="units.buildString('length', vehicle.distance, 1)" />
        <BngPropVal style="float: left" :keyLabel="'Insurance Class:'" :valueLabel="vehicle.insuranceClass?.name ?? 'Unknown'" />
      </div>

      <span
        style="flex: 1 0 auto; justify-content: flex-end; padding: 0.5em 0.75em; font-weight: 400; font-family: var(--fnt-defs)"
        v-if="vehicleShoppingData.disableShopping"
        >{{ vehicleShoppingData.disableShoppingReason }}</span
      >

      <BngButton
        v-if="vehicle.sellerId === vehicleShoppingData.currentSeller"
        @click="showVehicle(vehicle.shopId)"
        :accent="ACCENTS.secondary"
        :disabled="vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
        >Inspect Vehicle</BngButton
      >
      <BngButton v-else
        @click="showVehicle(vehicle.shopId)"
        :accent="ACCENTS.secondary"
        :disabled="vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
        >Set Route</BngButton
      >

      <BngButton
        v-if="!vehicleShoppingData.currentSeller"
        :disabled="vehicleShoppingData.playerAttributes.money.value < vehicle.quickTravelPrice || vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
        @click="confirmTaxi(vehicle)"
        :accent="vehicle.sellerId === 'private' ? ACCENTS.main : ACCENTS.secondary"
        ><span style="flex: 1 0 auto">Take Taxi</span></BngButton
      >

      <BngButton
        v-if="vehicle.sellerId !== 'private'"
        :disabled="vehicleShoppingData.tutorialPurchase || vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
        @click="openPurchaseMenu('instant', vehicle.shopId)"
        >Purchase</BngButton
      >
    </template>
  </BngCard>
</template>

<script>
import { icons } from "@/common/components/base"

const DRIVE_TRAIN_ICONS = {
  AWD: icons.AWD,
  "4WD": icons["4WD"],
  FWD: icons.FWD,
  RWD: icons.RWD,
  drivetrain_special: icons.drivetrainSpecial,
  drivetrain_generic: icons.drivetrainGeneric,
  defaultMissing: icons.drivetrainGeneric,
  defaultUnknown: icons.drivetrainGeneric,
}

const FUEL_TYPE_ICONS = {
  Battery: icons.charge,
  Gasoline: icons.fuelPump,
  Diesel: icons.fuelPump,
  defaultMissing: icons.fuelPump,
  defaultUnknown: icons.fuelPump,
}

const TRANSMISSION_ICONS = {
  Automatic: icons.transmissionA,
  Manual: icons.transmissionM,
  defaultMissing: icons.transmissionM,
  defaultUnknown: icons.transmissionM,
}
</script>

<script setup>
import { computed } from "vue"
import { lua, useBridge } from "@/bridge"
import { BngCard, BngButton, ACCENTS, BngPropVal, BngUnit } from "@/common/components/base"
import { AspectRatio } from "@/common/components/utility"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"

const { units } = useBridge()

const props = defineProps({
  vehicleShoppingData: Object,
  vehicle: Object,
})

const adjustedValue = computed(() => props.vehicle?.valueAdjusted || props.vehicle?.Value || 0)

const hasInsufficientFunds = computed(() => {
  if (props.vehicleShoppingData.cheatsMode) return false
  return adjustedValue.value > props.vehicleShoppingData.playerAttributes.money.value
})

const soldPercent = computed(() => {
  const asking = adjustedValue.value
  const sold = props.vehicle?.soldFor
  if (!asking || !sold) return 0
  return ((sold - asking) / asking) * 100
})

const soldDeltaPrefix = computed(() => (soldPercent.value >= 0 ? "+" : ""))
const soldDeltaClass = computed(() => (soldPercent.value > 0 ? "up" : soldPercent.value < 0 ? "down" : "flat"))

const confirmTaxi = async vehicle => {
  const res = await openConfirmation("", `Do you want to taxi to this vehicle for ${units.beamBucks(vehicle.quickTravelPrice)}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) quickTravelToVehicle(vehicle)
}

const showVehicle = shopId => {
  lua.career_modules_vehicleShopping.showVehicle(shopId)
}

const quickTravelToVehicle = vehicle => {
  lua.career_modules_vehicleShopping.quickTravelToVehicle(vehicle.shopId)
}

const openPurchaseMenu = (purchaseType, shopId) => {
  lua.career_modules_vehicleShopping.openPurchaseMenu(purchaseType, shopId)
}

const getAttributeIcon = (vehicle, attribute) => {
  let iconDict
  if (attribute == "Drivetrain") {
    iconDict = DRIVE_TRAIN_ICONS
  } else if (attribute == "Fuel Type") {
    iconDict = FUEL_TYPE_ICONS
  } else if (attribute == "Transmission") {
    iconDict = TRANSMISSION_ICONS
  }

  if (!vehicle[attribute]) return iconDict.defaultMissing

  let icon = iconDict[vehicle[attribute]]
  return icon || iconDict.defaultUnknown
}
</script>

<style scoped lang="scss">
.vehicle-card {
  //margin: 0.75rem 0.5rem;
  min-width: 16rem;
  max-width: 28rem;
  flex: 1 0.25 18rem;
  background-color: var(--bng-black-8);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0);
  }
  & :deep(.card-cnt) {
    flex-flow: row wrap;
  }
  :deep(.footer-container) {
    background-color: rgba(var(--bng-ter-blue-gray-800-rgb), 0.4);
  }
  & .cover-container {
    width: 20em !important;
    min-width: 20em !important;
    position: relative;
  }
  & .cover {
    width: 100%;
  }
  .sold-overlay {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%) rotate(-30deg);
    background-color: rgba(245, 29, 29, 0.8);
    color: white;
    padding: 1rem 3rem;
    font-size: 2rem;
    font-weight: bold;
    text-transform: uppercase;
    border: 3px solid white;
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);
  }
  .car-details {
    display: flex;
    flex-flow: column nowrap;
    flex: 1 1 auto;
    .car-value {
      padding: 0.5em;
      font-family: "Overpass", var(--fnt-defs);
      display: flex;
      flex-flow: column nowrap;
      .car-name {
        padding-bottom: 0.5rem;
        min-height: 5.5rem;
        &.sold {
          color: rgb(245, 29, 29);
        }
        .name {
          font-weight: 800;
          font-style: italic;
          margin: 0.25em 0 0 0;
        }
        .brand {
          font-weight: 600;
          color: var(--bng-cool-gray-100);
        }
      }
      .main-data {
        display: flex;
        flex-flow: row wrap;
        justify-content: flex-end;
        align-items: center;
        & > .prop-small {
          font-size: 0.8rem;
          padding-left: 1.75em;
          padding-top: 0.25em;
          padding-bottom: 0.25em;
          color: var(--bng-cool-gray-300);
          flex: 0 0 auto;
          & > :deep(.value-label) {
            font-weight: 400;
          }
          & > :deep(.icon) {
            // width: 1em;
            // height: 1em;
            top: 0.2em;
            left: 0.125em;
          }
        }
      }
      .car-price {
        font-size: 1rem;
        // border: 0.0625rem solid rgba(white, 0.25);
        border-radius: var(--bng-corners-1);
        padding-top: 0.25em;
        padding-bottom: 0.25em;
        align-self: flex-end;
        flex: 0 0 auto;
        & > :deep(.icon) {
          top: 0.25em;
        }
      }
      .price {
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: 0.1rem;
        text-align: right;
        .was {
          color: var(--bng-cool-gray-300);
          text-decoration: line-through;
          opacity: 0.8;
          font-size: 0.9rem;
        }
        .sold {
          font-weight: 800;
        }
        .delta {
          font-weight: 600;
          font-size: 0.9rem;
        }
        .delta.up { color: var(--bng-add-green-400); }
        .delta.down { color: var(--bng-add-red-400); }
        .delta.flat { color: var(--bng-off-white); opacity: 0.8; }
        .market {
          color: var(--bng-cool-gray-200);
          font-size: 0.9rem;
        }
      }
    }
    .car-data {
      display: none;
      flex-flow: row wrap;
      & > * {
        max-width: 15em;
        flex: 1 0 15em;
      }
    }
  }

  .taxi-price {
    position: relative;
    font-size: 0.8rem;
    line-height: 1.25em;
    padding-top: 0.125em;
    padding-bottom: 0.125em;
    padding-left: 1.5em;
    padding-right: 0.5em;
    margin-left: 0.5em;
    border: 0.0625rem solid rgba(white, 0.25);
    border-radius: var(--bng-corners-1);
    & > :deep(.icon) {
      // width: 1em;
      // height: 1em;
      top: 0em;
      left: 0.125em;
    }
  }

  .buttons > .bng-button {
    font-family: var(--fnt-defs);
  }

  &.row {
    max-width: calc(100%);
    flex: 1 0 100%;

    .prop-small {
      display: none;
    }
    .cover {
      flex: 0 0 22rem;
    }

    @media screen and (max-width: 719px) {
      & .cover {
        flex: 1 1 100%;
      }
    }

    @media screen and (max-width: 900px) {
      .car-details > .car-value {
        flex-flow: row wrap !important;
      }
    }

    @media screen and (min-width: 720px) {
      :deep(.card-cnt) {
        flex-flow: row nowrap;
      }
      .car-details {
        padding-left: 1rem;
        .car-name {
          .name {
            font-size: 1.5rem;
            min-width: 15rem;
          }
        }
      }
    }

    :deep(.card-cnt) {
      align-items: flex-start;
    }
    .car-details {
      flex: 1 1 auto;
      min-width: 18rem;
      // padding-bottom: 1rem;
      .car-value {
        flex-flow: row nowrap;
        align-items: flex-start;
        .car-name {
          flex: 1 1 auto;
          padding-right: 0.5rem;
        }
        .car-price {
          font-size: 1.25rem;
          align-self: auto;
          flex: 0 0 auto;
        }
      }
      .car-data {
        display: flex;
        padding-bottom: 0.75rem;
      }
    }
  }
}
</style>

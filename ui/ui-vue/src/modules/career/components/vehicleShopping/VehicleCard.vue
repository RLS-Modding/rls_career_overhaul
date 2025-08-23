<template>
  <BngCard class="vehicle-card">
    <div class="vehicle-content">
      <!-- Vehicle Image -->
      <div class="vehicle-image">
        <div class="image-container" :style="vehicle.preview ? { backgroundImage: `url('${vehicle.preview}')` } : {}">
          <div v-if="!vehicle.preview" class="image-placeholder">
            <BngIcon :type="icons.car" class="placeholder-icon" />
          </div>
        </div>
        <div v-if="vehicle.soldViewCounter > 0" class="sold-overlay">SOLD</div>
      </div>

      <!-- Vehicle Details -->
      <div class="vehicle-details">
        <div class="vehicle-header">
          <div class="vehicle-title">
            <h3 class="vehicle-name" :class="{ 'sold': vehicle.soldViewCounter > 0 }">
              {{ vehicle.year }} {{ vehicle.Name }} {{ vehicle.model || vehicle.Brand }}
            </h3>
            <p class="vehicle-brand">{{ vehicle.Brand }}</p>
          </div>
          <div class="vehicle-price">
            <div class="price-amount" :class="{ 'insufficient': hasInsufficientFunds }">
              <BngUnit :money="vehicle.Value" />
            </div>
            <div v-if="hasInsufficientFunds" class="insufficient-text">Insufficient Funds</div>
          </div>
        </div>

        <!-- Vehicle Specs Grid -->
        <div class="vehicle-specs">
          <div v-if="vehicle.Power" class="spec-item">
            <BngIcon :type="icons.gauge" class="spec-icon" />
            <span class="spec-label">Power:</span>
            <span class="spec-value">{{ units.buildString('power', vehicle.Power, 0) }}</span>
          </div>
          <div v-if="vehicle.Mileage !== undefined" class="spec-item">
            <BngIcon :type="icons.gauge" class="spec-icon" />
            <span class="spec-label">Mileage:</span>
            <span class="spec-value">{{ formatMileage(vehicle.Mileage) }}</span>
          </div>
          <div v-if="vehicle.Transmission" class="spec-item">
            <BngIcon :type="getAttributeIcon(vehicle, 'Transmission')" class="spec-icon" />
            <span class="spec-label">Transmission:</span>
            <span class="spec-value">{{ vehicle.Transmission }}</span>
          </div>
          <div v-if="vehicle['Fuel Type']" class="spec-item">
            <BngIcon :type="getAttributeIcon(vehicle, 'Fuel Type')" class="spec-icon" />
            <span class="spec-label">Fuel type:</span>
            <span class="spec-value">{{ vehicle['Fuel Type'] }}</span>
          </div>
          <div v-if="vehicle.Drivetrain" class="spec-item">
            <BngIcon :type="getAttributeIcon(vehicle, 'Drivetrain')" class="spec-icon" />
            <span class="spec-label">Drivetrain:</span>
            <span class="spec-value">{{ vehicle.Drivetrain }}</span>
          </div>
          <div v-if="vehicle.Weight" class="spec-item">
            <BngIcon :type="icons.gauge" class="spec-icon" />
            <span class="spec-label">Weight:</span>
            <span class="spec-value">{{ units.buildString('weight', vehicle.Weight, 0) }}</span>
          </div>
        </div>

        <!-- Seller Info -->
        <div class="seller-info">
          <div class="seller-details">
            <span v-if="!vehicleShoppingData.currentSeller" class="seller-label">
              Seller: <span class="seller-name">{{ vehicle.sellerName }}</span>
            </span>
            <span v-if="!vehicleShoppingData.currentSeller" class="distance">
              Distance: <span class="distance-value">{{ units.buildString('length', vehicle.distance, 1) }}</span>
            </span>
            <span class="insurance">
              Required Insurance: <span class="insurance-value">{{ vehicle.requiredInsurance?.name }}</span>
            </span>
          </div>
        </div>

        <!-- Action Buttons -->
        <div class="vehicle-actions">
          <div v-if="vehicleShoppingData.disableShopping" class="disabled-message">
            {{ vehicleShoppingData.disableShoppingReason }}
          </div>
          
          <div v-else class="action-buttons">
            <!-- Route/Inspect Button -->
            <BngButton
              :accent="ACCENTS.menu"
              size="sm"
              @click="showVehicle(vehicle.shopId)"
              :disabled="vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
              class="action-btn"
            >
              {{ vehicle.sellerId === vehicleShoppingData.currentSeller ? 'Inspect Vehicle' : 'Set Route' }}
            </BngButton>

            <!-- Taxi Button -->
            <BngButton
              v-if="!vehicleShoppingData.currentSeller"
              :accent="ACCENTS.menu"
              size="sm"
              :disabled="hasInsufficientTaxiFunds || vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
              @click="confirmTaxi(vehicle)"
              class="action-btn"
            >
              Take Taxi
              <span v-if="vehicle.quickTravelPrice" class="taxi-price">
                ({{ units.beamBucks(vehicle.quickTravelPrice) }})
              </span>
            </BngButton>

            <!-- Purchase Button -->
            <BngButton
              v-if="vehicle.sellerId !== 'private'"
              :accent="ACCENTS.main"
              size="sm"
              :disabled="hasInsufficientFunds || vehicleShoppingData.tutorialPurchase || vehicleShoppingData.disableShopping || Boolean(vehicle.soldViewCounter)"
              @click="openPurchaseMenu('instant', vehicle.shopId)"
              class="purchase-btn"
            >
              Purchase
            </BngButton>
          </div>
        </div>
      </div>
    </div>
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
import { BngCard, BngButton, ACCENTS, BngIcon, BngUnit, icons } from "@/common/components/base"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services/translation"

const { units } = useBridge()

const props = defineProps({
  vehicleShoppingData: Object,
  vehicle: Object,
})

const hasInsufficientFunds = computed(() => {
  return props.vehicle.Value > props.vehicleShoppingData.playerAttributes.money.value
})

const hasInsufficientTaxiFunds = computed(() => {
  return props.vehicleShoppingData.playerAttributes.money.value < props.vehicle.quickTravelPrice
})

const formatMileage = (mileage) => {
  if (mileage === 0) return "New"
  return units.buildString('length', mileage, 0)
}

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
  background: var(--bng-cool-gray-900);
  border: 1px solid var(--bng-cool-gray-600);
  border-radius: var(--bng-corners-2);
  transition: all 0.3s ease;
  overflow: hidden;

  &:hover {
    border-color: var(--bng-orange-alpha-30);
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }

  .vehicle-content {
    display: flex;
    gap: 1rem;
    padding: 0.75rem;
    min-height: 11rem;
  }

  .vehicle-image {
    position: relative;
    width: 18rem;
    height: 11rem;
    min-height: 11rem;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    
    .image-container {
      width: 100%;
      height: 100%;
      border-radius: var(--bng-corners-1);
      overflow: hidden;
      background: var(--bng-cool-gray-800);
      background-repeat: no-repeat;
      background-position: center center;
      background-size: cover;
      border: 1px solid var(--bng-cool-gray-700);
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.02);
      display: flex;
      align-items: center;
      justify-content: center;

      /* Ensure no nested image overlays the background */
      .vehicle-img { display: none; }
    }

    .image-placeholder {
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      background: var(--bng-cool-gray-800);

      .placeholder-icon {
        width: 4rem;
        height: 4rem;
        color: var(--bng-cool-gray-500);
      }
    }

    .sold-overlay {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%) rotate(-15deg);
      background: rgba(239, 68, 68, 0.9);
      color: white;
      padding: 0.5rem 1.5rem;
      font-size: 1.25rem;
      font-weight: bold;
      text-transform: uppercase;
      border: 2px solid white;
      border-radius: var(--bng-corners-1);
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
      z-index: 10;
    }

    
  }

  .vehicle-details {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 0.5rem 0.75rem 0.75rem 0;
    min-width: 0;
  }

  .vehicle-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 0.75rem;

    .vehicle-title {
      flex: 1;
      min-width: 0;

      .vehicle-name {
        font-size: 1.125rem;
        font-weight: 500;
        color: var(--bng-off-white);
        margin: 0 0 0.25rem 0;
        line-height: 1.3;

        &.sold {
          color: rgb(239, 68, 68);
        }
      }

      .vehicle-brand {
        font-size: 0.875rem;
        color: var(--bng-cool-gray-300);
        margin: 0;
      }
    }

    .vehicle-price {
      text-align: right;
      flex-shrink: 0;

      .price-amount {
        font-size: 1.4rem;
        font-weight: 700;
        color: var(--bng-orange);
        margin-bottom: 0.25rem;

        &.insufficient {
          color: #dc2626;
        }
      }

      .insufficient-text {
        font-size: 0.75rem;
        color: #dc2626;
        font-weight: 600;
        text-transform: uppercase;
      }
    }
  }

  .vehicle-specs {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 0.5rem;
    margin-bottom: 1rem;

    .spec-item {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      font-size: 0.875rem;
      color: var(--bng-cool-gray-300);

      .spec-icon {
        width: 1rem;
        height: 1rem;
        color: var(--bng-cool-gray-400);
        flex-shrink: 0;
      }

      .spec-label {
        color: var(--bng-cool-gray-400);
        flex-shrink: 0;
      }

      .spec-value {
        color: var(--bng-off-white);
        font-weight: 500;
      }
    }
  }

  .seller-info {
    margin-bottom: 0.75rem;
    padding: 0.5rem 0.75rem;
    background: var(--bng-cool-gray-875);
    border-radius: var(--bng-corners-1);
    border: 1px solid var(--bng-cool-gray-700);

    .seller-details {
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
      font-size: 0.875rem;
      color: var(--bng-cool-gray-300);

      span {
        display: flex;
        align-items: center;
        gap: 0.25rem;
      }

      .seller-name,
      .distance-value,
      .insurance-value {
        color: var(--bng-off-white);
        font-weight: 500;
      }
    }
  }

  .vehicle-actions {
    margin-top: auto;

    .disabled-message {
      text-align: center;
      color: var(--bng-cool-gray-400);
      font-style: italic;
      padding: 0.75rem;
    }

    .action-buttons {
      display: flex;
      gap: 0.5rem;
      align-items: center;

      .action-btn {
        flex: 1;
        border: 1px solid var(--bng-cool-gray-600);
        
        &:hover {
          background: var(--bng-orange-alpha-20);
          border-color: var(--bng-orange-alpha-50);
        }
      }

      .purchase-btn {
        flex: 1;
        background: var(--bng-orange);
        color: var(--bng-off-black);
        border: 1px solid var(--bng-orange);

        &:hover {
          background: var(--bng-orange-dark);
        }

        &:disabled {
          background: var(--bng-cool-gray-700);
          color: var(--bng-cool-gray-400);
          border-color: var(--bng-cool-gray-600);
        }
      }

      .taxi-price {
        font-size: 0.75rem;
        color: var(--bng-cool-gray-300);
        margin-left: 0.25rem;
      }
    }
  }
}

// Responsive adjustments
@media (max-width: 900px) {
  .vehicle-card .vehicle-content {
    flex-direction: column;
  }

  .vehicle-card .vehicle-image {
    width: 100%;
    height: 12rem;
  }

  .vehicle-card .vehicle-details {
    padding: 1rem;
  }
}
</style>

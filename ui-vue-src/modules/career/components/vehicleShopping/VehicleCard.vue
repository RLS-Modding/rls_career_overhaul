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
        <div v-if="vehicle.__sold || vehicle.soldViewCounter > 0" class="sold-overlay">SOLD</div>
      </div>

      <!-- Vehicle Details -->
      <div class="vehicle-details">
        <div class="vehicle-header">
          <div class="vehicle-title">
            <h3 class="vehicle-name" :class="{ 'sold': vehicle.__sold || vehicle.soldViewCounter > 0 }">
              {{ vehicle.year }} {{ vehicle.Name }} {{ vehicle.model || vehicle.Brand }}
            </h3>
            <p class="vehicle-brand">{{ vehicle.Brand }}</p>
          </div>
          <div class="vehicle-price">
            <div class="price-amount" :class="{ 'insufficient': hasInsufficientFunds, 'sold': vehicle.__sold || vehicle.soldViewCounter > 0 }">
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
              @click="vehicle.sellerId === vehicleShoppingData.currentSeller ? showVehicle(getVehicleId()) : navigateToPos(vehicle.pos, getVehicleId())"
              :disabled="vehicleShoppingData.disableShopping || Boolean(vehicle.__sold || vehicle.soldViewCounter)"
              class="action-btn"
            >
              {{ vehicle.sellerId === vehicleShoppingData.currentSeller ? 'Inspect Vehicle' : 'Set Route' }}
            </BngButton>

            <!-- Taxi Button -->
            <BngButton
              v-if="!vehicleShoppingData.currentSeller"
              :accent="ACCENTS.menu"
              size="sm"
              :disabled="hasInsufficientTaxiFunds || vehicleShoppingData.disableShopping || Boolean(vehicle.__sold || vehicle.soldViewCounter)"
              @click="confirmTaxi(getVehicleId(), vehicle)"
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
              :disabled="hasInsufficientFunds || vehicleShoppingData.tutorialPurchase || vehicleShoppingData.disableShopping || Boolean(vehicle.__sold || vehicle.soldViewCounter)"
              @click="openPurchaseMenu('instant', getVehicleId())"
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

const confirmTaxi = async (vehicleId, vehicle) => {
  console.log('confirmTaxi called with vehicleId:', vehicleId, 'vehicle:', vehicle)
  if (!vehicleId) {
    console.error('confirmTaxi: vehicleId is null or undefined!')
    return
  }
  const res = await openConfirmation("", `Do you want to taxi to this vehicle for ${units.beamBucks(vehicle.quickTravelPrice)}?`, [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { accent: ACCENTS.secondary } },
  ])
  if (res) {
    console.log('User confirmed taxi, calling quickTravelToVehicle with vehicleId:', vehicleId)
    quickTravelToVehicle(vehicleId)
  }
}

const showVehicle = vehicleId => {
  lua.career_modules_vehicleShopping.showVehicle(vehicleId)
}

const navigateToPos = (pos, vehicleId) => {
  lua.career_modules_vehicleShopping.navigateToPos(pos, vehicleId)
}

const quickTravelToVehicle = vehicleId => {
  lua.career_modules_vehicleShopping.quickTravelToVehicle(vehicleId)
}

const getVehicleId = () => {
  // Try multiple ways to get the vehicle ID
  const uid = props.vehicle.uid || props.vehicle.shopId || props.vehicle.id
  console.log('VehicleCard: getVehicleId called, uid:', uid, 'vehicle:', props.vehicle)
  if (!uid) {
    console.error('VehicleCard: Unable to get vehicle ID from vehicle object:', props.vehicle)
  }
  return uid || null
}

const openPurchaseMenu = (purchaseType, vehicleId) => {
  console.log('Vue openPurchaseMenu called with purchaseType:', purchaseType, 'vehicleId:', vehicleId)
  lua.career_modules_vehicleShopping.openPurchaseMenu(purchaseType, vehicleId)
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
  background: linear-gradient(135deg, var(--bng-cool-gray-850) 0%, var(--bng-cool-gray-900) 100%);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: 0.75rem;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  overflow: hidden;
  position: relative;

  &::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 1px;
    background: linear-gradient(90deg, 
      transparent 0%, 
      var(--bng-cool-gray-600) 50%, 
      transparent 100%);
    opacity: 0.5;
  }

  &:hover {
    border-color: var(--bng-orange-b400);
    transform: translateY(-3px);
    box-shadow: 
      0 10px 25px rgba(0,0,0,0.4),
      0 0 40px rgba(var(--bng-orange-rgb), 0.1);
    
    &::before {
      background: linear-gradient(90deg, 
        transparent 0%, 
        var(--bng-orange-b400) 50%, 
        transparent 100%);
      opacity: 0.8;
    }
  }

  .vehicle-content {
    display: flex;
    gap: 0;
    padding: 0;
    min-height: 11rem;
    height: auto;
  }

  .vehicle-image {
    position: relative;
    width: 24rem;
    min-height: 11rem;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    align-self: stretch;
    
    .image-container {
      width: 100%;
      height: 100%;
      border-radius: 0.75rem 0 0 0.75rem;
      overflow: hidden;
      background: linear-gradient(135deg, var(--bng-cool-gray-800) 0%, var(--bng-cool-gray-850) 100%);
      background-repeat: no-repeat;
      background-position: center center;
      background-size: cover;
      border-right: 1px solid var(--bng-cool-gray-750);
      box-shadow: inset 0 1px 2px rgba(0,0,0,0.3);
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;

      &::after {
        content: '';
        position: absolute;
        inset: 0;
        background: radial-gradient(ellipse at center, transparent 50%, rgba(0,0,0,0.15) 100%);
        pointer-events: none;
      }

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
      transform: translate(-50%, -50%) rotate(-12deg);
      background: linear-gradient(135deg, #ef4444, #dc2626);
      color: white;
      padding: 0.625rem 2rem;
      font-size: 1.5rem;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      border: 3px solid white;
      border-radius: 0.375rem;
      box-shadow: 
        0 8px 20px rgba(0, 0, 0, 0.6),
        0 0 0 1px rgba(0, 0, 0, 0.2);
      z-index: 10;
      animation: soldPulse 2s ease-in-out infinite;
    }

    @keyframes soldPulse {
      0%, 100% { transform: translate(-50%, -50%) rotate(-12deg) scale(1); }
      50% { transform: translate(-50%, -50%) rotate(-12deg) scale(1.05); }
    }
  }

  .vehicle-details {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 0.75rem 1rem;
    min-width: 0;
    height: 100%;
    overflow: hidden;
  }

  .vehicle-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 0.5rem;
    padding-bottom: 0.5rem;
    border-bottom: 1px solid var(--bng-cool-gray-800);

    .vehicle-title {
      flex: 1;
      min-width: 0;

      .vehicle-name {
        font-size: 1rem;
        font-weight: 600;
        color: var(--bng-off-white);
        margin: 0 0 0.25rem 0;
        line-height: 1.2;
        letter-spacing: -0.01em;

        &.sold {
          color: #ef4444;
          text-decoration: line-through;
          opacity: 0.8;
        }
      }

      .vehicle-brand {
        font-size: 0.75rem;
        color: var(--bng-cool-gray-400);
        margin: 0;
        font-weight: 500;
        letter-spacing: 0.025em;
        text-transform: uppercase;
      }
    }

    .vehicle-price {
      text-align: right;
      flex-shrink: 0;
      padding-left: 0.75rem;

      .price-amount {
        font-size: 1.25rem;
        font-weight: 800;
        color: var(--bng-orange);
        margin-bottom: 0.125rem;
        letter-spacing: -0.02em;
        text-shadow: 0 2px 4px rgba(0,0,0,0.3);

        &.insufficient {
          color: #ef4444;
        }

        &.sold {
          color: var(--bng-cool-gray-500);
          text-decoration: line-through;
        }
      }

      .insufficient-text {
        font-size: 0.625rem;
        color: #ef4444;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        padding: 0.125rem 0.375rem;
        background: rgba(239, 68, 68, 0.1);
        border-radius: 0.25rem;
        display: inline-block;
      }
    }
  }

  .vehicle-specs {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 0.25rem 0.75rem;
    margin-bottom: 0.5rem;
    padding: 0;

    .spec-item {
      display: flex;
      align-items: center;
      gap: 0.375rem;
      font-size: 0.7rem;
      color: var(--bng-cool-gray-300);
      padding: 0.125rem 0;

      .spec-icon {
        width: 0.875rem;
        height: 0.875rem;
        color: var(--bng-orange-b400);
        flex-shrink: 0;
        opacity: 0.7;
      }

      .spec-label {
        color: var(--bng-cool-gray-500);
        flex-shrink: 0;
        font-size: 0.625rem;
        text-transform: uppercase;
        letter-spacing: 0.025em;
      }

      .spec-value {
        color: var(--bng-off-white);
        font-weight: 600;
        margin-left: 0.125rem;
        font-size: 0.7rem;
      }
    }
  }

  .seller-info {
    margin-bottom: 0.5rem;
    padding: 0.375rem 0.5rem;
    background: var(--bng-cool-gray-875);
    border-radius: 0.25rem;
    border: 1px solid var(--bng-cool-gray-800);
    position: relative;
    overflow: hidden;

    &::before {
      content: '';
      position: absolute;
      top: 0;
      left: 0;
      width: 2px;
      height: 100%;
      background: var(--bng-orange-b400);
      opacity: 0.5;
    }

    .seller-details {
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
      font-size: 0.7rem;
      color: var(--bng-cool-gray-400);
      padding-left: 0.375rem;

      span {
        display: flex;
        align-items: center;
        gap: 0.25rem;
      }

      .seller-name,
      .distance-value,
      .insurance-value {
        color: var(--bng-off-white);
        font-weight: 600;
        font-size: 0.7rem;
      }
    }
  }

  .vehicle-actions {
    margin-top: auto;
    padding-top: 0.5rem;
    border-top: 1px solid var(--bng-cool-gray-800);

    .disabled-message {
      text-align: center;
      color: var(--bng-cool-gray-500);
      font-style: italic;
      padding: 0.75rem;
      background: var(--bng-cool-gray-875);
      border-radius: 0.375rem;
      border: 1px dashed var(--bng-cool-gray-700);
    }

    .action-buttons {
      display: flex;
      gap: 0.5rem;
      align-items: center;
      justify-content: flex-end;
      margin-left: auto;

      .action-btn {
        flex: 0 0 auto;
        padding: 0.375rem 0.625rem;
        font-size: 0.75rem;
        font-weight: 600;
        background: var(--bng-cool-gray-850);
        border: 1px solid var(--bng-cool-gray-700);
        border-radius: 0.25rem;
        transition: all 0.2s ease;
        position: relative;
        overflow: hidden;
        min-width: 7rem;
        
        &::before {
          content: '';
          position: absolute;
          top: 0;
          left: -100%;
          width: 100%;
          height: 100%;
          background: linear-gradient(90deg, transparent, var(--bng-orange-alpha-20), transparent);
          transition: left 0.3s ease;
        }
        
        &:hover:not(:disabled) {
          background: var(--bng-cool-gray-800);
          border-color: var(--bng-orange-b400);
          transform: translateY(-1px);
          box-shadow: 0 2px 8px rgba(0,0,0,0.3);
          
          &::before {
            left: 100%;
          }
        }

        &:disabled {
          opacity: 0.5;
          cursor: not-allowed;
        }
      }

      .purchase-btn {
        flex: 0 0 auto;
        background: linear-gradient(135deg, var(--bng-orange) 0%, var(--bng-orange-b600) 100%);
        color: var(--bng-off-black);
        border: 1px solid var(--bng-orange-b600);
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.025em;
        font-size: 0.75rem;
        padding: 0.375rem 0.75rem;
        min-width: 9rem;

        &:hover:not(:disabled) {
          background: linear-gradient(135deg, var(--bng-orange-b600) 0%, var(--bng-orange-b700) 100%);
          border-color: var(--bng-orange-b700);
          box-shadow: 
            0 4px 12px rgba(var(--bng-orange-rgb), 0.3),
            inset 0 1px 0 rgba(255,255,255,0.1);
        }

        &:disabled {
          background: var(--bng-cool-gray-750);
          color: var(--bng-cool-gray-500);
          border-color: var(--bng-cool-gray-700);
        }
      }

      .taxi-price {
        font-size: 0.625rem;
        color: var(--bng-cool-gray-400);
        margin-left: 0.125rem;
        font-weight: 500;
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

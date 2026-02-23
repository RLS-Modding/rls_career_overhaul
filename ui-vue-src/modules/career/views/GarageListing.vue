<template>
  <LayoutSingle class="garage-listing-layout">
    <div class="listing-container">
      <BngCard class="listing-card">
        <div class="property-preview" v-if="preview">
          <img :src="preview" alt="Property preview" class="preview-image" />
        </div>

        <div class="property-header">
          <h1 class="property-name">{{ name }}</h1>
          <div class="listed-price">${{ formatPrice(listedPrice) }}</div>
        </div>

        <div class="property-details">
          <div class="detail-item">
            <div class="detail-label">Capacity</div>
            <div class="detail-value">{{ capacity }} vehicles</div>
          </div>
          <div class="detail-item">
            <div class="detail-label">Parking Spots</div>
            <div class="detail-value">{{ parkingSpots }}</div>
          </div>
          <div class="detail-item" v-if="neighborhood">
            <div class="detail-label">Neighborhood</div>
            <div class="detail-value">{{ neighborhood }}</div>
          </div>
        </div>

        <div class="action-buttons">
          <BngButton
            @click="purchaseAtListedPrice"
            :accent="ACCENTS.primary"
            :disabled="cantPay || starterGarage"
            class="purchase-btn"
          >
            Purchase at Listed Price
          </BngButton>
          <BngButton
            @click="startNegotiation"
            :accent="ACCENTS.attention"
            :disabled="!canNegotiate || starterGarage"
            class="negotiate-btn"
          >
            Negotiate
          </BngButton>
          <BngButton
            @click="cancel"
            :accent="ACCENTS.secondary"
            class="cancel-btn"
          >
            Cancel
          </BngButton>
        </div>

        <div class="info-note" v-if="starterGarage">
          This is a starter garage and cannot be negotiated.
        </div>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { lua, useBridge } from '@/bridge'
import {
  BngButton,
  ACCENTS,
  BngCard
} from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'

const { events } = useBridge()

const garageId = ref('')
const name = ref('')
const preview = ref('')
const listedPrice = ref(0)
const capacity = ref(0)
const parkingSpots = ref(0)
const neighborhood = ref('')
const canNegotiate = ref(true)
const starterGarage = ref(false)
const cantPay = ref(true)

const handleGarageListingData = (data) => {
  if (!data) return
  
  garageId.value = data.garageId || ''
  name.value = data.name || 'Property'
  preview.value = data.preview || ''
  listedPrice.value = data.listedPrice || 0
  capacity.value = data.capacity || 0
  parkingSpots.value = data.parkingSpots || 0
  neighborhood.value = data.neighborhood || ''
  canNegotiate.value = data.canNegotiate !== false
  starterGarage.value = data.starterGarage || false
}

onMounted(async () => {
  events.on('openGarageListing', handleGarageListingData)
  
  // Check if player can afford
  try {
    cantPay.value = !(await lua.career_modules_garageManager.canPay())
  } catch (error) {
    console.error('Error checking if player can pay:', error)
    cantPay.value = true  // Assume can't pay if error
  }
})

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const purchaseAtListedPrice = () => {
  lua.career_modules_garageManager.purchaseGarageAtListedPrice(garageId.value)
  lua.career_career.closeAllMenus()
}

const startNegotiation = () => {
  lua.career_modules_garageManager.startGarageNegotiation(garageId.value)
}

const cancel = () => {
  lua.career_modules_garageManager.cancelGaragePurchase()
  lua.career_career.closeAllMenus()
}
</script>

<style scoped lang="scss">
.garage-listing-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.listing-container {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
}

.listing-card {
  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.9);
    border-radius: 0.75em;
    padding: 1.5em;
    box-shadow: 0 0 30px rgba(0, 0, 0, 0.6);
    border: 1px solid rgba(255, 255, 255, 0.2);
    max-width: 600px;
    width: 100%;
  }
}

.property-preview {
  margin-bottom: 1em;
  border-radius: 0.5em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.05);
}

.preview-image {
  width: 100%;
  height: auto;
  display: block;
}

.property-header {
  margin-bottom: 1em;
}

.property-name {
  font-size: 1.8em;
  font-weight: 600;
  margin: 0 0 0.25em 0;
}

.listed-price {
  font-size: 1.5em;
  font-weight: 700;
  color: #4caf50;
}

.property-details {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 1em;
  margin-bottom: 1.5em;
  padding: 1em;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 0.5em;
}

.detail-item {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.detail-label {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.6);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.detail-value {
  font-size: 1.1em;
  font-weight: 600;
}

.action-buttons {
  display: flex;
  gap: 0.75em;
  margin-top: 1em;
  flex-wrap: wrap;
}

.purchase-btn,
.negotiate-btn,
.cancel-btn {
  flex: 1;
  min-width: 150px;
}

.info-note {
  margin-top: 1em;
  padding: 0.75em;
  background: rgba(255, 193, 7, 0.1);
  border-left: 3px solid rgba(255, 193, 7, 0.5);
  border-radius: 0.25em;
  color: rgba(255, 193, 7, 0.9);
  font-size: 0.9em;
}
</style>

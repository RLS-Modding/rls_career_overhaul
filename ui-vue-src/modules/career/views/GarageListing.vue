<template>
  <LayoutSingle class="garage-listing-layout">
    <div class="listing-backdrop" @click="cancel">
      <div class="listing-panel" @click.stop>
        <div class="panel-preview" v-if="preview">
          <img :src="preview" alt="" class="preview-img" />
          <div class="preview-fade"></div>
          <div class="preview-badges">
            <span v-if="starterGarage" class="tag free">STARTER</span>
            <span class="tag label" v-else>FOR SALE</span>
          </div>
          <div class="preview-price">${{ formatPrice(listedPrice) }}</div>
        </div>

        <div class="panel-body">
          <div class="header-row">
            <div>
              <h1 class="prop-name">{{ name }}</h1>
              <div class="prop-location" v-if="neighborhood">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                {{ neighborhood }}
              </div>
            </div>
          </div>

          <div class="columns">
            <div class="col">
              <div class="col-title">Property Details</div>
              <div class="details-card">
                <div class="detail-row">
                  <span class="detail-key">Vehicle Capacity</span>
                  <span class="detail-val">{{ capacity }}</span>
                </div>
                <div class="detail-row">
                  <span class="detail-key">Parking Spots</span>
                  <span class="detail-val">{{ parkingSpots }}</span>
                </div>
              </div>
            </div>

            <div class="col">
              <div class="col-title">Cost Breakdown</div>
              <div class="details-card">
                <div class="detail-row">
                  <span class="detail-key">Listed Price</span>
                  <span class="detail-val money" :class="{ 'price-crossed': negotiatedPrice }">
                    ${{ formatPrice(listedPrice) }}
                  </span>
                </div>
                <div class="detail-row" v-if="negotiatedPrice">
                  <span class="detail-key">Negotiated Price</span>
                  <span class="detail-val money negotiated">${{ formatPrice(negotiatedPrice) }}</span>
                </div>
                <div class="frozen-badge" v-if="isFrozen && cooldownRemaining > 0">
                  Price frozen for {{ formatCooldown(cooldownRemaining) }}
                </div>
                <div class="detail-row" v-if="closingFee > 0">
                  <span class="detail-key">Closing Costs <span class="rate">(3%)</span></span>
                  <span class="detail-val money dim">+ ${{ formatPrice(closingFee) }}</span>
                </div>
                <div class="detail-row" v-if="propertyTax > 0">
                  <span class="detail-key">Property Tax <span class="rate">(1.2%)</span></span>
                  <span class="detail-val money dim">+ ${{ formatPrice(propertyTax) }}</span>
                </div>
                <div class="detail-divider"></div>
                <div class="detail-row total-row">
                  <span class="detail-key">Estimated Total</span>
                  <span class="detail-val money total-val">${{ formatPrice(estimatedTotal) }}</span>
                </div>
              </div>

              <button 
                v-if="negotiatedPrice && !isFrozen"
                class="btn btn-freeze full-width" 
                @click="freezeNegotiatedPrice"
              >
                Price Freeze
              </button>
            </div>
          </div>

          <div class="starter-note" v-if="starterGarage">
            This is a starter garage and cannot be negotiated.
          </div>

          <div class="cant-afford" v-if="cantPay && !starterGarage">
            You don't have enough funds to purchase this property.
          </div>

          <div class="cooldown-notice" v-if="cooldownRemaining > 0 && !negotiatedPrice">
            Negotiation on cooldown: {{ formatCooldown(cooldownRemaining) }}
          </div>

          <div class="btn-row">
            <button 
              class="btn btn-buy" 
              :disabled="cantPay || starterGarage" 
              @click="negotiatedPrice ? purchaseAtNegotiatedPrice() : purchaseAtListedPrice()"
            >
              {{ negotiatedPrice ? 'Buy at Negotiated Price' : 'Buy at Listed Price' }}
            </button>
            <button 
              class="btn btn-offer" 
              :disabled="!canNegotiate || starterGarage || cooldownRemaining > 0" 
              @click="startNegotiation"
            >
              Make an Offer
            </button>
            <button class="btn btn-cancel" @click="cancel">
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { lua, useBridge } from '@/bridge'
import { LayoutSingle } from '@/common/layouts'

const { events } = useBridge()

const garageId = ref('')
const name = ref('')
const preview = ref('')
const listedPrice = ref(0)
const negotiatedPrice = ref(null)
const closingFee = ref(0)
const propertyTax = ref(0)
const estimatedTotal = ref(0)
const capacity = ref(0)
const parkingSpots = ref(0)
const neighborhood = ref('')
const canNegotiate = ref(true)
const cooldownRemaining = ref(0)
const isFrozen = ref(false)
const starterGarage = ref(false)
const cantPay = ref(true)

const applyListingData = (data) => {
  if (!data) return
  garageId.value = data.garageId || data.id || ''
  name.value = data.name || 'Property'
  preview.value = data.preview || ''
  listedPrice.value = data.listedPrice || 0
  negotiatedPrice.value = data.negotiatedPrice || null
  closingFee.value = data.closingFee || 0
  propertyTax.value = data.propertyTax || 0
  estimatedTotal.value = data.estimatedTotal || data.listedPrice || 0
  capacity.value = data.capacity || 0
  parkingSpots.value = data.parkingSpots || 0
  neighborhood.value = data.neighborhood || ''
  canNegotiate.value = data.canNegotiate !== false
  cooldownRemaining.value = data.cooldownRemaining || 0
  isFrozen.value = data.isFrozen || false
  starterGarage.value = data.starterGarage || false
}

const fetchGarageListing = async () => {
  if (!garageId.value || !lua.career_modules_garageManager.requestGarageListing) return null
  try {
    return await lua.career_modules_garageManager.requestGarageListing(garageId.value)
  } catch (error) {
    return null
  }
}

const handleGarageListingData = async (data) => {
  if (!data) return
  applyListingData(data)
  if (!garageId.value) return
  if (!data.name || data.listedPrice == null || data.closingFee == null) {
    const fetchedListing = await fetchGarageListing()
    if (fetchedListing) {
      applyListingData(fetchedListing)
      return
    }
  }
  if (!data.name || data.listedPrice == null) {
    const fallback = await lua.career_modules_garageManager.requestGarageData()
    if (fallback) {
      name.value = fallback.name || name.value
      listedPrice.value = fallback.price ?? listedPrice.value
      capacity.value = fallback.capacity ?? capacity.value
      starterGarage.value = fallback.starterGarage ?? starterGarage.value
      canNegotiate.value = fallback.canNegotiate ?? canNegotiate.value
    }
  }
}

let cooldownTimer = null

onMounted(async () => {
  events.on('openGarageListing', handleGarageListingData)
  const pending = await lua.career_modules_garageManager.getPendingGarageListing()
  if (pending) await handleGarageListingData(pending)
  try {
    cantPay.value = !(await lua.career_modules_garageManager.canPay())
  } catch (error) {
    cantPay.value = true
  }

  cooldownTimer = setInterval(() => {
    if (cooldownRemaining.value > 0) {
      cooldownRemaining.value = Math.max(0, cooldownRemaining.value - 1)
    }
    if (cooldownRemaining.value <= 0 && negotiatedPrice.value) {
      negotiatedPrice.value = null
    }
  }, 1000)
})

onUnmounted(() => {
  events.off('openGarageListing', handleGarageListingData)
  if (cooldownTimer) clearInterval(cooldownTimer)
})

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const formatCooldown = (seconds) => {
  if (seconds <= 0) return ''
  const minutes = Math.floor(seconds / 60)
  const secs = seconds % 60
  if (minutes > 0) {
    return `${minutes}m ${secs}s`
  }
  return `${secs}s`
}

const purchaseAtListedPrice = () => {
  lua.career_modules_garageManager.purchaseGarageAtListedPrice(garageId.value)
  lua.career_career.closeAllMenus()
}

const purchaseAtNegotiatedPrice = () => {
  lua.career_modules_garageManager.purchaseGarageAtNegotiatedPrice(garageId.value)
  lua.career_career.closeAllMenus()
}

const startNegotiation = () => {
  lua.career_modules_garageManager.startGarageNegotiation(garageId.value)
}

const freezeNegotiatedPrice = () => {
  if (!garageId.value || !negotiatedPrice.value) return
  lua.career_modules_garageManager.freezeNegotiatedPrice(garageId.value, negotiatedPrice.value)
  isFrozen.value = true
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

.listing-backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.6);
  z-index: 100;
}

.listing-panel {
  width: 640px;
  max-width: calc(100vw - 40px);
  max-height: calc(100vh - 60px);
  overflow-y: auto;
  background: #0e0e0e;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.8);

  &::-webkit-scrollbar { width: 4px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 2px; }
}

.panel-preview {
  position: relative;
  width: 100%;
  height: 220px;
  background: #000;
  overflow: hidden;
}

.preview-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.preview-fade {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 80px;
  background: linear-gradient(to top, #0e0e0e, transparent);
  pointer-events: none;
}

.preview-badges {
  position: absolute;
  top: 14px;
  left: 14px;
  display: flex;
  gap: 6px;
}

.tag {
  font-size: 10px;
  font-weight: 700;
  padding: 4px 10px;
  border-radius: 5px;
  letter-spacing: 0.6px;

  &.free { background: #22c55e; color: white; }
  &.label {
    background: rgba(0, 0, 0, 0.55);
    color: rgba(255, 255, 255, 0.9);
    backdrop-filter: blur(6px);
    border: 1px solid rgba(255, 255, 255, 0.15);
  }
}

.preview-price {
  position: absolute;
  bottom: 16px;
  left: 20px;
  font-size: 26px;
  font-weight: 800;
  color: white;
  text-shadow: 0 2px 8px rgba(0, 0, 0, 0.9);
}

.panel-body {
  padding: 20px 24px 24px;
}

.header-row {
  margin-bottom: 20px;
}

.prop-name {
  font-size: 22px;
  font-weight: 700;
  margin: 0;
  line-height: 1.2;
}

.prop-location {
  display: flex;
  align-items: center;
  gap: 5px;
  color: rgba(255, 255, 255, 0.5);
  font-size: 13px;
  margin-top: 5px;
}

.columns {
  display: grid;
  grid-template-columns: 1fr 1.3fr;
  gap: 16px;
  margin-bottom: 20px;
}

.col-title {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: rgba(255, 255, 255, 0.35);
  margin-bottom: 8px;
  font-weight: 700;
}

.details-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 10px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.detail-key {
  font-size: 13px;
  color: rgba(255, 255, 255, 0.6);

  .rate {
    color: rgba(255, 255, 255, 0.3);
    font-size: 11px;
  }
}

.detail-val {
  font-size: 14px;
  font-weight: 600;
  color: white;
  white-space: nowrap;

  &.money {
    font-variant-numeric: tabular-nums;
  }

  &.dim {
    color: rgba(255, 255, 255, 0.5);
    font-weight: 400;
  }
}

.detail-divider {
  height: 1px;
  background: rgba(255, 255, 255, 0.08);
  margin: 2px 0;
}

.total-row {
  .detail-key {
    color: white;
    font-weight: 600;
  }
}

.total-val {
  color: #4caf50 !important;
  font-size: 16px !important;
  font-weight: 700 !important;
}

.starter-note {
  margin-bottom: 16px;
  padding: 10px 14px;
  background: rgba(255, 193, 7, 0.08);
  border-left: 3px solid rgba(255, 193, 7, 0.5);
  border-radius: 4px;
  color: rgba(255, 193, 7, 0.85);
  font-size: 13px;
}

.cant-afford {
  margin-bottom: 16px;
  padding: 10px 14px;
  background: rgba(239, 68, 68, 0.08);
  border-left: 3px solid rgba(239, 68, 68, 0.5);
  border-radius: 4px;
  color: rgba(239, 68, 68, 0.85);
  font-size: 13px;
}

.cooldown-notice {
  margin-bottom: 16px;
  padding: 10px 14px;
  background: rgba(255, 193, 7, 0.08);
  border-left: 3px solid rgba(255, 193, 7, 0.5);
  border-radius: 4px;
  color: rgba(255, 193, 7, 0.85);
  font-size: 13px;
}

.price-crossed {
  text-decoration: line-through;
  opacity: 0.5;
}

.negotiated {
  color: #4caf50 !important;
  font-weight: 700 !important;
}

.frozen-badge {
  padding: 6px 10px;
  background: rgba(59, 130, 246, 0.1);
  border: 1px solid rgba(59, 130, 246, 0.25);
  border-radius: 6px;
  color: rgba(59, 130, 246, 0.9);
  font-size: 11px;
  font-weight: 600;
  text-align: center;
  letter-spacing: 0.3px;
}

.btn-row {
  display: flex;
  gap: 10px;
}

.btn {
  flex: 1;
  padding: 12px 16px;
  border: none;
  border-radius: 10px;
  font-size: 13px;
  font-weight: 700;
  font-family: inherit;
  cursor: pointer;
  transition: opacity 0.15s ease, transform 0.1s ease;
  color: white;

  &:hover:not(:disabled) { opacity: 0.85; }
  &:active:not(:disabled) { transform: scale(0.97); }
  &:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
}

.btn-buy {
  background: #f97316;
}

.btn-offer {
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.15);

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
  }
}

.btn-freeze {
  background: rgba(59, 130, 246, 0.15);
  color: rgba(59, 130, 246, 0.9);
  border: 1px solid rgba(59, 130, 246, 0.3);

  &:hover:not(:disabled) {
    background: rgba(59, 130, 246, 0.25);
  }

  &.full-width {
    width: 100%;
    margin-top: 10px;
    flex: none;
  }
}

.btn-cancel {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.08);

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.7);
  }
}
</style>

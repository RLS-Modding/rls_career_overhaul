<script setup>
import { vPhoneNumber } from "../../components/phone/phoneNumber.js"
// One owned property in the listings view: its status, the asking price input and the
// actions that depend on that status. The parent holds the price and guidance per
// garage and runs every bridge call; this card reports the price edit and the taps.
import { computed } from 'vue'
import { vBngTextInput } from '@/common/directives'
import { formatPrice } from './realEstateFormat'

defineOptions({ directives: { BngTextInput: vBngTextInput } })

const props = defineProps({
  garage: { type: Object, required: true },
  imageFailed: { type: Boolean, default: false },
  price: { type: [Number, String], default: undefined },
  guidance: { type: Object, default: null },
})

const emit = defineEmits([
  'image-error', 'update:price', 'check-price', 'list-for-sale', 'move-out', 'reclaim', 'view-offers', 'remove-listing',
])

// v-model.number writes through this computed, so the parent receives the parsed number.
const priceInput = computed({
  get: () => props.price,
  set: value => emit('update:price', value),
})
</script>

<template>
  <div class="listings-card">
    <div class="listings-card-img">
      <img v-if="garage.preview && !imageFailed" :src="garage.preview" alt="" @error="emit('image-error')" />
      <div v-else class="card-img-ph">
        <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
        <span>No preview</span>
      </div>
      <div class="card-img-fade"></div>
      <div class="card-badges">
        <span v-if="garage.canReclaim" class="badge free">RECLAIM</span>
        <span v-if="garage.isRented" class="badge rented">RENTED</span>
        <span v-if="garage.isListed" class="badge listed">LISTED</span>
        <span v-if="garage.isStarter" class="badge starter">STARTER</span>
        <span v-else-if="garage.isGranted" class="badge starter">GRANTED</span>
      </div>
      <div class="listings-card-price">${{ formatPrice(garage.marketValue) }}</div>
    </div>

    <div class="listings-card-body">
      <div class="listings-card-info">
        <span class="listings-name">{{ garage.name }}</span>
        <div class="listings-card-meta">
          <span class="meta-item">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="3" width="15" height="13" rx="2"/><path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/></svg>
            {{ garage.vehicleCount }}/{{ garage.capacity }}
          </span>
          <span v-if="garage.canReclaim" class="meta-item">Previously granted — reclaim free</span>
          <span v-else-if="garage.offerCount" class="meta-item offer-count">{{ garage.offerCount }} offer(s)</span>
          <span v-else-if="garage.isListed" class="meta-item listing-active">Listed: ${{ formatPrice(garage.askingPrice) }}</span>
          <span v-else class="meta-item">Not listed</span>
        </div>
      </div>
    </div>

    <div class="listings-actions" v-if="garage.canReclaim">
      <p class="listing-guidance guidance-fair">
        You moved out of this granted property. Reclaim it anytime for free.
      </p>
      <button
        class="act-btn negotiate listings-full-btn"
        @click="emit('reclaim')"
      >
        Reclaim Free
      </button>
    </div>

    <div class="listings-actions" v-else-if="garage.isRented">
      <p class="listing-guidance guidance-fair">Rented property — cannot list for sale.</p>
    </div>

    <div class="listings-actions" v-else-if="garage.isGranted && !garage.isListed">
      <p class="listing-guidance guidance-fair">
        Granted property — no refund if you move out.
      </p>
      <button
        class="act-btn negotiate listings-full-btn"
        :disabled="!garage.canMoveOut"
        :title="garage.canMoveOut ? 'Give up access with no refund' : (garage.vehicleCount > 0 ? 'Remove all vehicles first' : 'Cannot move out')"
        @click="emit('move-out')"
      >
        Move Out
      </button>
      <p v-if="!garage.canMoveOut && garage.vehicleCount > 0" class="listing-guidance guidance-high">
        {{ garage.vehicleCount }} vehicle{{ garage.vehicleCount !== 1 ? 's' : '' }} still in garage
      </p>
    </div>

    <div class="listings-actions" v-else-if="!garage.isListed">
      <div class="listing-price-row">
        <input
          v-model.number="priceInput"
          type="number"
          min="0"
          placeholder="Asking price"
          class="listing-price-input"
          v-bng-text-input
         v-phone-number="5000"/>
        <button class="act-btn route" @click="emit('check-price')">Check Price</button>
      </div>
      <p v-if="guidance" class="listing-guidance" :class="`guidance-${guidance.tier || 'fair'}`">
        {{ guidance.label || 'Price check' }}: {{ guidance.description || '' }}
      </p>
      <button
        class="act-btn negotiate listings-full-btn"
        :disabled="!garage.canSell"
        @click="emit('list-for-sale')"
      >
        List for Sale
      </button>
    </div>

    <div class="listings-actions" v-else>
      <div class="listings-listed-row">
        <button class="act-btn negotiate" @click="emit('view-offers')">
          View Offers<span v-if="garage.offerCount"> ({{ garage.offerCount }})</span>
        </button>
        <button class="act-btn route" @click="emit('remove-listing')">
          Remove Listing
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/views/phoneRealEstate/shared";

// One owned property in the listings view. Owned by RealEstateOwnedListingCard.vue.

.listings-card {
  background: #1a1a1a;
  border-radius: 16px;
  border: 1px solid rgba(255,255,255,0.05);
}

.listings-card-img {
  position: relative;
  width: 100%;
  height: 150px;
  background: #0d0d0d;
  overflow: hidden;
  border-radius: 16px 16px 0 0;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.listings-card-price {
  position: absolute;
  bottom: 10px;
  left: 12px;
  font-size: 18px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.listings-card-body {
  padding: 10px 14px;
}

.listings-card-info {
  display: flex;
  flex-direction: column;
  gap: 4px;
}


.listings-card-meta {
  display: flex;
  align-items: center;
  gap: 14px;
  flex-wrap: wrap;
}

.listing-active {
  color: #34d399 !important;
}

.offer-count {
  color: #f97316 !important;
}

.listings-actions {
  padding: 0 14px 14px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.listing-price-row {
  display: flex;
  gap: 6px;
}

.listing-price-input {
  flex: 1;
  min-width: 0;
  padding: 8px 10px;
  border-radius: 10px;
  border: 1px solid rgba(255,255,255,0.12);
  background: #0d0d0d;
  color: #fff;
  font-size: 12px;
  font-family: inherit;
}

.listings-full-btn {
  width: 100%;
  justify-content: center;
}

.listing-guidance {
  margin: 0;
  font-size: 11px;
  line-height: 1.3;
  padding: 8px 10px;
  border-radius: 10px;
  background: #101010;
  border: 1px solid rgba(255,255,255,0.08);
}

.guidance-high { color: #34d399; }
.guidance-fair { color: #f97316; }
.guidance-low { color: #ef4444; }

.listings-listed-row {
  display: flex;
  gap: 8px;

  .act-btn { flex: 1; justify-content: center; }
}
</style>

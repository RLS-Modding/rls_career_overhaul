<template>
  <div class="sell-listings">
    <article v-for="row in rows" :key="row.id" class="listing-card">
      <div class="listing-main">
        <button type="button" class="listing-open" @click="openVehicle(row)">
          <span class="thumb" :style="row.thumbStyle"></span>
          <span class="listing-info">
            <span class="listing-meta">{{ row.year }}, {{ row.mileageText }}</span>
            <span class="listing-name">{{ row.niceName }}</span>
            <span class="listing-price-row">
              <span class="listing-price"><MoneyAmount>{{ row.askingText }}</MoneyAmount></span>
              <span v-if="row.delta" class="chip" :class="`chip--${row.delta.tone}`">{{ row.delta.text }}</span>
            </span>
          </span>
        </button>
        <div class="listing-actions">
          <button type="button" class="edit-btn" @click="$emit('edit-listing', row.id)">Edit</button>
          <button type="button" class="remove-btn" title="Remove listing" @click="confirmRemove(row)">×</button>
        </div>
      </div>

      <p v-if="row.disabled" class="listing-disabled">{{ row.disableReason }}</p>

      <button
        type="button"
        class="offers-row"
        :class="{ 'has-offers': row.offerCount > 0 }"
        @click="$emit('see-offers', row.id)"
      >
        <span class="offers-row-left">
          <span class="offers-dot" :class="{ live: row.offerCount > 0 }"></span>
          <span class="offers-text"><template v-if="row.offerCount">{{ row.offerCount }} {{ row.offerCount === 1 ? 'offer' : 'offers' }}, best <MoneyAmount>{{ row.bestText }}</MoneyAmount></template><template v-else>{{ row.offersText }}</template></span>
        </span>
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <path d="M9 6l6 6-6 6" />
        </svg>
      </button>
    </article>

    <button type="button" class="add-listing-btn" @click="$emit('add-listing')">
      + List a vehicle from your garage
    </button>
  </div>
</template>

<script setup>
import MoneyAmount from "../MoneyAmount.vue"
import { computed } from 'vue'
import { lua } from '@/bridge'
import { usePhoneMarketplaceConfirm } from '../../composables/usePhoneMarketplaceConfirm'
import { usePhoneMarketplaceListings } from '../../composables/usePhoneMarketplaceListings'
import { marketDelta, mileageText, usePhoneMarketplaceMoney } from '../../composables/usePhoneMarketplaceFormat'

defineEmits(['see-offers', 'add-listing', 'edit-listing'])

const { money } = usePhoneMarketplaceMoney()
const { askConfirm } = usePhoneMarketplaceConfirm()
const { listings, offersForListing, refreshListings } = usePhoneMarketplaceListings()

const rows = computed(() => listings.value.map(listing => {
  const live = offersForListing(listing.id).filter(o => !o.expired)
  const best = live.reduce((max, o) => Math.max(max, Number(o.offer.value) || 0), 0)
  const asking = Number(listing.value) || 0

  return {
    id: listing.id,
    niceName: listing.niceName,
    year: listing.vehicleData?.year || '—',
    mileageText: mileageText(listing.vehicleData?.mileage),
    thumbStyle: listing.thumbnail ? { backgroundImage: `url('${listing.thumbnail}')` } : {},
    askingText: money(asking),
    // selling: asking above estimated market is the warning, not the win
    delta: marketDelta(asking, listing.marketValue, { overIsGood: false }),
    offerCount: live.length,
    bestText: money(best),
    offersText: live.length
      ? `${live.length} ${live.length === 1 ? 'offer' : 'offers'}, best ${money(best)}`
      : 'No offers yet',
    disabled: !!listing.disabled,
    disableReason: listing.disableReason,
  }
}))

function openVehicle(row) {
  lua.extensions.ui_router.navigate('phone-marketplace-vehicle', {
    kind: 'own',
    vehicleId: String(row.id),
  })
}

function confirmRemove(row) {
  askConfirm(`Remove the listing for ${row.niceName}?`, async () => {
    await lua.overhaul_career_market_marketplace.removeVehicleListing(row.id)
    await refreshListings()
  })
}
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.sell-listings {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.listing-card {
  flex: none;
  border-radius: 16px;
  background: rgba(23, 28, 37, 0.92);
  border: 1px solid rgba(255, 255, 255, 0.09);
  overflow: hidden;
}

.listing-main {
  display: flex;
  align-items: flex-start;
  padding: 11px;
  gap: 8px;
}

.listing-open {
  flex: 1;
  display: flex;
  gap: 11px;
  min-width: 0;
  padding: 0;
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.thumb {
  flex: none;
  width: 100px;
  aspect-ratio: 16 / 9;
  border-radius: 10px;
  background: repeating-linear-gradient(135deg, #232a35 0, #232a35 10px, #1d232c 10px, #1d232c 20px) center / cover no-repeat;
}

.listing-info {
  flex: 1;
  min-width: 0;
}

.listing-meta {
  display: block;
  font-size: 10px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.42);
}

.listing-name {
  display: block;
  margin-top: 1px;
  font-size: 14px;
  font-weight: 700;
  line-height: 1.25;
  overflow-wrap: break-word;
}

.listing-price-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 7px;
  margin-top: 5px;
}

.listing-price {
  font-size: 14px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  color: #29c15a;
}

.listing-price-row .chip {
  margin-top: 0;
  font-size: 9.5px;
  padding: 2px 6px;
}

.remove-btn {
  flex: none;
  width: 28px;
  height: 28px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.04);
  color: rgba(255, 255, 255, 0.5);
  font: inherit;
  font-size: 15px;
  line-height: 1;
  cursor: pointer;
}

.listing-actions {
  flex: none;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 6px;
}

.edit-btn {
  flex: none;
  height: 28px;
  padding: 0 8px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.04);
  color: rgba(255, 255, 255, 0.7);
  font: inherit;
  font-size: 11px;
  font-weight: 700;
  cursor: pointer;
}

.listing-disabled {
  margin: 0;
  padding: 0 12px 10px;
  font-size: 11px;
  line-height: 1.4;
  color: #ff8a80;
}

.offers-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  width: 100%;
  min-height: 38px;
  padding: 9px 12px;
  box-sizing: border-box;
  border: none;
  border-top: 1px solid rgba(255, 255, 255, 0.07);
  background: rgba(255, 255, 255, 0.02);
  color: rgba(255, 255, 255, 0.7);
  font: inherit;
  cursor: pointer;

  &.has-offers {
    background: rgba(126, 182, 255, 0.07);
  }

  svg {
    flex: none;
    opacity: 0.6;
  }
}

.offers-row-left {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}

.offers-dot {
  flex: none;
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.2);

  &.live {
    background: #f44336;
  }
}

.offers-text {
  font-size: 11.5px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.42);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.offers-row.has-offers .offers-text {
  color: #c9e0ff;
}

.add-listing-btn {
  margin-top: 2px;
  min-height: 38px;
  padding: 10px;
  border: 1px dashed rgba(255, 255, 255, 0.18);
  border-radius: 11px;
  background: rgba(255, 255, 255, 0.03);
  color: rgba(255, 255, 255, 0.6);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
</style>

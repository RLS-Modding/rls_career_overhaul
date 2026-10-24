<template>
  <div class="phone-marketplace-home">
    <div class="search-bar-wrap">
      <div class="search-bar" data-focus-field>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,.45)" stroke-width="2.4">
          <circle cx="11" cy="11" r="7" />
          <path d="M20 20l-4-4" />
        </svg>
        <input
          v-model="searchQuery"
          class="search-input"
          type="text"
          placeholder="Search private listings"
          v-bng-text-input
          @keydown.stop
          @keyup.stop
          @keypress.stop
        >
      </div>
    </div>

    <div class="feed">
      <div class="feed-header">
        <div class="feed-title">Private listings</div>
        <div class="feed-count">{{ feedCountText }}</div>
      </div>

      <p v-if="!shopLoaded" class="feed-hint">Loading listings…</p>
      <p v-else-if="!feed.length" class="feed-hint">
        {{ searchQuery ? 'No private listings match that search.' : 'No private listings right now. Check back later.' }}
      </p>

      <article v-for="row in feed" :key="row.shopId" class="listing-card">
        <button type="button" class="listing-photo" :style="row.photoStyle" @click="openVehicle(row)">
          <span v-if="!row.preview" class="photo-placeholder">Vehicle photo</span>
          <span class="seller-chip">
            <span class="avatar avatar--sm" :style="{ background: row.avatarBg }">{{ row.initials }}</span>
            <span class="seller-name">{{ row.sellerName }}</span>
          </span>
        </button>

        <div class="listing-body">
          <button type="button" class="listing-heading" @click="openVehicle(row)">
            <span class="listing-meta">{{ row.year }}, {{ row.mileageText }}</span>
            <span class="listing-name-row">
              <span class="listing-name">{{ row.name }}</span>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,.4)" stroke-width="2.5">
                <path d="M9 6l6 6-6 6" />
              </svg>
            </span>
          </button>

          <div class="listing-footer">
            <div class="asking">
              <div class="asking-label">Asking</div>
              <div class="asking-value"><MoneyAmount>{{ row.askingText }}</MoneyAmount></div>
              <span v-if="row.delta" class="chip" :class="`chip--${row.delta.tone}`">{{ row.delta.text }}</span>
            </div>
            <button
              type="button"
              class="offer-btn"
              :disabled="!row.canNegotiate || negotiateInProgress"
              :title="row.canNegotiate ? '' : 'This seller will not haggle'"
              @click="makeOffer(row)"
            >
              Make an offer
            </button>
          </div>
        </div>
      </article>
    </div>

    <PhoneMarketplaceNav active="buy" :unread-count="unreadCount" />
  </div>
</template>

<script setup>
import MoneyAmount from "../../components/MoneyAmount.vue"
import { reportUiFailure } from "../../utils/safeLua"

import { computed, onMounted, onUnmounted, ref } from 'vue'
import PhoneMarketplaceNav from '../../components/phone/PhoneMarketplaceNav.vue'
import { lua, useBridge } from '@/bridge'
import { vBngTextInput } from '@/common/directives'
import { useVehicleShoppingStore } from '../../stores/vehicleShoppingStore'
import { usePhoneMarketplaceUi } from '../../composables/usePhoneMarketplaceUi'
import { usePhoneMarketplaceListings } from '../../composables/usePhoneMarketplaceListings'
import {
  avatarColour,
  avatarInitials,
  marketDelta,
  mileageText,
  usePhoneMarketplaceMoney,
} from '../../composables/usePhoneMarketplaceFormat'

usePhoneMarketplaceUi()

const { money } = usePhoneMarketplaceMoney()
const { unreadCount } = usePhoneMarketplaceListings()
const vehicleShoppingStore = useVehicleShoppingStore()
const { events } = useBridge()

const shopLoaded = ref(false)
const searchQuery = ref('')
const negotiateInProgress = ref(false)

const askingPrice = vehicle => Number(vehicle.valueAdjusted || vehicle.Value || 0)

/** Raw shop stock — not filteredVehicles, which applies the computer's shared search/filters. */
const privateListings = computed(() => {
  const shop = vehicleShoppingStore.vehicleShoppingData?.vehiclesInShop
  if (!shop) return []
  const list = Array.isArray(shop) ? shop : Object.values(shop)
  return list.filter(v => String(v.sellerId) === 'private' && !v.__sold && !v.soldViewCounter)
})

const feed = computed(() => {
  const query = searchQuery.value.trim().toLowerCase()
  return privateListings.value
    .filter(v => {
      if (!query) return true
      return [v.Name, v.Brand, v.sellerName, v.year]
        .some(field => field != null && String(field).toLowerCase().includes(query))
    })
    .map(v => {
      const asking = askingPrice(v)
      const sellerName = v.sellerName || 'Private seller'
      return {
        shopId: v.shopId || v.uid || v.id,
        name: [v.Brand, v.Name].filter(Boolean).join(' ') || v.Name || 'Vehicle',
        year: v.year || '—',
        preview: v.preview,
        photoStyle: v.preview ? { backgroundImage: `url('${v.preview}')` } : {},
        mileageText: mileageText(v.Mileage),
        sellerName,
        initials: avatarInitials(sellerName),
        avatarBg: avatarColour(sellerName),
        askingText: money(asking),
        // buying: paying under estimated market is the good outcome
        delta: marketDelta(asking, v.marketValue),
        canNegotiate: v.negotiationPossible !== false && !(Number(v.discountPercentage) > 0),
      }
    })
})

const feedCountText = computed(() => {
  const n = feed.value.length
  if (!shopLoaded.value) return ''
  return n === 1 ? '1 listing' : `${n} listings`
})

function openVehicle(row) {
  if (!row.shopId) return
  lua.extensions.ui_router.navigate('phone-marketplace-vehicle', {
    kind: 'listing',
    vehicleId: String(row.shopId),
  })
}

async function makeOffer(row) {
  if (negotiateInProgress.value || !row.shopId || !row.canNegotiate) return
  negotiateInProgress.value = true
  try {
    // Lua refuses some listings (discounted, non-negotiable, car meet rules) — it reports
    // back whether a negotiation actually opened.
    const started = await lua.overhaul_career_market_marketplace.startNegotiateSellingOffer(row.shopId, true)
    if (started) await lua.extensions.ui_router.navigate('phone-marketplace-negotiate')
  } finally {
    negotiateInProgress.value = false
  }
}

const onShopDelta = (delta) => {
  if (typeof vehicleShoppingStore.applyShopDelta === 'function') {
    vehicleShoppingStore.applyShopDelta(delta)
  }
}

onMounted(async () => {
  events.on('vehicleShopDelta', onShopDelta)
  try {
    await lua.overhaul_career_market_vehicleShopping.setShoppingUiOpen(true)
  } catch (_) { reportUiFailure(_, "optional action (PhoneMarketplace)") }
  await vehicleShoppingStore.requestVehicleShoppingData()
  shopLoaded.value = true
})

onUnmounted(() => {
  try {
    if (events && typeof events.off === 'function') events.off('vehicleShopDelta', onShopDelta)
  } catch (_) { reportUiFailure(_, "optional action (PhoneMarketplace)") }
  try { lua.overhaul_career_market_vehicleShopping.setShoppingUiOpen(false) } catch (_) { reportUiFailure(_, "optional action (PhoneMarketplace)") }
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.phone-marketplace-home {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  box-sizing: border-box;
  color: #fff;
  overflow: hidden;
}

.search-bar-wrap {
  flex: none;
  padding: 42px 12px 10px;
}

.search-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 9px 11px;
  border-radius: 11px;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.09);

  svg {
    flex: none;
  }
}

.search-input {
  flex: 1;
  min-width: 0;
  border: none;
  background: transparent;
  color: #fff;
  font: inherit;
  font-size: 12.5px;
  outline: none;

  &::placeholder {
    color: rgba(255, 255, 255, 0.4);
  }
}

.feed {
  @include mkt-scrollbar;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0 12px 12px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.feed-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}

.feed-title {
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.02em;
}

.feed-count {
  font-size: 10.5px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: rgba(255, 255, 255, 0.4);
}

.feed-hint {
  margin: 4px 0;
  font-size: 12.5px;
  line-height: 1.5;
  color: rgba(255, 255, 255, 0.42);
}

.listing-card {
  flex: none;
  border-radius: 16px;
  background: rgba(23, 28, 37, 0.92);
  border: 1px solid rgba(255, 255, 255, 0.09);
  overflow: hidden;
}

.listing-photo {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  aspect-ratio: 16 / 9;
  padding: 0;
  border: none;
  cursor: pointer;
  background: repeating-linear-gradient(135deg, #232a35 0, #232a35 12px, #1d232c 12px, #1d232c 24px) center / cover no-repeat;
}

.photo-placeholder {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.22);
}

.seller-chip {
  position: absolute;
  top: 9px;
  left: 9px;
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 8px;
  border-radius: 9px;
  background: rgba(0, 0, 0, 0.62);
}

.seller-name {
  font-size: 10.5px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.8);
}

.listing-body {
  padding: 11px 12px 12px;
}

.listing-heading {
  display: block;
  width: 100%;
  padding: 0;
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.listing-meta {
  display: block;
  font-size: 10.5px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.42);
}

.listing-name-row {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 2px;

  svg {
    flex: none;
  }
}

.listing-name {
  font-size: 15.5px;
  font-weight: 700;
  line-height: 1.25;
  overflow-wrap: break-word;
}

.listing-footer {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 10px;
  margin-top: 11px;
}

.asking {
  min-width: 0;
}

.asking-label {
  font-size: 9.5px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.asking-value {
  margin-top: 1px;
  font-size: 21px;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
}

.offer-btn {
  flex: none;
  min-height: 38px;
  padding: 9px 13px;
  border: none;
  border-radius: 10px;
  background: #7eb6ff;
  color: #0f1116;
  font: inherit;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;

  &:disabled {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.45);
    cursor: not-allowed;
  }
}
</style>

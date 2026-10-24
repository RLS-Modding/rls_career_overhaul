<template>
  <div class="phone-marketplace-vehicle">
    <template v-if="detail">
      <div class="detail-scroll">
        <div class="photo" :style="detail.photoStyle">
          <span v-if="!detail.preview" class="photo-placeholder">Vehicle photo</span>
        </div>

        <div class="detail-body">
          <div class="detail-sub">{{ detail.subtitle }}</div>
          <h1 class="detail-name">{{ detail.name }}</h1>

          <div class="price-row">
            <div>
              <div class="price-label">{{ detail.priceLabel }}</div>
              <div class="price-value"><MoneyAmount>{{ detail.priceText }}</MoneyAmount></div>
            </div>
            <span v-if="detail.delta" class="chip" :class="`chip--${detail.delta.tone}`">{{ detail.delta.text }}</span>
          </div>

          <div v-if="detail.condition !== null" class="condition-row">
            <span class="section-label condition-label">Condition</span>
            <span class="condition-track">
              <span class="condition-fill" :style="{ width: `${detail.condition}%`, background: detail.conditionColour }"></span>
            </span>
            <span class="condition-value" :style="{ color: detail.conditionColour }">{{ detail.condition }}%</span>
          </div>

          <p v-if="detail.damagedAfterListing" class="repair-warning">Damaged after listing — repair before accepting offers.</p>
          <p v-else-if="detail.needsRepair" class="repair-warning">Damaged — asking price and offers reflect condition.</p>

          <div v-if="detail.specs.length" class="spec-grid">
            <div v-for="spec in detail.specs" :key="spec.label" class="spec-tile">
              <div class="spec-label">{{ spec.label }}</div>
              <div class="spec-value">{{ spec.value }}</div>
            </div>
          </div>

          <section v-if="detail.rows.length" class="detail-section">
            <h2 class="section-label">Details</h2>
            <div v-for="row in detail.rows" :key="row.label" class="detail-row">
              <span class="row-label">{{ row.label }}</span>
              <span class="row-value"><MoneyAmount v-if="row.money">{{ row.value }}</MoneyAmount><template v-else>{{ row.value }}</template></span>
            </div>
          </section>

          <!-- stored lap/drift times only exist for vehicles you have owned and driven -->
          <section v-if="detail.showTimes" class="detail-section">
            <h2 class="section-label">Free-roam event times</h2>
            <div v-for="time in detail.times" :key="time.name" class="detail-row">
              <span class="row-label">{{ time.name }}</span>
              <span class="row-value tabular">{{ time.value }}</span>
            </div>
            <p v-if="!detail.times.length" class="no-times">No stored times</p>
          </section>

          <section v-if="detail.seller" class="seller-section">
            <div class="seller-head">
              <span class="avatar avatar--md" :style="{ background: detail.seller.avatarBg }">{{ detail.seller.initials }}</span>
              <div>
                <div class="seller-name">{{ detail.seller.name }}</div>
                <div class="seller-role">Private seller</div>
              </div>
            </div>
          </section>
        </div>
      </div>

      <div class="detail-actions">
        <button type="button" class="back-btn" @click="goBack">Back</button>
        <button v-if="!isOwn" type="button" class="route-btn" :disabled="routeInProgress" @click="setRoute">Route</button>
        <button
          type="button"
          class="cta-btn"
          :class="{ muted: !detail.ctaEnabled }"
          :disabled="!detail.ctaEnabled || ctaInProgress"
          @click="onCta"
        >
          {{ detail.ctaLabel }}
        </button>
      </div>

      <div v-if="taxiPrompt" class="taxi-overlay" @click.self="dismissTaxi">
        <div class="taxi-sheet">
          <div class="taxi-title">Route set</div>
          <p class="taxi-body">
            {{ detail.name }} is marked on your map.<template v-if="taxiPrompt.distanceText"> It's {{ taxiPrompt.distanceText }} away.</template>
            A taxi will drive out to pick you up. The fare is metered, so it's not known up front.
          </p>
          <div class="taxi-actions">
            <button type="button" class="taxi-btn deny" :disabled="taxiInProgress" @click="driveThere">I'll drive</button>
            <button type="button" class="taxi-btn accept" :disabled="taxiInProgress" @click="acceptTaxi">
              Call a taxi
            </button>
          </div>
        </div>
      </div>
    </template>

    <div v-else-if="!ready" class="mkt-empty missing">
      <p>Loading…</p>
    </div>

    <div v-else class="mkt-empty missing">
      <p>This listing is no longer available.</p>
      <button type="button" class="back-btn" @click="goBack">Back</button>
    </div>
  </div>
</template>

<script setup>
import MoneyAmount from "../../components/MoneyAmount.vue"
import { computed, onMounted, ref, shallowRef } from 'vue'
import { lua } from '@/bridge'
import '../../utils/installLuaBridgeFallbacks'
import { usePhoneMarketplaceUi } from '../../composables/usePhoneMarketplaceUi'
import { usePhoneMarketplaceListings, requestSellTab } from '../../composables/usePhoneMarketplaceListings'
import {
  avatarColour,
  avatarInitials,
  freeroamValueText,
  marketDelta,
  mileageText,
  usePhoneMarketplaceMoney,
} from '../../composables/usePhoneMarketplaceFormat'

const props = defineProps({
  /** 'own' for one of your listings, 'listing' for a marketplace listing you could buy. */
  kind: { type: String, required: true },
  /** inventory id for 'own', shop id for 'listing'. */
  vehicleId: { type: [String, Number], required: true },
})

usePhoneMarketplaceUi()

const { money } = usePhoneMarketplaceMoney()
const { listings, listingsLoaded, offersForListing } = usePhoneMarketplaceListings()
const feedVehicle = shallowRef(null)

const isOwn = computed(() => props.kind === 'own')
const shopLoaded = ref(false)
const ctaInProgress = ref(false)
const routeInProgress = ref(false)
const taxiInProgress = ref(false)
/** Set once a route is placed; offers the taxi as an accept/deny rather than doing it for you. */
const taxiPrompt = ref(null)

/**
 * Distinguishes "still fetching" from "this listing is genuinely gone". An empty owned-listings
 * response is a real answer, so it must not read as loading or the view sticks on the spinner
 * after the last listing is removed.
 */
const ready = computed(() => (isOwn.value ? listingsLoaded.value : shopLoaded.value))

const conditionColour = percent => (percent >= 80 ? '#6fe094' : percent >= 60 ? '#ffad66' : '#ff8a80')

const ownListing = computed(() =>
  listings.value.find(l => String(l.id) === String(props.vehicleId)) || null,
)

const ownDetail = computed(() => {
  const listing = ownListing.value
  if (!listing) return null

  const data = listing.vehicleData || {}
  const asking = Number(listing.value) || 0
  const offers = offersForListing(listing.id).filter(o => !o.expired)
  const times = Object.entries(data.FRETimes || {})
    .map(([name, value]) => ({ name, value: freeroamValueText(name, value) }))

  return {
    preview: listing.thumbnail,
    photoStyle: listing.thumbnail ? { backgroundImage: `url('${listing.thumbnail}')` } : {},
    subtitle: [data.year, mileageText(data.mileage)].filter(Boolean).join(', '),
    name: listing.niceName,
    priceLabel: 'Your asking price',
    priceText: money(asking),
    delta: marketDelta(asking, listing.marketValue, { overIsGood: true }),
    condition: Number.isFinite(Number(data.condition)) ? Number(data.condition) : null,
    conditionColour: conditionColour(Number(data.condition)),
    needsRepair: !!data.needsRepair,
    damagedAfterListing: !!listing.damagedAfterListing,
    specs: buildSpecs(data.power, data.torque, data.weight, data.powerPerTonne),
    rows: [
      { label: 'Odometer', value: mileageText(data.mileage) },
      { label: 'Est. market value', value: money(listing.marketValue), money: true },
      { label: 'Live offers', value: String(offers.length) },
    ],
    showTimes: true,
    times,
    seller: null,
    ctaLabel: offers.length
      ? `View ${offers.length} ${offers.length === 1 ? 'offer' : 'offers'}`
      : 'No offers yet',
    ctaEnabled: offers.length > 0,
  }
})

const feedDetail = computed(() => {
  const v = feedVehicle.value
  if (!v) return null

  const asking = Number(v.valueAdjusted || v.Value || 0)
  const sellerName = v.sellerName || 'Private seller'
  const rows = [
    { label: 'Odometer', value: mileageText(v.Mileage) },
    v.Transmission ? { label: 'Transmission', value: v.Transmission } : null,
    v.Drivetrain ? { label: 'Drivetrain', value: v.Drivetrain } : null,
    v['Fuel Type'] ? { label: 'Fuel type', value: v['Fuel Type'] } : null,
    { label: 'Est. market value', value: money(v.marketValue), money: true },
  ].filter(Boolean)

  return {
    preview: v.preview,
    photoStyle: v.preview ? { backgroundImage: `url('${v.preview}')` } : {},
    subtitle: [v.year, v.Brand].filter(Boolean).join(', '),
    name: [v.Brand, v.Name].filter(Boolean).join(' ') || v.Name || 'Vehicle',
    priceLabel: 'Asking price',
    priceText: money(asking),
    delta: marketDelta(asking, v.marketValue),
    // marketplace stock has no part conditions, so there is nothing honest to show here
    condition: null,
    conditionColour: '#6fe094',
    needsRepair: false,
    damagedAfterListing: false,
    specs: buildSpecs(v.Power, v.Torque, v.Weight, null),
    rows,
    showTimes: false,
    times: [],
    seller: {
      name: sellerName,
      initials: avatarInitials(sellerName),
      avatarBg: avatarColour(sellerName),
    },
    ctaLabel: 'Make an offer',
    ctaEnabled: v.negotiationPossible !== false && !(Number(v.discountPercentage) > 0),
  }
})

const detail = computed(() => (isOwn.value ? ownDetail.value : feedDetail.value))

function buildSpecs(power, torque, weight, powerPerTonne) {
  const num = value => {
    const n = Number(value)
    return Number.isFinite(n) && n > 0 ? n : null
  }
  const ps = num(power)
  const nm = num(torque)
  const kg = num(weight)
  const perTonne = num(powerPerTonne) ?? (ps && kg ? Math.round((ps / kg) * 1000) : null)

  return [
    ps ? { label: 'Power', value: `${Math.round(ps)} PS` } : null,
    nm ? { label: 'Torque', value: `${Math.round(nm)} Nm` } : null,
    kg ? { label: 'Weight', value: `${Math.round(kg).toLocaleString('en-US')} kg` } : null,
    perTonne ? { label: 'PS / t', value: String(perTonne) } : null,
  ].filter(Boolean)
}

async function setRoute() {
  if (routeInProgress.value || isOwn.value) return
  routeInProgress.value = true
  try {
    const res = await lua.overhaul_career_market_marketplace.routeToListing(props.vehicleId)
    if (!res?.ok) return
    const metres = Number(res.distance)
    taxiPrompt.value = {
      distanceText: Number.isFinite(metres) && metres > 0
        ? `${(metres / 1609.344).toFixed(1)} mi`
        : '',
    }
  } finally {
    routeInProgress.value = false
  }
}

function dismissTaxi() {
  taxiPrompt.value = null
}

/** Both exits spawn the listing vehicle; only the taxi flag differs. */
async function leaveForListing(wantTaxi) {
  if (taxiInProgress.value) return
  taxiInProgress.value = true
  try {
    await lua.overhaul_career_market_marketplace.goToListing(props.vehicleId, wantTaxi)
    taxiPrompt.value = null
  } finally {
    taxiInProgress.value = false
  }
}

const driveThere = () => leaveForListing(false)
const acceptTaxi = () => leaveForListing(true)

function goBack() {
  lua.extensions.ui_router.navigate(isOwn.value ? 'phone-marketplace-sell' : 'phone-marketplace')
}

async function onCta() {
  if (ctaInProgress.value || !detail.value?.ctaEnabled) return

  if (isOwn.value) {
    requestSellTab('offers')
    lua.extensions.ui_router.navigate('phone-marketplace-sell')
    return
  }

  ctaInProgress.value = true
  try {
    const started = await lua.overhaul_career_market_marketplace.startNegotiateSellingOffer(props.vehicleId, true)
    if (started) await lua.extensions.ui_router.navigate('phone-marketplace-negotiate')
  } finally {
    ctaInProgress.value = false
  }
}

onMounted(async () => {
  if (isOwn.value) return
  feedVehicle.value = await lua.overhaul_career_market_vehicleShopping.getListing(props.vehicleId)
  shopLoaded.value = true
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.phone-marketplace-vehicle {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  box-sizing: border-box;
  color: #fff;
  overflow: hidden;
}

.detail-scroll {
  @include mkt-scrollbar;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding-top: 42px;
}

.photo {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  aspect-ratio: 16 / 9;
  background: repeating-linear-gradient(135deg, #232a35 0, #232a35 12px, #1d232c 12px, #1d232c 24px) center / cover no-repeat;
}

.photo-placeholder {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.22);
}

.detail-body {
  padding: 13px 14px 16px;
}

.detail-sub {
  font-size: 10.5px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.42);
}

.detail-name {
  margin: 3px 0 0;
  font-size: 19px;
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: break-word;
}

.price-row {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 10px;
  margin-top: 13px;
  padding-bottom: 14px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

.price-label {
  font-size: 9.5px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.price-value {
  margin-top: 2px;
  font-size: 24px;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
}

.condition-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 13px;
}

.condition-label {
  flex: none;
  margin: 0;
}

.condition-track {
  flex: 1;
  height: 5px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.09);
  overflow: hidden;
}

.condition-fill {
  display: block;
  height: 100%;
}

.condition-value {
  flex: none;
  font-size: 11.5px;
  font-weight: 700;
}

.repair-warning {
  margin: 10px 0 0;
  font-size: 11.5px;
  line-height: 1.4;
  color: #ffad66;
}

.spec-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  margin-top: 14px;
}

.spec-tile {
  padding: 9px 10px;
  border-radius: 10px;
  background: rgba(255, 255, 255, 0.04);
}

.spec-label {
  font-size: 9px;
  font-weight: 600;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.spec-value {
  margin-top: 2px;
  font-size: 14px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.detail-section {
  margin-top: 16px;
}

.section-label {
  margin: 0 0 6px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.4);
}

.detail-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 7px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
}

.row-label {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.5);
}

.row-value {
  font-size: 12px;
  font-weight: 600;
  text-align: right;

  &.tabular {
    font-variant-numeric: tabular-nums;
  }
}

.no-times {
  margin: 4px 0 0;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.35);
}

.seller-section {
  margin-top: 16px;
  padding-top: 14px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}

.seller-head {
  display: flex;
  align-items: center;
  gap: 9px;
}

.seller-name {
  font-size: 12.5px;
  font-weight: 700;
}

.seller-role {
  margin-top: 1px;
  font-size: 10px;
  color: rgba(255, 255, 255, 0.4);
}

.detail-actions {
  flex: none;
  display: flex;
  gap: 7px;
  padding: 9px 14px calc(13px + #{$mkt-bottom-inset});
  background: #0b0d12;
  border-top: 1px solid rgba(255, 255, 255, 0.07);
}

.back-btn {
  flex: none;
  min-height: 42px;
  padding: 11px 14px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 10px;
  background: rgba(255, 255, 255, 0.05);
  color: rgba(255, 255, 255, 0.65);
  font: inherit;
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
}

.cta-btn {
  flex: 1;
  min-height: 42px;
  padding: 11px;
  border: none;
  border-radius: 10px;
  background: #7eb6ff;
  color: #0f1116;
  font: inherit;
  font-size: 12.5px;
  font-weight: 700;
  cursor: pointer;

  &.muted,
  &:disabled {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.45);
    cursor: default;
  }
}

.route-btn {
  flex: none;
  min-height: 42px;
  padding: 11px 14px;
  border: 1px solid rgba(126, 182, 255, 0.35);
  border-radius: 10px;
  background: rgba(126, 182, 255, 0.12);
  color: #9ec8ff;
  font: inherit;
  font-size: 12.5px;
  font-weight: 700;
  cursor: pointer;

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.taxi-overlay {
  position: absolute;
  inset: 0;
  z-index: 60;
  display: flex;
  align-items: flex-end;
  background: rgba(0, 0, 0, 0.62);
}

.taxi-sheet {
  width: 100%;
  padding: 16px 14px 18px;
  box-sizing: border-box;
  border-radius: 18px 18px 0 0;
  background: #171c25;
  border-top: 1px solid rgba(255, 255, 255, 0.12);
}

.taxi-title {
  font-size: 15px;
  font-weight: 800;
}

.taxi-body {
  margin: 6px 0 14px;
  font-size: 12.5px;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.65);
}

.taxi-actions {
  display: flex;
  gap: 8px;
}

.taxi-btn {
  flex: 1;
  min-height: 42px;
  padding: 11px 10px;
  border-radius: 10px;
  font: inherit;
  font-size: 12.5px;
  font-weight: 700;
  cursor: pointer;

  &.deny {
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.7);
  }

  &.accept {
    border: none;
    background: #7eb6ff;
    color: #0f1116;
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.missing {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 14px;
  margin: auto;
}
</style>

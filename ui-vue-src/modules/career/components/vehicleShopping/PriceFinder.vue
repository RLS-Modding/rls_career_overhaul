<template>
  <div v-if="priceFinderData" class="price-finder-container"
    :class="{ 'selling': amISelling, 'buying': !amISelling }">
    <div class="price-finder-label right">
      {{ priceFinderData.topIsTheir ? 'Your' : 'Their' }} Asking Price:
      <BngUnit class="money" :money="priceFinderData.rightPrice" />
    </div>

    <div class="price-finder-track">
      <!-- Minor tick marks  -->
      <div
        v-for="(tick, index) in priceFinderData.minorTicks"
        :key="'minor-' + index"
        class="price-finder-tick minor"
        :style="{ top: (100 - tick.position) + '%' }">
      </div>
      <!-- Major tick marks -->
      <div
        v-for="(tick, index) in priceFinderData.majorTicks"
        :key="'major-' + index"
        class="price-finder-tick major"
        :style="{ top: (100 - tick.position) + '%' }">
        <div class="tick-label" v-if="tick.position > 5 && tick.position < 95">{{ units.beamBucks(tick.price) }}</div>
      </div>
      <!-- Offer markers -->
      <template v-if="priceFinderData.hasBothInitialOffers">
        <div
          v-for="(offer, index) in priceFinderData.offers"
          :key="index"
          class="price-finder-marker"
          :class="{
            'my-offer': offer.isMyOffer,
            'their-offer': !offer.isMyOffer,
            'most-recent': offer.isMostRecent,
            'unsent': offer.isUnsent
          }"
          :style="{ top: (100 - offer.position) + '%' }">
          <div class="marker-triangle"></div>
        </div>
      </template>
      <!-- Market value marker -->
      <div
        v-if="priceFinderData.marketValuePosition !== null"
        class="price-finder-marker market-value"
        :style="{ top: (100 - priceFinderData.marketValuePosition) + '%', bottom: '0' }">
        <div class="marker-dot"></div>
      </div>
      <!-- Initial offer markers at the ends -->
      <div
        v-for="(marker, index) in priceFinderData.initialMarkers"
        :key="'initial-' + index"
        class="price-finder-marker"
        :class="{
          'my-offer': marker.isMyOffer,
          'their-offer': !marker.isMyOffer,
          'initial': true
        }"
        :style="{ top: (100 - marker.position) + '%' }">
        <div class="marker-triangle"></div>
      </div>
    </div>

    <div class="price-finder-label left">
      {{ priceFinderData.topIsTheir ? 'Their' : 'Your' }} initial offer:
      <BngUnit class="money" :money="priceFinderData.leftPrice" />
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngUnit } from "@/common/components/base"
import { useBridge } from "@/bridge"

const { units } = useBridge()

const props = defineProps({
  offerHistory: {
    type: Array,
    default: () => []
  },
  negotiationStatus: {
    type: String,
    default: ''
  },
  startingPrice: {
    type: Number,
    default: 0
  },
  offerPreview: {
    type: Number,
    default: 0
  },
  actualVehicleValue: {
    type: Number,
    default: null
  },
  amISelling: {
    type: Boolean,
    default: false
  }
})

const priceFinderData = computed(() => {
  const history = props.offerHistory || []
  if (history.length === 0) return null

  let initialTheirOffer = null
  let initialMyOffer = null

  for (const item of history) {
    if (initialTheirOffer === null && item.theirOffer != null) {
      initialTheirOffer = item.theirOffer
    }
    if (initialMyOffer === null && item.myOffer != null) {
      initialMyOffer = item.myOffer
    }
    if (initialTheirOffer !== null && initialMyOffer !== null) break
  }

  const hasBothInitialOffers = initialTheirOffer !== null && initialMyOffer !== null

  if (initialTheirOffer === null) initialTheirOffer = props.startingPrice
  if (initialMyOffer === null) initialMyOffer = props.offerPreview || props.startingPrice

  const offers = []
  let offerIndex = 0
  let lastMyOfferIndex = -1
  let lastTheirOfferIndex = -1

  for (const item of history) {
    if (item.myOffer != null) {
      offers.push({
        price: item.myOffer,
        isMyOffer: true,
        index: offerIndex++,
        isUnsent: false
      })
      lastMyOfferIndex = offers.length - 1
    } else if (item.theirOffer != null) {
      offers.push({
        price: item.theirOffer,
        isMyOffer: false,
        index: offerIndex++,
        isUnsent: false
      })
      lastTheirOfferIndex = offers.length - 1
    }
  }

  const isActiveStatus = props.negotiationStatus !== 'failed' &&
                        props.negotiationStatus !== 'accepted' &&
                        props.offerPreview > 0
  if (isActiveStatus) {
    offers.push({
      price: props.offerPreview,
      isMyOffer: true,
      index: offerIndex++,
      isUnsent: true
    })
    lastMyOfferIndex = offers.length - 1
  }

  const leftPrice = Math.min(initialTheirOffer, initialMyOffer)
  const rightPrice = Math.max(initialTheirOffer, initialMyOffer)
  const topIsTheir = props.amISelling
  const range = rightPrice - leftPrice || 1

  const calculateNiceTicks = (min, max, priceRange) => {
    const niceNumbers = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
    const tickRange = max - min
    if (tickRange === 0) return { majorTicks: [], minorTicks: [] }

    const targetTicks = 4
    const roughStep = tickRange / targetTicks

    const magnitude = Math.pow(10, Math.floor(Math.log10(roughStep)))
    const normalizedStep = roughStep / magnitude

    let closestNice = niceNumbers[0]
    let minDiff = Math.abs(normalizedStep - closestNice)
    for (const nice of niceNumbers) {
      const diff = Math.abs(normalizedStep - nice)
      if (diff < minDiff) {
        minDiff = diff
        closestNice = nice
      }
    }

    let step = closestNice * magnitude

    const niceMin = Math.floor(min / step) * step
    const niceMax = Math.ceil(max / step) * step

    const majorTicks = []
    for (let price = niceMin; price <= niceMax; price += step) {
      if (price >= min && price <= max) {
        const position = ((price - leftPrice) / priceRange) * 100
        majorTicks.push({
          price,
          position: Math.max(0, Math.min(100, position))
        })
      }
    }

    const minorStep = step / 5
    const minorTicks = []
    for (let price = niceMin; price <= niceMax; price += minorStep) {
      if (price >= min && price <= max) {
        if (Math.abs(price % step) > 0.01) {
          const position = ((price - leftPrice) / priceRange) * 100
          minorTicks.push({
            price,
            position: Math.max(0, Math.min(100, position))
          })
        }
      }
    }

    return { majorTicks, minorTicks }
  }

  const { majorTicks, minorTicks } = calculateNiceTicks(leftPrice, rightPrice, range)
  const hasVisibleTicks = range > 0 && majorTicks.length > 0

  const offerPositions = offers.map((offer, index) => {
    const position = ((offer.price - leftPrice) / range) * 100
    const isMostRecent = (offer.isMyOffer && index === lastMyOfferIndex) ||
                        (!offer.isMyOffer && index === lastTheirOfferIndex)

    return {
      ...offer,
      position: Math.max(0, Math.min(100, position)),
      isMostRecent: isMostRecent
    }
  })

  let marketValuePosition = null
  if (hasVisibleTicks &&
      props.actualVehicleValue != null &&
      props.actualVehicleValue > 0 &&
      props.actualVehicleValue >= leftPrice &&
      props.actualVehicleValue <= rightPrice) {
    const position = ((props.actualVehicleValue - leftPrice) / range) * 100
    marketValuePosition = Math.max(0, Math.min(100, position))
  }

  const initialMarkers = []
  if (hasVisibleTicks) {
    const theirPosition = initialTheirOffer === leftPrice ? 0 : 100
    initialMarkers.push({
      price: initialTheirOffer,
      isMyOffer: false,
      position: theirPosition,
      isInitial: true
    })
    const myPosition = initialMyOffer === leftPrice ? 0 : 100
    initialMarkers.push({
      price: initialMyOffer,
      isMyOffer: true,
      position: myPosition,
      isInitial: true
    })
  }

  return {
    initialTheirOffer,
    initialMyOffer,
    leftPrice,
    rightPrice,
    topIsTheir,
    hasBothInitialOffers,
    majorTicks,
    minorTicks,
    offers: offerPositions,
    marketValuePosition,
    initialMarkers
  }
})
</script>

<style scoped lang="scss">
.price-finder-container {
  padding: 0.5rem 1rem;
  background: var(--bng-cool-gray-900);
  border-radius: var(--bng-corners-2);
  border: 1px solid var(--bng-cool-gray-800);
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  width: 10rem;
  align-self: center;
  height: 100%;

  &.selling {
    border-top: 0.5rem solid var(--bng-orange-500);
    border-bottom: 0.5rem solid var(--bng-ter-blue-gray-700);
  }

  &.buying {
    border-top: 0.5rem solid var(--bng-ter-blue-gray-700);
    border-bottom: 0.5rem solid var(--bng-orange-500);
  }
}

.price-finder-label {
  flex: 0 0 auto;
  font-size: 0.75rem;
  font-weight: 600;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.25rem;
  min-width: 3.5rem;
  align-items: flex-start;
  text-align: left;

  :deep(.info-item) {
    padding: 0;
  }
}

.price-finder-track {
  flex: 0 0 auto;
  width: 0.5rem;
  background: var(--bng-cool-gray-800);
  border-radius: 0.25rem;
  position: relative;
  min-width: 0.5rem;
  flex: 1;
}

.price-finder-tick {
  position: absolute;
  transform: translateY(-50%);
  left: 0;
  height: 1px;
  background: rgba(255, 255, 255, 0.2);
  z-index: 0;

  &.minor {
    width: 0.25rem;
    left: 0.125rem;
  }

  &.major {
    width: 0.5rem;
    background: rgba(255, 255, 255, 0.4);

    .tick-label {
      position: absolute;
      left: 1.5rem;
      top: 50%;
      transform: translateY(-50%);
      font-size: 0.75rem;
      color: rgba(255, 255, 255, 0.6);
      white-space: nowrap;
      font-weight: 500;
    }
  }
}

.price-finder-marker {
  position: absolute;
  transform: translateY(-50%);
  left: 50%;
  margin-left: -0.5rem;
  z-index: 1;

  .marker-triangle {
    width: 0;
    height: 0;
    border-top: 0.375rem solid transparent;
    border-bottom: 0.375rem solid transparent;
  }

  &.my-offer {
    .marker-triangle {
      border-right: 0.5rem solid var(--bng-orange-700);
      border-left: none;
      transform: translateX(150%);
    }
  }

  &.their-offer {
    .marker-triangle {
      border-left: 0.5rem solid var(--bng-ter-blue-gray-700);
      border-right: none;
      transform: translateX(-50%);
    }
  }

  &.most-recent {
    z-index: 2;

    &.my-offer .marker-triangle {
      border-right-color: var(--bng-orange-500);
      filter: drop-shadow(0 0 0.25rem var(--bng-orange-400));
    }

    &.their-offer .marker-triangle {
      border-left-color: var(--bng-ter-blue-gray-500);
      filter: drop-shadow(0 0 0.25rem var(--bng-ter-blue-gray-400));
    }
  }

  &.unsent {
    opacity: 0.6;
  }

  &.market-value {
    z-index: 1;
    height: auto;
    transform: unset;

    .marker-dot {
      width: 0.5rem;
      height: 100%;
      background: #6ce17a44;
      border-radius: 0 0 0.25rem 0.25rem;
      border-top: 0.125rem solid #6ce17a88;
      left: 50%;
      transform: translate(50%, 0);
    }
  }
}
</style>
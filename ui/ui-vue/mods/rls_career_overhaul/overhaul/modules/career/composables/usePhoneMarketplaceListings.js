import { computed, onMounted, onUnmounted, ref } from 'vue'
import { lua, useBridge } from '@/bridge'

/**
 * Shared marketplace listing/offer state for the phone app.
 *
 * Browse, Sell and the vehicle info page all need the same listings plus the unread
 * offer count that drives the Sell badge, so this is a module-level singleton: one
 * `marketplaceListingsUpdated` subscription, one countdown tick, one seen-offer set.
 */

const SEEN_STORAGE_KEY = 'phone_marketplace_seen_offers'

const listings = ref([])
/** True once Lua has answered at least once, so callers can tell empty from still-fetching. */
const listingsLoaded = ref(false)
const seenOfferIds = ref(loadSeenOfferIds())
let subscribers = 0
let tickTimer = null
let subscribedEvents = null

function loadSeenOfferIds() {
  try {
    const raw = sessionStorage.getItem(SEEN_STORAGE_KEY)
    return new Set(raw ? JSON.parse(raw) : [])
  } catch (_) {
    return new Set()
  }
}

export function resetSeenMarketplaceOffers() {
  seenOfferIds.value = new Set()
  try {
    sessionStorage.removeItem(SEEN_STORAGE_KEY)
  } catch (_) {}
}

function persistSeenOfferIds() {
  try {
    sessionStorage.setItem(SEEN_STORAGE_KEY, JSON.stringify([...seenOfferIds.value]))
  } catch (_) {}
}

const asArray = value => {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== 'object') return []
  return Object.values(value)
}

function normalizeListings(data) {
  return asArray(data).map(listing => ({
    ...listing,
    offers: asArray(listing.offers),
  }))
}

function handleListings(data) {
  listings.value = normalizeListings(data)
  listingsLoaded.value = true
}

async function refreshListings() {
  handleListings(await lua.overhaul_career_market_marketplace.getListings())
}

/** Local 1s tick so the expiry countdown moves between Lua pushes. */
function tickCountdowns() {
  const hasRunningTimer = listings.value.some(listing => listing.offers.some(offer => offer.secondsLeft > 0))
  if (!hasRunningTimer) return

  listings.value = listings.value.map(listing => ({
    ...listing,
    offers: listing.offers.map(offer => (
      offer.secondsLeft > 0 ? { ...offer, secondsLeft: offer.secondsLeft - 1 } : offer
    )),
  }))
}

/**
 * Which Sell tab to land on next. Set by screens that hand off to Sell — the vehicle info
 * page's "View N offers" and a finished sale — and consumed once by the Sell screen.
 */
const pendingSellTab = ref(null)

export function requestSellTab(tab) {
  pendingSellTab.value = tab
}

export function takeRequestedSellTab() {
  const tab = pendingSellTab.value
  pendingSellTab.value = null
  return tab
}

export function offerKey(listingId, offer, index) {
  return offer?.id != null ? `offer-${offer.id}` : `offer-${listingId}-${index}`
}

export function usePhoneMarketplaceListings({ menuOpen = false } = {}) {
  const { events } = useBridge()

  /** Every live offer, newest listing order preserved, tagged with its listing. */
  const offers = computed(() => listings.value.flatMap(listing =>
    listing.offers.map((offer, index) => ({
      offer,
      index,
      listing,
      key: offerKey(listing.id, offer, index),
      // marketplace.lua sets expiredViewCounter = 0 the moment an offer expires (nil while live)
      expired: offer.expiredViewCounter != null,
    })),
  ))

  const activeOffers = computed(() => offers.value.filter(o => !o.expired))
  const unreadCount = computed(() => activeOffers.value.filter(o => !seenOfferIds.value.has(o.key)).length)

  const offersForListing = listingId => offers.value.filter(o => o.listing.id === listingId)

  function markOffersSeen() {
    const next = new Set(seenOfferIds.value)
    for (const entry of offers.value) next.add(entry.key)
    seenOfferIds.value = next
    persistSeenOfferIds()
  }

  const isUnread = entry => !seenOfferIds.value.has(entry.key)

  onMounted(async () => {
    subscribers += 1
    if (subscribers === 1) {
      subscribedEvents = events
      events.on('marketplaceListingsUpdated', handleListings)
      tickTimer = setInterval(tickCountdowns, 1000)
    }
    if (menuOpen) lua.overhaul_career_market_marketplace.menuOpened(true)
    await refreshListings()
  })

  onUnmounted(() => {
    if (menuOpen) lua.overhaul_career_market_marketplace.menuOpened(false)
    subscribers = Math.max(0, subscribers - 1)
    if (subscribers === 0) {
      subscribedEvents?.off('marketplaceListingsUpdated', handleListings)
      subscribedEvents = null
      clearInterval(tickTimer)
      tickTimer = null
    }
  })

  return {
    listings,
    listingsLoaded,
    offers,
    activeOffers,
    offersForListing,
    unreadCount,
    isUnread,
    markOffersSeen,
    refreshListings,
  }
}

import { computed, markRaw, reactive, ref } from 'vue'
import { defineStore } from 'pinia'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
import { groupBrokerRows } from '../utils/brokerOfferGrouping'
export { groupBrokerRows }

export const markets = [
  { id: 'parcels', name: 'Parcel Cargo', hint: 'Packages & crates', icon: 'box' },
  { id: 'trailers', name: 'Trailer Loads', hint: 'Supplied trailers', icon: 'trailer' },
  { id: 'liquids', name: 'Liquids', hint: 'Fuel & water', icon: 'drop' },
  { id: 'bulk', name: 'Bulk Materials', hint: 'Sand, gravel & more', icon: 'bulk' },
  { id: 'cars', name: 'Car Hauling', hint: 'Vehicle transport', icon: 'car' },
  { id: 'specialty', name: 'Specialty Cargo', hint: 'Concrete & cash', icon: 'specialty' },
]
export const defaults = () => ({
  search: '',
  sort: 'near',
  radius: 0,
  trailers: [],
  subtype: '',
  arrangement: '',
  markets: [],
  pickupFac: '',
  destFac: '',
})

function cargoSortKey(row) {
  return row.trailerType || `${Number(row.quantity || 0)} ${row.unit || ''}`
}

function compareRows(a, b, sort) {
  if (sort === 'titleAz') return String(a.title || '').localeCompare(String(b.title || ''))
  if (sort === 'titleZa') return String(b.title || '').localeCompare(String(a.title || ''))
  if (sort === 'pickupAz') return String(a.from || '').localeCompare(String(b.from || ''))
  if (sort === 'pickupZa') return String(b.from || '').localeCompare(String(a.from || ''))
  if (sort === 'destAz') return String(a.to || '').localeCompare(String(b.to || ''))
  if (sort === 'destZa') return String(b.to || '').localeCompare(String(a.to || ''))
  if (sort === 'pickupFar') return (b.pickupDistance ?? -Infinity) - (a.pickupDistance ?? -Infinity)
  if (sort === 'payAsc') return (Number(a.estimatedPay ?? a.pay) || 0) - (Number(b.estimatedPay ?? b.pay) || 0)
  if (sort === 'cargoAz') return cargoSortKey(a).localeCompare(cargoSortKey(b))
  if (sort === 'cargoZa') return cargoSortKey(b).localeCompare(cargoSortKey(a))
  const rank = row => sort === 'pay' ? -(row.estimatedPay ?? row.pay) : sort === 'short' ? row.haulDistance ?? Infinity
    : sort === 'long' ? -(row.haulDistance ?? -Infinity) : sort === 'rate'
      ? row.pickupDistance != null && row.haulDistance != null ? -(row.estimatedPay ?? row.pay) / Math.max(1, row.pickupDistance + row.haulDistance) : Infinity
      : row.pickupDistance ?? Infinity
  return rank(a) - rank(b)
}

export function filterOffers(rows, market, filters, scope) {
  const query = filters.search.toLocaleLowerCase()
  const marketTypes = filters.markets?.length ? filters.markets : null
  return rows.filter(row => (market === 'all' || row.market === market)
    && (!marketTypes || marketTypes.includes(row.market))
    && (!scope || row.origin?.facId === scope)
    && (!filters.pickupFac || row.origin?.facId === filters.pickupFac)
    && (!filters.destFac || row.destination?.facId === filters.destFac)
    && (!filters.radius || row.pickupDistance != null && row.pickupDistance <= filters.radius)
    && (!filters.subtype || row.subtype === filters.subtype)
    && (!filters.arrangement || row.arrangement === filters.arrangement)
    && (!filters.trailers.length || filters.trailers.includes(row.trailerType))
    && (!query || [row.title, row.from, row.to, row.trailerType].some(v => String(v || '').toLocaleLowerCase().includes(query))))
    .sort((a, b) => compareRows(a, b, filters.sort) || String(a.id).localeCompare(String(b.id)))
}

export function brokerLocationOptions(rows, market, kind) {
  const map = new Map()
  for (const row of rows) {
    if (market !== 'all' && row.market !== market) continue
    const loc = kind === 'pickup' ? row.origin : row.destination
    const facId = loc?.facId
    const name = kind === 'pickup' ? row.from : row.to
    if (facId && name) map.set(facId, name)
  }
  const empty = kind === 'pickup' ? 'Any pickup location' : 'Any delivery location'
  return [{ value: '', label: empty }, ...[...map.entries()].sort((a, b) => a[1].localeCompare(b[1])).map(([value, label]) => ({ value, label }))]
}

/** Pickup-radius presets from actual offer distances on this board (avoids useless mile buckets). */
export function brokerRadiusOptions(rows, market) {
  const distances = rows
    .filter(row => (market === 'all' || row.market === market) && row.pickupDistance != null && row.pickupDistance > 0)
    .map(row => row.pickupDistance)
    .sort((a, b) => a - b)
  if (!distances.length) return []
  const max = distances[distances.length - 1]
  const at = fraction => distances[Math.min(distances.length - 1, Math.max(0, Math.floor(fraction * (distances.length - 1))))]
  const raw = [...new Set([at(0.25), at(0.5), at(0.75), max].map(v => Math.ceil(v)))]
    .filter(v => v > 0)
    .sort((a, b) => a - b)
  return raw.map(value => ({ value, maxDistance: value }))
}
// Availability and vehicle fit are independent: a load can be unlocked but need equipment.
export const isLocked = row => row.access?.state ? row.access.state === 'locked' : row.unlocked === false
export const accessReasons = row => Object.values(row.access?.reasons || {}).length
  ? Object.values(row.access.reasons) : isLocked(row) ? [{ label: row.lockedReason || 'Requirement unavailable' }] : []
export function unlockLevel(row) {
  const needs = accessReasons(row).map(r => Number(r.need)).filter(Number.isFinite)
  return needs.length ? Math.max(...needs) : Infinity
}
export function requirementProgress(reason) {
  if (!(Number(reason.need) > 0)) return null
  return Math.min(1, Math.max(0, Number(reason.progress?.percent) || 0))
}
export function fitBadge(row) {
  const fit = row.access?.fit
  const current = fit?.current || {}
  const reason = current.reason?.label || current.reason || current.label || row.requirement || ''
  if (current.state === 'compatible') return { label: 'Fits', reason: current.reason?.label || current.reason || 'Current vehicle is compatible', state: 'ok' }
  if (current.state !== 'incompatible') return { label: 'Fit unknown', reason: reason || 'Bring a vehicle to check compatibility', state: 'unknown' }
  const owned = Object.values(fit.owned || {}).find(r => r.state === 'compatible')
  if (owned) return owned.equipment === 'trailer'
    ? { label: 'Needs trailer', reason: reason || 'Use your compatible owned trailer', state: 'warn' }
    : { label: 'Does not fit', reason: `Use your compatible owned vehicle${reason ? ': ' + reason : ''}`, state: 'warn' }
  if (Object.values(fit.loaners || {}).some(r => r.state === 'compatible')) return { label: 'Needs loaner', reason: reason || 'Compatible rental equipment is available', state: 'warn' }
  return { label: 'Does not fit', reason: reason || 'Current vehicle cannot carry this load', state: 'warn' }
}
// Time left on a timed offer as m:ss, 'Expired' at zero, or '' when it does not expire.
export function offerTimeLeft(row, logisticsTime) {
  if (row.offerExpiresAt == null || logisticsTime == null) return ''
  const remaining = Math.max(0, Math.ceil(row.offerExpiresAt - logisticsTime))
  return remaining ? `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')}` : 'Expired'
}
export function offerBadges(row, logisticsTime) {
  const modifiers = Object.values(row.modifiers || {})
  const badges = modifiers.map(m => m.label || m.name || m.type).filter(Boolean)
  for (const type of ['timed', 'fragile']) if (row[type] && !modifiers.some(m => m.type === type)) badges.push(type)
  const out = [...new Set(badges)].map(label => String(label).replace(/^./, c => c.toUpperCase()))
  if (row.offerExpiresAt != null) {
    if (logisticsTime == null) out.push(`Offer ends at ${Math.round(row.offerExpiresAt)}s logistics time`)
    else {
      const left = offerTimeLeft(row, logisticsTime)
      out.push(left === 'Expired' ? 'Offer expired' : `Expires in ${left}`)
    }
  }
  return out
}
export function brokerOfferRows(rows, tab = 'available') {
  const visible = rows.filter(row => isLocked(row) === (tab === 'locked'))
  const order = new Map(visible.map((row, index) => [row.id, index]))
  // Never merge rows with different eligibility, equipment, presence or expiry.
  const buckets = new Map()
  for (const row of visible) {
    const key = JSON.stringify([row.access, row.lockedReason, !!row.atPickup, row.offerExpiresAt, row.modifiers, row.timed, row.fragile])
    if (!buckets.has(key)) buckets.set(key, [])
    buckets.get(key).push(row)
  }
  return [...buckets.values()].flatMap(group => groupBrokerRows(group)).sort((a, b) =>
    (tab === 'locked' ? unlockLevel(a) - unlockLevel(b) : 0)
    || Number(!!b.atPickup) - Number(!!a.atPickup)
    || order.get(a.id) - order.get(b.id))
}
export function groupedOfferCount(rows) { return brokerOfferRows(rows).length }
export function jobTimeline(row) {
  const delivered = row.status === 'complete'
  const pickedUp = delivered || row.status === 'active' && (row.inTransit == null || Number(row.inTransit) > 0)
  return [
    { label: 'Reserved', done: true },
    { label: 'Picked up', done: pickedUp },
    { label: 'Delivered', done: delivered },
  ]
}
export const usePhoneBrokerStore = defineStore('overhaulPhoneBroker', () => {
  const data = ref({ offers: [], jobs: [], plans: {}, stops: [], loaners: [], rentals: [] })
  const view = ref('markets'), market = ref('all'), selected = ref(null), expanded = ref(false)
  const availability = ref('available')
  // resultCount restarts the message timer when the same message repeats.
  const scope = ref(''), message = ref(''), resultCount = ref(0), pending = ref(false), loaded = ref(false), containers = ref([])
  const preferences = reactive({ last: null, filters: {} })
  const scrolls = reactive({})
  const filter = computed(() => preferences.filters[market.value] || defaults())
  const rows = computed(() => filterOffers(data.value.offers || [], market.value, filter.value, scope.value))
  const selectedRow = computed(() => selected.value == null ? undefined
    : [...(data.value.jobs || []), ...(data.value.offers || []), ...Object.values(data.value.plans || {})].find(r => r.id === selected.value))
  let preferencesLoaded = false, profileKey
  let requestSequence = 0, latestRequestId, waitingRequest
  let stateVersion = 0, rentalRequest = false
  function releaseRequest(result) {
    pending.value = false
    if (!waitingRequest) return
    clearTimeout(waitingRequest.timer)
    waitingRequest.resolve(result)
    waitingRequest = null
  }
  function rehydrate() {
    stateVersion++
    releaseRequest()
    latestRequestId = undefined
    message.value = ''
  }
  function receive(payload) {
    if (!payload) return
    if (payload.baseRevision != null) {
      if (payload.baseRevision !== data.value.revision) return
      const offers = new Map(data.value.offers.map(row => [row.id, row]))
      for (const patch of Object.values(payload.offerPatches || {})) {
        const row = { ...offers.get(patch.id), ...patch.values }
        for (const key of Object.values(patch.removedFields || {})) delete row[key]
        offers.set(patch.id, row)
      }
      payload = { ...payload, offers: Object.values(payload.offerOrder || {}).map(id => offers.get(id)).filter(Boolean) }
      delete payload.offerPatches
      delete payload.offerOrder
      delete payload.baseRevision
    }
    stateVersion++
    // Lua encodes empty tables as objects; normalize collections at the boundary.
    // These collections are complete Lua snapshots, replaced on every update.
    // Keep the envelope reactive for action locks without proxying every row.
    for (const key of ['offers', 'jobs', 'stops', 'loaners', 'rentals']) payload[key] = markRaw(Object.values(payload[key] || {}))
    payload.plans = markRaw(payload.plans || {})
    for (const job of [...payload.offers, ...payload.jobs]) job.vehicles = Object.values(job.vehicles || {})
    if (profileKey !== payload.profile) { rehydrate(); preferencesLoaded = false; profileKey = payload.profile; selected.value = null; scope.value = ''; view.value = 'markets'; availability.value = 'available' }
    if (data.value.busy && payload.busy === false) message.value = ''
    data.value = payload; loaded.value = true
    if (payload.busy === false && payload.requestId === latestRequestId) releaseRequest()
    if (!preferencesLoaded) {
      preferences.last = payload.preferences?.last || null
      preferences.filters = payload.preferences?.filters || {}
      for (const f of Object.values(preferences.filters)) {
        f.trailers = Object.values(f.trailers || {})
        f.markets = Object.values(f.markets || {})
      }
      preferencesLoaded = true
    }
  }
  async function refresh() {
    const version = stateVersion
    try {
      const payload = await callModLua('overhaul_phone_apps_logistics.requestBrokerState', data.value.revision)
      if (version === stateVersion) receive(payload)
    }
    catch { if (version === stateVersion) message.value = 'Unable to load Job Broker. Try refreshing.' }
  }
  function action(name, payload = {}) {
    if (pending.value || data.value.busy) return
    const requestId = `${Date.now()}:${++requestSequence}`
    latestRequestId = requestId
    rentalRequest = name.endsWith('Rental') || name === 'startHere' && data.value.loaners.some(row => row.id === payload.id)
    pending.value = true
    return new Promise(resolve => {
      const request = { resolve }
      waitingRequest = request
      // Give the broker's 60-second native-callback watchdog time to finish first.
      request.timer = setTimeout(() => {
        if (waitingRequest !== request) return
        releaseRequest()
        message.value = 'The action timed out. Check your loads before trying again.'
        void refresh()
      }, 65000)
      const send = async () => {
        try {
          const result = await callModLua('overhaul_phone_apps_logistics.brokerAction', name, { ...payload, requestId })
          if (waitingRequest !== request) return
          if (!result) throw new Error('Job Broker is unavailable')
          receiveResult(result)
        } catch {
          if (waitingRequest !== request) return
          releaseRequest()
          message.value = 'The action could not finish. Check your loads before trying again.'
          void refresh()
        }
      }
      void send()
    })
  }
  function savePreferences() {
    callModLua('overhaul_phone_apps_logistics.brokerAction', 'preferences', { value: JSON.parse(JSON.stringify(preferences)) })
      .catch(() => { message.value = 'Preferences could not be saved.' })
  }
  function chooseMarket(id) {
    market.value = id; view.value = 'loads'; selected.value = null; availability.value = 'available'
    preferences.last = id; preferences.filters[id] = { ...defaults(), ...preferences.filters[id] }
    savePreferences()
  }
  function updateFilter(key, value) {
    preferences.filters[market.value] = { ...defaults(), ...filter.value, [key]: value }; savePreferences()
  }
  function resetFilters() { preferences.filters[market.value] = defaults(); savePreferences() }
  function receiveResult(result) {
    if (result?.requestId !== latestRequestId) return
    stateVersion++
    message.value = result?.message || ''
    resultCount.value++
    if (typeof result?.busy === 'boolean') data.value.busy = result.busy
    if (result?.ok && result?.id && !rentalRequest) { selected.value = result.id; view.value = 'jobs' }
    releaseRequest(result)
  }
  return { data, availability, view, market, selected, expanded, scope, message, resultCount, pending, loaded, containers, preferences, scrolls,
    filter, rows, selectedRow, receive, refresh, action, chooseMarket, updateFilter, resetFilters, receiveResult, rehydrate }
})

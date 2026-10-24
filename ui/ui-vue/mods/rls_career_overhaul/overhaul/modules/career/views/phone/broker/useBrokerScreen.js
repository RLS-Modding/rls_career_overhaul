// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { usePhoneViewFocus } from '../../../components/phone/usePhoneViewFocus.js'
import { refocusIfLost } from '../../../composables/useScreenEntryFocus.js'
import { usePhoneScreen } from '../../../composables/usePhoneScreen'
import { computed, defineAsyncComponent, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { openPhoneRoute } from '../../../utils/phoneNavigation'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'
import { useBridge } from '@/bridge'
import { brokerLocationOptions, brokerRadiusOptions, groupBrokerRows, groupedOfferCount, markets as fallbackMarkets, brokerOfferRows, isLocked, accessReasons, requirementProgress, fitBadge, offerBadges, offerTimeLeft, unlockLevel, jobTimeline, usePhoneBrokerStore } from '../../../stores/phoneBrokerStore'
import { callModLua } from '../../../utils/installLuaBridgeFallbacks'
import { useActionFocus } from '../../../composables/useActionFocus.js'
import { acquireScope } from '../../../utils/luaScopes'
import { addPopup } from '@/services/popup'
import { groupBrokerJobs } from '../../../utils/brokerJobGrouping.js'

export function useBrokerScreen() {
  // The market chooser does not draw a map. Load its renderer with the details.
  const RouteMap = defineAsyncComponent(() => import('../../../components/RouteMap.vue'))
  const CargoLoadPopup = defineAsyncComponent(() => import('../../../components/cargoOverview/CargoLoadPopup.vue'))
  let discardPopup = null
  const preparingDiscard = ref(false)

  // This screen loads through the mod's own Lua call path, as it always has.
  const callModLuaLoader = { extensions: { load: name => callModLua('extensions.load', name) } }
  const s = usePhoneBrokerStore(), route = useRoute(), router = useRouter(), events = useEvents(), { units } = useBridge()
  usePhoneScreen({ title: () => heading.value, onBack: back, expanded: () => s.expanded })
  const markets = computed(() => Object.values(s.data.markets || {}).length ? Object.values(s.data.markets) : fallbackMarkets)
  const jobsTab = ref('loads')
  const expandedJobStacks = ref(new Set())
  const isJobStack = row => s.view === 'jobs' && row.groupCount > 1
  const stackExpanded = row => expandedJobStacks.value.has(row.groupKey || row.id)
  async function toggleJobStack(row, opener = null) {
    const expanded = new Set(expandedJobStacks.value)
    if (expanded.has(row.groupKey || row.id)) expanded.delete(row.groupKey || row.id)
    else expanded.add(row.groupKey || row.id)
    expandedJobStacks.value = expanded
    await nextTick()
    await refocusIfLost(() => opener || [...(listEl.value?.querySelectorAll('.load-row') || [])].find(button => button.dataset.fk === (row.groupKey || row.id)), { force: true })
  }
  const screenRef = ref(null)
  const actionFocus = useActionFocus(screenRef)
  const openRequirements = () => callModLua('extensions.ui_router.navigate', 'phone-skills-details', { skillId: 'logistics' })
  function startHere(row) {
    if (working.value || isLocked(row)) return
    return actionFocus.run(() => s.action('startHere', { id: row.id, container: container.value || undefined, cars: selectedCars.value }))
  }
  const focusView = usePhoneViewFocus(screenRef, () => `${s.view}:${s.availability}:${jobsTab.value}:${s.selected || ''}`, root => s.selected ? root?.querySelector('.detail-pane') : root?.querySelector('.load-list, .market-grid, .loaners') || root)
  function changeTab(delta) {
    const tabs = ['markets', 'jobs', 'loaners']
    const index = Math.max(0, tabs.indexOf(s.view))
    s.selected = null; s.view = tabs[(index + delta + tabs.length) % tabs.length]
  }
  const openEmployment = () => openPhoneRoute(router, 'phone-employment')
  const listEl = ref(null), container = ref(''), selectedCars = ref([]), confirmingAbandon = ref(false)
  const rowLimit = ref(100)
  // Filters open as a sheet over the load list, like Sort.
  const filtersOpen = ref(false)
  // Offers that hand you a vehicle (trailers) show that vehicle; the rest show where the work starts.
  const rowImage = row => row?.vehiclePreview || row?.originPreview || null
  const routePreview = ref(null), routeLoading = ref(false), planPreview = ref(null), planLoading = ref(false)
  let previewRequest = 0
  async function loadRoutePreview() {
    const id = s.selectedRow?.id
    routePreview.value = null
    if (!id) return
    const request = ++previewRequest
    routeLoading.value = true
    try { const r = await callModLua('overhaul_phone_apps_logistics.requestRoutePreview', id); if (request === previewRequest) routePreview.value = r && r.legs ? r : null }
    catch { if (request === previewRequest) routePreview.value = null }
    finally { if (request === previewRequest) routeLoading.value = false }
  }
  async function loadPlanPreview() {
    planLoading.value = true
    try { const r = await callModLua('overhaul_phone_apps_logistics.requestPlanPreview'); planPreview.value = r && r.legs ? r : null }
    catch { planPreview.value = null }
    finally { planLoading.value = false }
  }
  watch(() => s.selectedRow?.id, loadRoutePreview)
  watch(() => [s.view, jobsTab.value, s.data.stops.map(x => x.id).join(',')], ([view, tab]) => { if (view === 'jobs' && tab === 'route') loadPlanPreview() }, { immediate: true })
  const renderedRows = computed(() => visibleRows.value.slice(0, rowLimit.value))
  watch(() => [s.market, s.filter, s.view, s.availability], () => { rowLimit.value = 100 })
  let refreshTimer, containerTimer, messageTimer
  watch(() => [s.message, s.resultCount], ([message]) => {
    clearTimeout(messageTimer)
    if (message) messageTimer = setTimeout(() => { if (s.message === message) s.message = '' }, 8000)
  })
  const containerLoading = ref(false), containerError = ref('')
  let containerRequest = 0
  const cargoOptions = [{ value: '', label: 'All cargo' }, { value: 'cement', label: 'Concrete' }, { value: 'cash', label: 'Cash' }]
  const arrangementOptions = [{ value: '', label: 'Any' }, { value: 'supplied', label: 'Trailer supplied' }, { value: 'own', label: 'Bring your own' }]
  const sortOptions = [
    { value: 'near', label: 'Nearest pickup' },
    { value: 'pay', label: 'Highest payout' },
    { value: 'short', label: 'Shortest haul' },
    { value: 'long', label: 'Longest haul' },
    { value: 'rate', label: 'Best pay per distance' },
    { value: 'titleAz', label: 'Load name A → Z' },
    { value: 'pickupAz', label: 'Pickup location A → Z' },
    { value: 'pickupZa', label: 'Pickup location Z → A' },
    { value: 'destAz', label: 'Delivery location A → Z' },
    { value: 'destZa', label: 'Delivery location Z → A' },
  ]
  const containerOptions = computed(() => [{ value: '', label: 'Choose cargo space' }, ...s.containers.map(c => ({ value: c.key, label: `${c.name} (${c.free} free)` }))])
  const working = computed(() => s.pending || s.data.busy)
  const marketName = computed(() => markets.value.find(m => m.id === s.market)?.name || 'All work')
  const heading = computed(() => s.data.employed && s.data.employerName ? `Employed at ${s.data.employerName}` : s.view === 'markets' ? 'Find work' : s.view === 'jobs' ? 'My Loads' : s.view === 'loaners' ? 'Loaners' : marketName.value)
  const activeJobs = computed(() => s.data.jobs.filter(j => !['complete', 'cancelled'].includes(j.status)))
  const availableCount = computed(() => brokerOfferRows(s.rows).length)
  const lockedCount = computed(() => brokerOfferRows(s.rows, 'locked').length)
  // Available loads sit under a heading for their pickup, with the distance to
  // it, instead of naming it in every card. Each pickup's loads stay together; the pickup with the first load
  // in the chosen sort leads, and loads keep that sort inside their pickup.
  const groupsByPickup = computed(() => s.view === 'loads' && s.availability === 'available' && !s.expanded)
  const pickupKey = j => j?.origin?.facId || j?.from || ''
  function keepPickupsTogether(rows) {
    const byPickup = new Map()
    for (const row of rows) {
      if (!byPickup.has(pickupKey(row))) byPickup.set(pickupKey(row), [])
      byPickup.get(pickupKey(row)).push(row)
    }
    return [...byPickup.values()].flat()
  }
  const visibleRows = computed(() => {
    if (s.view === 'jobs') return groupBrokerJobs([...activeJobs.value].sort((a, b) => Number(jobTimeline(a)[1].done) - Number(jobTimeline(b)[1].done)), row => jobTimeline(row)[1].done)
    const rows = brokerOfferRows(s.rows, s.availability)
    return groupsByPickup.value ? keepPickupsTogether(rows) : rows
  })
  // The heading for a pickup's first load: its name, and the pickup's distance
  // shaped like a row so BrokerPickup can draw it (You're here when at any of them).
  function pickupHeading(row, index) {
    if (!groupsByPickup.value) return null
    if (index && pickupKey(renderedRows.value[index - 1]) === pickupKey(row)) return null
    const loads = visibleRows.value.filter(other => pickupKey(other) === pickupKey(row))
    const distances = loads.map(load => Number(load.pickupDistance)).filter(Number.isFinite)
    return {
      name: row.from || 'Other pickups',
      pickup: { atPickup: loads.some(load => load.atPickup), pickupDistance: distances.length ? Math.min(...distances) : null },
    }
  }
  // Locked loads group under the level they unlock at; the heading carries the
  // requirement and your progress once, so the cards under it do not repeat it.
  const levelReason = row => accessReasons(row).find(reason => reason.kind === 'level' && reason.need != null)
  function unlockHeading(row, index) {
    if (s.view !== 'loads' || s.availability !== 'locked') return null
    const level = unlockLevel(row)
    if (index && unlockLevel(renderedRows.value[index - 1]) === level) return null
    const reason = Number.isFinite(level) ? levelReason(row) : null
    return reason ? { text: requirementText(reason), reason } : { text: 'Other requirements', reason: null }
  }
  function requirementText(reason) {
    const label = reason.label || 'Requirement unavailable'
    if (reason.kind === 'level' && reason.need != null) return `${label.replace(/ required$/i, '')} (you're level ${reason.have ?? 'unknown'})`
    return reason.need == null ? label : `${label} · Need ${reason.need}, have ${reason.have ?? 'Unknown'}`
  }
  // My Loads group by stage, which replaces the per-card timeline.
  const jobStage = row => jobTimeline(row)[1].done ? 'Picked up' : 'To pick up'
  function stageHeading(row, index) {
    if (s.view !== 'jobs') return ''
    if (index && jobStage(renderedRows.value[index - 1]) === jobStage(row)) return ''
    return jobStage(row)
  }
  const selectedListRow = computed(() => {
    if (!s.selected) return null
    if (s.view === 'jobs') return s.selectedRow || null
    return visibleRows.value.find(r => r.id === s.selected || r.groupOfferIds?.includes(s.selected)) || null
  })
  const filterCount = computed(() => Number(!!s.filter.radius)
    + Number(!!s.filter.subtype)
    + Number(!!s.filter.arrangement)
    + Number(!!s.filter.trailers.length)
    + Number(!!s.filter.pickupFac)
    + Number(!!s.filter.destFac)
    + Number(s.market === 'all' && !!s.filter.markets?.length))
  const trailerTypes = computed(() => [...new Set(s.data.offers.filter(r => (s.market === 'all' || r.market === s.market) && r.trailerType).map(r => r.trailerType))].sort())
  const pickupLocationOptions = computed(() => brokerLocationOptions(s.data.offers || [], s.market, 'pickup'))
  const destLocationOptions = computed(() => brokerLocationOptions(s.data.offers || [], s.market, 'delivery'))
  const radiusPresets = computed(() => brokerRadiusOptions(s.data.offers || [], s.market))
  const effectiveRadius = computed(() => {
    const r = s.filter.radius
    if (!r) return 0
    const presets = radiusPresets.value.map(p => p.value)
    if (presets.includes(r)) return r
    const next = presets.find(v => v >= r)
    return next ?? presets[presets.length - 1] ?? 0
  })
  const radiusDropdownItems = computed(() => {
    const items = [{ value: 0, label: 'Any distance' }]
    for (const preset of radiusPresets.value) {
      items.push({ value: preset.value, label: `Within ${dist(preset.value)}` })
    }
    const r = s.filter.radius
    if (r && !items.some(i => i.value === r)) {
      items.push({ value: r, label: `Within ${dist(r)} (saved)` })
    }
    return items
  })
  // Market glyphs come from the game's own cargo tabs and material data (cardboardBox / smallTrailer / keys1 / droplet / rocks).
  const MARKET_ICONS = { parcels: 'cardboardBox', trailers: 'smallTrailer', liquids: 'droplet', bulk: 'rocks', cars: 'keys1', specialty: 'concreteRoadBlock' }
  const marketIcon = id => icons[MARKET_ICONS[id]] || icons.cardboardBox
  // Vanilla vehicle previews stand in for each market (served from the game's vehicle content).
  const MARKET_IMAGES = { parcels: '/vehicles/md_series/md_60_cargobox.jpg', trailers: '/vehicles/dryvan/53ft.jpg', liquids: '/vehicles/tanker/diesel_3.jpg', bulk: '/vehicles/us_semi/t83s_dump.jpg', cars: '/vehicles/us_semi/t83s_rollback.jpg', specialty: '/vehicles/us_semi/t83s_mixer.jpg' }
  const marketImage = id => MARKET_IMAGES[id] || MARKET_IMAGES.parcels
  const loadCount = value => value + (value === 1 ? ' load' : ' loads')
  const money = value => Math.round(Number(value) || 0).toLocaleString()
  const rate = value => Number(value || 0).toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})
  function dist(value) {
    if (value == null) return '\u2014'
    const metres = Math.max(Number(value) || 0, 1)
    // Stock imperial length jumps straight from feet to miles; use its minor unit for short hops.
    const unit = metres < 160 ? 'lengthMinor' : 'length'
    if (units?.buildString) return units.buildString(unit, metres, metres < 160 ? 0 : metres < 1000 ? 2 : 1)
    return metres < 1000 ? Math.round(metres) + ' m' : (metres / 1000).toFixed(1) + ' km'
  }

  function isMarketFilterActive(id) {
    const selected = s.filter.markets || []
    return !selected.length || selected.includes(id)
  }
  const tableColumns = [
    { key: 'load', label: 'Load / route', span: 2, start: true, ascLabel: 'Sort load name A to Z', descLabel: 'Sort load name Z to A' },
    { key: 'pickup', label: 'Pickup', hint: 'Distance to pickup', ascLabel: 'Sort nearest pickup first', descLabel: 'Sort farthest pickup first' },
    { key: 'haul', label: 'Haul', ascLabel: 'Sort shortest haul first', descLabel: 'Sort longest haul first' },
    { key: 'cargo', label: 'Cargo', hint: 'Cargo or trailer type', ascLabel: 'Sort cargo A to Z', descLabel: 'Sort cargo Z to A' },
    { key: 'pay', label: 'Pay', ascLabel: 'Sort lowest pay first', descLabel: 'Sort highest pay first' },
  ]
  const COLUMN_SORTS = {
    load: { asc: 'titleAz', desc: 'titleZa' },
    pickup: { asc: 'near', desc: 'pickupFar' },
    haul: { asc: 'short', desc: 'long' },
    cargo: { asc: 'cargoAz', desc: 'cargoZa' },
    pay: { asc: 'payAsc', desc: 'pay' },
  }
  function setColumnSort(column, direction) {
    const next = COLUMN_SORTS[column]?.[direction]
    if (next) s.updateFilter('sort', next)
  }
  function columnSortActive(column, direction) {
    return COLUMN_SORTS[column]?.[direction] === s.filter.sort
  }
  function toggleMarketFilter(id) {
    const selected = [...(s.filter.markets || [])]
    const allIds = markets.value.map(m => m.id)
    let next
    if (!selected.length) {
      next = allIds.filter(x => x !== id)
    } else if (selected.includes(id)) {
      next = selected.filter(x => x !== id)
    } else {
      next = [...selected, id]
    }
    if (next.length === 0 || next.length === allIds.length) next = []
    s.updateFilter('markets', next)
  }
  function capacityText(row) { return Object.values(row.capacity || {}).map(c => `${Number(c.amount || 0).toLocaleString()} ${{parcel:'slots',fluid:'L liquid',dryBulk:'L bulk',cement:'L concrete',cash:'secure units'}[c.type] || c.type}`).join(', ') }
  function fact(row) { return row.trailerType || `${Number(row.quantity || 0).toLocaleString()} ${row.unit || ''}` }
  function pct(part) { const r = s.selectedRow; const total = (r?.delivered || 0) + (r?.inTransit || 0) + (r?.remaining || 0); return total ? (100 * (Number(part) || 0) / total).toFixed(1) + '%' : '0%' }
  // Requirement strings arrive as "Enclosed cargo · Logistics level 8"; show them as labelled facts instead.
  // Listed pay includes the Logistics level bonus the drop-off adds; clean-delivery bonuses come on top.
  const payOf = row => Number(row?.estimatedPay ?? row?.pay) || 0
  const detailFacts = computed(() => {
    const r = s.selectedRow; if (!r) return []
    const out = [{ k: 'Cargo', v: fact(r) }]
    if (r.requirement) out.push({ k: 'Needs', v: r.requirement })
    out.push({ k: 'Equipment', v: r.arrangement === 'supplied' ? 'Trailer supplied' : 'Bring your own', cls: r.arrangement === 'supplied' ? 'accent' : '' })
    if (Number(r.levelBonus) > 0) {
      out.push({ k: 'Base pay', v: money(r.basePay ?? r.pay), money: true })
      out.push({ k: 'Level bonus', v: '+' + Math.round(r.levelBonus * 100) + '%', cls: 'accent' })
    }
    return out
  })

  function legDistance(stop) { const leg = (s.data.route?.legs || []).find(l => l.stopId === stop.id); return leg && leg.distance != null ? dist(leg.distance) : '—' }
  function statusName(value) { return ({ reserved: 'Reserved', active: 'In progress', complete: 'Delivered' })[value] || value }
  function rememberScroll() { if (listEl.value) s.scrolls[s.view + ':' + s.market + ':' + s.availability] = listEl.value.scrollTop }
  async function closeDetail(returnGroupKey = null) {
    const id = String(s.selected)
    let returnKey = id
    s.selected = null
    if (s.view === 'jobs') {
      jobsTab.value = 'loads'
      const index = visibleRows.value.findIndex(row => row.groupJobs?.some(job => job.id === id) || (returnGroupKey && row.groupKey === returnGroupKey))
      if (index >= 0) {
        rowLimit.value = Math.max(rowLimit.value, index + 1)
        const stack = visibleRows.value[index]
        returnKey = stack.groupKey || stack.id
        if (stack.groupCount > 1) expandedJobStacks.value = new Set([...expandedJobStacks.value, returnKey])
      }
    }
    await nextTick()
    if (listEl.value) listEl.value.scrollTop = s.scrolls[s.view + ':' + s.market + ':' + s.availability] || 0
    await refocusIfLost(() => {
      const buttons = [...(listEl.value?.querySelectorAll('.load-row, .stack-job') || [])]
      return buttons.find(row => row.dataset.fk === 'job:' + id) || buttons.find(row => row.dataset.fk === returnKey)
    }, { force: true })
  }
  function select(row) {
    if (isJobStack(row)) return toggleJobStack(row)
    confirmingAbandon.value = false; rememberScroll(); s.selected = row.id; container.value = ''; selectedCars.value = []
  }
  function refreshContainers() {
    if (containerLoading.value) return
    const request = ++containerRequest
    containerLoading.value = true; containerError.value = ''; container.value = ''; s.containers = []
    containerTimer = setTimeout(() => {
      if (request !== containerRequest) return
      containerLoading.value = false
      containerError.value = 'Cargo scan timed out. Try Refresh equipment.'
    }, 8000)
    callModLua('overhaul_phone_apps_logistics.requestBrokerContainers').catch(() => {
      if (request !== containerRequest) return
      clearTimeout(containerTimer); containerLoading.value = false
      containerError.value = 'Could not read nearby cargo space. Try Refresh equipment.'
    })
  }
  watch([() => s.selectedRow?.id, () => s.selectedRow?.atPickup], () => {
    clearTimeout(containerTimer); containerRequest++; containerLoading.value = false
    container.value = ''; s.containers = []; containerError.value = ''
    if (s.selectedRow?.atPickup && ['parcel', 'material'].includes(s.selectedRow.kind)) refreshContainers()
  })
  function receiveContainers(data) {
    if (!s.selectedRow?.atPickup || !['parcel', 'material'].includes(s.selectedRow.kind)) return
    clearTimeout(containerTimer); containerRequest++; containerLoading.value = false; containerError.value = ''
    s.containers = Object.values(data || {})
    if (!s.containers.some(c => c.key === container.value)) container.value = ''
  }
  // Bulk parcel loading: every reserved parcel waiting at this pickup is listed, split across the nearby
  // boxes by slot size (largest parcel first, into the tightest box it fits), and loaded with one commit.
  // Tapping a box chip moves one parcel to the next box with room; unticking leaves parcels at the pickup.
  // Reserving from a "6×" group: pick how many identical offers to take (defaults to all of them).
  const reserveAmount = ref(1)
  const reserveGroup = computed(() => s.selectedRow && !s.selectedRow.status ? (selectedListRow.value?.groupCount || 1) : 1)
  const reserveMax = computed(() => Math.max(1, reserveGroup.value))
  const reserveSlots = n => s.selectedRow?.unit === 'slots' ? `${n * slotsOf(s.selectedRow)} slots` : `${n} ${n === 1 ? 'load' : 'loads'}`
  watch(() => [s.selected, reserveMax.value], () => { reserveAmount.value = reserveMax.value })
  function stepReserve(delta) { reserveAmount.value = Math.min(reserveMax.value, Math.max(1, reserveAmount.value + delta)) }
  function reserveSelected() {
    const r = s.selectedRow
    if (!r) return
    reserveAmount.value = Math.min(reserveMax.value, Math.max(1, reserveAmount.value))
    if (reserveAmount.value <= 1) { s.action('reserve', { id: r.id, signature: r.signature }); return }
    const ids = [r.id, ...(selectedListRow.value?.groupOfferIds || []).filter(id => id !== r.id)].slice(0, reserveAmount.value)
    const items = ids.map(id => ({ id, signature: (s.data.offers.find(o => o.id === id) || {}).signature })).filter(i => i.signature)
    s.action('reserveMany', { items })
  }
  const loadPlan = ref({}), loadSkip = ref({})
  const showLoader = computed(() => !!(s.selectedRow?.atPickup && s.selectedRow.kind === 'parcel' && pickupParcels.value.length))
  const slotsOf = j => Math.max(0, Number(j?.quantity) || 0)
  const pickupParcels = computed(() => {
    const r = s.selectedRow
    if (!r || r.kind !== 'parcel' || !r.atPickup || (r.status && r.status !== 'reserved')) return []
    const here = j => j.kind === 'parcel' && j.atPickup && j.unlocked !== false && pickupKey(j) === pickupKey(r)
    const jobs = activeJobs.value.filter(j => here(j) && j.status === 'reserved')
    // Browsing the market at the pickup: parcels on offer here can be loaded straight away ("Load now").
    const offers = r.status ? [] : (s.data.offers || []).filter(o => here(o) && !o.status)
    const list = [...jobs, ...offers]
    return [...list.filter(j => j.id === r.id), ...list.filter(j => j.id !== r.id)]
  })
  const parcelBoxes = computed(() => s.containers.filter(c => !c.types || c.types.parcel))
  const boxByKey = key => parcelBoxes.value.find(c => c.key === key)
  // All boxes on one vehicle: name it once above the boxes instead of on every row.
  const loadVehicle = computed(() => { const names = new Set(parcelBoxes.value.map(c => c.vehName || '')); return names.size === 1 ? [...names][0] : '' })
  const boxIndex = key => parcelBoxes.value.findIndex(c => c.key === key)
  const boxCap = c => Math.max(Number(c.capacity) || 0, Number(c.free) || 0)
  const boxHeld = c => Math.max(0, boxCap(c) - (Number(c.free) || 0))
  const boxUse = (key, except) => pickupParcels.value.reduce((n, j) => n + (j.id !== except && !loadSkip.value[j.id] && loadPlan.value[j.id] === key ? slotsOf(j) : 0), 0)
  const boxLeft = c => (Number(c.free) || 0) - boxUse(c.key)
  const roomFor = (c, j) => (Number(c.free) || 0) - boxUse(c.key, j.id) >= slotsOf(j)
  const canMove = j => parcelBoxes.value.some(c => c.key !== loadPlan.value[j.id] && roomFor(c, j))
  const share = (n, of) => of > 0 ? `${Math.min(100, Math.max(0, (n / of) * 100))}%` : '0%'
  // Short box names ("Cargo Box") unless two vehicles carry the same one, then the full "Vehicle Box" label.
  function boxLabel(c) {
    if (!c) return ''
    const short = c.boxName || c.name
    return parcelBoxes.value.filter(x => (x.boxName || x.name) === short).length > 1 ? c.name : short
  }
  function autoSplit() {
    const plan = {}, left = Object.fromEntries(parcelBoxes.value.map(c => [c.key, Number(c.free) || 0]))
    const queue = pickupParcels.value.filter(j => !loadSkip.value[j.id]).sort((a, b) => slotsOf(b) - slotsOf(a))
    for (const j of queue) {
      const fit = parcelBoxes.value.filter(c => left[c.key] >= slotsOf(j)).sort((a, b) => left[a.key] - left[b.key])[0]
      plan[j.id] = fit ? fit.key : ''
      if (fit) left[fit.key] -= slotsOf(j)
    }
    loadPlan.value = plan
  }
  function cycleBox(j) {
    const boxes = parcelBoxes.value, at = boxIndex(loadPlan.value[j.id])
    for (let step = 1; step <= boxes.length; step++) {
      const c = boxes[(at + step + boxes.length) % boxes.length]
      if (roomFor(c, j)) { loadPlan.value = { ...loadPlan.value, [j.id]: c.key }; return }
    }
  }
  // Identical parcels (same title, route, pay and slot size) show as one "3×" row like the load list.
  // Each parcel is still its own job, so a group can be split: some in one box, the rest in another.
  const pickupGroups = computed(() => groupBrokerRows(pickupParcels.value, { byStatus: true }))
  const jobOf = id => pickupParcels.value.find(j => j.id === id)
  const groupJobs = g => g.groupOfferIds.map(jobOf).filter(Boolean)
  const groupLoad = g => groupJobs(g).filter(j => !loadSkip.value[j.id]).length
  const groupStuck = g => groupJobs(g).filter(j => !loadSkip.value[j.id] && !boxByKey(loadPlan.value[j.id])).length
  function groupSplits(g) {
    const by = new Map()
    for (const j of groupJobs(g)) {
      const key = loadPlan.value[j.id]
      if (loadSkip.value[j.id] || !boxByKey(key)) continue
      const entry = by.get(key) || { key, n: 0, job: j }
      entry.n++; entry.job = j; by.set(key, entry)
    }
    return [...by.values()].sort((a, b) => boxIndex(a.key) - boxIndex(b.key))
  }
  // Keep a parcel in its box if it still fits, otherwise put it in the tightest box with room.
  function fitJob(j) {
    const cur = boxByKey(loadPlan.value[j.id])
    if (cur && roomFor(cur, j)) return
    const fit = parcelBoxes.value.filter(c => roomFor(c, j)).sort((a, b) => boxLeft(a) - boxLeft(b))[0]
    loadPlan.value = { ...loadPlan.value, [j.id]: fit ? fit.key : '' }
  }
  function setSkip(j, skip) { loadSkip.value = { ...loadSkip.value, [j.id]: skip }; if (!skip) fitJob(j) }
  function toggleGroup(g) { const on = groupLoad(g) > 0; for (const j of groupJobs(g)) setSkip(j, on) }
  function stepGroup(g, delta) {
    const jobs = groupJobs(g)
    if (delta > 0) { const j = jobs.find(x => loadSkip.value[x.id]); if (j) setSkip(j, false); return }
    const on = jobs.filter(x => !loadSkip.value[x.id])
    const j = on.find(x => !boxByKey(loadPlan.value[x.id])) || on[on.length - 1]
    if (j) setSkip(j, true)
  }
  const loadItems = computed(() => pickupParcels.value.filter(j => !loadSkip.value[j.id] && boxByKey(loadPlan.value[j.id])))
  watch(() => [s.selectedRow?.id, s.selectedRow?.status], () => {
    const keep = new Set(selectedListRow.value?.groupOfferIds || [s.selectedRow?.id])
    loadSkip.value = Object.fromEntries(pickupParcels.value.filter(j => !j.status && !keep.has(j.id)).map(j => [j.id, true]))
    autoSplit()
  })
  watch(() => [parcelBoxes.value.map(c => `${c.key}:${c.free}`).join(','), pickupParcels.value.map(j => j.id).join(',')], autoSplit)
  // Parcels leaving the pickup list (loaded, or a skipped one left behind) change box space: rescan.
  watch(() => [s.selectedRow?.id, pickupParcels.value.map(j => j.id).join(',')], ([id, now], [idBefore, before] = []) => {
    if (id === idBefore && now !== before && now) refreshContainers()
  })
  function loadParcels() {
    const picked = loadItems.value
    if (!picked.length) return
    if (picked.every(j => j.status)) { s.action('pickupBatch', { items: picked.map(j => ({ id: j.id, container: loadPlan.value[j.id] })) }); return }
    s.action('loadHere', { items: picked.map(j => j.status ? { id: j.id, container: loadPlan.value[j.id] } : { offer: j.id, signature: j.signature, container: loadPlan.value[j.id] }) })
  }
  // Label and hint for the load button, shared by My Loads (reserved) and the market ("Load now").
  const loadStep = computed(() => {
    if (!parcelBoxes.value.length) return { label: 'No cargo space nearby', hint: 'Bring a vehicle with room for this cargo', disabled: true }
    const items = loadItems.value, slots = items.reduce((n, j) => n + slotsOf(j), 0), boxes = new Set(items.map(j => loadPlan.value[j.id])).size
    const stuck = pickupParcels.value.filter(j => !loadSkip.value[j.id] && !loadPlan.value[j.id]).length
    const total = pickupParcels.value.length, loads = pickupGroups.value.filter(g => groupLoad(g)).length
    const market = !s.selectedRow?.status
    // In My Loads the button covers every parcel reserved here, not just the selected load, so say so.
    const label = !items.length ? 'Nothing to load' : market ? `Load ${items.length === 1 ? 'parcel' : items.length + ' parcels'} now` : total === 1 ? 'Load parcel' : items.length === total ? (total === 2 ? 'Load both parcels' : `Load all ${total} parcels`) : `Load ${items.length} of ${total} parcels`
    const into = `${slots} ${slots === 1 ? 'slot' : 'slots'} into ${boxes === 1 ? boxLabel(boxByKey(loadPlan.value[items[0]?.id])) : boxes + ' boxes'}`
    return { label, disabled: !items.length,
      hint: !items.length ? 'Tick the parcels to load' : `${loads > 1 ? `${loads} loads, ` : ''}${into}${stuck ? `, ${stuck} won't fit` : ''}` }
  })
  // Stack summaries only expand. Details and destructive actions always own one job.
  const selectedJobIds = computed(() => s.selectedRow?.status ? [s.selectedRow.id] : [])
  const abandonFine = computed(() => s.selectedRow?.status ? Number(s.selectedRow.abandonFine) || 0 : 0)
  async function cancelReservation() {
    const ids = selectedJobIds.value
    if (!ids.length) return
    const returnGroupKey = visibleRows.value.find(row => row.groupJobs?.some(job => ids.includes(job.id)))?.groupKey
    const result = await s.action('cancel', { id: ids[0] })
    if (result?.ok && ids.includes(s.selected)) await closeDetail(returnGroupKey)
  }
  async function abandon() {
    if (preparingDiscard.value || discardPopup) return
    const ids = selectedJobIds.value.slice()
    if (!ids.length) return
    preparingDiscard.value = true
    try {
      const quote = await callModLua('overhaul_phone_apps_logistics.requestDiscardGroups', ids)
      if (isUnmounted) return
      if (!quote?.ok) { s.message = quote?.message || 'Unable to read loaded cargo.'; return }
      const groups = Object.values(quote.groups || {})
      if (groups.length) {
        confirmingAbandon.value = false
        const first = groups[0]
        discardPopup = addPopup(CargoLoadPopup, {
          discardGroups: groups,
          cargo: { name: groups.length === 1 ? first.name : 'Selected work', ids: first.ids, targetLocations: [],
            throwAwayInfo: { penalty: first.penalty, location: { type: 'deleted' } } },
          discardHandler: selections => s.action('discardSelectedCargo', { token: quote.token, selections }),
        })
        await discardPopup.promise
        return
      }
      // Vehicle-delivery tasks and orders with nothing loaded retain their native
      // whole-job confirmation. They have no cargo quantities the picker can move.
      if (!confirmingAbandon.value) { confirmingAbandon.value = true; return }
      const result = await s.action('abandon', { id: ids[0] })
      if (result?.ok) s.selected = null
      confirmingAbandon.value = false
    } catch { s.message = 'Unable to read loaded cargo. Try again.' }
    finally { preparingDiscard.value = false; discardPopup = null }
  }
  function collect() { s.action('pickup', { id: s.selected, container: container.value, cars: selectedCars.value }) }
  // The orange button is always the next thing to do for this load, so the job reads as a guided
  // sequence: drive to the pickup, stage / bring out / load, drive to the delivery, hand over.
  const nextStep = computed(() => {
    const r = s.selectedRow
    if (!r || !r.status || r.status === 'complete') return null
    const nav = leg => () => s.action('navigate', { id: r.id, leg })
    const cars = r.vehicles || []
    const pendingCars = cars.filter(c => !c.status || c.status === 'pending')
    const stagedCars = cars.filter(c => c.status === 'staged')
    let needsPickup
    if (r.kind === 'cars') needsPickup = !stagedCars.length && (pendingCars.length > 0 || !cars.length)
    else if (r.kind === 'trailer') needsPickup = r.status === 'reserved'
    else needsPickup = r.status === 'reserved' || (!(Number(r.inTransit) > 0) && Number(r.remaining) > 0)
    if (needsPickup) {
      if (!r.atPickup) return { key: 'toPickup', label: 'Navigate to pickup', hint: `Drive to ${r.from || 'the pickup'}`, run: nav('pickup') }
      if (r.kind === 'cars') {
        const picked = selectedCars.value.filter(k => pendingCars.some(c => c.key === k))
        const count = picked.length || pendingCars.length
        return { key: 'stage', label: count === 1 ? 'Stage the vehicle' : picked.length ? `Stage ${count} vehicles` : `Stage all ${count} vehicles`, hint: 'Stage the cars at the lot, then load them on your hauler', disabled: !count,
          run: () => { if (!picked.length) selectedCars.value = pendingCars.map(c => c.key); collect() } }
      }
      if (r.kind === 'trailer') return { key: 'collect', label: 'Bring out the trailer', hint: 'The trailer is placed in the pickup bay for you to hook up', run: collect }
      if (r.kind === 'parcel') return { key: 'load', ...loadStep.value, run: loadParcels }
      if (r.kind === 'material') return { key: 'load', label: 'Load cargo', hint: 'Choose how much to load in the material loader', run: collect }
      const con = s.containers.find(c => c.key === container.value)
      if (!s.containers.length) return { key: 'load', label: 'No cargo space nearby', hint: 'Bring a vehicle with room for this cargo', disabled: true, run: collect }
      return { key: 'load', label: 'Load cargo', hint: con ? `Loads into ${con.name}` : 'Pick a cargo space above', disabled: !con, run: collect }
    }
    if (r.atDelivery) return { key: 'deliver', label: 'Navigate to delivery', hint: 'You are here. Hand over at the drop-off marker', run: nav('delivery') }
    return { key: 'toDelivery', label: 'Navigate to delivery', hint: r.kind === 'cars' && stagedCars.length ? `Load the staged cars, then drive to ${r.to || 'the delivery'}` : r.kind === 'trailer' ? `Hook up the trailer, then drive to ${r.to || 'the delivery'}` : `Deliver to ${r.to || 'the delivery'}`, run: nav('delivery') }
  })
  // With a single usable cargo space there is nothing to choose: preselect it.
  watch(() => [s.selected, s.containers.length], () => { if (!container.value && s.containers.length) { const c = s.containers.find(x => Number(x.free) > 0) || s.containers[0]; if (c) container.value = c.key } })
  function toggleCar(key) { selectedCars.value = selectedCars.value.includes(key) ? selectedCars.value.filter(k => k !== key) : [...selectedCars.value, key] }
  function toggleTrailer(type) { s.updateFilter('trailers', s.filter.trailers.includes(type) ? s.filter.trailers.filter(v => v !== type) : [...s.filter.trailers, type]) }
  watch(radiusPresets, presets => {
    const r = s.filter.radius
    if (!r || !presets.length) return
    const max = presets[presets.length - 1].value
    if (r > max) s.updateFilter('radius', max)
  }, { immediate: true })
  watch([pickupLocationOptions, destLocationOptions], () => {
    if (s.filter.pickupFac && !pickupLocationOptions.value.some(o => o.value === s.filter.pickupFac)) {
      s.updateFilter('pickupFac', '')
    }
    if (s.filter.destFac && !destLocationOptions.value.some(o => o.value === s.filter.destFac)) {
      s.updateFilter('destFac', '')
    }
  })
  function isSaved(row) { return Object.values(s.data.plans).some(p => p.id === row.id || p.offerId === row.id) }
  function stopJob(stop) { return s.data.jobs.find(j => j.id === stop.jobId) || s.data.plans[stop.jobId] }
  function openStop(stop) { const row = stopJob(stop); if (!row) return; s.selected = row.id; jobsTab.value = 'loads'; if (row.status) s.action('navigate', { id: row.id, leg: stop.kind, stopId: stop.id }) }
  function back() { if (confirmingAbandon.value) { confirmingAbandon.value = false; return true } if (s.selected) { closeDetail(); return true } if (s.view !== 'markets') { s.view = 'markets'; return true } return false }
  let isUnmounted = false
  let brokerRevision = null
  let brokerEventVersion = 0
  let brokerRefreshInFlight = false

  function receiveBrokerState(payload) {
    if (isUnmounted || !payload) return
    brokerEventVersion++
    if (payload.revision === brokerRevision) return
    if (payload.baseRevision != null && payload.baseRevision !== brokerRevision) return
    brokerRevision = payload.revision
    s.receive(payload)
  }

  async function refreshBroker(poll = false) {
    if (isUnmounted || brokerRefreshInFlight) return
    brokerRefreshInFlight = true
    const version = brokerEventVersion
    try {
      const method = poll === true ? 'requestBrokerUpdates' : 'requestBrokerState'
      const payload = await callModLua(`overhaul_phone_apps_logistics.${method}`, brokerRevision)
      if (isUnmounted || version !== brokerEventVersion) return
      if (payload?.unchanged) s.data.logisticsTime = payload.logisticsTime
      else receiveBrokerState(payload)
    } catch {
      if (!isUnmounted) s.message = 'Unable to load Job Broker. Try refreshing.'
    } finally {
      brokerRefreshInFlight = false
    }
  }

  onMounted(async () => {
    s.rehydrate()
    events.on('phoneBrokerState', receiveBrokerState); events.on('phoneBrokerResult', s.receiveResult); events.on('phoneBrokerContainers', receiveContainers)
    await acquireScope(callModLuaLoader, 'phone.logistics')
    if (isUnmounted) return
    await refreshBroker()
    if (isUnmounted) return
    const context = s.data.openContext || {}
    if (context.facility) { s.scope = context.facility; s.chooseMarket('all'); s.expanded = true }
    if (context.depot) { s.view = 'loaners'; s.expanded = true }
    if (context.tab === 'jobs') { s.view = 'jobs'; s.expanded = true }
    // Harness / deep links: open expanded, on a market, on a view, or with a load selected.
    if (context.market) s.chooseMarket(context.market)
    if (['loads', 'jobs', 'loaners', 'markets'].includes(context.view)) s.view = context.view
    if (context.view === 'filters') { s.view = 'loads'; filtersOpen.value = true }
    if (context.select) s.selected = context.select
    if (context.routeTab) jobsTab.value = 'route'
    if (context.expanded) s.expanded = true
    refreshTimer = setInterval(() => refreshBroker(true), 10000)
    if (route.query.facility) { s.scope = String(route.query.facility); s.chooseMarket('all'); s.expanded = true }
    if (route.query.depot) { s.view = 'loaners'; s.expanded = true }
  })
  onUnmounted(() => {
    isUnmounted = true
    discardPopup?.close(false)
    clearInterval(refreshTimer); clearTimeout(containerTimer); clearTimeout(messageTimer); containerRequest++
    events.off('phoneBrokerState', receiveBrokerState); events.off('phoneBrokerResult', s.receiveResult); events.off('phoneBrokerContainers', receiveContainers)
    // The Lua owner outlives the component. Stop its pending projection too.
    callModLua('overhaul_phone_apps_logistics.closeBrokerScreen').catch(() => {})
  })

  return { back, startHere, isJobStack, stackExpanded, toggleJobStack, isLocked, accessReasons, requirementProgress, fitBadge, offerBadges, offerTimeLeft, jobTimeline, unlockHeading, levelReason, requirementText, stageHeading, groupsByPickup, pickupHeading, openRequirements, availableCount, lockedCount, focusView, screenRef, changeTab, ref, BngIcon, icons, groupedOfferCount, markets, RouteMap, s, route, openEmployment, listEl, jobsTab, container, selectedCars, confirmingAbandon, rowLimit, filtersOpen, rowImage, routePreview, routeLoading, planPreview, planLoading, renderedRows, containerLoading, containerError, cargoOptions, arrangementOptions, sortOptions, working, marketName, heading, activeJobs, visibleRows, selectedListRow, filterCount, trailerTypes, pickupLocationOptions, destLocationOptions, effectiveRadius, radiusDropdownItems, marketIcon, marketImage, loadCount, money, rate, dist, isMarketFilterActive, tableColumns, setColumnSort, columnSortActive, toggleMarketFilter, capacityText, fact, pct, payOf, detailFacts, legDistance, statusName, rememberScroll, closeDetail, select, refreshContainers, reserveAmount, reserveGroup, reserveMax, reserveSlots, stepReserve, reserveSelected, showLoader, slotsOf, pickupParcels, parcelBoxes, boxByKey, loadVehicle, boxIndex, boxCap, boxHeld, boxUse, boxLeft, canMove, share, boxLabel, autoSplit, cycleBox, pickupGroups, groupLoad, groupStuck, groupSplits, toggleGroup, stepGroup, loadParcels, loadStep, selectedJobIds, abandonFine, cancelReservation, abandon, collect, nextStep, toggleCar, toggleTrailer, isSaved, stopJob, openStop, refreshBroker }

}

<!-- RLS Maintenance computer, house style. Same data, checks, cart and checkout as before; layout:
     the car first, then one row per system (icon, name, mileage, health bar + percent). A row opens
     to its service items: Check (reveals health) and Service (adds to the cart, price in gold).
     Orange is left to the cart's Confirm; status colour only where something is low or flat. -->
<template>
  <ComputerWrapper title="Maintenance" @back="confirmCancel">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'career-maintenance', canDeactivate: maintenanceBack }"
      class="maintenance-panel rls-house"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      :active="isMaintenanceActive">
      <!-- no inner heading: the page title already says Maintenance (context still switches to the cart) -->
      <div class="maintenance-body">
        <div v-if="vehicleName" class="car">
          <div class="car-photo">
            <img v-if="vehicleThumb && !thumbBroken" :src="vehicleThumb" alt="" @error="thumbBroken = true" />
            <BngIcon v-else class="car-fallback" :type="icons.wrench" />
          </div>
          <div class="car-copy">
            <span class="caption">Servicing</span>
            <strong class="car-name">{{ vehicleName }}</strong>
          </div>
        </div>

        <div v-if="errorMessage" class="notice" :class="{ bad: !checkoutBusy }">
          <BngIcon :type="checkoutBusy ? icons.wrench : icons.warning" />
          <span>{{ errorMessage }}</span>
        </div>

        <div v-if="loading" class="loading-copy hint">Loading maintenance data…</div>

        <div v-else class="system-list scroll" v-bng-ui-nav-scroll>
          <section
            v-for="(category, catIndex) in uiData.categories || []"
            :key="category.name"
            class="system"
            :class="{ open: isExpanded(category.name) }"
            v-bng-on-ui-nav:back.focusRequired="e => collapseOnBack(e, category.name)">
            <button
              type="button"
              class="system-head"
              :bng-scoped-nav-autofocus="catIndex === 0 && !entryFocused ? true : undefined"
              bng-nav-item
              v-bng-on-ui-nav:focus_d,focus_ud.focusRequired="e => enterSection(e, category.name)"
              v-bng-sound-class="'bng_click_hover_generic'"
              :aria-expanded="isExpanded(category.name)"
              @click="setExpanded(category.name, !isExpanded(category.name))">
              <BngIcon class="system-icon" :type="categoryIcon(category.name)" />
              <span class="system-copy">
                <span class="system-name">{{ category.label }}</span>
                <span class="system-meta">{{ formatDistance(category.avgMiles) }}</span>
              </span>
              <span class="health" :class="categorySummary(category).tone">
                <span v-if="categoryWorst(category) != null" class="health-bar"><span :style="{ transform: `scaleX(${categoryWorst(category) / 100})` }" /></span>
                <span class="health-text">{{ categorySummary(category).text }}</span>
              </span>
              <svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
            </button>

            <div v-if="isExpanded(category.name)" class="items">
              <div
                v-for="row in category.rows || []"
                :key="`${row.category}:${row.item}`"
                class="item"
                :class="isChecking(makeBusyKey(row, 'check')) && ['checking', `kind-${checkKind(row)}`]">
                <div class="item-copy">
                  <span class="item-name">{{ row.label }}</span>
                  <span class="health compact" :class="rowStatusClass(row)">
                    <span v-if="row.isRevealed" class="health-bar"><span :style="{ transform: `scaleX(${(Number(row.revealedPercent) || 0) / 100})` }" /></span>
                    <span class="health-text">{{ rowStatusText(row) }}</span>
                  </span>
                </div>
                <div class="item-actions">
                  <!-- while held, the magnifier turns into the item's animated icon (dipstick, sample, spark)
                       and the button's hold fill is the progress -->
                  <HouseButton
                    class="act-check"
                    compact
                    variant="quiet"
                    :icon="isChecking(makeBusyKey(row, 'check')) ? checkIcon(row) : icons.search"
                    :disabled="!!busyActionKey"
                    v-bng-tooltip="'Hold to check'"
                    v-bng-on-ui-nav:ok.asMouse.focusRequired
                    v-bng-click="{ holdCallback: e => onHold(e, () => runCheck(row)), holdDelay: CHECK_HOLD_MS, repeatInterval: 0 }"
                    @mousedown="e => holdStart(e, makeBusyKey(row, 'check'))"
                    @mouseup="holdEnd"
                    @mouseleave="holdEnd"
                    @blur="holdEnd">
                    Check
                  </HouseButton>
                  <span v-if="isServiceCovered(row)" class="pill soft included">Included</span>
                  <HouseButton
                    v-else-if="isServiceInCart(row)"
                    class="act-service"
                    compact
                    variant="quiet-danger"
                    :icon="icons.undo"
                    :disabled="checkoutBusy"
                    @click="e => keepRowFocus(e, () => toggleService(row))">
                    Remove
                  </HouseButton>
                  <HouseButton
                    v-else
                    class="act-service"
                    compact
                    :disabled="checkoutBusy"
                    @click="e => keepRowFocus(e, () => toggleService(row))">
                    {{ serviceButtonLabel(row) }}
                    <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatServicePrice(row.servicePrice) }}</span>
                  </HouseButton>
                </div>
              </div>
            </div>
          </section>

          <section
            v-if="uiData.sessionMode !== 'dyno'"
            class="system"
            :class="{ open: isExpanded('tires') }"
            v-bng-on-ui-nav:back.focusRequired="e => collapseOnBack(e, 'tires')">
            <button
              type="button"
              class="system-head"
              bng-nav-item
              v-bng-on-ui-nav:focus_d,focus_ud.focusRequired="e => enterSection(e, 'tires')"
              v-bng-sound-class="'bng_click_hover_generic'"
              :aria-expanded="isExpanded('tires')"
              @click="setExpanded('tires', !isExpanded('tires'))">
              <BngIcon class="system-icon" :type="icons.tire" />
              <span class="system-copy">
                <span class="system-name">Tires</span>
                <span v-if="tireMeta" class="system-meta">{{ tireMeta }}</span>
              </span>
              <span class="health" :class="tireSummary.tone">
                <span class="health-text">{{ tireSummary.text }}</span>
              </span>
              <svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
            </button>

            <div v-if="isExpanded('tires')" class="items">
              <p v-if="!uiData.tireShop?.available" class="hint tire-message">
                {{ uiData.tireShop?.message || "Tire service is unavailable." }}
              </p>

              <div v-else-if="!uiData.tireShop.inspected" class="item" :class="isChecking('tires:check') && ['checking', 'kind-tires']">
                <div class="item-copy">
                  <span class="item-name">Tread and pressure</span>
                  <span class="hint">Free inspection</span>
                </div>
                <div class="item-actions">
                  <HouseButton
                    class="act-wide"
                    compact
                    :icon="isChecking('tires:check') ? icons.tire : icons.search"
                    :disabled="!!busyActionKey"
                    v-bng-tooltip="'Hold to check'"
                    v-bng-on-ui-nav:ok.asMouse.focusRequired
                    v-bng-click="{ holdCallback: e => onHold(e, runTireCheck), holdDelay: CHECK_HOLD_MS, repeatInterval: 0 }"
                    @mousedown="e => holdStart(e, 'tires:check')"
                    @mouseup="holdEnd"
                    @mouseleave="holdEnd"
                    @blur="holdEnd">
                    Check all tires
                  </HouseButton>
                </div>
              </div>

              <template v-else>
                <div v-for="axle in uiData.tireShop.axles || []" :key="axle.id" class="item axle">
                  <div class="item-copy">
                    <span class="item-name">{{ axle.label }}</span>
                    <span class="hint">{{ axle.tireName }} ×{{ axle.tireCount }}</span>
                    <span class="wheels">
                      <span
                        v-for="wheel in axle.wheelStates || []"
                        :key="wheel.name"
                        class="pill"
                        :class="wheel.flat ? 'bad' : wheelTone(wheel.remainingPercent)">
                        {{ wheel.name }} {{ wheel.flat ? "Flat" : `${wheel.remainingPercent}%` }}
                      </span>
                    </span>
                  </div>
                  <div class="item-actions">
                    <HouseButton
                      v-if="isTireInCart(axle.id)"
                      class="act-service"
                      compact
                      variant="quiet-danger"
                      :icon="icons.undo"
                      :disabled="checkoutBusy"
                      @click="e => keepRowFocus(e, () => toggleTire(axle.id))">
                      Remove
                    </HouseButton>
                    <HouseButton
                      v-else
                      class="act-service"
                      compact
                      :disabled="checkoutBusy"
                      @click="e => keepRowFocus(e, () => toggleTire(axle.id))">
                      Replace <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatServicePrice(axle.subtotal) }}</span>
                    </HouseButton>
                  </div>
                </div>

                <div class="tire-all">
                  <HouseButton
                    v-if="allTiresInCart"
                    compact
                    variant="quiet-danger"
                    :icon="icons.undo"
                    :disabled="checkoutBusy"
                    @click="e => keepRowFocus(e, toggleAllTires)">
                    Remove all tires
                  </HouseButton>
                  <HouseButton
                    v-else
                    compact
                    :disabled="checkoutBusy || !(uiData.tireShop.axles || []).length"
                    @click="e => keepRowFocus(e, toggleAllTires)">
                    Replace all <span class="price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatServicePrice(uiData.tireShop.replaceAllSubtotal) }}</span>
                  </HouseButton>
                </div>
              </template>
            </div>
          </section>
        </div>
      </div>
    </ComputerPanel>

    <template #side>
      <ShoppingCart
        v-bng-scoped-nav="{ scopeId: 'career-maintenance-cart' }"
        :active="isCartActive"
        :cart-data="cartData"
        :player-money="playerMoney"
        confirm-button-text="Confirm"
        v-bng-on-ui-nav:context="switchToMaintenance"
        @apply="applyCart"
        @cancel="confirmCancel"
        @remove-item="removeCartItem"
      />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { computed, nextTick, onMounted, reactive, ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { installLuaBridgeFallbacks, callModLua } from "../utils/installLuaBridgeFallbacks"

installLuaBridgeFallbacks()
import { ACCENTS, BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngClick, vBngOnUiNav, vBngScopedNav, vBngSoundClass, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { useScopedNav } from "@/services/scopedNav/api"
import { HouseButton, openHouseConfirmation } from "../components/house/index.js"
import { useUINavBlocker } from "@/services/uiNavTracker"
import ComputerPanel from "../components/ComputerPanel.vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import ShoppingCart from "../components/ShoppingCart.vue"
import { METERS_PER_MILE, formatOdometer } from "../utils/units"
import { useScreenEntry, refocusIfLost } from "../composables/useScreenEntryFocus"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const { units } = useBridge()
const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const { switchScope, current } = useScopedNav()
const isCartActive = computed(() => current.value?.id === "career-maintenance-cart")
const isMaintenanceActive = computed(() => current.value?.id === "career-maintenance")
const switchToCart = () => switchScope("career-maintenance-cart")
const switchToMaintenance = () => switchScope("career-maintenance")
// B on the systems list (nothing open) leaves the screen like Tuning does, instead of first parking
// focus on the panel frame; open systems close first (collapseOnBack)
const maintenanceBack = () => {
  confirmCancel()
  return false
}

const CANCEL_MESSAGE = "Leave maintenance? Your cart will be cleared."
const CONFIRM_BUTTONS = [
  { label: "Yes", value: true },
  { label: "No", value: false, extras: { accent: ACCENTS.secondary } },
]

const uiData = ref({
  facilityName: "Maintenance",
  vehicle: null,
  categories: [],
  tireShop: null,
  playerMoney: 0,
})
const loading = ref(true)
const errorMessage = ref("")
const busyActionKey = ref("")
const checkoutBusy = ref(false)
const expandedKeys = reactive({})
const cartServices = ref([])
const cartTireAxles = ref([])

let refreshing = false

const parseMoney = value => {
  if (value && typeof value === "object") value = value.value
  const amount = Number(value)
  return Number.isFinite(amount) ? amount : null
}

const requestData = async () => {
  if (refreshing) return
  refreshing = true
  try {
    const result = await lua.overhaul_career_maintenance_maintenanceComputer.getMaintenanceUiData()
    if (result?.errorMessage) {
      errorMessage.value = result.debugError ? `${result.errorMessage} ${result.debugError}` : result.errorMessage
      return
    }
    if (!result?.enabled || !result?.vehicle) {
      await close()
      return
    }
    let playerMoneyValue = parseMoney(result.playerMoney)
    if (playerMoneyValue == null) {
      try {
        playerMoneyValue = parseMoney(await lua.overhaul_career_economy_playerAttributes.getAttributeValue("money"))
      } catch (_) {
        playerMoneyValue = null
      }
    }
    uiData.value = { ...result, playerMoney: playerMoneyValue }
    pruneCart()
    errorMessage.value = ""
  } catch (error) {
    errorMessage.value = error?.message || "Failed to load maintenance data."
  } finally {
    loading.value = false
    refreshing = false
  }
}

const vehicleName = computed(() => uiData.value.vehicle?.niceName || uiData.value.vehicle?.name || "")
const playerMoney = computed(() => parseMoney(uiData.value.playerMoney) ?? undefined)

const thumbBroken = ref(false)
const vehicleThumb = computed(() => {
  const v = uiData.value.vehicle
  return v?.thumbnail ? `${v.thumbnail}${v.dirtyDate ? `?${v.dirtyDate}` : ""}` : null
})

const CATEGORY_ICONS = {
  engine: icons.engine,
  radiator: icons.coolantTemp,
  transmission: icons.transmissionM,
  brakes: icons.wheelDisc,
  differential: icons.drivetrain,
  drivetrain: icons.drivetrain,
}
const categoryIcon = name => CATEGORY_ICONS[name] || icons.wrench

// lowest revealed health in a system (null when nothing has been checked yet)
const categoryWorst = category => {
  const revealed = (category.rows || []).filter(row => row.isRevealed)
  return revealed.length ? Math.min(...revealed.map(row => Number(row.revealedPercent) || 0)) : null
}

const wheelTone = percent => statusTone(percent)

// Lua sends the category odometer in miles (avgMiles); shown in the player's length unit
const formatDistance = miles => formatOdometer(units, (Number(miles) || 0) * METERS_PER_MILE)

// whole beams after the currency glyph, like the other house screens
const formatServicePrice = price => Math.max(0, Math.round(Number(price) || 0)).toLocaleString()

const isExpanded = key => Boolean(expandedKeys[key])

// Controller: B inside an open system closes it and puts focus back on its header (one level at a
// time); on a closed system B goes on to the screen's back (leave maintenance).
// Down on an open system's header goes into that system's first row (its Check). Left to geometry,
// the full-width header often matched the next header below instead and skipped the whole section
// (seen in game on Cooling / Transmission). Closed systems keep the normal d-pad move.
const enterSection = (event, key) => {
  const { name, value } = event?.detail || {}
  const down = name === "focus_d" ? !!value : name === "focus_ud" && Number(value) <= -0.5
  if (!down || !isExpanded(key)) return true
  // the focused header's own section (the event target can be the screen scope, not the header)
  const section = document.activeElement?.closest?.(".system")
  const target = section?.querySelector(
    ".items .act-check:not([disabled]), .items [bng-nav-item]:not([bng-no-nav]):not([disabled])"
  )
  if (!target) return true
  target.focus()
  return false
}

const collapseOnBack = (event, key) => {
  if (!isExpanded(key)) return true
  const section = event?.target?.closest?.(".system") || document.activeElement?.closest?.(".system")
  setExpanded(key, false)
  nextTick(() => section?.querySelector(".system-head")?.focus())
}

// Service / Remove (and Replace / Remove) are separate v-if buttons, so a swap drops focus;
// keep a pad on the same row (or the row's next usable button)
const keepRowFocus = (event, action) => {
  const row = event?.currentTarget?.closest?.(".item, .tire-all")
  action()
  if (row) refocusIfLost(() => row.querySelector(".act-service:not([disabled]), .tire-all button:not([disabled])") || row.querySelector("button:not([disabled])"), { force: true })
}
// a Check disables every Check while it runs (focus drops); afterwards return to that row, or to
// its system when the row was replaced (tire check -> per-axle rows)
const focusAfterCheck = (rowEl, sectionEl) => {
  if (!sectionEl) return
  refocusIfLost(() =>
    (rowEl && document.contains(rowEl) && rowEl.querySelector("button:not([disabled])")) ||
    sectionEl.querySelector(".items button:not([disabled])") ||
    sectionEl.querySelector(".system-head"), { force: true })
}

const setExpanded = (key, val) => {
  expandedKeys[key] = Boolean(val)
}

const statusTone = percent => {
  if (percent == null) return "unknown"
  if (percent <= 25) return "bad"
  if (percent <= 50) return "warn"
  return "ok"
}

const rowStatusText = row => (row.isRevealed ? `${row.revealedPercent}%` : "Unknown")

const rowStatusClass = row => (row.isRevealed ? statusTone(row.revealedPercent) : "unknown")

const categorySummary = category => {
  const rows = category.rows || []
  const revealed = rows.filter(row => row.isRevealed)
  if (!revealed.length) return { text: "Not checked", tone: "unknown" }
  const worst = Math.min(...revealed.map(row => Number(row.revealedPercent) || 0))
  const unknownCount = rows.length - revealed.length
  return {
    text: unknownCount ? `${worst}%, ${unknownCount} unknown` : `${worst}%`,
    tone: statusTone(worst),
  }
}

const axleStatusClass = percent => statusTone(percent)

const tireSummary = computed(() => {
  const shop = uiData.value.tireShop
  if (!shop?.available) return { text: "Unavailable", tone: "unknown" }
  if (!shop.inspected) return { text: "Not checked", tone: "unknown" }
  const axles = shop.axles || []
  if (axles.some(axle => axle.flat)) return { text: "Flat", tone: "bad" }
  if (!axles.length) return { text: "Checked", tone: "ok" }
  const worst = Math.min(...axles.map(axle => Number(axle.remainingPercent) || 0))
  return { text: `${worst}%`, tone: statusTone(worst) }
})

const tireMeta = computed(() => {
  const shop = uiData.value.tireShop
  if (!shop?.available) return ""
  const axles = shop.axles || []
  const count = axles.reduce((sum, axle) => sum + (Number(axle.tireCount) || 0), 0)
  if (!count) return ""
  const label = `${count} tire${count === 1 ? "" : "s"}`
  if (!shop.inspected) return `${label}, not yet checked`
  const weighted = axles.reduce((sum, axle) => sum + (Number(axle.remainingPercent) || 0) * (Number(axle.tireCount) || 0), 0)
  return `${label}, ${Math.round(weighted / count)}% tread remaining`
})

const findRow = (category, item) => {
  for (const cat of uiData.value.categories || []) {
    for (const row of cat.rows || []) {
      if (row.category === category && row.item === item) return row
    }
  }
  return null
}

const findAxle = axleId => (uiData.value.tireShop?.axles || []).find(axle => axle.id === axleId)

const isServiceInCart = row =>
  cartServices.value.some(entry => entry.category === row.category && entry.item === row.item)

const isServiceCovered = row =>
  cartServices.value.some(entry => {
    const cartRow = findRow(entry.category, entry.item)
    return cartRow && cartRow.category === row.category && cartRow.fillsItem === row.item
  })

const isTireInCart = axleId => cartTireAxles.value.includes(axleId)

const allTiresInCart = computed(() => {
  const axles = uiData.value.tireShop?.axles || []
  return axles.length > 0 && axles.every(axle => isTireInCart(axle.id))
})

const serviceButtonLabel = row => {
  if (isServiceCovered(row)) return "Included"
  if (isServiceInCart(row)) return "Remove"
  return row.actionLabel
}

const pruneCart = () => {
  cartServices.value = cartServices.value.filter(entry => findRow(entry.category, entry.item))
  cartTireAxles.value = cartTireAxles.value.filter(axleId => Boolean(findAxle(axleId)))
}

const cartHasItems = computed(() => cartData.value.items.length > 0)

const cartData = computed(() => {
  const items = []
  let total = 0

  for (const entry of cartServices.value) {
    const row = findRow(entry.category, entry.item)
    if (!row || isServiceCovered(row)) continue
    const price = Number(row.servicePrice) || 0
    items.push({
      name: `${row.actionLabel} ${row.label}`,
      price,
      removeShow: true,
      kind: "service",
      category: row.category,
      item: row.item,
    })
    total += price
  }

  for (const axleId of cartTireAxles.value) {
    const axle = findAxle(axleId)
    if (!axle) continue
    const price = Number(axle.subtotal) || 0
    items.push({
      name: `Replace ${axle.label} Tires`,
      extraInfo: `${axle.tireName}, ${axle.tireCount} tires`,
      price,
      removeShow: true,
      kind: "tire",
      axleId,
    })
    total += price
  }

  return { items, total, taxes: 0 }
})

const toggleService = row => {
  if (isServiceCovered(row)) return
  if (isServiceInCart(row)) {
    cartServices.value = cartServices.value.filter(
      entry => !(entry.category === row.category && entry.item === row.item)
    )
    return
  }
  if (row.fillsItem) {
    cartServices.value = cartServices.value.filter(
      entry => !(entry.category === row.category && entry.item === row.fillsItem)
    )
  }
  cartServices.value = [...cartServices.value, { category: row.category, item: row.item }]
}

const toggleTire = axleId => {
  if (isTireInCart(axleId)) {
    cartTireAxles.value = cartTireAxles.value.filter(id => id !== axleId)
    return
  }
  cartTireAxles.value = [...cartTireAxles.value, axleId]
}

const toggleAllTires = () => {
  const axles = uiData.value.tireShop?.axles || []
  if (allTiresInCart.value) {
    cartTireAxles.value = []
    return
  }
  cartTireAxles.value = axles.map(axle => axle.id)
}

const removeCartItem = item => {
  if (item.kind === "tire") {
    toggleTire(item.axleId)
    return
  }
  const row = findRow(item.category, item.item)
  if (row) toggleService(row)
}

const makeBusyKey = (row, action) => `${row.category}:${row.item}:${action}`

// Check is hold-to-confirm (same v-bng-click hold as the cart's Confirm); Fill / Replace only add
// to the cart, so they stay plain clicks.
// only the primary mouse button or the controller's OK completes a hold
const onHold = (event, action) => {
  if (event && !event.fromController && event.button != null && event.button !== 0) return
  action()
}

// Holding Check *is* the check: the animation runs for the length of the hold (letting go early
// cancels it) and the result shows when the hold completes.
const CHECK_HOLD_MS = 1400
const holdingKey = ref("")
const holdStart = (event, key) => {
  if (busyActionKey.value) return
  if (event && event.button != null && event.button !== 0) return
  holdingKey.value = key
}
const holdEnd = () => {
  holdingKey.value = ""
}
const isChecking = key => holdingKey.value === key || busyActionKey.value === key

// what kind of check: a level (dipstick), a fluid's quality (sample scan) or a part (spark / generic)
const checkKind = row => {
  const item = String(row.item || "").toLowerCase()
  if (item.includes("level")) return "level"
  if (item.includes("condition") || item.includes("integrity") || item.includes("quality")) return "quality"
  if (item.includes("ignition")) return "spark"
  return "generic"
}
const checkIcon = row => {
  const kind = checkKind(row)
  if (kind === "level" || kind === "quality") return row.category === "radiator" ? icons.coolantTemp : icons.droplet
  return categoryIcon(row.category)
}

const isBusy = (row, action) => busyActionKey.value === makeBusyKey(row, action)

const runCheck = async row => {
  if (busyActionKey.value) return
  const rowEl = document.activeElement?.closest?.(".item")
  const sectionEl = rowEl?.closest(".system")
  busyActionKey.value = makeBusyKey(row, "check")
  holdingKey.value = ""
  try {
    const result = await lua.overhaul_career_maintenance_maintenanceComputer.startCheck(
      Number(uiData.value.inventoryId),
      row.category,
      row.item
    )
    if (!result?.ok) {
      errorMessage.value = result?.message || "Unable to complete check."
      return
    }
    await requestData()
  } finally {
    busyActionKey.value = ""
    focusAfterCheck(rowEl, sectionEl)
  }
}

const runTireCheck = async () => {
  if (busyActionKey.value) return
  const rowEl = document.activeElement?.closest?.(".item")
  const sectionEl = rowEl?.closest(".system")
  busyActionKey.value = "tires:check"
  holdingKey.value = ""
  try {
    const result = await lua.overhaul_career_maintenance_maintenanceComputer.inspectTires(Number(uiData.value.inventoryId))
    if (!result?.ok) {
      errorMessage.value = result?.message || "Unable to inspect tires."
      return
    }
    await requestData()
  } finally {
    busyActionKey.value = ""
    focusAfterCheck(rowEl, sectionEl)
  }
}

const clearCart = () => {
  cartServices.value = []
  cartTireAxles.value = []
}

const applyCart = async () => {
  if (!cartHasItems.value || checkoutBusy.value) return
  checkoutBusy.value = true
  errorMessage.value = "Checking out..."
  try {
    const payload = JSON.stringify({
      services: cartServices.value.map(entry => ({ category: entry.category, item: entry.item })),
      tireAxleIds: [...cartTireAxles.value],
      quoteRevision: uiData.value.tireShop?.quoteRevision || "",
    })
    const result = await Promise.race([
      callModLua("overhaul_career_maintenance_maintenanceComputer.checkoutCart", Number(uiData.value.inventoryId), payload),
      new Promise((_, reject) => setTimeout(() => reject(new Error("Checkout timed out.")), 15000)),
    ])
    if ((result && result.ok === false) || result?.staleQuote) {
      errorMessage.value = result?.message || result?.debugError || "Unable to complete checkout."
      if (result?.staleQuote) await requestData()
      return
    }
    errorMessage.value = ""
    clearCart()
  } catch (error) {
    errorMessage.value = error?.message || "Unable to complete checkout."
  } finally {
    checkoutBusy.value = false
  }
}

const close = async () => {
  await callModLua("overhaul_career_maintenance_maintenanceComputer.closeMenu")
}

const confirmCancel = async () => {
  if (!cartHasItems.value || await openHouseConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)) {
    clearCart()
    await close()
  }
}

// the autofocus mark is for entry only, so later focus repairs return to the last row, not the top
const entryFocused = ref(false)
onMounted(async () => {
  await requestData()
  // mod route without a Lua targetScope: wake the systems list so the d-pad works at once
  focusScreenEntry("career-maintenance").then(() => setTimeout(() => { entryFocused.value = true }, 600))
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Root is ComputerPanel: `.maintenance-panel.computer-panel` outranks its scoped surface rules.
.maintenance-panel.computer-panel {
  --bng-card-height: 100%;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(36em, 100%);
  height: 100%;
  max-height: 100%;
  overflow: hidden;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.82);
  }

  &:deep(.panel-content) {
    background-color: transparent;
    flex: 1 1 0;
    min-height: 0;
    max-height: 100%;
    overflow: hidden;
  }
}

.maintenance-body {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  height: 100%;
  min-height: 0;
  padding: 1em 0.5em 0.8em 1em;
}

/* ---- the car */
.car {
  flex: 0 0 auto;
  display: grid;
  grid-template-columns: 8em minmax(0, 1fr);
  gap: 0.9em;
  align-items: center;
  margin-right: 0.5em;
}
.car-photo {
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--panel);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}
.car-fallback {
  font-size: 1.8em;
  color: rgba(255, 255, 255, 0.25);
}
.car-copy {
  display: grid;
  gap: 0.25em;
  min-width: 0;
}
.car-name {
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}

.notice {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.5em;
  margin-right: 0.5em;
  font-weight: 700;
}
.loading-copy {
  padding: 1em 0;
}

/* ---- systems */
.system-list {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  padding-right: 0.3em;
}
.system {
  flex: 0 0 auto;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.open {
    background: var(--panel-2);
  }
}
.system-head {
  position: relative; // the game frame (if any) anchors here, not on the panel
  appearance: none;
  display: grid;
  grid-template-columns: 1.6em minmax(0, 1fr) auto 1em;
  align-items: center;
  gap: 0.75em;
  width: 100%;
  margin: 0;
  padding: 0.75em 0.9em 0.65em;
  border: 0;
  border-radius: var(--radius-panel);
  background: transparent;
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  &:hover {
    background: rgba(255, 255, 255, 0.04);
  }
  // full-width row in a scroll box: inset ring, for the pad class and keyboard alike
  @include house-focus(var(--focus-inset));
}
.system-icon {
  font-size: 1.5em;
  color: rgba(255, 255, 255, 0.6);
  .open & {
    color: var(--accent-soft);
  }
}
.system-copy {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.system-name {
  font-size: 1.08em;
  font-weight: 800;
  line-height: 1.15;
}
.system-meta {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.chevron {
  width: 1em;
  height: 1em;
  fill: none;
  stroke: var(--faint);
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
  transform: rotate(-90deg);
  transition: transform 0.16s ease;
  .open & {
    transform: rotate(0deg);
  }
}

/* ---- health: bar + percent, colour only by exception */
.health {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.55em;
  min-width: 0;
  color: #fff;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  &.unknown {
    color: var(--faint);
    font-weight: 700;
  }
  &.warn {
    color: var(--warn);
  }
  &.bad {
    color: var(--bad);
  }
}
.health-bar {
  position: relative;
  width: 4.5em;
  height: 0.35em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  > span {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: rgba(255, 255, 255, 0.55);
    transform-origin: left center;
  }
  .warn > & > span {
    background: var(--warn);
  }
  .bad > & > span {
    background: var(--bad);
  }
}
.health.compact {
  justify-content: flex-start;
  font-size: 0.88em;
  .health-bar {
    width: 5.5em;
  }
}

/* ---- service items inside an open system */
.items {
  display: grid;
  gap: 0.35em;
  padding: 0 0.6em 0.6em;
}
.item {
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.8em;
  padding: 0.65em 0.6em 0.6em 0.75em;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.22);
}
.item-copy {
  display: grid;
  gap: 0.3em;
  min-width: 0;
  flex: 1 1 auto;
}
.item-name {
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
/* fixed columns so Check and Fill/Replace line up from row to row; the second fits "Service" + glyph + a 4-digit price */
.item-actions {
  flex: 0 0 auto;
  display: grid;
  grid-template-columns: 7.5em 10.6em;
  align-items: center;
  justify-items: stretch;
  gap: 0.35em;
  > * {
    min-width: 0;
  }
  .act-check {
    grid-column: 1;
  }
  .act-service,
  .included {
    grid-column: 2;
  }
  // label left, price right, so prices line up too
  .act-service :deep(.btn-label) {
    display: flex;
    width: 100%;
    justify-content: space-between;
    align-items: baseline; // the currency glyph makes the price taller than the label
  }
  .act-wide {
    grid-column: 1 / -1;
  }
}

/* ---- checking: the Check button's icon animates while held; its hold fill (accent) is the progress */
.checking .act-check,
.checking .act-wide {
  --bng-icon-color: var(--accent-soft, #ffb27a);
  :deep(.hold-fill) {
    background: rgba(255, 102, 0, 0.3);
  }
  :deep(.btn-icon) {
    color: var(--accent-soft, #ffb27a);
  }
}
// what the mechanic is doing: dipstick dips, a sample swirls, the plug sparks, the tire turns
.kind-level .house-button :deep(.btn-icon) { animation: dip 0.7s ease-in-out infinite; }
.kind-quality .house-button :deep(.btn-icon) { animation: swirl 1.2s ease-in-out infinite; }
.kind-spark .house-button :deep(.btn-icon) { animation: spark 0.35s steps(2) infinite; }
.kind-tires .house-button :deep(.btn-icon) { animation: spin 1.1s linear infinite; }
.kind-generic .house-button :deep(.btn-icon) { animation: swirl 1.2s ease-in-out infinite; }
@keyframes dip { 0%, 100% { transform: translateY(-0.1em); } 45% { transform: translateY(0.25em); } }
@keyframes swirl { 0%, 100% { transform: rotate(-14deg); } 50% { transform: rotate(14deg); } }
@keyframes spark { 0% { opacity: 1; transform: scale(1.05); } 50% { opacity: 0.45; transform: scale(0.88); } }
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .checking .house-button :deep(.btn-icon) {
    animation: none !important;
  }
}
.price {
  margin-left: 0.4em;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  .cur {
    margin-right: 0.1em;
    transform: translateY(0.08em);
  }
}
.included {
  justify-self: center;
}

/* ---- tires */
.wheels {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
  margin-top: 0.1em;
  .pill.ok {
    background: rgba(255, 255, 255, 0.09);
    color: rgba(255, 255, 255, 0.8);
  }
}
.tire-message {
  padding: 0.3em 0.4em;
}
.tire-all {
  display: flex;
  justify-content: flex-end;
  padding-top: 0.15em;
}
</style>

<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Passive business (Mini Mart, cafes, ...) sections inside the Business Computer, house style.
     The sidebar lists Dashboard, Stock & Supplies, Finances and Upgrades: the store expands the single
     Lua tab into those entries and passes the chosen one as data.view. LB/RB, B and sidebar focus are
     the shell's, as for every business type.
     Each section has the house page header (title + one hint line); the dashboard header carries the
     one open/closed switch. Each fact lives in one place: the dashboard summarises (earnings + Collect,
     next sale + net/hr, pickups, stock bar with quick orders, and an earnings outlook that fills the
     rest of the height); Stock = ordering, supplier, chain capacity; Finances = per-pallet and per-hour
     breakdown, stock value, sale; Upgrades = storage and wholesale.
     Type: three steps only. Kicker = .fact-key; every main figure = .value; secondary = .note.
     Pad: every action is a HouseButton / HouseSwitch with the house ring, disabled ones leave nav, the
     pallet quantity is a house slider stepped by the d-pad (no typing), and spending money is
     hold-to-confirm as in the other shops. B in the sale confirmation backs out of it first. -->
<template>
  <div ref="rootRef" class="rls-house passive-app" :class="{ fills: page === 'finances' }">
    <header class="page-head">
      <div class="page-copy">
        <h2 class="page-title">{{ PAGE_TITLES[page].title }}</h2>
        <p class="hint">{{ !supplyEnabled ? dashboard.description : page === 'dashboard' ? (dashboard.operating ? 'Sells one pallet per cycle during active career play.' : 'Closed: stock is kept and nothing sells.') : PAGE_TITLES[page].hint }}</p>
      </div>
      <!-- the one open/closed control -->
      <HouseSwitch v-if="supplyEnabled && page === 'dashboard'" class="store-switch" :model-value="!!dashboard.operating" :disabled="busy" data-fk="operating" @update:modelValue="toggleOperating">
        {{ dashboard.operating ? 'Store open' : 'Store closed' }}
      </HouseSwitch>
    </header>

    <p v-if="message" :class="['notice', messageError ? 'bad' : 'ok']">{{ message }}</p>

    <section v-if="!supplyEnabled" class="panel block">
      <h3 class="block-title">{{ dashboard.businessName || 'Property' }}</h3>
      <div class="actions start">
        <HouseButton v-if="canCollect" :disabled="busy" data-fk="collect" @click="collect">
          Collect existing earnings <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.uncollectedEarnings) }}
        </HouseButton>
        <HouseButton v-if="!saleQuote" variant="quiet-danger" :disabled="busy || saleLoading" data-fk="sell" @click="requestSaleQuote">Sell property</HouseButton>
      </div>
      <div v-if="saleQuote" class="sale-confirm" v-bng-on-ui-nav:back.focusRequired="cancelSale">
        <p class="hint">Expected payout: <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.netPayout) }}. Ownership benefits end when sold.</p>
        <div class="actions">
          <HouseButton variant="quiet" binding="back" :disabled="busy" data-fk="sale-cancel" @click="cancelSale">Cancel</HouseButton>
          <HouseButton variant="danger" :disabled="busy" data-fk="sale-confirm" v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: confirmSale, holdDelay: HOLD_MS, repeatInterval: 0 }">Confirm sale</HouseButton>
        </div>
      </div>
    </section>

    <template v-else>

    <!-- ===================== Dashboard: 3 cards / stock / outlook (fills the rest) ===================== -->
    <div v-if="page === 'dashboard'" class="widgets">
      <article class="widget">
        <header class="widget-head">
          <span class="fact-key">Pending earnings</span>
          <HouseButton variant="quiet" compact class="jump" :icon="icons.arrowSmallRight" data-fk="go-finances" aria-label="Open Finances" @click="goPage('finances')" />
        </header>
        <strong class="value money" :class="{ idle: !canCollect }"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.uncollectedEarnings) }}</strong>
        <span class="note">{{ canCollect ? 'Ready to collect' : 'Nothing to collect yet' }}</span>
        <div class="widget-actions">
          <!-- primary (the page's one orange button) only while there is something to collect -->
          <HouseButton
            compact
            :variant="canCollect ? 'primary' : 'neutral'"
            :binding="canCollect ? 'ok' : undefined"
            :disabled="busy || !canCollect"
            data-fk="collect"
            @click="collect">
            Collect
          </HouseButton>
        </div>
      </article>

      <article class="widget">
        <header class="widget-head">
          <span class="fact-key">Next sale</span>
        </header>
        <strong class="value" :class="cycleTone">{{ cycleLabel }}</strong>
        <span class="note"><span class="money nowrap"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.netProfitPerHour) }}</span> net per hour</span>
        <div class="widget-actions">
          <div class="meter thin grow"><span :style="{ width: (cyclePercent || 0) + '%' }"></span></div>
        </div>
      </article>

      <article class="widget">
        <header class="widget-head">
          <span class="fact-key">Pickups</span>
        </header>
        <strong class="value" :class="{ idle: !(dashboard.paidAtSupplier > 0) }">{{ dashboard.paidAtSupplier || 0 }}<small>ready</small></strong>
        <span class="note">{{ dashboard.inTransit || 0 }} in transit</span>
        <div class="widget-actions">
          <HouseButton compact :icon="icons.routeSimpleFlag" :disabled="busy || !(dashboard.paidAtSupplier > 0)" data-fk="pickup" @click="markPickup">Mark pickup</HouseButton>
        </div>
      </article>

      <article class="widget span-3">
        <header class="widget-head">
          <span class="fact-key">Stock</span>
          <HouseButton variant="quiet" compact class="jump" :icon="icons.arrowSmallRight" data-fk="go-stock" aria-label="Open Stock and Supplies" @click="goPage('stock')" />
        </header>
        <div class="widget-row">
          <div class="widget-copy grow">
            <strong class="value" :class="{ warn: !(dashboard.stock > 0) }">{{ dashboard.stock || 0 }}<small>/ {{ dashboard.capacity || 0 }} pallets</small></strong>
            <div class="meter"><span class="ok" :style="{ width: stockPercent + '%' }"></span></div>
            <span class="note">{{ runtimeSeconds ? `Sells out in ${duration(runtimeSeconds)} of active play` : 'Out of stock' }}</span>
          </div>
          <div class="widget-actions">
            <HouseButton
              compact
              :disabled="busy || maxOrder < 1"
              data-fk="quick-order-1"
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-bng-click="{ holdCallback: () => quickOrder(1), holdDelay: HOLD_MS, repeatInterval: 0 }">
              Order 1 <span class="btn-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.unitCost) }}</span>
            </HouseButton>
            <HouseButton
              v-if="maxOrder > 1"
              compact
              :disabled="busy"
              data-fk="quick-order-max"
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-bng-click="{ holdCallback: () => quickOrder(maxOrder), holdDelay: HOLD_MS, repeatInterval: 0 }">
              Order {{ maxOrder }} <span class="btn-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(maxOrder * (dashboard.unitCost || 0)) }}</span>
            </HouseButton>
          </div>
        </div>
      </article>

      <!-- projection from the current stock and cycle: one series (pending earnings if left uncollected) -->
      <article class="widget span-3 outlook">
        <header class="widget-head">
          <span class="fact-key">Earnings outlook</span>
          <span v-if="outlook" class="note"><span class="money nowrap"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(outlook.end) }}</span> pending at sell-out</span>
        </header>
        <div v-if="outlook" class="chart" role="img" :aria-label="`Pending earnings rise to ${money(outlook.end)} by sell-out`">
          <div class="plot">
            <span
              v-for="(bar, i) in outlook.bars"
              :key="i"
              class="bar"
              :class="{ after: bar.after }"
              :style="{ height: bar.pct + '%' }"
              :title="`+${duration(bar.t)}: ${money(bar.value)} pending`"></span>
            <span class="sellout" :style="{ left: outlook.sellOutPct + '%' }"><span class="note">Sell-out</span></span>
          </div>
          <div class="axis note">
            <span>Now</span>
            <span>+{{ duration(outlook.horizon / 2) }}</span>
            <span>+{{ duration(outlook.horizon) }}</span>
          </div>
        </div>
        <div v-else class="chart-empty">
          <strong class="value idle">{{ dashboard.operating ? 'No sales ahead' : 'Store closed' }}</strong>
          <span class="note">{{ dashboard.operating ? 'Order stock and deliver it to start selling again.' : 'Open the store to start selling the stock on hand.' }}</span>
        </div>
      </article>
    </div>

    <!-- ===================== Stock & Supplies: ordering, supplier, chain ===================== -->
    <div v-else-if="page === 'stock'" class="page">
      <section class="panel block">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Order stock</span>
            <h3 class="block-title">{{ dashboard.supplyName || 'Business Supplies' }}</h3>
          </div>
          <span class="pill"><BngIcon class="pill-icon" :type="icons.cardboardBox" />128-slot pallets</span>
        </header>
        <!-- flat inside the one card: the slider, then unit price + total + Order on one line -->
        <template v-if="maxOrder > 0">
          <div v-if="maxOrder > 1" class="qty-slider" v-bng-on-ui-nav:focus_d="focusOrder">
            <div class="slider-head">
              <span class="fact-key">Pallets</span>
              <strong class="value">{{ orderQuantity }}<small>pallet{{ orderQuantity === 1 ? '' : 's' }}</small></strong>
            </div>
            <!-- d-pad / stick left-right step it, faster while held (a native range ignores the pad) -->
            <input
              class="slider qty-range"
              type="range"
              min="1"
              :max="maxOrder"
              step="1"
              v-model.number="orderQuantity"
              :style="{ '--fill': quantityFill + '%' }"
              aria-label="Pallets to order"
              bng-nav-item
              data-fk="qty"
              v-bng-on-ui-nav-focus.repeat="quantityNav" />
            <div class="slider-ends note" aria-hidden="true"><span>1</span><span>{{ maxOrder }}</span></div>
          </div>
          <div class="order-foot">
            <span class="note"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.unitCost) }} per pallet</span>
            <div class="order-commit">
              <strong class="value money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(orderTotal) }}</strong>
              <HouseButton
                variant="primary"
                binding="ok"
                :disabled="busy || orderQuantity < 1"
                data-fk="order"
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                v-bng-click="{ holdCallback: orderStock, holdDelay: HOLD_MS, repeatInterval: 0 }">
                Order {{ orderQuantity }} pallet{{ orderQuantity === 1 ? '' : 's' }}
              </HouseButton>
            </div>
          </div>
        </template>
        <div v-else class="order-foot">
          <span class="note">{{ orderBlockedReason }}</span>
          <HouseButton variant="primary" disabled data-fk="order">Order pallets</HouseButton>
        </div>
      </section>

      <div class="two-up">
        <section class="panel block">
          <header class="block-head">
            <div class="head-copy">
              <span class="caption">Supplier</span>
              <h3 class="block-title">{{ supplierLabel }}</h3>
            </div>
          </header>
          <p class="hint">Park there and choose Pickup business supplies, then deliver the pallets to this store.</p>
          <div class="actions start">
            <HouseButton compact :icon="icons.routeSimpleFlag" :disabled="busy || !(dashboard.paidAtSupplier > 0)" data-fk="pickup" @click="markPickup">Route to supplier</HouseButton>
          </div>
        </section>

        <section class="panel block">
          <header class="block-head">
            <div class="head-copy">
              <span class="caption">Chain capacity</span>
              <h3 class="block-title">{{ dashboard.chainCapacity || 0 }} pallets</h3>
            </div>
          </header>
          <div class="progress">
            <div class="bar">
              <span class="ok" :style="{ width: chainPart(dashboard.chainStored) + '%' }"></span>
              <span class="transit" :style="{ width: chainPart(dashboard.chainReserved) + '%' }"></span>
            </div>
            <div class="legend">
              <span><b>{{ dashboard.chainStored || 0 }}</b>stored</span>
              <span><b>{{ dashboard.chainReserved || 0 }}</b>ordered</span>
              <span><b>{{ chainFree }}</b>free</span>
            </div>
          </div>
          <p class="hint">Shared by every store of this kind on this map.</p>
        </section>
      </div>
    </div>

    <!-- ===================== Finances: lifetime totals, economics beside the history, sale ===================== -->
    <div v-else-if="page === 'finances'" class="page fin-page">
      <section class="panel block lifetime">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Lifetime</span>
            <h3 class="block-title">{{ finance.since ? `Since ${dateLabel(finance.since)}` : 'Since this store opened' }}</h3>
          </div>
          <span v-if="totals.palletsSold" class="pill">{{ totals.palletsSold.toLocaleString() }} pallet{{ totals.palletsSold === 1 ? '' : 's' }} sold</span>
        </header>
        <div class="facts four">
          <div class="fact money"><span class="fact-key">Collected</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(totals.collected) }}</span></div>
          <div class="fact"><span class="fact-key">Supplies</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(totals.supplies) }}</span></div>
          <div class="fact"><span class="fact-key">Upgrades</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(totals.upgrades) }}</span></div>
          <div class="fact" :class="totals.net < 0 ? 'bad' : 'ok'"><span class="fact-key">Net result</span><span class="fact-value">{{ totals.net < 0 ? '−' : '' }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(Math.abs(totals.net)) }}</span></div>
        </div>
      </section>

      <div class="fin-grid">
        <div class="fin-col">
      <section class="panel block">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Unit economics</span>
            <h3 class="block-title">Each pallet sold</h3>
          </div>
          <span v-if="cycleLength" class="pill"><BngIcon class="pill-icon" :type="icons.timer" />{{ duration(cycleLength) }} to sell</span>
        </header>
        <div class="lines breakdown">
            <div class="line"><span>Sale price</span><strong class="amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.unitRevenue) }}</strong></div>
            <div class="line"><span>Supply cost <small>{{ dashboard.wholesaleOwned ? 'wholesale' : 'standard' }}</small></span><strong class="amount negative">−<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.unitCost) }}</strong></div>
            <div class="line total-line"><span>Net per pallet</span><strong class="amount ok"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.netProfitPerPallet) }}</strong></div>
        </div>
      </section>

      <!-- per-hour rates and the stock on hand in one card: one header, four figures -->
      <section class="panel block">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Running numbers</span>
            <h3 class="block-title">{{ dashboard.stock || 0 }} pallet{{ dashboard.stock === 1 ? '' : 's' }} on hand</h3>
          </div>
        </header>
        <div class="facts two">
          <div class="fact money"><span class="fact-key">Gross / hour</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ perHour(dashboard.unitRevenue) }}</span></div>
          <div class="fact"><span class="fact-key">Supplies / hour</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ perHour(dashboard.unitCost) }}</span></div>
          <div class="fact money"><span class="fact-key">Stock sales value</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money((dashboard.stock || 0) * (dashboard.unitRevenue || 0)) }}</span></div>
          <div class="fact ok"><span class="fact-key">Stock net value</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money((dashboard.stock || 0) * (dashboard.netProfitPerPallet || 0)) }}</span></div>
        </div>
      </section>
        </div>

        <!-- every money movement this store caused, newest first; the list scrolls inside the card -->
        <section class="panel block history">
          <header class="block-head">
            <div class="head-copy">
              <span class="caption">History</span>
              <h3 class="block-title">Recent activity</h3>
            </div>
          </header>
          <ul v-if="finance.history.length" class="history-list scroll" v-bng-ui-nav-scroll>
            <li v-for="(row, index) in finance.history" :key="`${row.time}-${index}`" class="history-row">
              <span class="history-icon" :class="{ in: row.income }"><BngIcon :type="historyIcon(row.kind)" /></span>
              <span class="history-copy">
                <span class="history-label">{{ historyLabel(row) }}</span>
                <span class="note">{{ timeAgo(row.time) }}</span>
              </span>
              <strong class="history-amount" :class="{ in: row.income }">{{ row.income ? '+' : '−' }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(row.amount) }}</strong>
            </li>
          </ul>
          <div v-else class="history-empty">
            <span class="note">Nothing yet. Collections, supply orders and upgrades show up here.</span>
          </div>
        </section>
      </div>

      <section class="panel block">
        <header v-if="!saleQuote" class="block-head">
          <div class="head-copy">
            <span class="caption">Property</span>
            <h3 class="block-title">Sell {{ dashboard.businessName || 'business' }}</h3>
            <p class="hint">Get a final resale quote before permanently closing this business.</p>
          </div>
          <HouseButton variant="quiet-danger" :disabled="busy || saleLoading" data-fk="sell" @click="requestSaleQuote">
            {{ saleLoading ? 'Loading quote…' : 'Sell store' }}
          </HouseButton>
        </header>
        <!-- B backs out of the confirmation before it leaves the page -->
        <div v-else class="sale-confirm" v-bng-on-ui-nav:back.focusRequired="cancelSale">
          <div class="head-copy">
            <span class="caption">Confirm permanent sale</span>
            <h3 class="block-title">Expected payout: <span class="money nowrap"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(saleQuote.netPayout) }}</span></h3>
          </div>
          <p class="notice bad">Stock, pending supply orders, in-transit supplies, upgrades, and uncollected earnings are forfeited. Collect earnings first if you want to keep them.</p>
          <div class="actions">
            <HouseButton variant="quiet" binding="back" :disabled="busy" data-fk="sale-cancel" @click="cancelSale">Cancel</HouseButton>
            <HouseButton
              variant="danger"
              binding="ok"
              :disabled="busy"
              data-fk="sale-confirm"
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-bng-click="{ holdCallback: confirmSale, holdDelay: HOLD_MS, repeatInterval: 0 }">
              Confirm sale
            </HouseButton>
          </div>
        </div>
      </section>
    </div>

    <!-- ===================== Upgrades: storage and wholesale ===================== -->
    <div v-else class="page">
      <section class="panel block">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Storage</span>
            <h3 class="block-title">{{ dashboard.capacity || 0 }} pallets<template v-if="dashboard.nextStorageCapacity"> → {{ dashboard.nextStorageCapacity }}</template></h3>
          </div>
          <span class="pill" :class="{ ok: !dashboard.nextStorageCapacity }"><BngIcon class="pill-icon" :type="dashboard.nextStorageCapacity ? icons.stack3 : icons.checkmark" />Level {{ storageLevel }} / {{ maxStorageLevel }}</span>
        </header>
        <div class="levels" aria-hidden="true">
          <span v-for="n in maxStorageLevel" :key="n" :class="{ on: n <= storageLevel }"></span>
        </div>
        <div v-if="dashboard.nextStorageCapacity" class="upgrade-foot">
          <span class="note">Adds {{ duration(dashboard.nextStorageRuntimeAddedSeconds) }} of stocked runtime</span>
          <HouseButton
            :disabled="busy"
            data-fk="storage"
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: upgradeStorage, holdDelay: HOLD_MS, repeatInterval: 0 }">
            Upgrade for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.nextStorageUpgradeCost) }}
          </HouseButton>
        </div>
        <p v-else class="hint">Storage is fully upgraded.</p>
      </section>

      <section class="panel block">
        <header class="block-head">
          <div class="head-copy">
            <span class="caption">Supply contract</span>
            <h3 class="block-title">Wholesale agreement</h3>
          </div>
          <span v-if="dashboard.wholesaleOwned" class="pill ok"><BngIcon class="pill-icon" :type="icons.checkmark" />Owned</span>
        </header>
        <template v-if="!dashboard.wholesaleOwned">
          <div class="facts">
            <div class="fact money"><span class="fact-key">Pallet price</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.baseUnitCost) }} → <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.wholesaleUnitCost) }}</span></div>
            <div class="fact ok"><span class="fact-key">Extra net</span><span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.wholesaleImprovementPerHour) }} <small>/ hr</small></span></div>
            <div class="fact"><span class="fact-key">Pays back in</span><span class="fact-value">{{ duration(dashboard.wholesalePaybackSeconds) }}</span></div>
          </div>
          <div class="actions">
            <HouseButton
              :disabled="busy"
              data-fk="wholesale"
              v-bng-on-ui-nav:ok.asMouse.focusRequired
              v-bng-click="{ holdCallback: buyWholesale, holdDelay: HOLD_MS, repeatInterval: 0 }">
              Purchase for <BngIcon class="cur" :type="icons.beamCurrency" />{{ money(dashboard.wholesaleUpgradeCost) }}
            </HouseButton>
          </div>
        </template>
        <p v-else class="hint">All future {{ dashboard.supplyName || 'business supply' }} orders use the wholesale price.</p>
      </section>
    </div>
    </template>
  </div>
</template>

<script setup>
import { setFocus } from "@/services/uiNavFocus"
import { useNowSeconds } from "../../../../composables/useNowSeconds.js"
import { assignChanged, secondsUntil } from "../../../../stores/businessComputer/businessTime.js"
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { BngIcon, icons } from '@/common/components/base'
import { vBngClick, vBngOnUiNav, vBngOnUiNavFocus, vBngUiNavScroll } from '@/common/directives'
import { HouseButton, HouseSwitch } from '../../../house/index.js'
import { refocusIfLost } from '../../../../composables/useScreenEntryFocus'
import { useBusinessComputerStore } from "../../../../stores/businessComputerStore"
import { useBusinessSessionStore } from "../../../../stores/businessComputer/businessSessionStore.js"

const props = defineProps({ data: Object })
const dashboard = reactive({})
const nowSeconds = useNowSeconds()
const runtimeExpiresAtSeconds = ref(null)
const cycleExpiresAtSeconds = ref(null)
const runtimeSeconds = computed(() => dashboard.operating
  ? secondsUntil(runtimeExpiresAtSeconds.value, nowSeconds.value) : Number(dashboard.remainingRuntimeSeconds) || 0)
const cycleRemainingSeconds = computed(() => dashboard.operating
  ? secondsUntil(cycleExpiresAtSeconds.value, nowSeconds.value) : Number(dashboard.cycleRemainingSeconds) || 0)
const supplyEnabled = computed(() => dashboard.supplyEnabled !== false)
const busy = ref(false)
const message = ref('')
const messageError = ref(false)
const orderQuantity = ref(1)
const saleQuote = ref(null)
const saleLoading = ref(false)
// Finances: lifetime totals and the history rows (Lua records every collection, order and upgrade)
const finance = reactive({ history: [], totals: {}, since: null, now: null })
const totals = computed(() => {
  const t = finance.totals || {}
  const n = key => Math.round(Number(t[key]) || 0)
  return { collected: n('collected'), supplies: n('supplies'), upgrades: n('upgrades'), net: n('net'), palletsSold: n('palletsSold') }
})
const rootRef = ref(null)
let poll = null
let unmounted = false
// spending money is hold-to-confirm, as in the other shops (EngineRetail, vehicle purchase)
const HOLD_MS = 1000

const computerStore = useBusinessComputerStore()
const sessionStore = useBusinessSessionStore()
// the sidebar entry picks the section (the store's passive sections pass it as data.view)
const PAGES = ['dashboard', 'stock', 'finances', 'upgrades']
const page = computed(() => (supplyEnabled.value && PAGES.includes(props.data?.view) ? props.data.view : 'dashboard'))
const PAGE_TITLES = {
  dashboard: { title: 'Dashboard' },
  stock: { title: 'Stock & Supplies', hint: 'Pay for pallets here; they wait at the supplier until you collect them.' },
  finances: { title: 'Finances', hint: 'What each sale earns and what the stock on hand is worth.' },
  upgrades: { title: 'Upgrades', hint: 'Grow storage and lower what each pallet costs.' },
}

const orderTotal = computed(() => Math.max(0, Math.round(orderQuantity.value || 0)) * (Number(dashboard.unitCost) || 0))
const canCollect = computed(() => Number(dashboard.uncollectedEarnings) > 0)
const maxOrder = computed(() => Math.max(0, Math.floor(Number(dashboard.maximumOrder) || 0)))
const cycleRunning = computed(() => !!dashboard.operating && dashboard.stock > 0)
const cycleSeconds = computed(() => Math.max(0, Number(dashboard.cycleSeconds) || 0))
const cycleLabel = computed(() => !dashboard.operating ? 'Closed' : dashboard.stock > 0 ? duration(cycleRemainingSeconds) : 'Out of stock')
// status by exception: closed is quiet, an empty store is a warning
const cycleTone = computed(() => (!dashboard.operating ? 'idle' : dashboard.stock > 0 ? null : 'warn'))
// Lua sends cycleSeconds; older data can be derived from the runtime of the stock on hand
const cycleLength = computed(() => {
  if (cycleSeconds.value) return cycleSeconds.value
  const stock = Number(dashboard.stock) || 0
  const runtime = runtimeSeconds.value
  const first = cycleRemainingSeconds.value
  return stock > 1 ? Math.max(0, (runtime - first) / (stock - 1)) : 0
})
const cyclePercent = computed(() => {
  if (!cycleLength.value || !cycleRunning.value) return null
  return Math.min(100, Math.max(0, (1 - (cycleRemainingSeconds.value) / cycleLength.value) * 100))
})
// Earnings outlook: pending earnings over time if nothing is collected, from the stock on hand and the
// cycle (one sale per cycle adds the sale price). The horizon runs a little past sell-out so the flat
// part shows where earning stops.
const OUTLOOK_BARS = 28
const outlook = computed(() => {
  const stock = Number(dashboard.stock) || 0
  const runtime = runtimeSeconds.value
  if (!dashboard.operating || stock <= 0 || runtime <= 0) return null
  const first = cycleRemainingSeconds.value
  const cycle = cycleLength.value || runtime
  const base = Number(dashboard.uncollectedEarnings) || 0
  const revenue = Number(dashboard.unitRevenue) || 0
  const end = base + stock * revenue
  const horizon = runtime * 1.2
  const bars = []
  for (let i = 1; i <= OUTLOOK_BARS; i++) {
    const t = (horizon * i) / OUTLOOK_BARS
    const sold = t + 0.5 < first ? 0 : Math.min(stock, Math.floor((t - first) / cycle + 1e-6) + 1)
    const value = base + sold * revenue
    bars.push({ t, value, pct: end > 0 ? Math.max(1.5, (value / end) * 100) : 0, after: t > runtime + 1 })
  }
  return { bars, end, horizon, sellOutPct: (runtime / horizon) * 100 }
})
const stockPercent = computed(() => {
  const cap = Number(dashboard.capacity) || 0
  return cap > 0 ? Math.min(100, Math.max(0, ((Number(dashboard.stock) || 0) / cap) * 100)) : 0
})
const storageLevel = computed(() => dashboard.storageLevel || 1)
const maxStorageLevel = computed(() => Math.max(1, dashboard.maxStorageLevel || 5))
const supplierLabel = computed(() => dashboard.supplierName || 'Business supplier')
const chainFree = computed(() => Math.max(0, (dashboard.chainCapacity || 0) - (dashboard.chainStored || 0) - (dashboard.chainReserved || 0)))
const chainPart = value => {
  const cap = Number(dashboard.chainCapacity) || 0
  return cap > 0 ? Math.min(100, Math.max(0, ((Number(value) || 0) / cap) * 100)) : 0
}
// Controller stepping for the pallet slider (same directive as the loan amount). The binding object must
// stay the same between renders (the directive restarts its hold-repeat when it changes), so it only
// rebuilds when the orderable maximum changes.
const quantityNav = computed(() => ({
  min: 1,
  max: maxOrder.value,
  step: 1,
  value: () => Number(orderQuantity.value) || 1,
  callback: (dir, val) => {
    if (val != null) setQuantity(val)
  },
}))
const quantityFill = computed(() => (maxOrder.value > 1 ? ((orderQuantity.value - 1) / (maxOrder.value - 1)) * 100 : 100))
// one muted line when nothing can be ordered: the chain has no room, or the wallet cannot cover a pallet
const orderBlockedReason = computed(() => {
  if (dashboard.chainFree === 0 || chainFree.value === 0) return 'No room: every pallet of chain capacity is stored or already ordered.'
  if (dashboard.affordableQuantity === 0) return 'Your wallet cannot cover one pallet right now.'
  return 'Ordering is unavailable right now.'
})

// number only: the template puts the game currency glyph in front
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
const perHour = value => (cycleLength.value > 0 ? money((Number(value) || 0) * 3600 / cycleLength.value) : '—')
function duration(value) {
  const total = Math.max(0, Math.ceil(Number(value) || 0))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  if (hours) return `${hours}h ${minutes}m`
  return `${minutes}m ${String(seconds).padStart(2, '0')}s`
}

function focusOrder() {
  if (document.activeElement?.dataset?.fk !== "qty") return true
  const target = rootRef.value?.querySelector('[data-fk="order"]')
  if (target) { target.scrollIntoView({ block: 'nearest' }); setFocus(target) }
  return false
}
function setQuantity(value) {
  const max = maxOrder.value
  if (max <= 0) return
  orderQuantity.value = Math.min(max, Math.max(1, Math.round(value)))
}

// Pad: actions disable every control while busy, and section / v-if swaps remove the focused one. Put
// focus back on the same control (data-fk) once it is live again, else on the first live control here.
const focusedKey = () => document.activeElement?.closest?.('[data-fk]')?.dataset.fk
const restoreFocus = (key, opts) => refocusIfLost(() => {
  const root = rootRef.value
  if (!root) return null
  return (key && root.querySelector(`[data-fk="${key}"]:not(:disabled):not(.disabled)`)) || root.querySelector('button:not(:disabled), .house-switch:not(.disabled)')
}, opts)

// widget ">" links select that section in the sidebar, like clicking its sidebar row
function goPage(id) {
  if (!sessionStore.registeredTabs.some(tab => tab.id === id)) return
  computerStore.switchView(id)
  // the link is gone with the dashboard; carry on from the new section's first control
  restoreFocus(null, { force: true })
}

const FINANCE_POLL_MS = 10000
let refreshInFlight = false
let refreshQueued = false
let lastFinanceRefreshAt = 0
async function refresh(force = false) {
  if (unmounted) return
  if (refreshInFlight) { refreshQueued ||= force === true; return }
  refreshInFlight = true
  try {
    const businessId = props.data?.businessId
    const result = await lua.overhaul_career_business_computer.getPassiveBusinessDashboardData(businessId)
    if (unmounted || businessId !== props.data?.businessId) return
    if (result && typeof result === 'object') {
      // Lua omits these fields once storage is fully upgraded; clear the previous offer.
      const next = { nextStorageCapacity: null, nextStorageUpgradeCost: null, ...result }
      // A business without a supply chain omits stock fields; drop keys the new payload no longer carries.
      for (const key of Object.keys(dashboard)) if (!(key in next)) delete dashboard[key]
      assignChanged(dashboard, next)
      const receivedAtSeconds = Math.floor(Date.now() / 1000)
      runtimeExpiresAtSeconds.value = receivedAtSeconds + Math.max(0, Number(result.remainingRuntimeSeconds) || 0)
      cycleExpiresAtSeconds.value = receivedAtSeconds + Math.max(0, Number(result.cycleRemainingSeconds) || 0)
    }
    if (page.value === 'finances' && (force === true || Date.now() - lastFinanceRefreshAt >= FINANCE_POLL_MS)) await refreshFinance()
  } finally {
    refreshInFlight = false
    if (refreshQueued) { refreshQueued = false; void refresh() }
  }
}
async function refreshFinance() {
  lastFinanceRefreshAt = Date.now()
  const result = await lua.overhaul_career_business_computer.getPassiveBusinessFinanceData?.(props.data?.businessId)
  if (result?.success) {
    // Lua sends an empty history as {}
    assignChanged(finance, {
      history: Array.isArray(result.history) ? result.history : Object.values(result.history || {}),
      totals: result.totals || {}, since: result.since || null, now: result.now || null,
    })
  }
}
// names checked against the game's icon font (a missing name renders the red placeholder)
const HISTORY_ICONS = { collect: 'banknotes', order: 'cardboardBox', storage: 'stack3', wholesale: 'cardboardBoxCoins' }
const historyIcon = kind => icons[HISTORY_ICONS[kind]] || icons.beamCurrency
function historyLabel(row) {
  if (row.kind === 'collect') return 'Collected earnings'
  if (row.kind === 'order') return row.quantity ? `Ordered ${row.quantity} pallet${row.quantity === 1 ? '' : 's'}` : 'Ordered supplies'
  if (row.kind === 'storage') return 'Storage upgrade'
  if (row.kind === 'wholesale') return 'Wholesale agreement'
  return 'Payment'
}
// Lua times are real-world seconds (os.time), the same clock as the wallet history
const dateLabel = seconds => new Date((Number(seconds) || 0) * 1000).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
function timeAgo(seconds) {
  const now = Number(finance.now) || Date.now() / 1000
  const diff = Math.max(0, now - (Number(seconds) || 0))
  if (diff < 60) return 'Just now'
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)} h ago`
  if (diff < 7 * 86400) return `${Math.floor(diff / 86400)} d ago`
  return dateLabel(seconds)
}
async function perform(method, ...args) {
  if (busy.value) return
  const key = focusedKey()
  busy.value = true
  message.value = ''
  try {
    const result = await lua.overhaul_career_business_computer[method](props.data?.businessId, ...args)
    messageError.value = result?.success === false
    message.value = result?.message || (result?.success ? 'Updated successfully.' : '')
    await refresh(true)
  } finally {
    busy.value = false
    restoreFocus(key)
  }
}
const collect = () => perform('collectPassiveBusinessEarnings')
const upgradeStorage = () => perform('purchasePassiveBusinessStorageUpgrade')
const buyWholesale = () => perform('purchasePassiveBusinessWholesale')
const toggleOperating = () => perform('setPassiveBusinessOperating', !dashboard.operating)
const markPickup = () => perform('setPassiveBusinessSupplyRoute')
const orderStock = async () => {
  const quantity = Math.min(Math.max(1, Math.round(orderQuantity.value || 1)), dashboard.maximumOrder || 0)
  if (quantity <= 0) return
  await perform('orderPassiveBusinessSupply', quantity)
  orderQuantity.value = Math.min(1, dashboard.maximumOrder || 0)
}
// dashboard quick order: same Lua call and limit as the Stock section
const quickOrder = async quantity => {
  const amount = Math.min(Math.max(1, Math.round(quantity || 1)), dashboard.maximumOrder || 0)
  if (amount <= 0) return
  await perform('orderPassiveBusinessSupply', amount)
}
const requestSaleQuote = async () => {
  if (busy.value || saleLoading.value) return
  saleLoading.value = true
  try {
    const result = await lua.overhaul_career_business_computer.requestPassiveBusinessSaleData(props.data?.businessId)
    if (result?.success) {
      saleQuote.value = result
      // the Sell button is gone; land on the safe choice
      restoreFocus('sale-cancel', { force: true })
    } else {
      messageError.value = true
      message.value = result?.message || 'The resale quote is unavailable.'
    }
  } finally {
    saleLoading.value = false
    if (!saleQuote.value) restoreFocus('sell')
  }
}
const cancelSale = () => {
  saleQuote.value = null
  restoreFocus('sell', { force: true })
  return false
}
const confirmSale = async () => {
  if (busy.value) return
  busy.value = true
  try {
    const result = await lua.overhaul_career_business_computer.sellPassiveBusiness(props.data?.businessId)
    if (result?.success === false) {
      messageError.value = true
      message.value = result?.message || 'The business could not be sold.'
      busy.value = false
      restoreFocus('sale-cancel')
    }
  } catch (error) {
    busy.value = false
  }
}

// leaving Finances drops a pending sale confirmation; a message belongs to the section it came from
watch(page, value => {
  if (value !== 'finances') saleQuote.value = null
  else refreshFinance()
  message.value = ''
})
watch(() => dashboard.maximumOrder, maximum => {
  const max = Math.max(0, Math.floor(Number(maximum) || 0))
  if (max <= 0) orderQuantity.value = 0
  else if (orderQuantity.value < 1 || orderQuantity.value > max) orderQuantity.value = Math.min(1, max)
})

onMounted(async () => {
  await refresh(true)
  if (unmounted) return
  poll = window.setInterval(refresh, 5000)
})
onUnmounted(() => {
  unmounted = true
  window.clearInterval(poll)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* The Business Computer card carries .rls-house and the vh-based em scale; everything here is em.
   No fixed heights or overflow-hidden value lines: values keep their full line box at every scale. */
.passive-app {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  min-width: 0;
  min-height: 100%;
  color: #fff;
  font-variant-numeric: tabular-nums;
}

.caption { display: block; }
.hint { font-size: 0.85em; line-height: 1.4; }
.nowrap { white-space: nowrap; }
.money { color: var(--money); }
.faint { color: var(--faint) !important; }
.note {
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.3;
}
.pill-icon,
.key-icon {
  --bng-icon-size: 1.15em;
  flex: 0 0 auto;
  transform: translateY(-0.1em);
}

/* ---------- page header (house .page-head) ---------- */
.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: var(--space-2) var(--space-4);
}
.page-copy {
  display: grid;
  gap: 0.3em;
  min-width: 0;
  flex: 1 1 16em;
}
.page-title {
  margin: 0;
  color: #fff;
  font-size: 1.4em;
  font-weight: 800;
  line-height: 1.15;
}
.page-head .hint { font-size: 0.9em; }
.store-switch {
  flex: 0 0 auto;
  font-weight: 700;
}

/* ---------- type: three steps (kicker .fact-key / figure .value / secondary .note) ---------- */
.value {
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.25;
  white-space: nowrap;
  small {
    margin-left: 0.3em;
    color: var(--faint);
    font-size: 0.6em;
    font-weight: 700;
  }
}
.value.idle { color: var(--faint); }
.value.warn { color: var(--warn); }

/* ---------- dashboard: 3 cards, stock, outlook taking the remaining height ---------- */
.widgets {
  flex: 1 1 auto;
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  grid-template-rows: auto auto minmax(11em, 1fr);
  gap: var(--space-2);
}
.widget {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-width: 0;
  padding: 0.75em 0.9em 0.85em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.widget.span-3 { grid-column: 1 / -1; }
.widget-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  min-height: 1.7em;
}
.house-button.jump {
  margin: -0.35em -0.45em -0.35em 0;
  padding: 0.4em 0.45em;
  font-size: 0.9em;
}
.widget-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.6em 0.9em;
}
.widget-copy {
  display: grid;
  gap: 0.35em;
  min-width: 0;
}
.widget-copy.grow { flex: 1 1 14em; }
.widget-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.4em;
}
.widget > .widget-actions {
  margin-top: auto;
  padding-top: 0.45em;
  min-height: 2.4em;
}
.widget-actions .grow { flex: 1 1 auto; }
.meter.thin { height: 0.35em; }
.meter.thin > span { background: rgba(255, 255, 255, 0.55); }
.btn-price {
  margin-left: 0.35em;
  color: var(--money);
  .cur { --bng-icon-size: 1em; }
}

/* outlook chart */
.outlook { min-height: 0; }
.chart {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-height: 6em;
}
.plot {
  position: relative;
  flex: 1 1 auto;
  display: flex;
  align-items: flex-end;
  gap: 2px;
  min-height: 5em;
  border-bottom: 1px solid var(--line);
}
.plot .bar {
  flex: 1 1 0;
  min-width: 0;
  border-radius: 4px 4px 0 0;
  background: var(--money);
  opacity: 0.85;
}
.plot .bar.after { background: rgba(255, 255, 255, 0.14); opacity: 1; }
.sellout {
  position: absolute;
  top: 0;
  bottom: 0;
  width: 0;
  border-left: 1px dashed rgba(255, 255, 255, 0.35);
  pointer-events: none;
  .note {
    position: absolute;
    top: 0;
    right: 0.4em;
    white-space: nowrap;
  }
}
.axis {
  display: flex;
  justify-content: space-between;
}
.chart-empty {
  flex: 1 1 auto;
  display: grid;
  place-content: center;
  justify-items: center;
  gap: 0.3em;
  text-align: center;
}

/* ---------- section pages ---------- */
.page {
  display: grid;
  gap: var(--space-2);
}
.block {
  gap: var(--space-3);
  padding: 0.9em 1em;
}
.block-head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--space-2) var(--space-4);
}
.head-copy {
  display: grid;
  gap: 0.25em;
  flex: 1 1 14em;
  min-width: 0;
}
.head-copy .block-title { font-size: 1.15em; overflow-wrap: anywhere; }
.block-head > .pill { flex: 0 0 auto; }
.fact-value small { color: var(--faint); font-size: 0.75em; font-weight: 700; }
/* figures are never cut off ("12,…"): a fact that does not fit moves to the next row of its grid */
.facts { grid-template-columns: repeat(auto-fit, minmax(min(100%, 7.5em), 1fr)); }
.fact-value {
  overflow: visible;
  text-overflow: clip;
}
.facts.two { grid-template-columns: repeat(auto-fit, minmax(min(100%, 9em), 1fr)); }
.actions.start { justify-content: flex-start; }
.two-up {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--space-2);
}
.two-up .block { align-content: start; }

/* order: flat inside the card */
.qty-slider {
  display: grid;
  gap: 0.35em;
}
.slider-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--space-3);
}
.slider-ends {
  display: flex;
  justify-content: space-between;
}
// controller focus on the slider: only its thumb lights up (a ring round the whole track read as too
// much); the game's frame stays hidden
.qty-range {
  &.focus-visible {
    outline: none;
    box-shadow: none;
  }
  &.focus-visible::before {
    display: none !important;
  }
  &.focus-visible::-webkit-slider-thumb {
    box-shadow: 0 0 0 0.22em rgba(255, 102, 0, 0.55), 0 0.05em 0.3em rgba(0, 0, 0, 0.35);
  }
}
.order-foot {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2) var(--space-4);
  padding-top: var(--space-3);
  border-top: 1px solid var(--line);
}
.order-commit {
  display: flex;
  align-items: center;
  gap: 0.8em;
}

/* finances: lifetime row, then the economics column beside a history list that takes the remaining
   height (the page fills the content area; only the list scrolls) */
.passive-app.fills { height: 100%; }
.fin-page {
  flex: 1 1 0;
  min-height: 0;
  // the middle row never drops below the economics column (only the history list gives way and scrolls)
  grid-template-rows: auto minmax(min-content, 1fr) auto;
}
.facts.four { grid-template-columns: repeat(auto-fit, minmax(min(100%, 8.5em), 1fr)); }
.fact.bad .fact-value { color: var(--bad); }
.fact.ok .fact-value { color: var(--ok); }
.fin-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr);
  gap: var(--space-2);
  min-height: 0;
}
.fin-col {
  display: grid;
  align-content: start;
  gap: var(--space-2);
  min-width: 0;
}
.history {
  display: flex;
  flex-direction: column;
  min-height: 12em;
}
.history-list {
  flex: 1 1 0;
  min-height: 0;
  margin: 0 -0.4em;
  padding: 0 0.4em;
  list-style: none;
}
.history-row {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.7em;
  padding: 0.5em 0;
  border-bottom: 1px solid var(--line);
  &:last-child { border-bottom: 0; }
}
.history-icon {
  display: grid;
  place-items: center;
  width: 1.9em;
  height: 1.9em;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.07);
  color: var(--muted);
  --bng-icon-size: 1em;
  &.in { color: var(--money); }
}
.history-copy {
  display: grid;
  gap: 0.1em;
  min-width: 0;
}
.history-label {
  font-weight: 700;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.history-amount {
  font-weight: 800;
  white-space: nowrap;
  &.in { color: var(--money); }
  .cur { --bng-icon-size: 1em; }
}
.history-empty {
  flex: 1 1 auto;
  display: grid;
  place-content: center;
  text-align: center;
}

/* finances: breakdown lines, flat inside the card */
.breakdown .line {
  font-weight: 600;
  small { margin-left: 0.4em; color: var(--faint); font-size: 0.8em; font-weight: 700; }
}
.line .amount { font-weight: 800; white-space: nowrap; }
.line .amount.ok { color: var(--ok); }
.line.total-line { font-weight: 800; }

/* upgrades: one segment per storage level */
.levels {
  display: grid;
  grid-auto-flow: column;
  grid-auto-columns: minmax(0, 1fr);
  gap: 0.3em;
}
.levels span {
  height: 0.45em;
  border-radius: 1em;
  background: rgba(255, 255, 255, 0.12);
}
.levels span.on { background: var(--ok); }
.upgrade-foot {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2) var(--space-4);
}

/* sale */
.sale-confirm {
  display: grid;
  gap: var(--space-3);
}

/* game currency glyph in front of amounts: drawn at the text's own size, coloured like it */
.cur {
  --bng-icon-size: 1.1em;
  margin-right: 0.08em;
  transform: translateY(0.06em);
}
</style>

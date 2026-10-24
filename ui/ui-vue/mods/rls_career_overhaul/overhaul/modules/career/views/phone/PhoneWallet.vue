<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Phone Wallet: balance and recent activity, plus the same money grouped by vehicle, by work type
     and by category. The Lua read model groups, sorts and totals; this screen picks the view and
     draws it. Reading order: tabs and sorts (data), loading, motion, then the template's pieces. -->
<template>
  <div ref="rootRef" class="wallet" v-bng-on-ui-nav:tab_l="() => stepTab(-1)" v-bng-on-ui-nav:tab_r="() => stepTab(1)">
    <div ref="scrollRef" class="wallet-scroll" :class="{ grouped: tab.groupBy !== 'none' }" v-bng-ui-nav-scroll.force
      :bng-no-child-nav="menuOpen ? 'true' : null">
      <div :id="panelId" ref="bodyRef" class="wallet-body" role="tabpanel" :aria-labelledby="`${panelId}-${tab.id}`"
        :aria-busy="loading ? 'true' : null" :class="{ moving: contentMoving }">
        <div v-if="(failed || retrying) && view" class="wallet-banner" role="status">
          <span>Couldn't refresh. Showing the last loaded history.</span>
          <button type="button" class="wallet-pill-button" bng-nav-item :aria-disabled="retrying ? 'true' : null" @click="tryAgain">{{ retrying ? "Trying again" : "Try again" }}</button>
        </div>
        <div v-if="(failed || retrying) && !view" class="wallet-empty">
          <h3>Wallet history didn't load</h3>
          <p>Your money is safe. Try again in a moment.</p>
          <button type="button" class="wallet-pill-button" bng-nav-item :aria-disabled="retrying ? 'true' : null" @click="tryAgain">{{ retrying ? "Trying again" : "Try again" }}</button>
        </div>

        <template v-else-if="view">
          <!-- Activity -->
          <template v-if="tab.id === 'activity'">
            <section class="wallet-card" aria-label="Balance">
              <span class="wallet-key">Balance</span>
              <strong class="wallet-balance">{{ formatMoney(view.balance) }}</strong>
              <div class="wallet-card-stats">
                <span><span class="wallet-key">Earned</span><b class="on-card-income">{{ formatMoney(view.totals.income) }}</b></span>
                <span><span class="wallet-key">Spent</span><b class="on-card-expense">{{ formatMoney(view.totals.expenses) }}</b></span>
                <span><span class="wallet-key">Net</span><b>{{ formatSigned(view.totals.net) }}</b></span>
                <span v-if="toneOf(transferNet(view.totals)) !== 'neutral'"><span class="wallet-key">Transfers</span><b>{{ formatSigned(transferNet(view.totals)) }}</b></span>
              </div>
              <div v-if="view.totals.income || view.totals.expenses" class="wallet-split" aria-hidden="true">
                <i v-if="view.totals.income > 0" class="split-income" :style="{ flexGrow: view.totals.income }"></i>
                <i v-if="view.totals.expenses > 0" class="split-expense" :style="{ flexGrow: view.totals.expenses }"></i>
              </div>
            </section>

            <div v-if="!view.rows.length" class="wallet-empty">
              <span class="wallet-empty-icon" aria-hidden="true"><BngIcon :type="icons.banknotes" /></span>
              <h3>No transactions yet</h3>
              <p>Money you earn from work and spend on cars, fuel and repairs shows up here.</p>
            </div>
            <template v-else>
              <div class="wallet-section-head">
                <h3>Recent</h3>
                <button ref="sortButtonRef" type="button" class="wallet-pill-button" data-fk="sort" bng-nav-item @click="openSort">
                  <BngIcon :type="icons.sortDesc" /> {{ currentSort.label }}
                </button>
              </div>
              <WalletTransactionList :rows="view.rows" :limit="rowLimit" :now="now" label="Recent transactions" />
              <button v-if="view.rows.length > rowLimit || view.paging?.hasMore" type="button" class="wallet-more" bng-nav-item @click="showMoreRows">
                {{ pageLoading ? "Loading" : "Show more" }}
              </button>
            </template>
          </template>

          <!-- Grouped tabs: a deck of group cards; one pulls out to show everything in it -->
          <template v-else>
            <div class="wallet-section-head">
              <h3>{{ groupHeading }}</h3>
              <button v-if="view.groups.length" ref="sortButtonRef" type="button" class="wallet-pill-button" data-fk="sort" bng-nav-item @click="openSort">
                <BngIcon :type="icons.sortDesc" /> {{ currentSort.label }}
              </button>
            </div>

            <div v-if="tabEmpty" class="wallet-empty">
              <span class="wallet-empty-icon" aria-hidden="true"><BngIcon :type="icons[tab.icon] || icons[FALLBACK_ICON]" /></span>
              <h3>{{ tab.emptyTitle }}</h3>
              <p>{{ tab.emptyText }}</p>
            </div>

            <!-- Categories: where the money went -->
            <section v-if="tab.id === 'categories' && shares.length && !view.paging?.hasMore" ref="panelRef" class="wallet-panel" aria-label="Spending by category">
              <span class="wallet-key">Spent by category</span>
              <strong class="wallet-panel-total expense">{{ formatMoney(view.totals.expenses) }}</strong>
              <!-- Each segment is a stop for pointer, keyboard and controller. Its label says what the tooltip shows. -->
              <div class="wallet-split tall" role="group" aria-label="Spending by category" @pointerleave="hideShare">
                <button v-for="share in shares" :key="share.id" type="button" class="wallet-share" :style="{ flexGrow: share.amount, backgroundColor: share.accent }"
                  :aria-label="shareLabel(share, $ctx_t)" bng-nav-item @pointerenter="showShare(share, $event.currentTarget)" @focus="showShare(share, $event.currentTarget)" @blur="hideShare"></button>
              </div>
              <div v-if="shareTip" class="wallet-share-tip" aria-hidden="true" :style="{ left: `${shareTip.left}px`, top: `${shareTip.top}px` }">
                <strong>{{ displayName(shareTip.share.name, $ctx_t) }}</strong>
                <span>{{ formatMoney(shareTip.share.amount) }}</span>
                <span>{{ percentLabel(shareTip.share.share) }} of spending</span>
              </div>
            </section>

            <!-- Keyed by tab: groups of different kinds can share an id ("unknown"). -->
            <GroupCardStack v-if="!tabEmpty" :key="tab.id" class="wallet-stack" :groups="view.groups" :tint="tabAccent" :label="tab.title" :detail-label="tab.title" @open="loadGroup" @more="loadGroup" @close="closeGroup">
              <template #card="{ group }">
                <span class="wallet-stack-card">
                  <span class="wallet-tile" :style="{ backgroundColor: tabAccent(group) }" aria-hidden="true">
                    <BngIcon :type="icons[groupIcon(group)] || icons[FALLBACK_ICON]" />
                  </span>
                  <span class="wallet-row-copy">
                    <span class="wallet-group-name">{{ groupLabel(group, tab.groupBy, $ctx_t) }}</span>
                    <span class="wallet-row-sub">{{ countLabel(group.totals.count) }}<template v-if="shareOf(group)">, {{ shareOf(group) }} of spending</template></span>
                  </span>
                  <span class="wallet-row-amount">
                    <span class="wallet-key">Net</span>
                    <b class="wallet-group-net" :class="toneOf(group.totals.net)">{{ formatSigned(group.totals.net) }}</b>
                  </span>
                </span>
              </template>
              <!-- The pulled-out header already names the group and puts it back when tapped. -->
              <template #detail="{ group, limit, page, showMore }">
                <div class="wallet-detail">
                  <div class="wallet-group-stats">
                    <span><span class="wallet-key">Earned</span><b class="income">{{ formatMoney(group.totals.income) }}</b></span>
                    <span><span class="wallet-key">Spent</span><b class="expense">{{ formatMoney(group.totals.expenses) }}</b></span>
                    <span v-if="toneOf(transferNet(group.totals)) !== 'neutral'"><span class="wallet-key">Transfers</span><b>{{ formatSigned(transferNet(group.totals)) }}</b></span>
                    <span v-else-if="tab.groupBy !== 'category' && topCost(group)"><span class="wallet-key">Top cost</span><b>{{ displayName(topCost(group), $ctx_t) }}</b></span>
                  </div>
                  <div v-if="group.totals.income > 0 || group.totals.expenses > 0" class="wallet-split" aria-hidden="true">
                    <i v-if="group.totals.income > 0" class="split-income" :style="{ flexGrow: group.totals.income }"></i>
                    <i v-if="group.totals.expenses > 0" class="split-expense" :style="{ flexGrow: group.totals.expenses }"></i>
                  </div>
                  <p v-if="group.loading" class="wallet-row-sub">Loading transactions</p>
                  <button v-if="group.failed" type="button" class="wallet-more" bng-nav-item @click="loadGroup(group, group.rows.length + 1)">Try again</button>
                  <WalletTransactionList :rows="group.rows" :limit="limit" :now="now" :group-by="tab.groupBy" :label="`${groupLabel(group, tab.groupBy, $ctx_t)} transactions`" />
                  <button v-if="group.rows.length > limit || group.paging?.hasMore" type="button" class="wallet-more" bng-nav-item @click="showMore">
                    {{ group.loading ? "Loading" : group.paging ? "Show more" : "Show " + Math.min(page, group.rows.length - limit) + " more" }}
                  </button>
                </div>
              </template>
            </GroupCardStack>
            <button v-if="view.paging?.hasMore" type="button" class="wallet-more" bng-nav-item @click="loadMore">{{ pageLoading ? "Loading" : "Show more groups" }}</button>
          </template>
          <p v-if="pageFailed" class="wallet-row-sub" role="status">Could not load more. Try again.</p>
        </template>

        <div v-else class="wallet-loading" aria-live="polite">Loading your wallet</div>
      </div>
    </div>

    <header class="wallet-header" :bng-no-child-nav="menuOpen ? 'true' : null">
      <div class="wallet-segment" role="tablist" aria-label="Wallet views">
        <span ref="thumbRef" class="wallet-segment-thumb" aria-hidden="true"></span>
        <button v-for="entry in TABS" :key="entry.id" type="button" role="tab" class="wallet-segment-button"
          :class="{ active: entry.id === selectedId }" :aria-selected="entry.id === selectedId" :id="`${panelId}-${entry.id}`" :aria-controls="panelId" :data-fk="`tab-${entry.id}`" bng-nav-item
          @pointerdown="selectTab(entry.id)" @click="selectTab(entry.id)">{{ entry.label }}</button>
      </div>
    </header>

    <WalletSortMenu :open="menuOpen" :top="menuTop" :label="tab.sortTitle" :options="tab.sorts"
      :model-value="sortChoice[tab.id]" @update:model-value="chooseSort" @close="menuOpen = false" />
  </div>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { uniqueId } from "@/services/uniqueId"
import { usePhoneScreen } from "../../composables/usePhoneScreen"
import { useNowSeconds } from "../../composables/useNowSeconds"
import { useWalletHistory } from "../../composables/useWalletHistory.js"
import WalletTransactionList from "../../components/phone/wallet/WalletTransactionList.vue"
import WalletSortMenu from "../../components/phone/wallet/WalletSortMenu.vue"
import GroupCardStack from "../../components/wallet/GroupCardStack.vue"
import { createSpring } from "../../utils/springMotion.js"
import {
  FALLBACK_ICON, GROUP_SORTS, TRANSACTION_SORTS, categoryIcon, countLabel, displayName, formatMoney, formatSigned, groupAccent, groupLabel, isKnownGroup,
  menuTopBelow, percentLabel, prefersReducedMotion, sourceIcon, spendingShares, toneOf, tooltipAbove, transferNet,
} from "../../utils/walletFinance.js"

defineOptions({ name: "PhoneWallet" })

const TABS = [
  { id: "activity", label: "Activity", title: "Wallet", groupBy: "none", sorts: TRANSACTION_SORTS, sortTitle: "Sort activity" },
  { id: "vehicles", label: "Vehicles", title: "Vehicles", groupBy: "vehicle", sorts: GROUP_SORTS, sortTitle: "Sort vehicles", icon: "car", counted: ["vehicle", "vehicles"],
    emptyTitle: "No vehicle money yet", emptyText: "Fuel, repairs, insurance and pay earned with a car are added up per vehicle." },
  { id: "work", label: "Work", title: "Work", groupBy: "source", sorts: GROUP_SORTS, sortTitle: "Sort work", icon: "career", counted: ["work type", "work types"], countKnownOnly: true,
    emptyTitle: "No work pay yet", emptyText: "Pay from deliveries, taxi fares and other jobs is added up per work type." },
  { id: "categories", label: "Categories", title: "Categories", groupBy: "category", sorts: GROUP_SORTS, sortTitle: "Sort categories", icon: "banknotes", counted: ["category", "categories"],
    emptyTitle: "No transactions yet", emptyText: "Spending and earnings are sorted into categories as they happen." },
]
const ROW_PAGE = 40
const SEGMENT_RESPONSE = 0.32
const CONTENT_RESPONSE = 0.36
const EXIT_RESPONSE = 0.18
// The old content is invisible well before its spring rests; swap then, so no blank gap shows.
const SWAP_AT = 0.02
// Leaving the Wallet and coming back returns to the same tab and sorts.
const VIEW_STORAGE_KEY = "overhaul.wallet.view"
const FADE_RESPONSE = 0.12
const CONTENT_SHIFT_PX = 18
const UNRECORDED_ICON = "banknotes"

usePhoneScreen()
const panelId = uniqueId("wallet-panel")
// Relative times only change by the minute; a minute clock keeps the list from redrawing every second.
const seconds = useNowSeconds()
const now = computed(() => Math.floor(seconds.value / 60) * 60)
const rootRef = ref(null)
const scrollRef = ref(null)
const bodyRef = ref(null)
const thumbRef = ref(null)
const sortButtonRef = ref(null)
const panelRef = ref(null)

function readSavedView() {
  try { return JSON.parse(globalThis.sessionStorage?.getItem(VIEW_STORAGE_KEY) || "null") || {} } catch { return {} }
}
const saved = readSavedView()
const startTab = TABS.some(entry => entry.id === saved.tab) ? saved.tab : TABS[0].id
// selectedId follows the segment at once; tabId is the tab whose content is on screen.
const selectedId = ref(startTab)
const tabId = ref(startTab)
const tab = computed(() => TABS.find(entry => entry.id === tabId.value) || TABS[0])
const sortChoice = reactive(Object.fromEntries(TABS.map(entry => [entry.id,
  entry.sorts.some(sort => sort.id === saved.sorts?.[entry.id]) ? saved.sorts[entry.id] : entry.sorts[0].id])))
watch([tabId, sortChoice], () => {
  try { globalThis.sessionStorage?.setItem(VIEW_STORAGE_KEY, JSON.stringify({ tab: tabId.value, sorts: { ...sortChoice } })) } catch { /* storage is optional */ }
}, { deep: true })
const currentSort = computed(() => tab.value.sorts.find(sort => sort.id === sortChoice[tab.value.id]) || tab.value.sorts[0])
const rowLimit = ref(ROW_PAGE)
const menuOpen = ref(false)
const menuTop = ref(0)

function optionsFor(entry) {
  const sort = entry.sorts.find(choice => choice.id === sortChoice[entry.id]) || entry.sorts[0]
  return { groupBy: entry.groupBy, sortBy: sort.sortBy, direction: sort.direction }
}
const options = computed(() => optionsFor(tab.value))
const { view, loading, failed, retry, prefetch, loadMore, loadGroup, closeGroup, pageLoading, pageFailed } = useWalletHistory(options)
const retrying = ref(false)
async function tryAgain() {
  if (retrying.value) return
  retrying.value = true
  try { await retry() } finally { retrying.value = false }
}
function showMoreRows() { rowLimit.value += ROW_PAGE; if (rowLimit.value > view.value.rows.length) loadMore() }

// ---- Derived views --------------------------------------------------------------------------
// "Unspecified work type" and "Other money: ..." are listed but not counted as work types.
const groupHeading = computed(() => {
  const groups = view.value?.groups || []
  const counted = tab.value.countKnownOnly ? groups.filter(isKnownGroup) : groups
  return countLabel(counted.length, ...(tab.value.counted || [])) + (view.value?.paging?.hasMore ? " shown" : "")
})
const tabEmpty = computed(() => !view.value?.groups.length)
const shares = computed(() => tab.value.id === "categories" ? spendingShares(view.value?.groups || [], view.value?.totals.expenses) : [])

function shareOf(group) {
  const share = shares.value.find(entry => entry.id === group.id)
  return share && share.share >= 0.005 ? `${Math.round(share.share * 100)}%` : ""
}
const tabAccent = group => groupAccent(group, tab.value.groupBy)

// ---- Spending bar tooltip ---------------------------------------------------------------------
// One tooltip for the whole bar: the segment under the pointer or holding focus.
const shareTip = ref(null)
function showShare(share, segment) {
  shareTip.value = { share, ...tooltipAbove(segment, panelRef.value) }
}
function hideShare() { shareTip.value = null }
function shareLabel(share, translate) {
  return `${displayName(share.name, translate)}, ${formatMoney(share.amount)}, ${percentLabel(share.share)} of spending`
}
// Card icon: categories bring their own; vehicles show a car, work its work type, and groups with
// nothing recorded ("Unspecified work type", "Other money: ...") a plain banknote.
function groupIcon(group) {
  if (tab.value.id === "categories") return categoryIcon(group.category || group.rows[0]?.category)
  if (!isKnownGroup(group)) return UNRECORDED_ICON
  return tab.value.id === "vehicles" ? "car" : sourceIcon(group)
}
// The category that cost this group the most, named for the card.
function topCost(group) {
  if (group.costs) return group.costs[0]?.name || ""
  const byCategory = new Map()
  for (const row of group.rows) {
    if (row.amount >= 0 || row.category?.id === "transfer") continue
    const name = row.category?.name || "Other"
    byCategory.set(name, (byCategory.get(name) || 0) - row.amount)
  }
  let best = ""
  let most = 0
  for (const [name, amount] of byCategory) if (amount > most) { best = name; most = amount }
  return best
}

// ---- Actions --------------------------------------------------------------------------------
// The segment answers at once; the content follows when the old tab has left (see Motion).
function selectTab(id) {
  if (id === selectedId.value || !TABS.some(entry => entry.id === id)) return
  const from = TABS.findIndex(entry => entry.id === selectedId.value)
  const to = TABS.findIndex(entry => entry.id === id)
  selectedId.value = id
  menuOpen.value = false
  moveThumb(to)
  prefetch(optionsFor(TABS[to]))
  leaveContent(Math.sign(to - from))
}
function stepTab(direction) {
  const index = TABS.findIndex(entry => entry.id === selectedId.value)
  const next = TABS[(index + direction + TABS.length) % TABS.length]
  selectTab(next.id)
  nextTick(() => {
    const button = rootRef.value?.querySelector(`[data-fk="tab-${next.id}"]`)
    if (button) setFocus(button)
  })
}
function openSort() {
  menuTop.value = menuTopBelow(sortButtonRef.value, rootRef.value)
  menuOpen.value = true
}
function chooseSort(id) {
  sortChoice[tab.value.id] = id
  rowLimit.value = ROW_PAGE
}

// ---- Motion ---------------------------------------------------------------------------------
// The segment thumb glides on a spring and retargets from its live position if pressed again.
const thumbSpring = createSpring({
  value: 0, response: SEGMENT_RESPONSE, damping: 1,
  onUpdate: value => { if (thumbRef.value) thumbRef.value.style.transform = `translateX(${value * 100}%)` },
})
// Content is one spring: 1 is shown, 0 is gone. A new tab sends the old content out on the side
// away from the chosen segment, swaps at 0, and brings the new content in from the chosen side.
// Pressing again mid-way only retargets the same spring, so nothing jumps; going back to the shown
// tab retraces the path in.
let contentSide = 0
let entering = true
// The list gets its own compositing layer only while it moves.
const contentMoving = ref(false)
let reduced = false
const contentSpring = createSpring({
  value: 1, response: CONTENT_RESPONSE, damping: 1,
  onUpdate: paintContent,
  onRest: () => { contentMoving.value = false },
})
function paintContent(progress) {
  if (!entering && progress <= SWAP_AT) { swapContent(); return }
  const body = bodyRef.value
  if (!body) return
  body.style.opacity = String(Math.min(1, Math.max(0, progress)))
  body.style.transform = reduced || progress >= 1 ? "" : `translateX(${(1 - progress) * contentSide * CONTENT_SHIFT_PX}px)`
}
function moveThumb(index) {
  if (prefersReducedMotion()) thumbSpring.set(index)
  else thumbSpring.to(index)
}
function leaveContent(direction) {
  reduced = prefersReducedMotion()
  contentMoving.value = true
  const response = reduced ? FADE_RESPONSE : EXIT_RESPONSE
  if (selectedId.value === tabId.value) {
    // Back to the tab still on screen: return along the way it was leaving.
    entering = true
    contentSpring.to(1, { response: reduced ? FADE_RESPONSE : CONTENT_RESPONSE })
    return
  }
  // Only content at rest picks a side; content already moving keeps its side, so it never jumps.
  if (contentSpring.value >= 1) contentSide = -direction
  entering = false
  contentSpring.to(0, { response })
}
function swapContent() {
  entering = true
  if (tabId.value === selectedId.value) {
    contentSpring.to(1, { response: reduced ? FADE_RESPONSE : CONTENT_RESPONSE })
    return
  }
  const from = TABS.findIndex(entry => entry.id === tabId.value)
  const to = TABS.findIndex(entry => entry.id === selectedId.value)
  tabId.value = selectedId.value
  rowLimit.value = ROW_PAGE
  if (scrollRef.value) scrollRef.value.scrollTop = 0
  contentSide = Math.sign(to - from)
  contentSpring.to(1, { response: reduced ? FADE_RESPONSE : CONTENT_RESPONSE })
}

onMounted(() => thumbSpring.set(TABS.findIndex(entry => entry.id === selectedId.value)))
onBeforeUnmount(() => { thumbSpring.stop(); contentSpring.stop() })

// A tooltip belongs to the bar it was shown on: another tab or a refreshed view takes it down.
watch([tabId, shares], hideShare)

// A tab with nothing to sort closes a menu left open by a refresh.
watch(() => tab.value.groupBy === "none" ? view.value?.rows.length : view.value?.groups.length, count => { if (!count) menuOpen.value = false })
</script>

<style scoped>
.wallet {
  /* The phone's top bar already names the app and the segment shows the tab: no large title. */
  --wallet-header-height: 70px;
  position: relative;
  overflow: hidden;
  background: #0f1013;
  color: #fff;
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  font-size: 12px;
}
.wallet-scroll { position: absolute; inset: 0; overflow-y: auto; scrollbar-width: none; }
.wallet-scroll::-webkit-scrollbar { display: none; }
.wallet-body.moving { will-change: transform, opacity; }
.wallet-body { display: grid; gap: 14px; padding: calc(var(--wallet-header-height) + 10px) 12px 24px; }

/* Translucent header: content scrolls under it; a soft fade replaces a divider line. */
.wallet-header {
  position: absolute;
  z-index: 4;
  top: 0;
  left: 0;
  right: 0;
  padding: 40px 14px 10px;
  /* Near-opaque plate, no blur: content scrolls and animates under it, and the game's UI is
     CPU-rasterized, so live glass would repaint every frame. */
  background: rgba(15, 16, 19, 0.94);
}
.wallet-header::after {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  bottom: -14px;
  height: 14px;
  background: linear-gradient(to bottom, rgba(15, 16, 19, 0.55), rgba(15, 16, 19, 0));
  pointer-events: none;
}

.wallet-segment { position: relative; display: grid; grid-template-columns: repeat(4, 1fr); padding: 2px; border-radius: 9px; background: rgba(118, 118, 128, 0.24); }
.wallet-segment-thumb {
  position: absolute;
  top: 2px;
  bottom: 2px;
  left: 2px;
  width: calc((100% - 4px) / 4);
  border-radius: 7px;
  background: #636366;
  box-shadow: 0 2px 6px rgba(0, 0, 0, 0.3);
  will-change: transform;
}
.wallet-segment-button {
  position: relative;
  z-index: 1;
  margin: 0;
  padding: 7px 0 5px;
  border: 0;
  border-radius: 7px;
  background: transparent;
  color: rgba(255, 255, 255, 0.72);
  font: inherit;
  font-size: 11.5px;
  font-weight: 700;
  letter-spacing: 0.01em;
  cursor: pointer;
  transition: transform 100ms ease-out, color 150ms ease;
}
.wallet-segment-button.active { color: #fff; }
.wallet-segment-button:active { transform: scale(0.95); }

.wallet-key { display: block; color: rgba(235, 235, 245, 0.62); font-size: 10px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }

/* Balance card */
.wallet-card {
  position: relative;
  overflow: hidden;
  padding: 16px 16px 14px;
  border-radius: 18px;
  background: linear-gradient(135deg, #1f6f43 0%, #145236 45%, #0f3b2a 100%);
}
.wallet-card::after { content: ""; position: absolute; right: -40px; top: -60px; width: 180px; height: 180px; border-radius: 50%; background: rgba(255, 255, 255, 0.06); pointer-events: none; }
.wallet-card .wallet-key { color: rgba(255, 255, 255, 0.7); }
.wallet-balance { overflow-wrap: anywhere; display: block; margin: 4px 0 12px; font-size: 34px; font-weight: 800; line-height: 1.05; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; }
.wallet-card-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 8px; }
/* Earned, Spent and one more figure share a single row in a pulled-out card. */
.wallet-group-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(84px, 1fr)); gap: 8px; }
.wallet-banner { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #3a2a1a; color: #ffd8a8; font-size: 12px; font-weight: 600; }
.wallet-card-stats b, .wallet-group-stats b { display: block; margin-top: 2px; font-size: 14px; font-weight: 800; font-variant-numeric: tabular-nums; white-space: normal; overflow-wrap: anywhere; }
.on-card-income { color: #8ff0ae; }
.on-card-expense { color: #ffc0bb; }
.wallet-split { display: flex; gap: 2px; height: 6px; margin-top: 12px; overflow: hidden; border-radius: 3px; }
.wallet-split.tall { height: 10px; margin-top: 10px; border-radius: 5px; }
.wallet-split > * { display: block; flex: 1 1 0; min-width: 3px; height: 100%; }
.wallet-share { margin: 0; padding: 0; border: 0; border-radius: 0; cursor: default; }
.wallet-share:hover, .wallet-share.focus-visible { filter: brightness(1.2); outline: none; }
.wallet-card .split-income { background: #8ff0ae; }
.wallet-card .split-expense { background: #ffc0bb; }
.split-income { background: #30d158; }
.split-expense { background: #ff453a; }

.wallet-section-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 0 4px; }
.wallet-section-head h3 { margin: 0; font-size: 17px; font-weight: 800; letter-spacing: -0.015em; }
.wallet-pill-button {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin: 0;
  padding: 6px 10px 4px;
  border: 0;
  border-radius: 999px;
  background: rgba(118, 118, 128, 0.24);
  color: #e5e5ea;
  font: inherit;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
  transition: transform 100ms ease-out;
  --bng-icon-color: currentColor;
}
.wallet-pill-button:active { transform: scale(0.97); }
.wallet-more { margin: -4px 0 0; padding: 10px; border: 0; border-radius: 12px; background: #1c1c1f; color: #0a84ff; font: inherit; font-size: 13px; font-weight: 700; cursor: pointer; }

.income { color: #30d158; }
.expense { color: #ff6961; }

.wallet-tile { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 9px; color: #fff; font-size: 18px; --bng-icon-color: #fff; }
.wallet-row-copy { display: grid; gap: 3px; min-width: 0; }
.wallet-group-name { display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; font-size: 14px; font-weight: 800; letter-spacing: -0.01em; white-space: normal; overflow-wrap: anywhere; }
.wallet-row-sub { overflow: hidden; color: rgba(235, 235, 245, 0.62); font-size: 11px; letter-spacing: 0.01em; white-space: normal; overflow-wrap: anywhere; }
.wallet-row-amount { grid-column: 2; display: flex; align-items: baseline; justify-content: space-between; gap: 1px; text-align: right; }
.wallet-group-net { white-space: nowrap; font-size: 15px; font-weight: 800; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
.wallet-group-stats b { font-size: 13px; }

/* Grouped tabs fill the screen: the deck scrolls inside itself and a pulled-out card covers it. */
.wallet-scroll.grouped { overflow: hidden; }
.wallet-scroll.grouped .wallet-body { display: flex; flex-direction: column; height: 100%; padding-bottom: 8px; }
.wallet-stack {
  flex: 1 1 auto;
  min-height: 0;
  --stack-radius: 14px;
  --stack-card-bg: #232327;
  --stack-sheet-bg: #18181b;
  --stack-depth: 14px;
  --stack-edge: inset 0 0.5px 0 rgba(255, 255, 255, 0.14);
}
.wallet-stack-card { display: grid; grid-template-columns: 34px minmax(0, 1fr); align-items: center; gap: 10px; padding: 10px 12px; }
.wallet-detail { display: grid; gap: 10px; padding: 10px 12px 12px; }
.wallet-detail .wallet-split { margin-top: 0; }

.wallet-panel { position: relative; padding: 12px; border-radius: 14px; background: #1c1c1f; }
.wallet-share-tip {
  position: absolute;
  z-index: 2;
  display: grid;
  gap: 1px;
  min-width: 6em;
  padding: 6px 10px 5px;
  border-radius: 10px;
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 8px 20px rgba(0, 0, 0, 0.45);
  text-align: center;
  white-space: nowrap;
  pointer-events: none;
  transform: translate(-50%, -100%);
}
.wallet-share-tip strong { font-size: 12px; font-weight: 800; }
.wallet-share-tip span { color: rgba(235, 235, 245, 0.7); font-size: 11px; font-weight: 600; font-variant-numeric: tabular-nums; }
.wallet-panel-total { display: block; margin-top: 4px; font-size: 24px; font-weight: 800; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }

.wallet-empty { display: grid; justify-items: center; gap: 8px; padding: 36px 24px; text-align: center; }
.wallet-empty h3 { margin: 6px 0 0; font-size: 17px; font-weight: 800; letter-spacing: -0.015em; }
.wallet-empty p { margin: 0; color: rgba(235, 235, 245, 0.62); font-size: 12.5px; line-height: 1.45; }
.wallet-empty-icon { display: grid; place-items: center; width: 56px; height: 56px; border-radius: 16px; background: #2c2c30; color: #8e8e93; font-size: 28px; --bng-icon-color: #8e8e93; }
.wallet-loading { padding: 40px 0; color: rgba(235, 235, 245, 0.6); font-size: 13px; text-align: center; }

@media (prefers-reduced-motion: reduce) {
  .wallet-segment-button:active, .wallet-pill-button:active { transform: none; }
}
@media (prefers-reduced-transparency: reduce) {
  .wallet-header { background: #0f1013; }
}
</style>

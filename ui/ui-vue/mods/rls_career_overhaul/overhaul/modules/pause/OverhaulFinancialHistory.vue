<!-- Pause menu > History > Financial History in the house style. One compact row of wallet totals,
     one row of controls (Group by segments, a Sort menu that includes the order), then either every
     transaction (None) or a deck of group cards (vehicle, work type, category, month): each card
     shows its name, colour, count and net, and pulls out to show its totals and transactions.
     The Lua read model groups, sorts and totals; this card only chooses the view and draws it.
     LB/RB stay with the pause menu's own tabs. -->
<template>
  <section class="rls-house rls-house-card fin-history" aria-label="Financial history">
    <header class="fin-head">
      <h2>Financial History</h2>
      <div v-if="view" class="stats fin-stats">
        <div class="stat money"><span class="stat-key">Balance</span><span class="stat-value">{{ formatMoney(view.balance) }}</span></div>
        <div class="stat ok"><span class="stat-key">Earned</span><span class="stat-value">{{ formatMoney(view.totals.income) }}</span></div>
        <div class="stat bad"><span class="stat-key">Spent</span><span class="stat-value">{{ formatMoney(view.totals.expenses) }}</span></div>
        <div class="stat"><span class="stat-key">Net</span><span class="stat-value">{{ formatSigned(view.totals.net) }}</span></div>
        <div v-if="toneOf(transferNet(view.totals)) !== 'neutral'" class="stat"><span class="stat-key">Transfers</span><span class="stat-value">{{ formatSigned(transferNet(view.totals)) }}</span></div>
      </div>
    </header>

    <div class="fin-controls">
      <div class="seg bar fin-groupings" role="radiogroup" aria-label="Group by">
        <button v-for="option in GROUPINGS" :key="option.id" type="button" role="radio" :aria-checked="groupBy === option.id"
          :class="{ active: groupBy === option.id }" :data-fk="`group-${option.id}`" bng-nav-item
          :bng-scoped-nav-autofocus="groupBy === option.id ? 'true' : null" @click="setGrouping(option.id)">{{ option.label }}</button>
      </div>
      <HouseMenu v-model="sortChoice" class="fin-sort" compact :items="SORT_CHOICES" aria-label="Sort" />
    </div>

    <div class="fin-body">
      <!-- Both notices stay up while retrying and keep their button focusable (aria-disabled, not
           disabled), so controller focus stays where the player pressed. -->
      <div v-if="(failed || retrying) && view" class="fin-note fin-stale" role="status">
        <span class="hint">Couldn't refresh. Showing the last loaded history.</span>
        <HouseButton compact variant="quiet" :aria-disabled="retrying ? 'true' : null" @click="tryAgain">{{ retrying ? "Trying again" : "Try again" }}</HouseButton>
      </div>
      <div v-if="(failed || retrying) && !view" class="fin-empty" role="status">
        <p>Financial history didn't load.</p>
        <HouseButton compact :aria-disabled="retrying ? 'true' : null" @click="tryAgain">{{ retrying ? "Trying again" : "Try again" }}</HouseButton>
      </div>
      <p v-else-if="!view" class="fin-empty" aria-live="polite">Loading</p>
      <p v-else-if="!view.totals.count" class="fin-empty">No money has moved yet. Earnings from work and spending on cars, fuel and repairs show up here.</p>

      <div v-else-if="groupBy === 'none'" class="fin-scroll scroll" v-bng-ui-nav-scroll.force>
        <div class="fin-panel">
          <WalletHouseLines :rows="view.rows.slice(0, rowLimit)" :now="now" />
        </div>
        <HouseButton v-if="view.rows.length > rowLimit || view.paging?.hasMore" variant="quiet" class="fin-more" @click="showMoreRows">
          {{ pageLoading ? "Loading" : "Show more" }}
        </HouseButton>
      </div>

      <template v-else>
        <p v-if="groupBy === 'period'" class="hint fin-note">Months follow UTC time.</p>
        <!-- Keyed by grouping: groups of different kinds can share an id ("unknown"), so a new
             grouping always starts with every card in the deck. -->
        <GroupCardStack :key="groupBy" class="fin-stack" :groups="view.groups" :tint="swatchFor" :label="`Grouped by ${groupingLabel}`" :detail-label="groupingLabel" @open="loadGroup" @more="loadGroup" @close="closeGroup">
          <template #card="{ group }">
            <span class="fin-card">
              <span class="fin-swatch" :style="{ backgroundColor: swatchFor(group) }" aria-hidden="true"></span>
              <span class="fin-card-name">
                <strong>{{ displayName(groupTitle(group, groupBy), $ctx_t) }}</strong>
                <small>{{ countLabel(group.totals.count) }}</small>
              </span>
              <span class="fin-card-net">
                <span class="stat-key">Net</span>
                <b :class="toneClass(group.totals.net)">{{ formatSigned(group.totals.net) }}</b>
              </span>
            </span>
          </template>
          <!-- The pulled-out header already names the group and puts it back when chosen. -->
          <template #detail="{ group, close, limit, page, showMore }">
            <div class="fin-detail">
              <div class="fin-detail-stats">
                <div class="fin-gstat"><span class="stat-key">Earned</span><b class="pos">{{ formatMoney(group.totals.income) }}</b></div>
                <div class="fin-gstat"><span class="stat-key">Spent</span><b class="neg">{{ formatMoney(group.totals.expenses) }}</b></div>
                <div v-if="toneOf(transferNet(group.totals)) !== 'neutral'" class="fin-gstat"><span class="stat-key">Transfers</span><b>{{ formatSigned(transferNet(group.totals)) }}</b></div>
                <HouseButton compact variant="quiet" binding="back" class="fin-back" @click="close">Back to all</HouseButton>
              </div>
              <p v-if="group.rows.some(row => row.legacy)" class="hint fin-note">Includes older entries saved without details.</p>
              <p v-if="group.loading" class="hint">Loading transactions</p>
              <HouseButton v-if="group.failed" compact @click="loadGroup(group, group.rows.length + 1)">Try again</HouseButton>
              <WalletHouseLines :rows="group.rows.slice(0, limit)" :now="now" :group-by="groupBy" />
              <HouseButton v-if="group.rows.length > limit || group.paging?.hasMore" variant="quiet" class="fin-more" @click="showMore">
                {{ group.loading ? "Loading" : group.paging ? "Show more" : "Show " + Math.min(page, group.rows.length - limit) + " more" }}
              </HouseButton>
            </div>
          </template>
        </GroupCardStack>
        <HouseButton v-if="view.paging?.hasMore" compact @click="loadMore">{{ pageLoading ? "Loading" : "Show more groups" }}</HouseButton>
      </template>
      <p v-if="pageFailed" class="hint" role="status">Could not load more. Try again.</p>
    </div>
  </section>
</template>

<script setup>
import { computed, ref } from "vue"
import { vBngUiNavScroll } from "@/common/directives"
import "../career/utils/installLuaBridgeFallbacks.js"
import HouseButton from "../career/components/house/HouseButton.vue"
import HouseMenu from "../career/components/house/HouseMenu.vue"
import GroupCardStack from "../career/components/wallet/GroupCardStack.vue"
import WalletHouseLines from "../career/components/wallet/WalletHouseLines.vue"
import { useNowSeconds } from "../career/composables/useNowSeconds"
import { useWalletHistory } from "../career/composables/useWalletHistory.js"
import {
  GROUPINGS, SORT_CHOICES, countLabel, displayName, formatMoney, formatSigned, groupAccent, groupTitle, parseSortChoice, toneOf, transferNet,
} from "../career/utils/walletFinance.js"

defineOptions({ name: "OverhaulFinancialHistory" })

const PAGE = 60

const groupBy = ref("none")
const sortChoice = ref(SORT_CHOICES[0].value)
const rowLimit = ref(PAGE)
// Relative times only change by the minute; redraw the list at most once a minute.
const seconds = useNowSeconds()
const now = computed(() => Math.floor(seconds.value / 60) * 60)

const options = computed(() => ({ groupBy: groupBy.value, ...parseSortChoice(sortChoice.value) }))
const { view, failed, retry, loadMore, loadGroup, closeGroup, pageLoading, pageFailed } = useWalletHistory(options)
function showMoreRows() { rowLimit.value += PAGE; if (rowLimit.value > view.value.rows.length) loadMore() }
const retrying = ref(false)
async function tryAgain() {
  if (retrying.value) return
  retrying.value = true
  try { await retry() } finally { retrying.value = false }
}
const groupingLabel = computed(() => GROUPINGS.find(option => option.id === groupBy.value)?.label || "Group")

function setGrouping(id) {
  groupBy.value = id
  rowLimit.value = PAGE
}
const toneClass = amount => ({ income: "pos", expense: "neg" })[toneOf(amount)] || ""

const swatchFor = group => groupAccent(group, groupBy.value)
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.fin-history {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  /* The pause content area has no height of its own; take the screen's, less the pause top bar,
     bottom bar and their margins (--fin-pause-chrome), so a pulled-out card has room. */
  --fin-pause-chrome: 9.5rem;
  height: calc(100vh - var(--fin-pause-chrome));
  min-height: 0;
  padding: 0.9em 1em;
  border-radius: var(--radius-panel);
  background: rgba(21, 21, 23, 0.94);
}
/* Mod pause buttons can't pass a card class, so this card gives the stock card it sits in the
   stock extra-wide size (layoutMenu's .menu-content-card-1--extra-wide): totals fit on one row
   and reasons on one line. The selector outranks the stock card width rule. */
:global(.layout-menu .menu-screen .menu-content .menu-content-card.menu-content-card-1:has(.fin-history)) {
  width: clamp(36rem, 46vw, 58rem);
}
.fin-head { display: grid; gap: 0.4em; }
.fin-head h2 { margin: 0; font-size: 1.3em; font-weight: 800; line-height: 1.15; letter-spacing: -0.01em; }
.fin-stats { gap: 0.4em 1.5em; }
.fin-stats .stat-value { font-size: 1.12em; font-weight: 800; font-variant-numeric: tabular-nums; }
.stat.bad .stat-value { color: var(--bad); }

.fin-controls { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); }
.fin-groupings { flex: 1 1 100%; min-width: 0; gap: 0.15em; padding: 0.22em; }
.fin-groupings button { flex: 1 1 auto; padding: 0.42em 0.3em 0.3em; font-size: 0.82em; white-space: nowrap; }
.fin-sort { margin-left: auto; flex: 0 0 auto; width: 6.4em; font-size: 0.82em; }

.fin-body { display: flex; flex-direction: column; flex: 1 1 auto; min-height: 0; gap: var(--space-2); }
/* The house scrollbar comes from .scroll (rlsHouse); scrollbar-width would switch it back to the native one. */
.fin-scroll { display: flex; flex-direction: column; gap: 0.7em; min-height: 0; padding-right: 0.3em; }
.fin-panel { flex: 0 0 auto; overflow: hidden; border-radius: var(--radius-panel); background: var(--panel); }
.fin-empty { display: grid; justify-items: center; gap: 0.6em; margin: 0; padding: 2em 0.5em; color: var(--muted); font-weight: 600; text-align: center; }
.fin-note { margin: 0 0.2em; }
.fin-stale { display: flex; align-items: center; justify-content: space-between; gap: var(--space-2); }
.fin-more { align-self: center; }

/* The deck: house surfaces, a light top edge on each card and a soft shadow onto the one behind. */
.fin-stack {
  --stack-radius: var(--radius-panel);
  --stack-card-bg: #2a2a2f;
  --stack-sheet-bg: #202024;
  --stack-depth: 1.1em;
  --stack-edge: inset 0 1px 0 rgba(255, 255, 255, 0.09);
}
.fin-card { display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 0.6em; padding: 0.6em var(--inset) 0.55em; }
.fin-swatch { width: 0.8em; height: 0.8em; border-radius: 0.2em; }
.fin-card-name { display: grid; gap: 0.05em; min-width: 0; }
.fin-card-name strong { overflow: hidden; font-size: 1em; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow-wrap: anywhere; }
.fin-card-name small { color: var(--faint); font-size: 0.76em; font-weight: 600; }
.fin-card-net { grid-column: 2; display: flex; align-items: baseline; justify-content: space-between; gap: 0.05em; }
.fin-card-net .stat-key { font-size: 0.6em; }
.fin-card-net b { white-space: nowrap; font-size: 1em; font-variant-numeric: tabular-nums; }
.pos { color: var(--ok); }
.neg { color: var(--bad); }

.fin-detail { display: grid; gap: 0.3em; }
.fin-detail-stats { display: flex; flex-wrap: wrap; align-items: center; gap: 1.4em; padding: 0.5em var(--inset) 0.55em; border-bottom: 1px solid var(--line); }
.fin-gstat { display: grid; gap: 0.05em; }
.fin-gstat .stat-key { font-size: 0.6em; }
.fin-gstat b { white-space: nowrap; font-size: 0.98em; font-variant-numeric: tabular-nums; }
.fin-back { margin-left: auto; }
</style>

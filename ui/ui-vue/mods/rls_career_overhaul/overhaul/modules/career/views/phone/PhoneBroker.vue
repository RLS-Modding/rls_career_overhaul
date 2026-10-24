<template>
  <div data-broker-scope class="broker" ref="screenRef" v-bng-ui-nav-scroll v-bng-on-ui-nav:tab_l="() => changeTab(-1)" v-bng-on-ui-nav:tab_r="() => changeTab(1)" :class="{ expanded: s.expanded, 'market-home': s.view === 'markets'}">
    <header data-broker-scope v-if="s.expanded" class="apphead">
      <h2 data-broker-scope>{{ heading }}</h2>
      <BrokerExpand />
    </header>
    <div data-broker-scope v-if="s.data.employed" class="empty employed-state">
      <span data-broker-scope class="empty-badge"><BngIcon data-broker-scope :type="icons.badge" /></span>
      <p data-broker-scope class="employed-copy">You have a job right now. You need to be unemployed to take independent work.</p>
      <button data-broker-scope class="primary" @click="openEmployment">Open Employment</button>
    </div>
    <div data-broker-scope v-else-if="!s.loaded" class="empty"><p data-broker-scope>Loading available work…</p><button data-broker-scope @click="refreshBroker">Try again</button></div>
    <template v-else>
      <section data-broker-scope v-if="s.view === 'markets'" class="market-body scroll" v-bng-ui-nav-scroll>
        <div data-broker-scope class="view-bar"><p data-broker-scope class="intro">Choose your market</p><BrokerExpand v-if="!s.expanded" /></div>
        <div data-broker-scope class="market-grid"><button data-broker-scope v-for="m in markets" :key="m.id" class="market-tile" :class="{ last: s.preferences.last === m.id }" @click="s.chooseMarket(m.id)">
          <span data-broker-scope class="tile-img"><img data-broker-scope :src="marketImage(m.id)" alt="" loading="lazy" /><BngIcon data-broker-scope class="tile-glyph" :type="marketIcon(m.id)" /></span>
          <span data-broker-scope class="tile-copy"><strong data-broker-scope>{{ m.name }}</strong><span data-broker-scope>{{ m.hint }}</span></span>
          <span data-broker-scope class="pill" :class="s.data.offers.some(r => r.market === m.id) ? 'accent' : 'muted'">{{ loadCount(groupedOfferCount(s.data.offers.filter(r => r.market === m.id))) }}</span>
        </button></div>
        <button data-broker-scope class="browse-all" @click="s.chooseMarket('all')">Browse all work <span data-broker-scope class="pill">{{ loadCount(groupedOfferCount(s.data.offers)) }}</span></button>
      </section>
      <BrokerWork @vue:mounted="focusView" v-else-if="s.view === 'loads' || s.view === 'jobs'" />
      <BrokerLoaners @vue:mounted="focusView" v-else-if="s.view === 'loaners'" />
      <nav data-broker-scope class="nav"><button data-broker-scope :class="{ active: ['markets','loads'].includes(s.view) }" @click="s.view = 'markets'; s.selected = null"><BngIcon data-broker-scope :type="icons.search" /><span data-broker-scope>Loads</span></button><button data-broker-scope :class="{ active: s.view === 'jobs' }" @click="s.view = 'jobs'; s.selected = null"><BngIcon data-broker-scope :type="icons.listIndented" /><span data-broker-scope>My Loads</span></button><button data-broker-scope :class="{ active: s.view === 'loaners' }" @click="s.view = 'loaners'; s.selected = null"><BngIcon data-broker-scope :type="icons.carCoins" /><span data-broker-scope>Loaners</span></button></nav>
    </template>
    <button data-broker-scope v-if="s.message" class="message" aria-live="polite" @click="s.message = ''">{{ s.message }} <span data-broker-scope>×</span></button>
  </div>
</template>

<script setup>
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { defineAsyncComponent, provide } from 'vue'
import { useBrokerScreen } from './broker/useBrokerScreen'
import BrokerExpand from './broker/BrokerExpand.vue'
const context = useBrokerScreen()
provide(Symbol.for('overhaul.phoneBroker'), context)
const { focusView, screenRef, changeTab, BngIcon, icons, groupedOfferCount, markets, s, openEmployment, heading, marketIcon, marketImage, loadCount, refreshBroker } = context
const BrokerLoaners = defineAsyncComponent(() => import('./broker/BrokerLoaners.vue'))
const BrokerWork = defineAsyncComponent(() => import('./broker/BrokerWork.vue'))
</script>

<!-- The shared scope marker follows the original template across lazy parts.
     It preserves selector weight without styling stock child internals. -->
<style>

/* House style shared with EmployeeShift: dark gray, orange accent, Overpass, soft corners, no stripes. */
.broker[data-broker-scope] { --accent: var(--bng-orange-b400, #ff6600); --panel: rgba(255, 255, 255, 0.06); --panel-2: rgba(255, 255, 255, 0.1); --line: rgba(255, 255, 255, 0.1); --muted: rgba(255, 255, 255, 0.72); --faint: rgba(255, 255, 255, 0.55); --money: #fde68a; --ok: #4ade80;
  height: 100%; box-sizing: border-box; padding-top: 4.2em; display: flex; flex-direction: column; position: relative; background: #151517; color: #fff; font-family: "Overpass", var(--fnt-defs, sans-serif); font-size: 12px; line-height: 1.35; --bng-icon-color: currentColor;
}
.broker.expanded[data-broker-scope] { font-size: clamp(0.8rem, calc(1.3vh * var(--ui-scale, 1)), 1.5rem);
}
.broker[data-broker-scope] * { box-sizing: border-box;
}
.broker[data-broker-scope] .bng-icon { font-size: 1.25em;
}

/* ---- buttons and fields */
.broker button[data-broker-scope], .broker input[data-broker-scope], .broker select[data-broker-scope] { font: inherit; color: inherit; background: var(--panel-2); border: 0; border-radius: 0.6em; padding: 0.62em 0.95em 0.5em; line-height: 1;
}
.broker button[data-broker-scope] { cursor: pointer; font-weight: 700; white-space: nowrap; transition: background-color 0.12s, transform 0.08s;
}
.broker button[data-broker-scope]:hover:not(:disabled) { background: rgba(255, 255, 255, 0.16);
}
.broker button[data-broker-scope]:active:not(:disabled) { transform: translateY(1px);
}
.broker button[data-broker-scope]:disabled { opacity: 0.45; cursor: default;
}
.broker .primary[data-broker-scope] { background: var(--accent); color: #fff;
}
.broker .primary[data-broker-scope]:hover:not(:disabled) { background: #ff7a1f;
}
.broker input[data-broker-scope] { background: rgba(0, 0, 0, 0.3); border: 1px solid var(--line); border-radius: 0.5em; padding: 0.6em 0.8em; font-weight: 400;
}
.broker input[data-broker-scope]::placeholder { color: var(--faint);
}
.icon-btn[data-broker-scope] { display: grid; place-items: center; width: 2.4em; height: 2.4em; padding: 0 !important;
}
@keyframes tip-spin-broker-scope {
to { transform: rotate(360deg);
}
}
.icon-btn svg[data-broker-scope] { width: 1.15em; height: 1.15em; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round;
}
.pill[data-broker-scope] { display: inline-flex; align-items: center; gap: 0.25em; width: fit-content; justify-self: start; padding: 0.3em 0.55em 0.2em; border-radius: 0.3em; background: var(--panel-2); color: rgba(255, 255, 255, 0.8); font-size: 0.78em; font-weight: 700; line-height: 1; white-space: nowrap;
}
.pill.accent[data-broker-scope] { background: rgba(255, 102, 0, 0.25); color: #ffb27a;
}
.pill.muted[data-broker-scope] { background: transparent; color: var(--faint); padding-left: 0;
}
.muted[data-broker-scope] { color: var(--muted);
}

/* ---- header */
.apphead[data-broker-scope] { display: flex; justify-content: space-between; align-items: center; gap: 0.75em; padding: 0.4em 1em 0.6em; flex-shrink: 0;
}
.apphead h2[data-broker-scope] { margin: 0; font-size: 1.55em; font-weight: 800; font-style: italic; letter-spacing: -0.01em; line-height: 1.1;
}
.broker:not(.expanded) .header-expand[data-broker-scope] { flex: 0 0 auto; background: transparent; color: var(--faint); transition: color 0.12s;
}
.broker:not(.expanded) .header-expand[data-broker-scope]:hover, .broker:not(.expanded) .header-expand[data-broker-scope].focus-visible { background: transparent; color: #fff;
}
.scroll[data-broker-scope] { overflow: auto; min-height: 0; flex: 1; scrollbar-gutter: stable;
}
.scroll[data-broker-scope]::-webkit-scrollbar { width: 0.45em; height: 0.45em;
}
.scroll[data-broker-scope]::-webkit-scrollbar-track { background: transparent;
}
.scroll[data-broker-scope]::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.1em solid transparent; background-clip: padding-box;
}
.scroll[data-broker-scope]::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box;
}

/* ---- markets */
.market-body[data-broker-scope] { padding: 0 1em 1em;
}
.view-bar[data-broker-scope] { display: flex; justify-content: space-between; align-items: center; gap: 0.6em; margin: 0 0 0.6em;
}
.intro[data-broker-scope] { margin: 0; color: var(--muted);
}
.market-grid[data-broker-scope] { display: grid; grid-template-columns: 1fr; gap: 0.5em;
}
.market-tile[data-broker-scope] { display: flex; align-items: center; gap: 0.7em; width: 100%; text-align: left; padding: 0.7em 0.8em 0.7em 0.75em !important; border-radius: 0.5em !important; background: var(--panel) !important; font-weight: 400;
}
.market-tile[data-broker-scope]:hover:not(:disabled) { background: var(--panel-2) !important;
}
.market-tile.last[data-broker-scope] { box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.55);
}
.market-tile .tile-img[data-broker-scope] { position: relative; flex: 0 0 auto; width: 5.2em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35);
}
.market-tile .tile-img img[data-broker-scope] { display: block; width: 100%; height: 100%; object-fit: cover;
}
.market-tile .tile-img[data-broker-scope]::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top right, rgba(20, 20, 22, 0.7), rgba(20, 20, 22, 0) 60%); pointer-events: none;
}
.market-tile .tile-glyph[data-broker-scope] { position: absolute; left: 0.3em; bottom: 0.2em; font-size: 1.1em; color: #fff; filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.9));
}
.market-tile .tile-copy[data-broker-scope] { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.15em;
}
.market-tile strong[data-broker-scope] { font-size: 1.1em; line-height: 1.15; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.market-tile .tile-copy span[data-broker-scope] { color: var(--muted); font-size: 0.9em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.market-tile .pill[data-broker-scope] { flex: 0 0 auto;
}
.browse-all[data-broker-scope] { width: 100%; display: flex; justify-content: space-between; align-items: center; margin-top: 0.6em; padding: 0.8em 0.9em !important;
}
.browse-all .pill[data-broker-scope] { font-size: 0.8em;
}

/* ---- bottom nav */
.nav[data-broker-scope] { display: flex; justify-content: space-around; gap: 0.25em; padding: 0.35em 0.5em 0.5em; border-top: 1px solid var(--line); background: rgba(0, 0, 0, 0.25); flex-shrink: 0;
}
.nav button[data-broker-scope] { position: relative; flex: 1 1 0; display: flex; flex-direction: column; align-items: center; gap: 0.25em; padding: 0.55em 0.4em 0.5em; background: transparent !important; color: var(--muted); font-size: 0.85em; font-weight: 600;
}
.nav button[data-broker-scope] .bng-icon { font-size: 1.7em;
}
.nav button.active[data-broker-scope] { color: #fff;
}
.nav button.active[data-broker-scope]::after { content: ""; position: absolute; left: 50%; bottom: 0; width: 2.4em; height: 3px; border-radius: 3px; background: var(--accent); transform: translateX(-50%);
}

/* ---- loads: toolbar, list, rows */
.empty[data-broker-scope] { padding: 2em 1em; text-align: center; color: var(--muted); flex: 1; display: grid; gap: 0.6em; justify-items: center; align-content: center;
}
.empty-badge[data-broker-scope] { display: grid; place-items: center; width: 3.6em; height: 3.6em; border-radius: 50%; background: var(--panel-2); color: #ffb27a; margin-bottom: 0.3em;
}
.empty-badge[data-broker-scope] .bng-icon { font-size: 2.1em;
}
.employed-state .employed-copy[data-broker-scope] { margin: 0; font-size: 1.15em; font-weight: 700; line-height: 1.35; max-width: 18em; color: #fff;
}
.employed-state button[data-broker-scope] { margin-top: 0.6em; padding: 0.75em 1.4em 0.6em;
}
.empty h3[data-broker-scope] { margin: 0; color: #fff;
}
.empty p[data-broker-scope] { margin: 0;
}

/* ---- detail */
@keyframes car-pick-broker-scope {
0% { transform: scale(0.99); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.1);
}
60% { transform: scale(1.004); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6);
}
100% { transform: scale(1);
}
}

/* ---- route plan */

/* ---- loaners */

/* ---- toast */
.message[data-broker-scope] { position: absolute; bottom: 4.4em; left: 1em; right: 1em; z-index: 10; text-align: left; padding: 0.75em 0.9em !important; background: #26262a !important; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.6), inset 0 0 0 1px rgba(255, 102, 0, 0.5); font-weight: 400; white-space: normal;
}
.message span[data-broker-scope] { float: right; font-weight: 700; color: var(--accent);
}

/* ---- expanded: full-screen board */
.expanded .apphead[data-broker-scope] { padding: 0.6em 1.5em;
}
.expanded .apphead h2[data-broker-scope] { font-size: 1.8em;
}
.expanded .market-body[data-broker-scope] { padding: 0 1.5em 1.5em;
}
.expanded .market-grid[data-broker-scope] { grid-template-columns: repeat(auto-fill, minmax(min(17em, 100%), 1fr)); gap: 0.6em;
}
.expanded .market-tile[data-broker-scope] { padding: 0.9em 1em !important;
}
.expanded .message[data-broker-scope] { left: 25%; right: 25%;
}
.expanded .nav[data-broker-scope] { justify-content: center; gap: 2em;
}
.expanded .nav button[data-broker-scope] { flex: 0 1 9em;
}
@media (min-width: 1100px) {
.expanded .apphead[data-broker-scope] { width: 100%; max-width: 100em; margin-left: auto; margin-right: auto;
}
}
@media (max-width: 1099px) {
.expanded .message[data-broker-scope] { left: 1em; right: 1em;
}
}

/* ---- expanded market home: centred */
.expanded.market-home .apphead[data-broker-scope] { width: 100%; max-width: 60em; margin: clamp(0.5em, 6vh, 4em) auto 0; padding: 0.6em 1.5em 0.4em;
}
.expanded.market-home .apphead h2[data-broker-scope] { font-size: 2.2em;
}
.expanded.market-home .market-body[data-broker-scope] { width: 100%; max-width: 60em; margin: 0 auto; padding: 0 1.5em 1.5em;
}
.expanded.market-home .intro[data-broker-scope] { font-size: 1.05em; margin-bottom: 1em;
}
.expanded.market-home .market-grid[data-broker-scope] { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.7em;
}
.expanded.market-home .market-grid[data-broker-scope] { grid-template-columns: repeat(3, minmax(0, 1fr));
}
.expanded.market-home .market-tile[data-broker-scope] { flex-direction: column; align-items: stretch; padding: 0 !important; gap: 0; overflow: hidden;
}
.expanded.market-home .market-tile .tile-img[data-broker-scope] { width: 100%; aspect-ratio: 16 / 8; border-radius: 0;
}
.expanded.market-home .market-tile .tile-glyph[data-broker-scope] { left: 0.5em; bottom: 0.4em; font-size: 1.6em;
}
.expanded.market-home .market-tile .tile-copy[data-broker-scope] { padding: 0.6em 0.8em 0.2em;
}
.expanded.market-home .market-tile .pill[data-broker-scope] { margin: 0 0.8em 0.7em;
}
.expanded.market-home .market-tile strong[data-broker-scope] { font-size: 1.25em;
}
.expanded.market-home .browse-all[data-broker-scope] { margin-top: 0.9em; padding: 1em 1.1em !important; font-size: 1.05em;
}
@media (max-width: 800px) {
.expanded.market-home .market-grid[data-broker-scope] { grid-template-columns: repeat(2, minmax(0, 1fr));
}
}

/* Job Broker dropdowns (unscoped: the option list is teleported to the popover container). */

/* the popover shell around the list: no box of its own for broker dropdowns */
</style>

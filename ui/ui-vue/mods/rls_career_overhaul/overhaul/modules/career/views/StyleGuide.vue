<template>
  <div class="guide-screen scroll" v-bng-scoped-nav="scope" v-bng-ui-nav-scroll v-bng-on-ui-nav:back="back">
    <div class="rls-house rls-house-card guide">
      <ControllerExamples />
      <header class="mast">
        <div>
          <div class="kicker">Career UI</div>
          <h1>Style guide</h1>
          <p>Fictional samples for layout and interaction.</p>
        </div>
        <nav class="index" aria-label="Sections">
          <a v-for="section in sections" :key="section.id" class="btn btn-text" :href="'#' + section.id">{{ section.label }}</a>
        </nav>
      </header>

      <section :id="sections[0].id" class="group">
        <h2>{{ sections[0].label }}</h2>
        <div class="bento foundations">
          <div class="cell wide">
            <div class="swatches">
              <div v-for="swatch in swatches" :key="swatch.name" class="swatch">
                <i :style="{ background: swatch.value }"></i>
                <strong>{{ swatch.name }}</strong>
              </div>
            </div>
          </div>
          <div class="cell">
            <div class="stack">
              <div class="kicker">Facility</div>
              <h3 class="block-title">Sample quarry</h3>
              <p class="money">$860</p>
            </div>
          </div>
          <div class="cell">
            <div class="space-list">
              <div v-for="step in spaces" :key="step.name" class="space-row">
                <div class="pair" :style="{ gap: step.value }"><i></i><i></i></div>
                <span class="mono">{{ step.name }}</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[1].id" class="group">
        <h2>{{ sections[1].label }}</h2>
        <div class="pair-grid even">
          <div class="panel stack fill">
            <div class="apphead">
              <h2>Load detail</h2>
              <div class="cluster tight">
                <button type="button" class="btn btn-text">Send</button>
                <button type="button" class="icon-btn" aria-label="Close">
                  <svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" /></svg>
                </button>
              </div>
            </div>
            <div class="actions">
              <button type="button" class="btn btn-quiet">Save</button>
              <button type="button" class="btn btn-quiet-danger">Abandon</button>
              <button type="button" class="btn btn-primary" disabled>Reserve</button>
            </div>
            <div class="actions">
              <button type="button" class="btn">Keep</button>
              <button type="button" class="btn btn-danger">Abandon</button>
              <button type="button" class="btn btn-primary">Next job</button>
            </div>
          </div>
          <div class="rls-house rls-house-phone phone-sample stack">
            <div class="actions">
              <button type="button" class="btn compact btn-quiet">Edit route</button>
              <button type="button" class="btn compact btn-primary" disabled>Start run</button>
            </div>
            <div class="actions">
              <button type="button" class="btn compact btn-quiet-danger">Abandon</button>
              <button type="button" class="btn compact btn-primary">Next</button>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[2].id" class="group">
        <h2>{{ sections[2].label }}</h2>
        <div class="bento choosing">
          <div class="cell">
            <div class="cluster">
              <span class="pill">Standard</span>
              <span class="pill accent">On shift</span>
              <span class="pill ok">Clear</span>
              <span class="pill warn">Waiting</span>
              <span class="pill bad">Locked</span>
              <span class="pill soft">Stored</span>
            </div>
          </div>
          <div class="cell">
            <div class="seg">
              <button type="button" :class="{ active: navTab === 'work' }" @click="navTab = 'work'">Work</button>
              <button type="button" :class="{ active: navTab === 'garage' }" @click="navTab = 'garage'">Garage</button>
              <button type="button" :class="{ active: navTab === 'profile' }" @click="navTab = 'profile'">Profile</button>
            </div>
          </div>
          <div class="cell">
            <div class="seg bar">
              <button type="button" :class="{ active: filterTab === 'day' }" @click="filterTab = 'day'">Day</button>
              <button type="button" :class="{ active: filterTab === 'week' }" @click="filterTab = 'week'">Week</button>
              <button type="button" :class="{ active: filterTab === 'season' }" @click="filterTab = 'season'">Season</button>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[3].id" class="group">
        <h2>{{ sections[3].label }}</h2>
        <div class="bento entering">
          <div class="cell">
            <div class="stack">
              <label class="field-block">
                <span class="caption">Yard name</span>
                <input class="field" type="text" placeholder="North gate" />
              </label>
              <label class="field-block">
                <span class="caption">Note</span>
                <textarea class="field area short" v-model="note" placeholder="Trailer on the left"></textarea>
              </label>
              <label class="field-block">
                <span class="caption">Locked</span>
                <input class="field" type="text" value="Assigned" disabled />
              </label>
              <div class="field-block">
                <span class="caption">Search</span>
                <label class="search" data-focus-field>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
                  <input v-model="query" type="text" placeholder="Driver or facility" aria-label="Search" />
                  <button v-if="query" type="button" class="search-clear" aria-label="Clear search" @click="query = ''">
                    <svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18" /></svg>
                  </button>
                </label>
              </div>
            </div>
          </div>
          <div class="cell">
            <div class="field-block menu" :class="{ open: menuOpen }">
              <span class="caption">Home yard</span>
              <button type="button" class="menu-btn" aria-haspopup="listbox" :aria-expanded="menuOpen" @click="menuOpen = !menuOpen">
                <span>{{ marketLabel }}</span>
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
              </button>
              <div v-if="menuOpen" class="menu-list" role="listbox">
                <div class="menu-group">Yards</div>
                <button v-for="item in markets" :key="item.id" type="button" class="menu-item" role="option" :class="{ selected: market === item.id }" :aria-selected="market === item.id" @click="pickMarket(item.id)">
                  {{ item.name }}
                  <span class="meta">{{ item.meta }}</span>
                </button>
                <div class="menu-group">Depots</div>
                <button v-for="item in depots" :key="item.id" type="button" class="menu-item" role="option" :class="{ selected: market === item.id }" :aria-selected="market === item.id" @click="pickMarket(item.id)">
                  {{ item.name }}
                  <span class="meta">{{ item.meta }}</span>
                </button>
              </div>
            </div>
          </div>
          <div class="column">
            <div class="cell">
              <div class="stack">
                <label class="field-block">
                  <span class="caption">Distance: {{ miles }} mi</span>
                  <input class="slider" type="range" min="0" max="100" v-model.number="miles" :style="{ '--fill': miles + '%' }" aria-label="Distance" />
                </label>
                <div class="field-block">
                  <span class="caption">Pallets</span>
                  <div class="stepper" data-focus-field>
                    <input type="text" inputmode="numeric" :value="pallets" aria-label="Pallet count" @change="setCount" />
                    <div class="stepper-btns">
                      <button type="button" aria-label="Increase count" :disabled="pallets >= 100" @click="bump(1)">
                        <svg viewBox="0 0 24 24"><path d="M6 14l6-6 6 6" /></svg>
                      </button>
                      <button type="button" aria-label="Decrease count" :disabled="pallets <= 0" @click="bump(-1)">
                        <svg viewBox="0 0 24 24"><path d="M6 10l6 6 6-6" /></svg>
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <div class="cell">
              <div class="toggle-grid">
                <label class="check"><input type="checkbox" v-model="insured" /> Cargo cover</label>
                <label class="check"><input type="checkbox" checked disabled /> Radio</label>
                <label class="switch"><input type="checkbox" v-model="hired" /><span class="knob"></span> Night runs</label>
                <label class="switch"><input type="checkbox" disabled /><span class="knob"></span> Locked</label>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[4].id" class="group">
        <h2>{{ sections[4].label }}</h2>
        <div class="bento place">
          <div class="place-card">
            <div class="hero scrim-side ph-yard">
              <div class="hero-copy">
                <strong>North gate</strong>
                <span>Company trucks</span>
              </div>
            </div>
            <div class="stats">
              <div class="stat"><span class="stat-key">Crew</span><span class="stat-value">Evening</span></div>
              <div class="stat money"><span class="stat-key">Gate fee</span><span class="stat-value">$40</span></div>
              <div class="stat ok"><span class="stat-key">Bay</span><span class="stat-value">Clear</span></div>
            </div>
          </div>
          <div class="place-card hero-only">
            <div class="hero tall scrim-bottom ph-dock">
              <div class="hero-copy">
                <div class="kicker">Delivery</div>
                <strong>Cold storage</strong>
                <span>Dock closes soon</span>
              </div>
            </div>
          </div>
          <div class="cell">
            <div class="stack">
              <div class="progress" aria-label="Contract progress">
                <div class="bar"><span class="done" style="width: 45%"></span><span class="transit" style="width: 20%"></span></div>
                <div class="legend"><span><b>45</b>delivered</span><span><b>20</b>rolling</span><span><b>35</b>left</span></div>
              </div>
              <div class="facts">
                <div class="fact money"><span class="fact-key">Paid</span><span class="fact-value">$1,240</span></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[5].id" class="group">
        <h2>{{ sections[5].label }}</h2>
        <div class="bento lists">
          <div class="slot list-pair">
            <div class="stack list-stack">
              <button v-for="item in rows" :key="item.id" type="button" class="row" :class="{ selected: rowId === item.id }" @click="rowId = item.id">
                <span class="thumb" :class="item.photo"></span>
                <span class="row-copy">
                  <strong>{{ item.title }}</strong>
                  <span>{{ item.meta }}</span>
                </span>
                <span class="money">{{ item.pay }}</span>
              </button>
            </div>
          </div>
          <div class="slot list-pair">
            <div class="panel">
              <div class="stats">
                <div class="stat money"><span class="stat-key">Wages</span><span class="stat-value">$430</span></div>
                <div class="stat"><span class="stat-key">Runs</span><span class="stat-value">2</span></div>
                <div class="stat warn"><span class="stat-key">Wear</span><span class="stat-value">Scrape</span></div>
              </div>
              <div class="sheet">
                <div class="lines">
                  <div class="line"><span>Quarry run</span><strong class="money">$280</strong></div>
                  <div class="line"><span>Return leg</span><strong class="money">$190</strong></div>
                  <div class="line"><span>Wear</span><strong class="negative">-$40</strong></div>
                </div>
              </div>
            </div>
          </div>
          <div class="slot">
            <div class="stack">
              <div class="split-head"><span class="kicker">Morning</span><hr class="rule" /></div>
              <div class="lines">
                <div class="line"><span>Clocked in</span><span class="hint">6:12</span></div>
                <div class="line"><span>Loaded</span><span class="hint">6:40</span></div>
              </div>
              <div class="split-head"><span class="kicker">Afternoon</span><hr class="rule" /></div>
              <div class="lines">
                <div class="line"><span>Dock signed</span><span class="hint">11:05</span></div>
                <div class="line"><span class="negative">Trailer scrape</span><span class="hint">11:18</span></div>
              </div>
            </div>
          </div>
          <div class="slot">
            <div class="lines">
              <button v-for="item in settings" :key="item.id" type="button" class="line" :class="{ selected: settingId === item.id }" @click="settingId = item.id">
                <span class="row-copy">
                  <strong>{{ item.title }}</strong>
                  <span>{{ item.meta }}</span>
                </span>
              </button>
            </div>
          </div>
          <div class="slot">
            <div class="scroll scroll-demo">
              <div class="lines">
                <div v-for="stop in stops" :key="stop.n" class="line"><span>{{ stop.name }}</span><strong class="money">{{ stop.pay }}</strong></div>
              </div>
            </div>
          </div>
          <div class="slot">
            <div class="tiles">
              <button v-for="tile in tiles" :key="tile.id" type="button" class="tile-card" :class="{ picked: tileId === tile.id }" @click="tileId = tile.id">
                <span class="thumb" :class="tile.photo"></span>
                <span class="tile-copy">
                  <strong>{{ tile.name }}</strong>
                  <span class="pill" :class="tile.pill">{{ tile.state }}</span>
                </span>
              </button>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[6].id" class="group">
        <div class="bento dropdowns">
          <div class="cell hug">
            <div class="toolbar-row">
              <div class="menu compact" :class="{ open: sortOpen }">
                <button type="button" class="menu-btn" aria-haspopup="listbox" :aria-expanded="sortOpen" @click="toggleSort">
                  <span>{{ sortLabel }}</span>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
                </button>
                <div v-if="sortOpen" class="menu-list" role="listbox">
                  <button v-for="item in sorts" :key="item.id" type="button" class="menu-item" role="option" :class="{ selected: sort === item.id }" :aria-selected="sort === item.id" @click="pickSort(item.id)">{{ item.name }}</button>
                </div>
              </div>
              <div class="menu compact multi" :class="{ open: filterOpen }">
                <button type="button" class="menu-btn" aria-haspopup="listbox" :aria-expanded="filterOpen" @click="toggleFilters">
                  <span>Filters<span v-if="filterCount" class="pill accent">{{ filterCount }}</span></span>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
                </button>
                <div v-if="filterOpen" class="menu-list" role="listbox" aria-multiselectable="true">
                  <button v-for="item in filterOptions" :key="item.id" type="button" class="menu-item" role="option" :class="{ checked: filters.includes(item.id) }" :aria-selected="filters.includes(item.id)" @click="toggleFilter(item.id)">
                    <span>{{ item.name }}</span>
                    <svg v-if="filters.includes(item.id)" class="item-check" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
                  </button>
                </div>
              </div>
            </div>
          </div>
          <div class="cell">
            <div class="stack">
              <div class="field-block">
                <span class="caption">Trailer</span>
                <div class="chips">
                  <button v-for="chip in trailerChips" :key="chip" type="button" :class="{ active: trailers.includes(chip) }" @click="toggleTrailer(chip)">{{ chip }}</button>
                </div>
              </div>
              <div class="field-block">
                <span class="caption">Haul</span>
                <div class="chips">
                  <button v-for="chip in haulChips" :key="chip" type="button" :class="{ active: haul === chip }" @click="haul = chip">{{ chip }}</button>
                </div>
              </div>
            </div>
          </div>
          <div class="cell">
            <div class="fold" :class="{ open: foldOpen }">
              <button type="button" class="fold-summary" @click="foldOpen = !foldOpen">
                <span class="fold-copy">
                  <strong>Phone size</strong>
                  <span>{{ phoneScaleLabel }}</span>
                </span>
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
              </button>
              <div v-if="foldOpen" class="fold-body">
                <input class="slider" type="range" min="80" max="140" v-model.number="phoneScale" :style="{ '--fill': ((phoneScale - 80) / 60 * 100) + '%' }" aria-label="Phone scale" />
              </div>
            </div>
            <div class="menu wallpaper-menu" :class="{ open: wallpaperOpen }">
              <button type="button" class="fold-summary" aria-haspopup="listbox" :aria-expanded="wallpaperOpen" @click="wallpaperOpen = !wallpaperOpen">
                <span class="fold-copy">
                  <strong>Wallpaper</strong>
                  <span>{{ wallpaperLabel }}</span>
                </span>
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
              </button>
              <div v-if="wallpaperOpen" class="menu-list" role="listbox">
                <button v-for="item in wallpapers" :key="item.id" type="button" class="menu-item" role="option" :class="{ selected: wallpaper === item.id }" :aria-selected="wallpaper === item.id" @click="pickWallpaper(item.id)">{{ item.name }}</button>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section :id="sections[7].id" class="group">
        <h2>{{ sections[7].label }}</h2>
        <div class="stack layouts">
          <div class="page-shell">
            <div class="apphead">
              <h2>Stops</h2>
              <button type="button" class="icon-btn" aria-label="Refresh">
                <svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.35-5.65" /><path d="M20 4v4.5h-4.5" /></svg>
              </button>
            </div>
            <div class="simple-columns">
              <div class="lines">
                <button v-for="stop in stops.slice(0, 4)" :key="'simple-' + stop.n" type="button" class="line" :class="{ selected: simpleId === stop.n }" @click="simpleId = stop.n">
                  <span class="row-copy">
                    <strong>{{ stop.name }}</strong>
                    <span>Gate check</span>
                  </span>
                  <strong class="money">{{ stop.pay }}</strong>
                </button>
              </div>
              <div class="empty compact-empty">
                <div class="empty-glyph">
                  <svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h10M4 17h14" /></svg>
                </div>
                <h3>No more stops</h3>
                <button type="button" class="btn btn-primary compact">Add stop</button>
              </div>
            </div>
          </div>

          <div class="page-shell">
            <div class="split">
              <div class="split-list">
                <label class="search" data-focus-field>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
                  <input v-model="loadQuery" type="text" placeholder="Search loads" aria-label="Search loads" />
                </label>
                <button v-for="item in detailRows" :key="item.id" type="button" class="row" :class="{ selected: detailId === item.id }" @click="detailId = item.id">
                  <span class="thumb" :class="item.photo"></span>
                  <span class="row-copy">
                    <strong>{{ item.title }}</strong>
                    <span>{{ item.meta }}</span>
                  </span>
                  <span class="money">{{ item.pay }}</span>
                </button>
              </div>
              <div class="split-detail stack" v-if="activeDetail">
                <div class="hero scrim-bottom" :class="activeDetail.photo">
                  <div class="hero-copy">
                    <strong>{{ activeDetail.title }}</strong>
                  </div>
                </div>
                <div class="load-metrics">
                  <div class="facts">
                    <div class="fact"><span class="fact-key">Pickup</span><span class="fact-value">{{ activeDetail.pickup }}</span></div>
                    <div class="fact"><span class="fact-key">Haul</span><span class="fact-value">{{ activeDetail.haul }}</span></div>
                    <div class="fact ok"><span class="fact-key">Bay</span><span class="fact-value">Clear</span></div>
                  </div>
                  <div class="route-pair">
                    <strong class="route-place">{{ activeDetail.from }}</strong>
                    <span class="route-arrow" aria-hidden="true">
                      <svg viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" /></svg>
                    </span>
                    <strong class="route-place">{{ activeDetail.to }}</strong>
                  </div>
                </div>
                <div class="actions">
                  <button type="button" class="btn">Save</button>
                  <button type="button" class="btn btn-primary">Reserve</button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="bento shell-bits">
          <div class="cell">
            <div class="stack">
              <p class="notice">Updating…</p>
              <p class="notice ok">Confirmed</p>
              <p class="notice bad">Cancelled</p>
            </div>
          </div>
          <div class="cell bare">
            <section class="modal flat">
              <h3>Abandon this load?</h3>
              <div class="actions">
                <button type="button" class="btn btn-quiet">Keep</button>
                <button type="button" class="btn btn-danger">Abandon</button>
              </div>
            </section>
          </div>
          <div class="cell">
            <div class="ledger">
              <div class="ledger-row"><span>Base rate</span><strong class="money">$640</strong></div>
              <div class="ledger-row"><span>Bonus</span><strong class="money">$80</strong></div>
              <div class="ledger-row"><span>Fuel</span><strong class="negative">-$60</strong></div>
              <div class="ledger-row"><span>Wear</span><strong class="negative">-$25</strong></div>
            </div>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, ref } from "vue"
import { lua } from "@/bridge"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import ControllerExamples from "../components/house/ControllerExamples.vue"

const scope = { scopeId: 'root', activateOnMount: true, preferAutoFocus: true, canDeactivate: () => false }
const back = event => { event.stopPropagation(); lua.extensions.ui_router.back() }

const sections = [
  { id: "foundations", label: "Foundations" },
  { id: "actions", label: "Actions" },
  { id: "choosing", label: "Choosing" },
  { id: "entering", label: "Entering" },
  { id: "place", label: "Place" },
  { id: "lists", label: "Lists" },
  { id: "dropdowns", label: "Dropdowns" },
  { id: "layouts", label: "Layouts" },
]

const navTab = ref("work")
const filterTab = ref("week")
const rowId = ref("lumber")
const settingId = ref("alerts")
const tileId = ref("flatbed")
const simpleId = ref(1)
const detailId = ref("steel")
const query = ref("")
const loadQuery = ref("")
const note = ref("")
const market = ref("quarry")
const menuOpen = ref(true)
const sortOpen = ref(false)
const sort = ref("pay")
const filterOpen = ref(false)
const filters = ref(["night", "open"])
const foldOpen = ref(true)
const wallpaperOpen = ref(true)
const wallpaper = ref("dark")
const phoneScale = ref(110)
const insured = ref(true)
const hired = ref(true)
const pallets = ref(12)
const miles = ref(35)
const trailers = ref(["Flatbed"])
const haul = ref("Short")

const markets = [
  { id: "quarry", name: "Quarry", meta: "Sample region" },
  { id: "port", name: "Port", meta: "Sample region" },
]
const depots = [
  { id: "north", name: "North gate", meta: "Evenings" },
  { id: "south", name: "South lot", meta: "Day" },
]
const sorts = [
  { id: "pay", name: "Highest pay" },
  { id: "near", name: "Nearest pickup" },
  { id: "haul", name: "Shortest haul" },
]
const filterOptions = [
  { id: "night", name: "Night runs" },
  { id: "company", name: "Company only" },
  { id: "open", name: "Open loads" },
]
const wallpapers = [
  { id: "dark", name: "Default dark" },
  { id: "yard", name: "Yard dusk" },
  { id: "dock", name: "Dock night" },
]

const marketLabel = computed(() => [...markets, ...depots].find(item => item.id === market.value)?.name || "")
const sortLabel = computed(() => sorts.find(item => item.id === sort.value)?.name || "")
const filterCount = computed(() => filters.value.length)
const wallpaperLabel = computed(() => wallpapers.find(item => item.id === wallpaper.value)?.name || "")
const phoneScaleLabel = computed(() => (phoneScale.value / 100).toFixed(1) + "x")
const pickMarket = id => { market.value = id }
const toggleSort = () => {
  sortOpen.value = !sortOpen.value
  if (sortOpen.value) filterOpen.value = false
}
const toggleFilters = () => {
  filterOpen.value = !filterOpen.value
  if (filterOpen.value) sortOpen.value = false
}
const pickSort = id => { sort.value = id; sortOpen.value = false }
const pickWallpaper = id => { wallpaper.value = id; wallpaperOpen.value = false }
const toggleFilter = id => {
  if (filters.value.includes(id)) filters.value = filters.value.filter(item => item !== id)
  else filters.value = [...filters.value, id]
}
const toggleTrailer = chip => {
  if (trailers.value.includes(chip)) trailers.value = trailers.value.filter(item => item !== chip)
  else trailers.value = [...trailers.value, chip]
}
const bump = delta => { pallets.value = Math.min(100, Math.max(0, pallets.value + delta)) }
const setCount = event => {
  const next = Math.round(Number(event.target.value))
  pallets.value = Number.isFinite(next) ? Math.min(100, Math.max(0, next)) : 0
  event.target.value = pallets.value
}

const swatches = [
  { name: "--accent", value: "var(--accent)" },
  { name: "--page", value: "var(--page)" },
  { name: "--panel", value: "var(--panel)" },
  { name: "--panel-2", value: "var(--panel-2)" },
  { name: "--money", value: "var(--money)" },
  { name: "--ok", value: "var(--ok)" },
  { name: "--warn", value: "var(--warn)" },
  { name: "--bad", value: "var(--bad)" },
]

const spaces = [
  { name: "--space-1", value: "var(--space-1)" },
  { name: "--space-2", value: "var(--space-2)" },
  { name: "--space-3", value: "var(--space-3)" },
  { name: "--space-4", value: "var(--space-4)" },
]

const trailerChips = ["Flatbed", "Box", "Tanker", "Lowboy"]
const haulChips = ["Any", "Short", "Long"]

const rows = [
  { id: "lumber", title: "Lumber run", meta: "Quarry → Port", pay: "$860", photo: "ph-dock" },
  { id: "aggregate", title: "Aggregate", meta: "Port → Quarry", pay: "$410", photo: "ph-yard" },
  { id: "parts", title: "Parts crate", meta: "Garage → Shop", pay: "$190", photo: "ph-shop" },
]

const settings = [
  { id: "alerts", title: "Route alerts", meta: "Near stops" },
  { id: "damage", title: "Damage warnings", meta: "Pay risk" },
  { id: "quiet", title: "Quiet hours", meta: "10pm–6am" },
]

const stops = [
  { n: 1, name: "North gate", pay: "$80" },
  { n: 2, name: "Scale house", pay: "$40" },
  { n: 3, name: "Fuel island", pay: "$25" },
  { n: 4, name: "Cold dock", pay: "$190" },
  { n: 5, name: "Yard office", pay: "$15" },
  { n: 6, name: "South lot", pay: "$60" },
]

const tiles = [
  { id: "flatbed", name: "Flatbed", state: "Assigned", pill: "accent", photo: "ph-yard" },
  { id: "van", name: "Box van", state: "Ready", pill: "ok", photo: "ph-dock" },
  { id: "hauler", name: "Hauler", state: "Locked", pill: "bad", photo: "ph-shop" },
]

const detailRows = [
  { id: "steel", title: "Steel coils", meta: "Quarry → Port", pay: "$720", photo: "ph-yard", from: "Sample quarry", to: "Sample port", pickup: "4.2 mi", haul: "18 mi" },
  { id: "chilled", title: "Chilled freight", meta: "Port → Dock", pay: "$540", photo: "ph-dock", from: "Sample port", to: "Cold storage", pickup: "1.1 mi", haul: "9 mi" },
  { id: "gravel", title: "Gravel top-up", meta: "Quarry → Yard", pay: "$310", photo: "ph-shop", from: "Sample quarry", to: "Company yard", pickup: "2.6 mi", haul: "6 mi" },
]

const activeDetail = computed(() => detailRows.find(item => item.id === detailId.value) || detailRows[0])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.guide-screen {
  height: 100%;
  overflow: auto;
  background: #0c0c0e;
  color: #fff;
  scroll-behavior: smooth;
}
.guide {
  width: min(78em, 100%);
  margin: 0 auto;
  padding: 1.6em 1.4em 3.6em;
  display: grid;
  gap: 2.4em;
}
.mast {
  display: flex;
  flex-wrap: wrap;
  align-items: end;
  justify-content: space-between;
  gap: 1em 1.4em;
  padding-bottom: 1.1em;
  border-bottom: 1px solid var(--line);
}
.guide h1 {
  margin: 0.15em 0 0;
  font-size: 2.1em;
  font-weight: 800;
  letter-spacing: -0.03em;
  line-height: 1;
}
.index {
  display: flex;
  flex-wrap: wrap;
  gap: 0.15em 0.85em;
  justify-content: flex-end;
}
.group { display: grid; gap: 1em; scroll-margin-top: 1em; }
.group > h2 {
  margin: 0;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--faint);
}
.bento {
  display: grid;
  grid-template-columns: repeat(12, minmax(0, 1fr));
  gap: 1.05em;
  align-items: start;
}
.cell {
  grid-column: span 4;
  display: grid;
  gap: 0.7em;
  align-content: start;
  min-width: 0;
  padding: 1em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.cell.bare {
  background: transparent;
  padding: 0;
  gap: 0.55em;
}
.cell.bare .caption { padding-left: 0.15em; }
.slot {
  grid-column: span 4;
  display: grid;
  gap: 0.7em;
  align-content: start;
  min-width: 0;
}
.column {
  grid-column: span 4;
  display: grid;
  gap: 1.05em;
  min-width: 0;
}
.column > .cell { grid-column: auto; }
.lists .slot { grid-column: span 4; }
.foundations .cell:first-child { grid-column: span 12; }
.foundations .cell:nth-child(2),
.foundations .cell:nth-child(3) { grid-column: span 6; }
.guide .stack > p { margin: 0; }
.entering .cell,
.place .cell,
.place .place-card,
.choosing .cell,
.dropdowns .cell,
.shell-bits .cell { grid-column: span 4; }
.place .place-card.hero-only { background: transparent; }
.place .place-card.hero-only > .hero { border-radius: var(--radius-panel); }
.toggle-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.95em 0.85em; align-items: center; }
.pair-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.5fr) minmax(0, 1fr);
  gap: 1.05em;
  align-items: start;
}
.fill { height: auto; }
.lists .list-pair {
  grid-column: span 4;
  align-self: start;
}
.lists .list-stack { gap: var(--space-3); }
.wallpaper-menu {
  margin-top: 0.65em;
  position: relative;
}
.wallpaper-menu .fold-summary {
  width: 100%;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
}
.wallpaper-menu.open .fold-summary svg { transform: rotate(180deg); }
.wallpaper-menu.open .fold-summary,
.wallpaper-menu.open .fold-summary:focus,
.wallpaper-menu.open .fold-summary.focus-visible {
  outline: none;
  box-shadow: none;
}
.layouts { gap: 1.05em; }
.simple-columns {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1em;
  align-items: stretch;
}
.mono { font-family: Consolas, ui-monospace, monospace; font-size: 0.84em; color: var(--accent-soft); }
.swatches { display: grid; grid-template-columns: repeat(8, minmax(0, 1fr)); gap: 0.55em; }
.swatch { display: grid; gap: 0.3em; min-width: 0; }
.swatch i {
  display: block;
  height: 2.4em;
  border-radius: var(--radius-thumb);
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
}
.swatch strong { font-size: 0.72em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.space-list { display: grid; gap: 0.55em; }
.space-row { display: grid; grid-template-columns: 5em minmax(0, 1fr); gap: 0.7em; align-items: center; }
.pair { display: flex; align-items: center; font-size: 1.8em; }
.pair i { width: 0.6em; height: 0.6em; border-radius: 0.12em; background: var(--accent); }
.scroll-demo { max-height: 10em; padding-right: 0.3em; }
.phone-sample {
  width: min(100%, 22em);
  justify-self: start;
  align-content: start;
  gap: var(--space-3);
  padding: var(--inset);
  border-radius: var(--radius-control);
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
}
.phone-sample .actions { width: 100%; }
.tiles { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.65em; }
.ph-yard { background: linear-gradient(145deg, #3a2a22 0%, #8a4b28 42%, #1a1a1c 100%); }
.ph-dock { background: linear-gradient(160deg, #1d3344 0%, #3d6d86 48%, #151517 100%); }
.ph-shop { background: linear-gradient(200deg, #2a2e24 0%, #6d7348 40%, #17171a 100%); }
.thumb.ph-yard, .thumb.ph-dock, .thumb.ph-shop { box-shadow: none; }
.field.area.short { min-height: 3.2em; }
.compact-empty { padding: 0.9em 0.5em; place-content: center; height: 100%; }
.guide .modal.flat {
  position: relative;
  width: 100%;
  margin: 0;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08);
}
.menu-btn .pill { margin-left: 0.35em; }
.dropdowns .cell.hug {
  width: max-content;
  max-width: 100%;
  justify-self: start;
  padding: 0.55em;
}
.dropdowns .toolbar-row {
  flex-wrap: nowrap;
  align-items: flex-start;
}
.guide .menu.open .menu-btn,
.guide .menu.open .menu-btn:focus,
.guide .menu.open .menu-btn.focus-visible {
  outline: none;
  box-shadow: none;
}
.guide .panel.stack {
  gap: var(--space-3);
}
.guide .panel .actions + .actions {
  margin-top: 0.15em;
}

@media (max-width: 980px) {
  .bento, .pair-grid, .simple-columns, .swatches, .tiles, .space-row { grid-template-columns: minmax(0, 1fr); }
  .cell, .column,
  .foundations .cell:first-child,
  .foundations .cell:nth-child(2),
  .foundations .cell:nth-child(3),
  .entering .cell,
  .place .cell,
  .place .place-card,
  .choosing .cell,
  .lists .slot,
  .dropdowns .cell,
  .shell-bits .cell { grid-column: span 1; }
  .split { grid-template-columns: minmax(0, 1fr); }
}
</style>

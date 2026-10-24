<template>
  <div class="profiles-toolbar">
    <div class="pt-search">
      <input
        v-model="search"
        class="pt-input"
        bng-scoped-nav-autofocus
        placeholder="Search profiles..."
        :disabled="disabled"
        @focus="emit('search-focus')"
        @blur="emit('search-blur')" />
    </div>

    <div class="pt-controls">
      <div :ref="setSortContainer" class="pt-dropdown">
        <button type="button" class="pt-trigger" @click.stop="emit('toggle-sort')" @mousedown.stop>
          <span>{{ sortLabel }}</span>
          <span class="pt-chevron">&#x25BE;</span>
        </button>
        <teleport to="body">
          <!-- Teleported menus need their own navigation scopes. -->
          <div
            v-if="sortOpen"
            v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (closeSort(), false) }"
            v-bng-on-ui-nav:menu="closeSort"
            class="pt-menu"
            :style="sortStyle"
            @click.stop
            @mousedown.stop>
            <div
              v-for="opt in sortOptions"
              :key="opt.value"
              class="pt-option"
              :class="{ 'pt-option--active': opt.value === sortMode }"
              role="button"
              tabindex="0"
              bng-nav-item
              :bng-scoped-nav-autofocus="opt.value === sortMode ? '' : null"
              @click.stop="emit('select-sort', opt.value)"
              @keydown.enter.prevent="emit('select-sort', opt.value)"
              @mousedown.stop>
              {{ opt.label }}
            </div>
          </div>
        </teleport>
      </div>

      <div :ref="setFilterContainer" class="pt-dropdown">
        <button type="button" class="pt-trigger" @click.stop="emit('toggle-filter')" @mousedown.stop>
          <span>Filter{{ activeFilterCount > 0 ? ` (${activeFilterCount})` : '' }}</span>
          <span class="pt-chevron">&#x25BE;</span>
        </button>
        <teleport to="body">
          <div
            v-if="filterOpen"
            v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (closeFilter(), false) }"
            v-bng-on-ui-nav:menu="closeFilter"
            class="pt-menu pt-menu--filter"
            :style="filterStyle"
            @click.stop
            @mousedown.stop>
            <div class="pt-filter-group">
              <div class="pt-filter-heading">Path</div>
              <label v-for="p in pathFilterOptions" :key="p" class="pt-check">
                <input type="checkbox" :checked="activePaths.has(p)" @change="emit('toggle-path', p)" />
                <span>{{ p }}</span>
              </label>
            </div>
            <div class="pt-filter-sep" />
            <div class="pt-filter-group">
              <div class="pt-filter-heading">Difficulty</div>
              <label v-for="d in difficultyFilterOptions" :key="d" class="pt-check">
                <input type="checkbox" :checked="activeDifficulties.has(d)" @change="emit('toggle-difficulty', d)" />
                <span>{{ d }}</span>
              </label>
            </div>
            <div v-if="challengeOptions.length" class="pt-filter-sep" />
            <div v-if="challengeOptions.length" class="pt-filter-group">
              <div class="pt-filter-heading">Story</div>
              <label v-for="c in challengeOptions" :key="c" class="pt-check">
                <input type="checkbox" :checked="activeChallenges.has(c)" @change="emit('toggle-challenge', c)" />
                <span>{{ c }}</span>
              </label>
            </div>
            <div v-if="activeFilterCount > 0" class="pt-filter-sep" />
            <button v-if="activeFilterCount > 0" class="pt-clear-btn" @click.stop="emit('clear-filters')" @mousedown.stop>Clear All</button>
          </div>
        </teleport>
      </div>
    </div>
  </div>
</template>

<script setup>
// The search box and the sort and filter dropdowns above the save strip. It draws what the view passes in and reports
// what was picked. The view keeps the saves, the filter sets, and which menu is open.
import { computed } from "vue"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import {
  DIFFICULTY_FILTER_OPTIONS as difficultyFilterOptions,
  PATH_FILTER_OPTIONS as pathFilterOptions,
} from "../../components/start/careerStartModes.js"

const props = defineProps({
  searchQuery: { type: String, required: true },
  disabled: { type: Boolean, default: false },
  sortOptions: { type: Array, required: true },
  sortMode: { type: String, required: true },
  sortLabel: { type: String, required: true },
  sortOpen: { type: Boolean, default: false },
  sortStyle: { type: String, default: "" },
  filterOpen: { type: Boolean, default: false },
  filterStyle: { type: String, default: "" },
  activeFilterCount: { type: Number, default: 0 },
  activePaths: { type: Set, required: true },
  activeDifficulties: { type: Set, required: true },
  activeChallenges: { type: Set, required: true },
  challengeOptions: { type: Array, required: true },
  /** Receives the element that holds each dropdown, so the view can position its menu. */
  setSortContainer: { type: Function, required: true },
  setFilterContainer: { type: Function, required: true },
})

const emit = defineEmits([
  "update:searchQuery",
  "search-focus",
  "search-blur",
  "toggle-sort",
  "select-sort",
  "close-sort",
  "toggle-filter",
  "close-filter",
  "toggle-path",
  "toggle-difficulty",
  "toggle-challenge",
  "clear-filters",
])

const search = computed({
  get: () => props.searchQuery,
  set: value => emit("update:searchQuery", value),
})

const closeSort = () => emit("close-sort")
const closeFilter = () => emit("close-filter")
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

/* The right-hand part of the view's toolbar row, after Back. It ends where the
   open card ends; the row sets the shared control height. */
.profiles-toolbar {
  display: flex;
  flex: 1 1 auto;
  min-width: 0;
  align-items: center;
  justify-content: flex-end;
  gap: 0.75em;
  position: relative;
  z-index: 2;
}

/* Fixed rather than fluid: it is one item in a centred group now, and growing
   to fill the row would push the dropdowns back out to the edge. */
.pt-search {
  flex: 0 0 auto;
  width: 20em;
}

.pt-input {
  width: 100%;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  box-sizing: border-box;
  height: var(--profiles-control-height, auto);
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  outline: none;

  &::placeholder { color: rgba(255, 255, 255, 0.35); }
  &:focus { border-color: rgba(148, 163, 184, 0.5); }
}

.pt-controls {
  display: flex;
  gap: 0.5em;
  flex-shrink: 0;
}

.pt-dropdown { position: relative; }

.pt-trigger {
  display: flex;
  align-items: center;
  gap: 0.5em;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  box-sizing: border-box;
  height: var(--profiles-control-height, auto);
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;

  &:hover { border-color: rgba(71, 85, 105, 0.8); }
}

.pt-chevron { opacity: 0.5; font-size: 0.9em; }

.pt-menu {
  background: rgba(10, 14, 24, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  font-size: calc-ui-rem();
}

.pt-option {
  padding: 0.4em 0.6em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  font-size: 0.82em;
  white-space: nowrap;

  &:hover, &:focus { background: rgba(30, 41, 59, 0.6); outline: none; }
  /* Orange, like every other accent on this screen — this was the lone blue. */
  &.pt-option--active { background: rgba(255, 122, 26, 0.16); color: #ff9647; }
}

.pt-menu--filter {
  min-width: 14em;
  max-height: 28em;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

.pt-filter-group { padding: 0.25em 0.35em; }
.pt-filter-heading {
  font-size: 0.72em;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.45);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.25em 0.25em 0.35em;
}

.pt-check {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.3em 0.25em;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.82em;
  color: #fff;

  &:hover { background: rgba(30, 41, 59, 0.5); }

  input[type="checkbox"] {
    accent-color: #ff7a1a;
    width: 1em;
    height: 1em;
    cursor: pointer;
  }
}

.pt-filter-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.35);
  margin: 0.25em 0.35em;
}

.pt-clear-btn {
  display: block;
  width: calc(100% - 0.5em);
  margin: 0.25em auto;
  padding: 0.35em;
  border: 0;
  border-radius: 6px;
  background: rgba(239, 68, 68, 0.15);
  color: #f87171;
  font-size: 0.78em;
  font-weight: 600;
  cursor: pointer;

  &:hover { background: rgba(239, 68, 68, 0.25); }
}
</style>

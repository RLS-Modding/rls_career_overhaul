<template>
  <div class="sort-dropdown" ref="rootEl">
    <div class="sort-dropdown-container" :class="{ open: isOpen }">
      <div class="sort-btn" :class="{ active: isOpen }" @click="isOpen = !isOpen">
        Sort
        <div v-if="isActive" class="sort-count">1</div>
        <BngIcon :type="icons.arrowSmallDown" />
      </div>

      <Teleport to="body">
        <div class="sort-panel" v-show="isOpen" @click.stop ref="panelEl">
          <div class="panel-arrow"></div>
        <div class="panel-header">
          <div class="title">Sort Vehicles</div>
          <BngButton v-if="isActive" :accent="ACCENTS.secondary" size="sm" class="clear-btn" @click="clearSort">Clear</BngButton>
        </div>
        <div v-if="isActive" class="active-text">Sorted by {{ activeLabel }}</div>

        <div class="options-wrapper">
          <div class="options">
            <button
              v-for="opt in sortOptions"
              :key="opt.id"
              class="option"
              :class="{ selected: opt.field === store.sortField && opt.direction === store.sortDirection }"
              @click="applyOption(opt)"
            >
              <span>{{ opt.label }}</span>
            </button>
          </div>
        </div>

        <div class="panel-footer">Select a sorting option to organize the vehicle listings</div>
        </div>
      </Teleport>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, onMounted, onBeforeUnmount, Teleport, nextTick, watch } from "vue"
import { BngIcon, BngButton, ACCENTS, icons } from "@/common/components/base"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"

const store = useVehicleShoppingStore()
const isOpen = ref(false)
const rootEl = ref(null)
const panelEl = ref(null)

const isActive = computed(() => store.sortField !== 'Value' || store.sortDirection !== 'asc')

const formatFieldLabel = (key) => {
  if (!key) return ''
  if (key === 'Value') return 'Price'
  return key.replace(/_/g, ' ').replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/^./, s => s.toUpperCase())
}

const makeLabel = (field, dir) => {
  const base = formatFieldLabel(field)
  if (field === 'year') return dir === 'desc' ? 'Year: Newest First' : 'Year: Oldest First'
  if (field === 'Value') return dir === 'asc' ? 'Price: Low to High' : 'Price: High to Low'
  return `${base}: ${dir === 'asc' ? 'Low to High' : 'High to Low'}`
}

const sortOptions = computed(() => {
  const fields = Array.isArray(store.numericFields) ? store.numericFields : []
  const ordered = ['Value','year','Mileage','Power', ...fields.filter(f => !['Value','year','Mileage','Power'].includes(f))]
  const opts = []
  ordered.forEach(f => {
    if (!fields.includes(f)) return
    opts.push({ id: `${f}-asc`, field: f, direction: 'asc', label: makeLabel(f, 'asc') })
    opts.push({ id: `${f}-desc`, field: f, direction: 'desc', label: makeLabel(f, 'desc') })
  })
  return opts
})

const activeLabel = computed(() => makeLabel(store.sortField || 'Value', store.sortDirection || 'asc'))

const applyOption = (opt) => {
  store.setSort(opt.field, opt.direction)
  isOpen.value = false
}

const clearSort = () => {
  store.setSort('Value', 'asc')
  isOpen.value = false
}

// Position panel relative to trigger
function positionPanel() {
  if (!rootEl.value || !panelEl.value) return
  const trigger = rootEl.value.querySelector('.sort-btn')
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  panelEl.value.style.position = 'fixed'
  panelEl.value.style.top = `${rect.bottom + 4}px`
  panelEl.value.style.left = `${rect.left}px`
}

// Watch for open state to position panel
watch(isOpen, async (newVal) => {
  if (newVal) {
    await nextTick()
    positionPanel()
    window.addEventListener('resize', positionPanel)
    window.addEventListener('scroll', positionPanel)
  } else {
    window.removeEventListener('resize', positionPanel)
    window.removeEventListener('scroll', positionPanel)
  }
})

// local click-outside to close
function onDocClick(e) {
  if (!rootEl.value || !panelEl.value) return
  if (!rootEl.value.contains(e.target) && !panelEl.value.contains(e.target)) {
    isOpen.value = false
  }
}
onMounted(() => document.addEventListener("click", onDocClick, true))
onBeforeUnmount(() => {
  document.removeEventListener("click", onDocClick, true)
  window.removeEventListener('resize', positionPanel)
  window.removeEventListener('scroll', positionPanel)
})
</script>

<style scoped lang="scss">
.sort-dropdown {
  display: flex;
  position: relative;
}


.sort-dropdown-container {
  position: relative;
  display: inline-block;
}

.sort-btn {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--bng-cool-gray-800);
  border: 1px solid var(--bng-cool-gray-600);
  border-radius: var(--bng-corners-1);
  color: var(--bng-off-white);
  cursor: pointer;
  transition: all 0.2s ease;
  font-size: 0.875rem;
  font-weight: 500;
  height: 2.75rem;
  padding: 0.75rem 1rem;

  &:hover { background: var(--bng-orange-alpha-10); border-color: var(--bng-orange-alpha-50); }
  &.active { border-color: var(--bng-orange); background: var(--bng-orange-alpha-10); }

  .sort-count {
    padding: 0.125rem 0.375rem;
    background: var(--bng-orange);
    color: var(--bng-off-black);
    border-radius: var(--bng-corners-1);
    font-size: 0.75rem;
    font-weight: 600;
    min-width: 1.125rem;
    height: 1.125rem;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
  }
}

.sort-panel {
  width: 22rem;
  max-width: calc(100vw - 4rem);
  background: var(--bng-cool-gray-900);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: var(--bng-corners-2);
  box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  padding: 0;
  position: fixed;
  z-index: 12000;
  height: 22rem;
  overflow: hidden;
  /* fake popover arrow */
  .panel-arrow {
    position: absolute;
    top: -0.5rem;
    left: 1rem;
    width: 1rem;
    height: 1rem;
    transform: rotate(45deg);
    background: var(--bng-cool-gray-900);
    border-left: 1px solid var(--bng-cool-gray-700);
    border-top: 1px solid var(--bng-cool-gray-700);
    box-shadow: -2px -2px 4px rgba(0,0,0,0.15);
  }
}

.panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--bng-cool-gray-600);
  .title { font-weight: 500; color: var(--bng-off-white); font-size: 0.9rem; }
  .clear-btn { color: rgb(239,68,68); }
}

.active-text { padding: 0 1rem 0.5rem 1rem; color: var(--bng-cool-gray-300); font-size: 0.75rem; }

.options-wrapper { height: 16rem; overflow-y: auto; }
.options { padding: 0.5rem; display: flex; flex-direction: column; gap: 0.25rem; }

.option {
  width: 100%;
  text-align: left;
  padding: 0.5rem 0.75rem;
  border-radius: var(--bng-corners-1);
  color: var(--bng-off-white);
  background: transparent;
  border: 1px solid transparent;
  font-size: 0.875rem;
  cursor: pointer;
  transition: background 120ms ease;
}
.option:hover { background: var(--bng-cool-gray-800); }
.option.selected { background: var(--bng-orange-alpha-15); color: var(--bng-orange); border-color: var(--bng-orange); }

.panel-footer { padding: 0.75rem 1rem; border-top: 1px solid var(--bng-cool-gray-600); color: var(--bng-cool-gray-300); font-size: 0.75rem; }
</style>



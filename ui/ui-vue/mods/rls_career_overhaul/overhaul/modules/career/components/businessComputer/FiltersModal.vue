<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div v-if="show" class="rls-house rls-house-card filters-overlay" @click.self="handleClose">
        <div
          ref="modalRef" class="modal filters-modal"
          v-bng-on-ui-nav:tab_l,tab_r="skipSection"
          v-bng-scoped-nav="modalScope" v-bc-modal-focus
          v-bng-on-ui-nav:back,menu="handleClose"
          >
          <header class="filters-head">
            <h3>Filters</h3>
            <p class="hint">Manage job visibility, notifications, and manager assignments.</p>
          </header>

          <div class="filters-body scroll" v-bng-ui-nav-scroll @focusin="revealFocusedList">
            <!-- Blacklist -->
            <section class="filter-section">
              <div class="section-head">
                <div class="section-copy">
                  <strong class="section-name">Blacklist</strong>
                  <span class="hint">Exclude selected vehicles from job generation.</span>
                </div>
                <div class="cluster tight">
                  <span class="pill">{{ blacklistCount }} / {{ blacklistMax }} slots</span>
                  <span class="pill">Generation {{ generationPercent }}%</span>
                </div>
              </div>

              <p v-if="!blacklistUnlocked" class="notice locked">
                <BngIcon :type="icons.lockClosed" class="lock-glyph" />
                <span>Unlock the Blacklist skill to use this feature.</span>
              </p>
              <div v-else class="section-body">
                <label class="search" data-focus-field>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
                  <input
                    v-model="blacklistFilter"
                    placeholder="Search by name, brand, or model"
                    v-bng-text-input bng-no-nav="true"
                    ref="blacklistInputRef"
                  />
                </label>
                <div class="list-grid">
                  <div class="list-column">
                    <span class="caption">Available vehicles</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <button
                          v-for="vehicle in filteredBlacklistOptions"
                          :key="`blacklist-option-${vehicle.modelKey}`"
                          type="button"
                          class="line pick-line"
                          :disabled="blacklistFull" :bng-no-nav="(blacklistFull) ? 'true' : null"
                          @click.stop="handleAddBlacklist(vehicle.modelKey)"
                          @mousedown.stop
                        >
                          <span class="vehicle-copy">
                            <strong>{{ vehicle.name }}</strong>
                            <span v-if="vehicle.brand" class="hint">{{ vehicle.brand }}</span>
                          </span>
                          <span class="add-label">
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
                            Add
                          </span>
                        </button>
                      </div>
                      <p v-if="filteredBlacklistOptions.length === 0" class="list-empty">No vehicles available</p>
                    </div>
                  </div>
                  <div class="list-column">
                    <span class="caption">Blacklisted</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <div
                          v-for="modelKey in blacklist"
                          :key="`blacklist-${modelKey}`"
                          class="line"
                        >
                          <span class="vehicle-copy">
                            <strong>{{ getVehicleName(modelKey) }}</strong>
                            <span v-if="getVehicleBrand(modelKey)" class="hint">{{ getVehicleBrand(modelKey) }}</span>
                          </span>
                          <HouseButton
                            variant="quiet-danger"
                            compact
                            @click.stop="handleRemoveBlacklist(modelKey)"
                            @mousedown.stop
                          >
                            Remove
                          </HouseButton>
                        </div>
                      </div>
                      <p v-if="blacklist.length === 0" class="list-empty">No vehicles blacklisted</p>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <!-- Notification list -->
            <section class="filter-section">
              <div class="section-head">
                <div class="section-copy">
                  <strong class="section-name">Notification list</strong>
                  <span class="hint">Get alerts for specific vehicles. Optional auto-accept per model.</span>
                </div>
                <div class="cluster tight">
                  <span class="pill">{{ notificationCount }} / {{ notificationMax }} slots</span>
                </div>
              </div>

              <p v-if="!notificationUnlocked" class="notice locked">
                <BngIcon :type="icons.lockClosed" class="lock-glyph" />
                <span>Unlock the Notification List skill to use this feature.</span>
              </p>
              <div v-else class="section-body">
                <label class="search" data-focus-field>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
                  <input
                    v-model="notificationFilter"
                    placeholder="Search by name, brand, or model"
                    v-bng-text-input bng-no-nav="true"
                  />
                </label>
                <div class="list-grid">
                  <div class="list-column">
                    <span class="caption">Available vehicles</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <button
                          v-for="vehicle in filteredNotificationOptions"
                          :key="`notification-option-${vehicle.modelKey}`"
                          type="button"
                          class="line pick-line"
                          :disabled="notificationFull" :bng-no-nav="(notificationFull) ? 'true' : null"
                          @click.stop="handleAddNotification(vehicle.modelKey)"
                          @mousedown.stop
                        >
                          <span class="vehicle-copy">
                            <strong>{{ vehicle.name }}</strong>
                            <span v-if="vehicle.brand" class="hint">{{ vehicle.brand }}</span>
                          </span>
                          <span class="add-label">
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
                            Add
                          </span>
                        </button>
                      </div>
                      <p v-if="filteredNotificationOptions.length === 0" class="list-empty">No vehicles available</p>
                    </div>
                  </div>
                  <div class="list-column">
                    <span class="caption">Notifications</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <div
                          v-for="entry in notificationList"
                          :key="`notification-${entry.model_key}`"
                          class="line"
                        >
                          <span class="vehicle-copy">
                            <strong>{{ getVehicleName(entry.model_key) }}</strong>
                            <span v-if="getVehicleBrand(entry.model_key)" class="hint">{{ getVehicleBrand(entry.model_key) }}</span>
                          </span>
                          <span class="item-actions">
                            <HouseSwitch
                              class="auto-accept"
                              :model-value="entry.autoAccept === true"
                              @update:model-value="enabled => handleToggleAutoAccept(entry.model_key, enabled)"
                            >
                              Auto-accept
                            </HouseSwitch>
                            <HouseButton
                              variant="quiet-danger"
                              compact
                              @click.stop="handleRemoveNotification(entry.model_key)"
                              @mousedown.stop
                            >
                              Remove
                            </HouseButton>
                          </span>
                        </div>
                      </div>
                      <p v-if="notificationList.length === 0" class="list-empty">No notifications set</p>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <!-- Manager blacklist -->
            <section class="filter-section">
              <div class="section-head">
                <div class="section-copy">
                  <strong class="section-name">Manager blacklist</strong>
                  <span class="hint">Prevent the manager from auto-assigning selected jobs.</span>
                </div>
                <div class="cluster tight">
                  <span class="pill">{{ managerBlacklistCount }} / {{ managerBlacklistMax }} slots</span>
                </div>
              </div>

              <p v-if="!managerBlacklistUnlocked" class="notice locked">
                <BngIcon :type="icons.lockClosed" class="lock-glyph" />
                <span>Unlock the Manager Blacklist skill to use this feature.</span>
              </p>
              <div v-else class="section-body">
                <label class="search" data-focus-field>
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.25" /><path d="M15.2 15.2L20 20" /></svg>
                  <input
                    v-model="managerBlacklistFilter"
                    placeholder="Search by name, brand, or model"
                    v-bng-text-input bng-no-nav="true"
                  />
                </label>
                <div class="list-grid">
                  <div class="list-column">
                    <span class="caption">Available vehicles</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <button
                          v-for="vehicle in filteredManagerBlacklistOptions"
                          :key="`manager-blacklist-option-${vehicle.modelKey}`"
                          type="button"
                          class="line pick-line"
                          :disabled="managerBlacklistFull" :bng-no-nav="(managerBlacklistFull) ? 'true' : null"
                          @click.stop="handleAddManagerBlacklist(vehicle.modelKey)"
                          @mousedown.stop
                        >
                          <span class="vehicle-copy">
                            <strong>{{ vehicle.name }}</strong>
                            <span v-if="vehicle.brand" class="hint">{{ vehicle.brand }}</span>
                          </span>
                          <span class="add-label">
                            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
                            Add
                          </span>
                        </button>
                      </div>
                      <p v-if="filteredManagerBlacklistOptions.length === 0" class="list-empty">No vehicles available</p>
                    </div>
                  </div>
                  <div class="list-column">
                    <span class="caption">Manager blacklist</span>
                    <div class="list-box scroll" v-bng-ui-nav-scroll>
                      <div class="lines">
                        <div
                          v-for="modelKey in managerBlacklist"
                          :key="`manager-blacklist-${modelKey}`"
                          class="line"
                        >
                          <span class="vehicle-copy">
                            <strong>{{ getVehicleName(modelKey) }}</strong>
                            <span v-if="getVehicleBrand(modelKey)" class="hint">{{ getVehicleBrand(modelKey) }}</span>
                          </span>
                          <HouseButton
                            variant="quiet-danger"
                            compact
                            @click.stop="handleRemoveManagerBlacklist(modelKey)"
                            @mousedown.stop
                          >
                            Remove
                          </HouseButton>
                        </div>
                      </div>
                      <p v-if="managerBlacklist.length === 0" class="list-empty">No vehicles blocked for the manager</p>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <footer class="filters-foot">
            <p class="hint">Changes save as you make them.</p>
            <HouseButton variant="primary" bng-scoped-nav-autofocus @click.stop="handleClose" @mousedown.stop>
              Done
            </HouseButton>
          </footer>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { computed, onMounted, ref, watch } from "vue"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import { useBusinessTechsStore } from "../../stores/businessComputer/businessTechsStore.js"
import { vBngTextInput, vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseSwitch } from "../house/index.js"

const props = defineProps({
  show: {
    type: Boolean,
    default: false
  }
})

const emit = defineEmits(['close'])

const sessionStore = useBusinessSessionStore()
const techsStore = useBusinessTechsStore()

// controller: own scope while open (mounted with v-if), opens on Done, B/Start close
const modalScope = bcModalScope("job-filters")
const modalRef = ref(null)
const skipSection = event => {
  const sections = [...(modalRef.value?.querySelectorAll('.filter-section') || [])]
  const current = document.activeElement?.closest('.filter-section')
  const direction = event.detail.name === 'tab_l' ? -1 : 1
  const start = sections.indexOf(current)
  for (let offset = 1; offset <= sections.length; offset++) {
    const section = sections[(start + direction * offset + sections.length * 2) % sections.length]
    const target = section.querySelector('button:not(:disabled), input:not([bng-no-nav="true"])')
    if (target) { target.scrollIntoView({ block: 'nearest' }); setFocus(target); break }
  }
  return false
}

// The vehicle lists are small scroll boxes inside the scrolling body. The game's d-pad only scrolls the
// nearest scroll box and skips items the outer body has clipped, so keep the whole list box (or the
// focused control) in view of the outer body whenever focus moves.
const revealFocusedList = (event) => {
  const target = event.target?.closest?.(".list-box") || event.target
  target?.scrollIntoView?.({ block: "nearest", inline: "nearest" })
}

onMounted(() => {
  if (props.show) {
    refreshData()
  }
})

watch(() => props.show, (isOpen) => {
  if (isOpen) {
    refreshData()
  }
})

const blacklistFilter = ref("")
const notificationFilter = ref("")
const managerBlacklistFilter = ref("")

const blacklistData = computed(() => {
  const data = techsStore.blacklistData
  if (!data || typeof data !== 'object') return {}
  return {
    blacklist: Array.isArray(data.blacklist) ? data.blacklist : [],
    availableVehicles: Array.isArray(data.availableVehicles) ? data.availableVehicles : [],
    level: data.level || 0,
    maxSlots: data.maxSlots || 0,
    generationMultiplier: typeof data.generationMultiplier === 'number' ? data.generationMultiplier : 1.0
  }
})

const notificationData = computed(() => {
  const data = techsStore.notificationListData
  if (!data || typeof data !== 'object') return {}
  return {
    notificationList: Array.isArray(data.notificationList) ? data.notificationList : [],
    availableVehicles: Array.isArray(data.availableVehicles) ? data.availableVehicles : [],
    level: data.level || 0,
    maxSlots: data.maxSlots || 0
  }
})

const managerData = computed(() => {
  const data = techsStore.managerBlacklistData
  if (!data || typeof data !== 'object') return {}
  return {
    managerBlacklist: Array.isArray(data.managerBlacklist) ? data.managerBlacklist : [],
    availableVehicles: Array.isArray(data.availableVehicles) ? data.availableVehicles : [],
    level: data.level || 0,
    maxSlots: data.maxSlots || 0
  }
})

const availableVehicles = computed(() => {
  const blacklist = blacklistData.value.availableVehicles
  const notification = notificationData.value.availableVehicles
  const manager = managerData.value.availableVehicles
  
  if (Array.isArray(blacklist) && blacklist.length > 0) return blacklist
  if (Array.isArray(notification) && notification.length > 0) return notification
  if (Array.isArray(manager) && manager.length > 0) return manager
  return []
})

const vehicleNameMap = computed(() => {
  const map = new Map()
  const vehicles = availableVehicles.value
  if (!Array.isArray(vehicles)) return map
  for (const vehicle of vehicles) {
    if (vehicle && vehicle.modelKey) {
      map.set(vehicle.modelKey, vehicle)
    }
  }
  return map
})

const getVehicleName = (modelKey) => {
  const vehicle = vehicleNameMap.value.get(modelKey)
  return vehicle?.name || modelKey
}

const getVehicleBrand = (modelKey) => {
  const vehicle = vehicleNameMap.value.get(modelKey)
  return vehicle?.brand || ""
}

const blacklist = computed(() => {
  const list = blacklistData.value.blacklist
  return Array.isArray(list) ? list : []
})
const blacklistCount = computed(() => blacklist.value.length)
const blacklistMax = computed(() => blacklistData.value.maxSlots ?? 0)
const blacklistUnlocked = computed(() => (blacklistData.value.level || 0) > 0)
const blacklistFull = computed(() => blacklistCount.value >= blacklistMax.value)
const generationPercent = computed(() => {
  const multiplier = blacklistData.value.generationMultiplier
  if (typeof multiplier !== "number") return 100
  return Math.round(multiplier * 100)
})

const notificationList = computed(() => {
  const list = notificationData.value.notificationList
  return Array.isArray(list) ? list : []
})
const notificationCount = computed(() => notificationList.value.length)
const notificationMax = computed(() => notificationData.value.maxSlots ?? 0)
const notificationUnlocked = computed(() => (notificationData.value.level || 0) > 0)
const notificationFull = computed(() => notificationCount.value >= notificationMax.value)

const managerBlacklist = computed(() => {
  const list = managerData.value.managerBlacklist
  return Array.isArray(list) ? list : []
})
const managerBlacklistCount = computed(() => managerBlacklist.value.length)
const managerBlacklistMax = computed(() => managerData.value.maxSlots ?? 0)
const managerBlacklistUnlocked = computed(() => (managerData.value.level || 0) > 0)
const managerBlacklistFull = computed(() => managerBlacklistCount.value >= managerBlacklistMax.value)

const filterVehicles = (list, filterText, excludeKeys) => {
  if (!Array.isArray(list)) return []
  const filterValue = (filterText || "").trim().toLowerCase()
  const excluded = new Set(Array.isArray(excludeKeys) ? excludeKeys : [])
  return list.filter(vehicle => {
    if (!vehicle || !vehicle.modelKey || excluded.has(vehicle.modelKey)) return false
    if (!filterValue) return true
    
    const name = (vehicle.name || vehicle.modelKey || "").toLowerCase()
    const modelKey = (vehicle.modelKey || "").toLowerCase()
    const brand = (vehicle.brand || "").toLowerCase()
    
    return name.includes(filterValue) || 
           modelKey.includes(filterValue) || 
           brand.includes(filterValue)
  })
}

const filteredBlacklistOptions = computed(() => {
  return filterVehicles(availableVehicles.value, blacklistFilter.value, blacklist.value)
})

const filteredNotificationOptions = computed(() => {
  const list = notificationList.value
  const existing = Array.isArray(list) ? list.map(entry => entry?.model_key).filter(Boolean) : []
  return filterVehicles(availableVehicles.value, notificationFilter.value, existing)
})

const filteredManagerBlacklistOptions = computed(() => {
  return filterVehicles(availableVehicles.value, managerBlacklistFilter.value, managerBlacklist.value)
})

const refreshData = async () => {
  if (!sessionStore.businessId || !sessionStore.hasCapability('customerJobs')) return
  await Promise.all([
    techsStore.fetchBlacklistData(),
    techsStore.fetchNotificationListData(),
    techsStore.fetchManagerBlacklistData()
  ])
}

const handleAddBlacklist = async (modelKey) => {
  if (!modelKey || blacklistFull.value) return
  const list = blacklist.value
  const next = Array.isArray(list) ? [...list, modelKey] : [modelKey]
  const success = await techsStore.updateBlacklist(next)
  if (success) await techsStore.fetchBlacklistData()
}

const handleRemoveBlacklist = async (modelKey) => {
  const list = blacklist.value
  const next = Array.isArray(list) ? list.filter(key => key !== modelKey) : []
  const success = await techsStore.updateBlacklist(next)
  if (success) await techsStore.fetchBlacklistData()
}

const handleAddNotification = async (modelKey) => {
  if (!modelKey || notificationFull.value) return
  const list = notificationList.value
  const next = Array.isArray(list) ? [...list, { model_key: modelKey, autoAccept: false }] : [{ model_key: modelKey, autoAccept: false }]
  const success = await techsStore.updateNotificationList(next)
  if (success) await techsStore.fetchNotificationListData()
}

const handleRemoveNotification = async (modelKey) => {
  const list = notificationList.value
  const next = Array.isArray(list) ? list.filter(entry => entry?.model_key !== modelKey) : []
  const success = await techsStore.updateNotificationList(next)
  if (success) await techsStore.fetchNotificationListData()
}

const handleToggleAutoAccept = async (modelKey, enabled) => {
  const list = notificationList.value
  if (!Array.isArray(list)) return
  const next = list.map(entry => {
    if (entry?.model_key === modelKey) {
      return { ...entry, autoAccept: enabled === true }
    }
    return entry
  })
  const success = await techsStore.updateNotificationList(next)
  if (success) await techsStore.fetchNotificationListData()
}

const handleAddManagerBlacklist = async (modelKey) => {
  if (!modelKey || managerBlacklistFull.value) return
  const list = managerBlacklist.value
  const next = Array.isArray(list) ? [...list, modelKey] : [modelKey]
  const success = await techsStore.updateManagerBlacklist(next)
  if (success) await techsStore.fetchManagerBlacklistData()
}

const handleRemoveManagerBlacklist = async (modelKey) => {
  const list = managerBlacklist.value
  const next = Array.isArray(list) ? list.filter(key => key !== modelKey) : []
  const success = await techsStore.updateManagerBlacklist(next)
  if (success) await techsStore.fetchManagerBlacklistData()
}

const handleClose = () => {
  emit('close')
}

watch(() => sessionStore.businessId, () => {
  if (props.show) {
    refreshData()
  }
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .filters-modal {
    transition: transform 0.18s ease-out;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .filters-modal {
    transform: translateY(0.6em) scale(0.98);
  }
}

.filters-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
}

.filters-modal {
  width: min(64em, 94vw);
  max-height: 88vh;
  display: flex;
  flex-direction: column;
  gap: 0;
  padding: 0;
  overflow: hidden;
}

.filters-head {
  flex: 0 0 auto;
  display: grid;
  gap: 0.3em;
  padding: 1.1em 1.25em 0.8em;

  h3 {
    font-size: 1.3em;
  }
}

.filters-body {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  align-content: start;
  gap: 1.6em;
  padding: 0.4em 1.25em 1.2em;
}

.filters-foot {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding: 0.85em 1.25em 1.1em;
}

/* ---- section ---- */
.filter-section {
  display: grid;
  gap: var(--space-3);
}

.section-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.5em 1em;
}

.section-copy {
  flex: 1 1 16em;
  min-width: 0;
  display: grid;
  gap: 0.2em;
}

.section-name {
  font-size: 1.08em;
  font-weight: 800;
  line-height: 1.2;
}

.pill {
  font-variant-numeric: tabular-nums;
}

.notice.locked {
  display: flex;
  align-items: center;
  gap: 0.55em;
}

.lock-glyph {
  flex: 0 0 auto;
  font-size: 1.1em;
  color: var(--faint);
}

.section-body {
  display: grid;
  gap: var(--space-3);
}

.list-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(18em, 1fr));
  gap: 1em;
}

.list-column {
  display: grid;
  align-content: start;
  gap: 0.45em;
  min-width: 0;
}

.list-box {
  max-height: 18em;
  min-height: 4.5em;
  border-radius: var(--radius-panel);
  background: rgba(255, 255, 255, 0.04);
  box-shadow: inset 0 0 0 1px var(--line);

  .line {
    padding-left: 0.75em;
    padding-right: 0.6em;
  }
}

.vehicle-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  gap: 0.15em;

  strong {
    font-weight: 700;
    line-height: 1.2;
  }
}

.pick-line {
  &:disabled {
    opacity: 0.45;
    cursor: default;
  }

  &:hover:not(:disabled) .add-label {
    color: #fff;
  }
}

.add-label {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 700;

  svg {
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    transform: translateY(-0.08em);
  }
}

.item-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.75em;
}

.auto-accept {
  font-size: 0.88em;
  color: var(--muted);
  white-space: nowrap;
}

.list-empty {
  margin: 0;
  padding: 1.2em 1em;
  text-align: center;
  color: var(--faint);
  font-size: 0.9em;
  font-weight: 600;
}
</style>

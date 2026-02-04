<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div v-if="show" class="modal-overlay" @click.self="handleClose">
        <div class="modal-content" @click.stop ref="modalContentRef">
          <div class="modal-header">
            <h2 class="modal-title">Filters</h2>
            <p class="modal-subtitle">Manage job visibility, notifications, and manager assignments.</p>
            <button class="modal-close" @click.stop="handleClose" @mousedown.stop data-focusable>×</button>
          </div>

          <div class="modal-body">
            <section class="filter-section">
              <div class="section-header">
                <div class="section-title-group">
                  <h3>Blacklist</h3>
                  <p>Exclude selected vehicles from job generation.</p>
                </div>
                <div class="section-meta">
                  <span class="meta-badge">Slots {{ blacklistCount }} / {{ blacklistMax }}</span>
                  <span class="meta-badge">Generation {{ generationPercent }}%</span>
                </div>
              </div>

              <div v-if="!blacklistUnlocked" class="locked-banner">
                Unlock the Blacklist skill to use this feature.
              </div>
              <div v-else class="section-body">
                <div class="filter-input">
                  <input
                    v-model="blacklistFilter"
                    placeholder="Search by name, brand, or model..."
                    v-bng-text-input
                    ref="blacklistInputRef"
                  />
                </div>
                <div class="list-grid">
                  <div class="list-column">
                    <h4>Available Vehicles</h4>
                    <div class="list-container">
                      <div class="list">
                        <button
                          v-for="vehicle in filteredBlacklistOptions"
                          :key="`blacklist-option-${vehicle.modelKey}`"
                          class="list-item"
                          :disabled="blacklistFull"
                          @click.stop="handleAddBlacklist(vehicle.modelKey)"
                          @mousedown.stop
                          data-focusable
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ vehicle.name }}</span>
                            <span v-if="vehicle.brand" class="vehicle-brand">{{ vehicle.brand }}</span>
                          </div>
                          <span class="action-add">+ Add</span>
                        </button>
                        <div v-if="filteredBlacklistOptions.length === 0" class="list-empty">
                          No vehicles available
                        </div>
                      </div>
                    </div>
                  </div>
                  <div class="list-column">
                    <h4>Blacklisted</h4>
                    <div class="list-container">
                      <div class="list">
                        <div
                          v-for="modelKey in blacklist"
                          :key="`blacklist-${modelKey}`"
                          class="list-item static"
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ getVehicleName(modelKey) }}</span>
                            <span v-if="getVehicleBrand(modelKey)" class="vehicle-brand">{{ getVehicleBrand(modelKey) }}</span>
                          </div>
                          <button
                            class="action-button remove"
                            @click.stop="handleRemoveBlacklist(modelKey)"
                            @mousedown.stop
                            data-focusable
                          >
                            Remove
                          </button>
                        </div>
                        <div v-if="blacklist.length === 0" class="list-empty">
                          No vehicles blacklisted
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="filter-section">
              <div class="section-header">
                <div class="section-title-group">
                  <h3>Notification List</h3>
                  <p>Get alerts for specific vehicles. Optional auto-accept per model.</p>
                </div>
                <div class="section-meta">
                  <span class="meta-badge">Slots {{ notificationCount }} / {{ notificationMax }}</span>
                </div>
              </div>

              <div v-if="!notificationUnlocked" class="locked-banner">
                Unlock the Notification List skill to use this feature.
              </div>
              <div v-else class="section-body">
                <div class="filter-input">
                  <input
                    v-model="notificationFilter"
                    placeholder="Search by name, brand, or model..."
                    v-bng-text-input
                  />
                </div>
                <div class="list-grid">
                  <div class="list-column">
                    <h4>Available Vehicles</h4>
                    <div class="list-container">
                      <div class="list">
                        <button
                          v-for="vehicle in filteredNotificationOptions"
                          :key="`notification-option-${vehicle.modelKey}`"
                          class="list-item"
                          :disabled="notificationFull"
                          @click.stop="handleAddNotification(vehicle.modelKey)"
                          @mousedown.stop
                          data-focusable
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ vehicle.name }}</span>
                            <span v-if="vehicle.brand" class="vehicle-brand">{{ vehicle.brand }}</span>
                          </div>
                          <span class="action-add">+ Add</span>
                        </button>
                        <div v-if="filteredNotificationOptions.length === 0" class="list-empty">
                          No vehicles available
                        </div>
                      </div>
                    </div>
                  </div>
                  <div class="list-column">
                    <h4>Notifications</h4>
                    <div class="list-container">
                      <div class="list">
                        <div
                          v-for="entry in notificationList"
                          :key="`notification-${entry.model_key}`"
                          class="list-item static"
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ getVehicleName(entry.model_key) }}</span>
                            <span v-if="getVehicleBrand(entry.model_key)" class="vehicle-brand">{{ getVehicleBrand(entry.model_key) }}</span>
                          </div>
                          <div class="item-actions">
                            <label class="toggle">
                              <input
                                type="checkbox"
                                :checked="entry.autoAccept === true"
                                @change="handleToggleAutoAccept(entry.model_key, $event.target.checked)"
                              />
                              <span>Auto-accept</span>
                            </label>
                            <button
                              class="action-button remove"
                              @click.stop="handleRemoveNotification(entry.model_key)"
                              @mousedown.stop
                              data-focusable
                            >
                              Remove
                            </button>
                          </div>
                        </div>
                        <div v-if="notificationList.length === 0" class="list-empty">
                          No notifications set
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="filter-section">
              <div class="section-header">
                <div class="section-title-group">
                  <h3>Manager Blacklist</h3>
                  <p>Prevent the manager from auto-assigning selected jobs.</p>
                </div>
                <div class="section-meta">
                  <span class="meta-badge">Slots {{ managerBlacklistCount }} / {{ managerBlacklistMax }}</span>
                </div>
              </div>

              <div v-if="!managerBlacklistUnlocked" class="locked-banner">
                Unlock the Manager Blacklist skill to use this feature.
              </div>
              <div v-else class="section-body">
                <div class="filter-input">
                  <input
                    v-model="managerBlacklistFilter"
                    placeholder="Search by name, brand, or model..."
                    v-bng-text-input
                  />
                </div>
                <div class="list-grid">
                  <div class="list-column">
                    <h4>Available Vehicles</h4>
                    <div class="list-container">
                      <div class="list">
                        <button
                          v-for="vehicle in filteredManagerBlacklistOptions"
                          :key="`manager-blacklist-option-${vehicle.modelKey}`"
                          class="list-item"
                          :disabled="managerBlacklistFull"
                          @click.stop="handleAddManagerBlacklist(vehicle.modelKey)"
                          @mousedown.stop
                          data-focusable
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ vehicle.name }}</span>
                            <span v-if="vehicle.brand" class="vehicle-brand">{{ vehicle.brand }}</span>
                          </div>
                          <span class="action-add">+ Add</span>
                        </button>
                        <div v-if="filteredManagerBlacklistOptions.length === 0" class="list-empty">
                          No vehicles available
                        </div>
                      </div>
                    </div>
                  </div>
                  <div class="list-column">
                    <h4>Manager Blacklist</h4>
                    <div class="list-container">
                      <div class="list">
                        <div
                          v-for="modelKey in managerBlacklist"
                          :key="`manager-blacklist-${modelKey}`"
                          class="list-item static"
                        >
                          <div class="vehicle-info">
                            <span class="vehicle-name">{{ getVehicleName(modelKey) }}</span>
                            <span v-if="getVehicleBrand(modelKey)" class="vehicle-brand">{{ getVehicleBrand(modelKey) }}</span>
                          </div>
                          <button
                            class="action-button remove"
                            @click.stop="handleRemoveManagerBlacklist(modelKey)"
                            @mousedown.stop
                            data-focusable
                          >
                            Remove
                          </button>
                        </div>
                        <div v-if="managerBlacklist.length === 0" class="list-empty">
                          No vehicles blocked for the manager
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div class="modal-footer">
            <button class="btn btn-primary" @click.stop="handleClose" @mousedown.stop data-focusable>
              Close
            </button>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { computed, onMounted, ref, watch, nextTick, inject, onUnmounted } from "vue"
import { Teleport } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { vBngTextInput } from "@/common/directives"

const props = defineProps({
  show: {
    type: Boolean,
    default: false
  }
})

const emit = defineEmits(['close'])

const controllerNav = inject('controllerNav', null)
const modalContentRef = ref(null)
const store = useBusinessComputerStore()

const pushModalToController = () => {
  if (!controllerNav || !props.show) return
  nextTick(() => {
    if (modalContentRef.value) {
      controllerNav.pushModal(modalContentRef.value, handleClose)
    }
  })
}

onMounted(() => {
  if (props.show) {
    pushModalToController()
    refreshData()
  }
})

onUnmounted(() => {
  if (controllerNav && modalContentRef.value) {
    controllerNav.removeModal(modalContentRef.value)
  }
})

watch(() => props.show, (isOpen) => {
  if (isOpen) {
    pushModalToController()
    refreshData()
  }
})

const blacklistFilter = ref("")
const notificationFilter = ref("")
const managerBlacklistFilter = ref("")

const blacklistData = computed(() => {
  const data = store.blacklistData
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
  const data = store.notificationListData
  if (!data || typeof data !== 'object') return {}
  return {
    notificationList: Array.isArray(data.notificationList) ? data.notificationList : [],
    availableVehicles: Array.isArray(data.availableVehicles) ? data.availableVehicles : [],
    level: data.level || 0,
    maxSlots: data.maxSlots || 0
  }
})

const managerData = computed(() => {
  const data = store.managerBlacklistData
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
  if (!store.businessId || store.businessType !== "tuningShop") return
  await Promise.all([
    store.fetchBlacklistData(),
    store.fetchNotificationListData(),
    store.fetchManagerBlacklistData()
  ])
}

const handleAddBlacklist = async (modelKey) => {
  if (!modelKey || blacklistFull.value) return
  const list = blacklist.value
  const next = Array.isArray(list) ? [...list, modelKey] : [modelKey]
  const success = await store.updateBlacklist(next)
  if (success) await store.fetchBlacklistData()
}

const handleRemoveBlacklist = async (modelKey) => {
  const list = blacklist.value
  const next = Array.isArray(list) ? list.filter(key => key !== modelKey) : []
  const success = await store.updateBlacklist(next)
  if (success) await store.fetchBlacklistData()
}

const handleAddNotification = async (modelKey) => {
  if (!modelKey || notificationFull.value) return
  const list = notificationList.value
  const next = Array.isArray(list) ? [...list, { model_key: modelKey, autoAccept: false }] : [{ model_key: modelKey, autoAccept: false }]
  const success = await store.updateNotificationList(next)
  if (success) await store.fetchNotificationListData()
}

const handleRemoveNotification = async (modelKey) => {
  const list = notificationList.value
  const next = Array.isArray(list) ? list.filter(entry => entry?.model_key !== modelKey) : []
  const success = await store.updateNotificationList(next)
  if (success) await store.fetchNotificationListData()
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
  const success = await store.updateNotificationList(next)
  if (success) await store.fetchNotificationListData()
}

const handleAddManagerBlacklist = async (modelKey) => {
  if (!modelKey || managerBlacklistFull.value) return
  const list = managerBlacklist.value
  const next = Array.isArray(list) ? [...list, modelKey] : [modelKey]
  const success = await store.updateManagerBlacklist(next)
  if (success) await store.fetchManagerBlacklistData()
}

const handleRemoveManagerBlacklist = async (modelKey) => {
  const list = managerBlacklist.value
  const next = Array.isArray(list) ? list.filter(key => key !== modelKey) : []
  const success = await store.updateManagerBlacklist(next)
  if (success) await store.fetchManagerBlacklistData()
}

const handleClose = () => {
  emit('close')
}

watch(() => store.businessId, () => {
  if (props.show) {
    refreshData()
  }
})
</script>

<style scoped lang="scss">
.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
}

.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.75);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
  padding: 1em;
}

.modal-content {
  background: rgba(15, 15, 15, 0.98);
  border: 2px solid rgba(255, 153, 51, 0.4);
  border-radius: 12px;
  max-width: 90vw;
  width: 100%;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.6);
  overflow: hidden;
}

.modal-header {
  padding: 1.5em 2em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  position: relative;
  flex-shrink: 0;

  .modal-title {
    margin: 0;
    color: #fff;
    font-size: 1.75em;
    font-weight: 600;
  }

  .modal-subtitle {
    margin: 0.5em 0 0;
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.95em;
  }

  .modal-close {
    position: absolute;
    top: 1.5em;
    right: 2em;
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.7);
    font-size: 2em;
    line-height: 1;
    cursor: pointer;
    padding: 0;
    width: 1.5em;
    height: 1.5em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;

    &:hover {
      color: #fff;
    }
  }
}

.modal-body {
  padding: 1.5em 2em;
  overflow-y: auto;
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 1.5em;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);

  &::-webkit-scrollbar {
    width: 10px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(100, 116, 139, 0.2);
    border-radius: 10px;
  }

  &::-webkit-scrollbar-thumb {
    background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
    border-radius: 10px;
    border: 2px solid rgba(15, 23, 42, 0.98);
  }

  &::-webkit-scrollbar-thumb:hover {
    background-image: linear-gradient(180deg, #ff8a2a, #f86f10);
  }
}

.modal-footer {
  padding: 1em 2em;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  display: flex;
  justify-content: flex-end;
  flex-shrink: 0;
}

.filter-section {
  background: rgba(20, 20, 20, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 10px;
  padding: 1.25em;
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.section-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 1em;
  flex-wrap: wrap;

  .section-title-group {
    flex: 1;
    min-width: 200px;

    h3 {
      margin: 0;
      color: #fff;
      font-size: 1.15em;
      font-weight: 600;
    }

    p {
      margin: 0.35em 0 0;
      color: rgba(255, 255, 255, 0.55);
      font-size: 0.9em;
    }
  }

  .section-meta {
    display: flex;
    gap: 0.75em;
    flex-wrap: wrap;
  }

  .meta-badge {
    background: rgba(255, 153, 51, 0.15);
    border: 1px solid rgba(255, 153, 51, 0.3);
    color: rgba(255, 255, 255, 0.9);
    padding: 0.35em 0.75em;
    border-radius: 6px;
    font-size: 0.85em;
    font-weight: 500;
    white-space: nowrap;
  }
}

.locked-banner {
  background: rgba(255, 255, 255, 0.05);
  border: 1px dashed rgba(255, 255, 255, 0.2);
  border-radius: 8px;
  padding: 0.75em 1em;
  color: rgba(255, 255, 255, 0.6);
  text-align: center;
  font-size: 0.9em;
}

.section-body {
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.filter-input {
  input {
    width: 100%;
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
    padding: 0.6em 0.85em;
    color: #fff;
    font-size: 0.95em;
    transition: border-color 0.2s, background 0.2s;

    &:focus {
      outline: none;
      border-color: rgba(255, 153, 51, 0.5);
      background: rgba(0, 0, 0, 0.5);
    }

    &::placeholder {
      color: rgba(255, 255, 255, 0.4);
    }
  }
}

.list-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 1em;
}

.list-column {
  display: flex;
  flex-direction: column;
  gap: 0.75em;

  h4 {
    margin: 0;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.85em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 600;
  }
}

.list-container {
  max-height: 300px;
  overflow-y: auto;
  border-radius: 8px;
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 255, 255, 0.05);
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);

  &::-webkit-scrollbar {
    width: 10px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(100, 116, 139, 0.2);
    border-radius: 10px;
  }

  &::-webkit-scrollbar-thumb {
    background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
    border-radius: 10px;
    border: 2px solid rgba(15, 23, 42, 0.98);
  }

  &::-webkit-scrollbar-thumb:hover {
    background-image: linear-gradient(180deg, #ff8a2a, #f86f10);
  }
}

.list {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
  padding: 0.5em;
}

.list-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1em;
  padding: 0.65em 0.85em;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  transition: all 0.2s;
  cursor: pointer;
  text-align: left;

  .vehicle-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.2em;
    min-width: 0;
  }

  .vehicle-name {
    font-size: 0.9em;
    font-weight: 500;
  }

  .vehicle-brand {
    font-size: 0.75em;
    color: rgba(255, 255, 255, 0.5);
    font-style: italic;
  }

  .action-add {
    color: #ff9933;
    font-weight: 600;
    font-size: 0.85em;
    white-space: nowrap;
  }

  &:hover:not(:disabled) {
    border-color: rgba(255, 153, 51, 0.5);
    background: rgba(255, 153, 51, 0.1);
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.list-item.static {
  background: rgba(0, 0, 0, 0.4);
  cursor: default;

  .vehicle-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.2em;
    min-width: 0;
  }

  .vehicle-name {
    font-size: 0.9em;
    font-weight: 500;
  }

  .vehicle-brand {
    font-size: 0.75em;
    color: rgba(255, 255, 255, 0.5);
    font-style: italic;
  }

  .item-actions {
    display: flex;
    align-items: center;
    gap: 0.75em;
  }
}

.action-button {
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: #fff;
  border-radius: 6px;
  padding: 0.4em 0.85em;
  cursor: pointer;
  font-size: 0.85em;
  transition: all 0.2s;
  white-space: nowrap;

  &.remove {
    background: rgba(244, 67, 54, 0.15);
    border-color: rgba(244, 67, 54, 0.3);
    color: rgba(255, 255, 255, 0.9);

    &:hover {
      background: rgba(244, 67, 54, 0.25);
      border-color: rgba(244, 67, 54, 0.5);
    }
  }

  &:hover:not(.remove) {
    border-color: rgba(255, 153, 51, 0.5);
    background: rgba(255, 153, 51, 0.15);
  }
}

.toggle {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.7);
  cursor: pointer;
  white-space: nowrap;

  input {
    accent-color: #ff9933;
    cursor: pointer;
  }
}

.list-empty {
  padding: 1.5em;
  text-align: center;
  border: 1px dashed rgba(255, 255, 255, 0.1);
  border-radius: 8px;
  color: rgba(255, 255, 255, 0.4);
  font-size: 0.9em;
}

.btn {
  padding: 0.65em 1.5em;
  border-radius: 8px;
  border: none;
  font-size: 0.95em;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;

  &.btn-primary {
    background: rgba(255, 153, 51, 0.2);
    border: 1px solid rgba(255, 153, 51, 0.4);
    color: #fff;

    &:hover {
      background: rgba(255, 153, 51, 0.3);
      border-color: rgba(255, 153, 51, 0.6);
    }
  }
}

@media (max-width: 768px) {
  .modal-content {
    max-width: 95vw;
    max-height: 95vh;
  }

  .modal-header,
  .modal-body,
  .modal-footer {
    padding: 1em 1.25em;
  }

  .list-grid {
    grid-template-columns: 1fr;
  }
}
</style>

<template>
    <PhoneWrapper app-name="Facility Work" status-font-color="#FFFFFF" status-blend-mode="normal">
        <div class="facility-work-container">
            <!-- Header / Status -->
            <div class="app-header">
                <BngIcon :type="icons.cogs" class="header-icon" />
                <h1>Facility Work</h1>
            </div>

            <!-- Facility Selection List -->
            <div class="facility-list" v-if="!onDuty && !selectedFacilityId && facilities.length > 0">
                <div class="list-header">Select Facility</div>
                <div 
                    class="facility-card" 
                    v-for="fac in facilities" 
                    :key="fac.id"
                    @click="selectFacility(fac.id)"
                >
                    <div class="fac-name">{{ formatName(fac.name) }}</div>
                    <div class="fac-meta">Default batch: {{ fac.batchSize }}</div>
                </div>
            </div>

            <!-- Dashboard (Start/End Shift) -->
            <div class="dashboard-container" v-else-if="selectedFacilityId || onDuty || facilities.length === 1">
                
                <!-- Back Button -->
                <div class="nav-bar" v-if="!onDuty && facilities.length > 1">
                    <button class="back-btn" @click="clearSelection">
                        &lt; Back to List
                    </button>
                    <div class="current-fac">{{ facilityName }}</div>
                </div>

                <!-- Main Status Panel -->
                <div class="status-panel">
                    <div class="status-row">
                        <span class="label">Status:</span>
                        <span class="value" :class="statusClass">{{ statusText }}</span>
                    </div>
                    <div class="status-row">
                        <span class="label">Session Pay:</span>
                        <span class="value">${{ formatCurrency(sessionTotalPay) }}</span>
                    </div>
                    <div class="status-row">
                        <span class="label">Session Rep:</span>
                        <span class="value">{{ sessionTotalRep }}</span>
                    </div>
                    <div class="status-row">
                        <span class="label">Materials Moved:</span>
                        <span class="value">{{ sessionMaterialsMoved }}</span>
                    </div>
                </div>

                <!-- Batch Size Slider -->
                <div class="settings-panel" v-if="!onDuty && available">
                    <div class="setting-row">
                        <span class="label">Batch Size: {{ batchSize }}</span>
                        <input 
                            type="range" 
                            min="1" 
                            max="20" 
                            v-model.number="batchSize" 
                            @change="updateBatchSize"
                            class="slider"
                        >
                    </div>
                </div>
    
                <!-- Controls -->
                <div class="controls-container">
                    <button
                        class="action-button start-btn"
                        v-if="!onDuty && available"
                        @click="startShift"
                    >
                        Start shift
                    </button>
                    <button
                        class="action-button stop-btn"
                        v-if="onDuty"
                        @click="endShift"
                    >
                        End shift
                    </button>
                    <button
                        class="action-button complete-loading-btn"
                        v-if="onDuty && truckWaitingForLoad"
                        @click="completeLoading"
                    >
                        Complete loading
                    </button>
                    <button
                        class="action-button repair-btn"
                        v-if="onDuty"
                        @click="repairForklift"
                    >
                        Repair forklift
                    </button>
                </div>

                <!-- Info message when off duty -->
                <div class="info-panel" v-if="!onDuty && available">
                    <p>Tap <strong>Start shift</strong> to begin. A forklift will spawn for you. Move materials to the drop zone to earn pay and rep.</p>
                </div>
                <!-- Hint when facilities exist but Start shift not available (e.g. missing drop trigger) -->
                <div class="info-panel disabled-msg" v-if="!onDuty && !available && facilities.length > 0">
                    <p>Start shift is not available on this map. Add a drop trigger (e.g. <strong>facilityWork_drop</strong>) and ensure the spawn zone exists in the level.</p>
                </div>
            </div>

            <!-- Unavailable message only when no facilities at all (config not loaded or no facilities for this level) -->
            <div class="disabled-msg" v-if="facilities.length === 0">
                <p>Facility work is not available on this map.</p>
                <p class="hint">Ensure this level has <code>facilityWorkConfig.json</code> and at least one facility with a spawn zone.</p>
            </div>
        </div>
    </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, onUnmounted, computed } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngIcon, icons } from "@/common/components/base"
import { lua, useBridge } from '@/bridge'

const { events } = useBridge()

// State
const onDuty = ref(false)
const sessionTotalPay = ref(0)
const sessionTotalRep = ref(0)
const sessionMaterialsMoved = ref(0)
const available = ref(false)
const facilities = ref([])
const selectedFacilityId = ref(null)
const batchSize = ref(8)
const truckWaitingForLoad = ref(false)

// Computed
const statusText = computed(() => {
    if (!available.value && facilities.value.length === 0) return 'Unavailable'
    return onDuty.value ? 'On duty' : 'Off duty'
})

const statusClass = computed(() => {
    if (!available.value && facilities.value.length === 0) return 'text-red'
    return onDuty.value ? 'text-green' : 'text-grey'
})

const facilityName = computed(() => {
    const f = facilities.value.find(x => x.id === selectedFacilityId.value)
    return f ? formatName(f.name) : 'Unknown'
})

// Formatting
const formatCurrency = (val) => {
    return (val ?? 0).toFixed(2)
}

const formatName = (str) => {
    // Simple CamelCase to Title Case if needed, or just return
    return str.replace(/([A-Z])/g, ' $1').trim()
}

// Escape for use inside a double-quoted Lua string (prevents injection)
const escapeLuaString = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')

// Actions
const selectFacility = (id) => {
    selectedFacilityId.value = id
    // Use raw engineLua to bypass bridge proxy cache; escape id to prevent Lua injection
    if (id) {
        const safeId = escapeLuaString(id)
        window.bngApi.engineLua(`gameplay_facilityWork.selectFacility("${safeId}")`)
    } else {
        window.bngApi.engineLua(`gameplay_facilityWork.selectFacility(nil)`)
    }
}

const clearSelection = () => {
    selectedFacilityId.value = null
    window.bngApi.engineLua(`gameplay_facilityWork.selectFacility(nil)`)
}

const updateBatchSize = () => {
    window.bngApi.engineLua(`gameplay_facilityWork.setBatchSize(${batchSize.value})`)
}

const startShift = async () => {
    try {
        console.log("Starting shift with batch size:", batchSize.value)
        // Use raw engineLua to ensure it works even if proxy is stale
        window.bngApi.engineLua(`gameplay_facilityWork.setBatchSize(${batchSize.value})`)
        
        await lua.gameplay_facilityWork.startFacilityWork()
        await lua.gameplay_facilityWork.requestFacilityWorkState()
    } catch (e) {
        console.error("Facility Work Error:", e)
    }
}

const endShift = async () => {
    try {
        await lua.gameplay_facilityWork.endFacilityWork()
        await lua.gameplay_facilityWork.requestFacilityWorkState()
    } catch (e) {
        console.error("Facility Work Error:", e)
    }
}

const completeLoading = async () => {
    try {
        window.bngApi.engineLua('gameplay_facilityWork.completeTruckLoading()')
        await lua.gameplay_facilityWork.requestFacilityWorkState()
    } catch (e) {
        console.error("Facility Work Error:", e)
    }
}

const repairForklift = async () => {
    try {
        window.bngApi.engineLua('gameplay_facilityWork.repairForklift()')
        await lua.gameplay_facilityWork.requestFacilityWorkState()
    } catch (e) {
        console.error("Facility Work Error:", e)
    }
}

// Event Handling
const updateState = (data) => {
    if (!data) return
    onDuty.value = !!data.onDuty
    sessionTotalPay.value = data.sessionTotalPay ?? 0
    sessionTotalRep.value = data.sessionTotalRep ?? 0
    sessionMaterialsMoved.value = data.sessionMaterialsMoved ?? 0
    available.value = !!data.available
    facilities.value = data.facilities || []
    selectedFacilityId.value = data.selectedFacilityId || null
    if (data.preferredBatchSize) {
        batchSize.value = data.preferredBatchSize
    } else if (selectedFacilityId.value) {
        const fac = facilities.value.find(x => x.id === selectedFacilityId.value)
        if (fac) batchSize.value = fac.batchSize
    }
    truckWaitingForLoad.value = !!data.truckWaitingForLoad
}

onMounted(async () => {
    await lua.extensions.load('gameplay_facilityWork')
    events.on('updateFacilityWorkState', updateState)
    await lua.gameplay_facilityWork.requestFacilityWorkState()
})

onUnmounted(() => {
    events.off('updateFacilityWorkState', updateState)
})
</script>

<style scoped lang="scss">
.facility-work-container {
    padding: 1em;
    padding-top: 3em;
    padding-bottom: 3em;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: linear-gradient(to bottom, #e8f5e9, #c8e6c9);
    color: #333;
    overflow-y: auto;
    box-sizing: border-box;
}

.app-header {
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 1.5em;
    gap: 0.5em;

    h1 {
        font-size: 1.5em;
        font-weight: 800;
        color: #2d5a27;
        margin: 0;
    }

    .header-icon {
        color: #2d5a27;
        font-size: 1.5em;
    }
}

.facility-list {
    display: flex;
    flex-direction: column;
    gap: 0.8em;
}

.list-header {
    font-weight: 700;
    font-size: 1.1em;
    color: #444;
    margin-bottom: 0.5em;
}

.facility-card {
    background: white;
    padding: 1em;
    border-radius: 12px;
    box-shadow: 0 2px 5px rgba(0,0,0,0.05);
    cursor: pointer;
    transition: transform 0.1s, box-shadow 0.1s;

    &:active {
        transform: scale(0.98);
        background: #f1f8e9;
    }

    .fac-name {
        font-weight: 700;
        font-size: 1.1em;
        color: #2d5a27;
        margin-bottom: 0.2em;
    }

    .fac-meta {
        font-size: 0.9em;
        color: #777;
    }
}

.nav-bar {
    display: flex;
    align-items: center;
    margin-bottom: 1em;
    gap: 1em;

    .back-btn {
        background: none;
        border: none;
        color: #2d5a27;
        font-weight: 700;
        cursor: pointer;
        padding: 0;
        font-size: 1em;
    }

    .current-fac {
        font-weight: 700;
        color: #444;
        margin-left: auto;
    }
}

.settings-panel {
    background: white;
    padding: 1em;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
    margin-bottom: 1em;
}

.setting-row {
    display: flex;
    flex-direction: column;
    gap: 0.5em;

    .label {
        font-weight: 600;
        color: #666;
    }

    .slider {
        width: 100%;
        accent-color: #2d5a27;
    }
}

.status-panel {
    background: white;
    padding: 1em;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
    margin-bottom: 1em;
}

.status-row {
    display: flex;
    justify-content: space-between;
    margin-bottom: 0.5em;
    font-size: 1.1em;

    &:last-child {
        margin-bottom: 0;
    }

    .label {
        font-weight: 600;
        color: #666;
    }

    .value {
        font-weight: 700;
    }
}

.controls-container {
    margin-bottom: 1em;
}

.action-button {
    width: 100%;
    padding: 1em;
    border: none;
    border-radius: 12px;
    font-size: 1.1em;
    font-weight: 700;
    cursor: pointer;
    transition: transform 0.1s;

    &:active {
        transform: scale(0.98);
    }

    &.start-btn {
        background: #2d5a27;
        color: white;
    }

    &.stop-btn {
        background: #1b3d16;
        color: white;
    }

    &.complete-loading-btn {
        background: #c17a0a;
        color: white;
        margin-top: 0.5em;
    }

    &.repair-btn {
        background: #5c4a2a;
        color: white;
        margin-top: 0.5em;
    }
}

.info-panel {
    background: white;
    padding: 1em;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
    margin-bottom: 1em;
    font-size: 0.95em;
    color: #555;

    p {
        margin: 0;
        line-height: 1.4;
    }
}

.disabled-msg {
    text-align: center;
    color: #c62828;
    margin-top: 0.5em;
    font-weight: 600;
    padding: 0.5em;

    .hint {
        font-size: 0.9em;
        font-weight: 500;
        color: #666;
        margin-top: 0.5em;
    }
    code {
        font-family: monospace;
        background: rgba(0,0,0,0.06);
        padding: 0.1em 0.3em;
        border-radius: 4px;
    }
}

.text-grey { color: #999; }
.text-green { color: #2e7d32; }
.text-red { color: #c62828; }
</style>

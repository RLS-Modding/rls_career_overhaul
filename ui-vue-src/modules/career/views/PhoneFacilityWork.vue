<template>
    <PhoneWrapper app-name="Facility Work" status-font-color="#FFFFFF" status-blend-mode="normal">
        <div class="facility-work-container">
            <!-- Header / Status -->
            <div class="app-header">
                <BngIcon :type="icons.cogs" class="header-icon" />
                <h1>Facility Work</h1>
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
            </div>

            <!-- Info message when off duty -->
            <div class="info-panel" v-if="!onDuty && available">
                <p>Tap <strong>Start shift</strong> to begin. Get in a forklift and move materials to the drop zone to earn pay and rep.</p>
            </div>

            <!-- Unavailable message -->
            <div class="disabled-msg" v-if="!available">
                Facility work is not available on this map. This map may not have the required triggers and spawn zone configured.
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

// Computed
const statusText = computed(() => {
    if (!available.value) return 'Unavailable'
    return onDuty.value ? 'On duty' : 'Off duty'
})

const statusClass = computed(() => {
    if (!available.value) return 'text-red'
    return onDuty.value ? 'text-green' : 'text-grey'
})

// Formatting
const formatCurrency = (val) => {
    return (val ?? 0).toFixed(2)
}

// Actions
const startShift = async () => {
    await lua.gameplay_facilityWork.startFacilityWork()
    await lua.gameplay_facilityWork.requestFacilityWorkState()
}

const endShift = async () => {
    lua.gameplay_facilityWork.endFacilityWork()
    await lua.gameplay_facilityWork.requestFacilityWorkState()
}

// Event Handling
const updateState = (data) => {
    if (!data) return
    onDuty.value = !!data.onDuty
    sessionTotalPay.value = data.sessionTotalPay ?? 0
    sessionTotalRep.value = data.sessionTotalRep ?? 0
    sessionMaterialsMoved.value = data.sessionMaterialsMoved ?? 0
    available.value = !!data.available
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
}

.text-grey { color: #999; }
.text-green { color: #2e7d32; }
.text-red { color: #c62828; }
</style>

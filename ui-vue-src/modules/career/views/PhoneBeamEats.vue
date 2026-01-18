<template>
    <PhoneWrapper app-name="BeamEats" status-font-color="#FFFFFF" status-blend-mode="normal">
        <div class="beameats-container">
            <!-- Header / Status -->
            <div class="app-header">
                <BngIcon :type="icons.fastFood" class="header-icon" />
                <h1>BeamEats Driver</h1>
            </div>

            <!-- Main Status Panel -->
            <div class="status-panel">
                <div class="status-row">
                    <span class="label">Status:</span>
                    <span class="value" :class="statusClass">{{ statusText }}</span>
                </div>
                <div class="status-row">
                    <span class="label">Today's Earnings:</span>
                    <span class="value">${{ formatCurrency(cumulativeReward) }}</span>
                </div>
                <div class="status-row">
                    <span class="label">Streak:</span>
                    <span class="value">{{ orderStreak }}</span>
                </div>
            </div>

            <!-- Active Job Info (if any) -->
            <div class="job-panel" v-if="currentOrder">
                <div class="job-header">Current Order</div>
                <div class="job-details">
                    <div class="detail-row">
                        <span class="icon">🏪</span>
                        <span>{{ currentOrder.restaurant }}</span>
                    </div>
                    <div class="detail-row">
                        <span class="icon">📍</span>
                        <span>{{ currentOrder.destination ? (currentOrder.destination.name || 'Customer') : 'Customer' }}</span>
                    </div>
                    <div class="detail-row">
                        <span class="icon">💰</span>
                        <span>${{ currentOrder.baseFareDisplay }}</span>
                    </div>
                </div>
            </div>

            <!-- Controls -->
            <div class="controls-container">
                <button 
                    class="action-button start-btn" 
                    v-if="state === 'start' || state === 'disabled'"
                    @click="startShift"
                    :disabled="state === 'disabled'"
                >
                    {{ state === 'disabled' ? 'Unavailable' : 'Start Shift' }}
                </button>

                <button 
                    class="action-button stop-btn" 
                    v-if="state !== 'start' && state !== 'disabled'"
                    @click="endShift"
                >
                    End Shift
                </button>
            </div>

            <!-- Disabled Message -->
            <div class="disabled-msg" v-if="state === 'disabled'">
                {{ disabledReason }}
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
const state = ref('start')
const currentOrder = ref(null)
const cumulativeReward = ref(0)
const orderStreak = ref(0)
const disabledReason = ref('')

// Computed
const statusText = computed(() => {
    switch (state.value) {
        case 'start': return 'Offline'
        case 'ready': return 'Looking for orders...'
        case 'pickup': return 'Picking up order'
        case 'dropoff': return 'Delivering order'
        case 'disabled': return 'Unavailable'
        default: return state.value
    }
})

const statusClass = computed(() => {
    switch (state.value) {
        case 'start': return 'text-grey'
        case 'ready': return 'text-blue'
        case 'pickup': return 'text-orange'
        case 'dropoff': return 'text-green'
        case 'disabled': return 'text-red'
        default: return ''
    }
})

// Formatting
const formatCurrency = (val) => {
    return val.toFixed(2)
}

// Actions
const startShift = () => {
    lua.gameplay_beamEats.setAvailable()
}

const endShift = () => {
    lua.gameplay_beamEats.stopBeamEatsJob()
}

// Event Handling
const updateState = (data) => {
    if (!data) return
    state.value = data.state
    currentOrder.value = data.currentOrder
    cumulativeReward.value = data.cumulativeReward
    orderStreak.value = data.orderStreak
    disabledReason.value = data.disabledReason
}

onMounted(() => {
    // Ensure the extension is loaded when the app opens
    if (!lua.gameplay_beamEats) {
        lua.extensions.load('gameplay_beamEats')
    }

    events.on('updateBeamEatsState', updateState)
    lua.gameplay_beamEats.requestBeamEatsState()
})

onUnmounted(() => {
    events.off('updateBeamEatsState', updateState)
})

</script>

<style scoped lang="scss">
.beameats-container {
    padding: 1em;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: linear-gradient(to bottom, #fff5f5, #ffe0e0);
    color: #333;
    overflow-y: auto; /* Allow scrolling if content is too tall */
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
        color: #ff4757;
        margin: 0;
    }

    .header-icon {
        color: #ff4757;
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

.job-panel {
    background: white;
    padding: 1em;
    border-radius: 12px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
    margin-bottom: 1em;
    flex-grow: 1;

    .job-header {
        font-size: 1.1em;
        font-weight: 800;
        color: #333;
        margin-bottom: 0.5em;
        border-bottom: 2px solid #eee;
        padding-bottom: 0.5em;
    }

    .detail-row {
        display: flex;
        gap: 0.5em;
        margin-bottom: 0.5em;
        align-items: center;
        font-size: 1.1em;
    }
}

.controls-container {
    margin-top: auto;
    padding-top: 1em;
    flex-shrink: 0; /* Prevent shrinking */
}

.action-button {
    width: 100%;
    padding: 1em;
    border: none;
    border-radius: 12px;
    font-size: 1.2em;
    font-weight: 700;
    cursor: pointer;
    transition: transform 0.1s;

    &:active {
        transform: scale(0.98);
    }

    &.start-btn {
        background: #ff4757;
        color: white;
        
        &:disabled {
            background: #ccc;
            cursor: not-allowed;
        }
    }

    &.stop-btn {
        background: #2f3542;
        color: white;
    }
}

.disabled-msg {
    text-align: center;
    color: #ff4757;
    margin-top: 0.5em;
    font-weight: 600;
}

// Text Colors
.text-grey { color: #999; }
.text-blue { color: #1e90ff; }
.text-orange { color: #ffa502; }
.text-green { color: #2ed573; }
.text-red { color: #ff4757; }

</style>
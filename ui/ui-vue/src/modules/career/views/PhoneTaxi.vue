<template>
    <PhoneWrapper app-name="Taxi" status-font-color="#FFFFFF" status-blend-mode="normal">
        <div class="taxi-container" ref="container" @click="handleBackgroundClick">
            <!-- Minimap Background -->
            <div class="map-container">
                <svg class="minimap-layer terrain-layer"></svg>
                <svg class="minimap-layer vehicle-layer"></svg>
            </div>

            <!-- Reward + Driver Rating Top Bar -->
            <div class="reward-bubble" v-if="currentState !== 'start'">
                <span class="total">${{ formatCurrency(totalReward) }}</span>
                <span class="divider">|</span>
                <span class="driver">★ {{ driverRatingDisplay }}</span>
            </div>

            <!-- Start State -->
            <div class="bottom-panel" v-if="currentState === 'start'">
                <div class="rider-details center">
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.person" />
                        {{ currentCapacity }}
                    </span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.carUp" />
                        {{ vehicleMultiplier }}
                    </span>
                </div>
                <button class="state-button" @click.stop="setState('ready')">
                    Drive Now
                </button>
            </div>

            <!-- Ready State -->
            <div class="bottom-panel" v-if="currentState === 'ready'">
                <div class="rider-details center">
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.person" />
                        {{ currentCapacity }}
                    </span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.carUp" />
                        {{ vehicleMultiplier }}
                    </span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.sync" />
                        {{ fareStreak }}
                    </span>
                </div>
                <button class="state-button stop" @click.stop="setState('stop')">
                    Stop Driving
                </button>
            </div>

            <!-- Pickup/Dropoff State -->
            <div class="bottom-panel" v-if="currentState === 'pickup' || currentState === 'dropoff'">
                <div class="rider-details">
                    <span class="rider-type">{{ riderType }}</span>
                    <button class="info-button" @click.stop="toggleInfo">?</button>
                    <span class="rider-info">{{ riderValueDisplay }}</span>
                </div>
                <div class="ride-status">
                    {{ currentState === 'pickup' ? 'Picking up' : 'Dropping off' }} {{ riderCount }} passengers
                </div>
                <div class="fare-display small">
                    ${{ formatCurrency(farePerKm) }} <span class="tip-note">excluding tip</span>
                </div>
                <div class="rider-details center">
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.person" />
                        {{ riderCount }}/{{ currentCapacity }}
                    </span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.carUp" />
                        {{ vehicleMultiplier }}
                    </span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.sync" />
                        {{ fareStreak }}
                    </span>
                </div>
            </div>

            <!-- Accept Rider State -->
            <div class="bottom-panel rider" v-if="currentState === 'accept'">
                <div class="rider-header">
                    <div class="rider-title">
                        <span class="rider-type">{{ riderType }}</span>
                        <button class="info-button" @click.stop="toggleInfo">?</button>
                    </div>
                    <button class="close-button" @click.stop="setState('reject')">
                        <BngIcon class="x-icon" :type="icons.xmark" />
                    </button>
                </div>
                <div class="fare-display">
                    ${{ formatCurrency(farePerKm) }} <span class="tip-note">excluding tip</span>
                </div>
                <div class="rider-details">
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.person" />
                        {{ riderCount }}
                    </span>
                    <span class="rider-info">{{ riderValueDisplay }}</span>
                    <span class="rider-info">
                        <BngIcon class="app-icon" :type="icons.sync" />
                        {{ fareStreak }}
                    </span>
                </div>
                <button class="state-button" @click.stop="setState('working')">
                    Accept
                </button>
            </div>

            <!-- Complete State -->
            <div class="complete-overlay" v-if="currentState === 'complete'">
                <div class="complete-modal">
                    <div class="fare-header">
                        <div class="fare-display center">${{ formatCurrency(totalFare) }}</div>
                        <div class="fare-rating"> ★ {{ passengerRatingDisplay }}</div>
                    </div>
                    <div class="fare-breakdown">
                        <div class="breakdown-section">
                            <div class="breakdown-label">Base Fare</div>
                            <div class="breakdown-amount">${{ formatCurrency(baseFareAmount) }}</div>
                        </div>
                        <div class="breakdown-section clickable" @click.stop="toggleTipBreakdown" :aria-expanded="showTipBreakdown">
                            <div class="breakdown-label">Tips</div>
                            <div class="breakdown-amount" :class="{ 'positive': totalTipsAmount > 0, 'negative': totalTipsAmount < 0 }">
                                {{ totalTipsAmount > 0 ? '+' : '' }}${{ formatCurrency(Math.abs(totalTipsAmount)) }}
                                <span class="count-badge" v-if="Object.keys(tipBreakdownData).length > 0">{{ Object.keys(tipBreakdownData).length }}</span>
                                <span class="dropdown-icon" :class="{ open: showTipBreakdown }">▼</span>
                            </div>
                        </div>
                        <transition name="collapse">
                            <div class="tip-breakdown" v-if="Object.keys(tipBreakdownData).length > 0 && showTipBreakdown">
                                <div class="tip-item" v-for="(amount, name) in tipBreakdownData" :key="name">
                                    <span class="tip-name">{{ name }}</span>
                                    <span class="tip-amount" :class="{ 'positive': amount >= 0, 'negative': amount < 0 }">
                                        {{ amount >= 0 ? '+' : '' }}${{ formatCurrency(Math.abs(amount)) }}
                                    </span>
                                </div>
                            </div>
                        </transition>
                    </div>
                    <div class="rider-details center">
                        <span class="rider-info">{{ riderType }}</span>
                        <button class="info-button" @click.stop="toggleInfo">?</button>
                        <span class="rider-info">{{ riderValueDisplay }}</span>
                    </div>
                    <button class="state-button complete" @click.stop="setState('ready')">Complete</button>
                </div>
            </div>

            <!-- Disabled State Overlay -->
            <div class="disabled-overlay" v-if="currentState === 'disabled'" @click="closeDisabledOverlay">
                <div class="disabled-modal" @click.stop>
                    <button class="disabled-close" @click="closeDisabledOverlay">✕</button>
                    <div class="disabled-icon">🚫</div>
                    <div class="disabled-title">Taxi Unavailable</div>
                    <div class="disabled-message">{{ disabledReason || 'Taxi is currently disabled' }}</div>
                </div>
            </div>

            <!-- Passenger Info Popover -->
            <div class="info-popover" v-if="showInfo" @click.stop>
                <div class="info-title">{{ riderType }}</div>
                <div class="info-body">{{ riderDescription }}</div>
                <button class="info-close" @click.stop="toggleInfo">Close</button>
            </div>
        </div>
    </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, computed } from 'vue'
import { useMinimapStore } from '../stores/minimapStore'
import PhoneWrapper from './PhoneWrapper.vue'
import { BngIcon, icons } from "@/common/components/base"
import { useEvents } from '@/services/events'
import { lua } from "@/bridge"

const events = useEvents()

const store = useMinimapStore()
const container = ref(null)

// State management
const currentState = ref('ready')
const totalReward = ref(0)
const fareStreak = ref(0)

// Fare
const currentFare = ref({})
const farePerKm = ref(0)
const distanceTraveled = ref(0)
const totalFare = ref(0)
const timeMultiplier = ref(0)
const baseFareAmount = ref(0)
const totalTipsAmount = ref(0)
const tipBreakdownData = ref({})
const showTipBreakdown = ref(false)

// Vehicle Specific
const vehicleMultiplier = ref(0)
const currentCapacity = ref(0)

// Rider Details
const riderType = ref('Standard')
const riderCount = ref(0)
const riderRating = ref(0)
const driverRating = ref(5)
const lastPassengerRating = ref(null)
const driverRatingDisplay = computed(() => Number(driverRating.value ?? 5).toFixed(1))
const disabledReason = ref('')
const riderValueDisplay = computed(() => {
    const rating = Number(riderRating.value || 0)
    // Map 1-5 rating to $-$$$$$ for display of how "high paying"
    const count = Math.max(1, Math.min(5, Math.round(rating)))
    return '$'.repeat(count)
})
const showInfo = ref(false)
const riderDescription = ref('')
const toggleInfo = () => { showInfo.value = !showInfo.value }
const passengerRatingDisplay = computed(() => {
    const v = lastPassengerRating.value
    if (v === null || typeof v === 'undefined' || isNaN(v)) return '5.0'
    return Number(v).toFixed(1)
})

const formatCurrency = (value) => {
    if (value >= 1e6) {
        const millions = (value / 1e6).toPrecision(3)
        return `${millions.replace(/\.0+$|(\.[0-9]*[1-9])0+$/, '$1')}M`
    }
    if (value >= 1e3) {
        const thousands = (value / 1e3).toPrecision(3)
        return `${thousands.replace(/\.0+$|(\.[0-9]*[1-9])0+$/, '$1')}k`
    }
    return value.toFixed(0)
}

const setState = (newState) => {
    currentState.value = newState
    if (newState === 'start') {
        lua.gameplay_taxi.prepareTaxiJob()
        totalReward.value = 0
    } else if (newState === 'reject') {
        lua.gameplay_taxi.rejectJob()
        currentState.value = 'ready'
    } else if (newState === 'ready') {
        lua.gameplay_taxi.setAvailable()
    } else if (newState === 'working') {
        lua.gameplay_taxi.acceptJob()
        currentState.value = 'pickup'

    } else if (newState === 'stop') {
        lua.gameplay_taxi.stopTaxiJob()
        currentState.value = 'start'
    }
}


const handleBackgroundClick = () => {
    if (currentState.value === 'complete') {
        setState('ready')
    }
}

const closeDisabledOverlay = () => {
    // Navigate back to start state when closing disabled overlay
    if (currentState.value === 'disabled') {
        setState('start')
    }
}

const handleFare = () => {
    if (!currentFare.value) return

    farePerKm.value = Number(currentFare.value.baseFare ?? 0)
    riderCount.value = Number(currentFare.value.passengers ?? 0)
    riderRating.value = Number(currentFare.value.passengerRating ?? 0)
    totalFare.value = Number(currentFare.value.totalFare ?? 0)
    distanceTraveled.value = Number(currentFare.value.totalDistance ?? 0)
    timeMultiplier.value = Number(currentFare.value.timeMultiplier ?? 1)
    riderType.value = currentFare.value.passengerTypeName ?? 'Standard'
    riderDescription.value = currentFare.value.passengerDescription ?? ''
    
    // Handle new tip breakdown data
    baseFareAmount.value = Number(currentFare.value.baseFare ?? 0)
    totalTipsAmount.value = Number(currentFare.value.totalTips ?? 0)
    tipBreakdownData.value = currentFare.value.tipBreakdown ?? {}
    showTipBreakdown.value = false
    
    // Debug logging
    console.log('Tip breakdown data:', tipBreakdownData.value)
    console.log('Total tips amount:', totalTipsAmount.value)
    console.log('Object keys length:', Object.keys(tipBreakdownData.value).length)
}

const toggleTipBreakdown = () => {
    console.log('Toggle tip breakdown clicked!')
    showTipBreakdown.value = !showTipBreakdown.value
    console.log('showTipBreakdown is now:', showTipBreakdown.value)
}

onMounted(() => {
    events.on('updateTaxiState', (state) => {
        console.log('Received taxi state update:', state)
        currentState.value = state.state
        currentFare.value = state.currentFare
        currentCapacity.value = state.availableSeats
        vehicleMultiplier.value = state.vehicleMultiplier
        totalReward.value = state.cumulativeReward,
            fareStreak.value = state.fareStreak
        
        // Update passenger type if available from state
        if (state.currentPassengerType) {
            riderType.value = state.currentPassengerType
        }
        if (typeof state.playerRating !== 'undefined') {
            driverRating.value = Number(state.playerRating)
        }
        if (typeof state.lastPassengerRating !== 'undefined') {
            lastPassengerRating.value = Number(state.lastPassengerRating)
        }
        if (typeof state.disabledReason !== 'undefined') {
            disabledReason.value = state.disabledReason
        }
        
        handleFare()
    })
    store.init()
    const terrainLayer = container.value.querySelector('.terrain-layer')
    const vehicleLayer = container.value.querySelector('.vehicle-layer')
    terrainLayer.appendChild(store.svgLayers.terrain)
    vehicleLayer.appendChild(store.svgLayers.vehicles)
    lua.gameplay_taxi.requestTaxiState()
})

</script>

<style scoped lang="scss">
.taxi-container {
    position: relative;
    width: 100%;
    height: 100%;
}

.map-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: rgba(40, 40, 40, 0.9);
}

.minimap-layer {
    position: absolute;
    width: 100%;
    height: 100%;
    pointer-events: none;
}

.bottom-panel {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    background: rgb(216, 224, 246);
    color: rgb(0, 0, 0);
    padding: 0.75rem;
    margin: 0.5rem;
    margin-bottom: 2rem;
    border-radius: 15px;

    &.rider {
        background: rgb(216, 224, 246);
        color: rgb(0, 0, 0);
        font-weight: 600;
    }
}

.capacity-display {
    display: flex;
    gap: 2rem;
    margin-bottom: 1.5rem;
    justify-content: space-between;
    padding: 0.5rem 3rem 0 3rem;
    font-size: 1.25em;
    font-family: 'Overpass', sans-serif;
    font-weight: 600;
    align-items: center;

    .capacity-item {
        display: flex;
    }
}

.reward-bubble {
    position: absolute;
    top: 40px;
    left: 50%;
    transform: translateX(-50%);
    background: rgba(0, 0, 0, 0.9);
    padding: 0.5rem 1.0rem;
    border-radius: 25px;
    color: white;
    font-weight: bold;
    font-size: 1.1em;
    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    display: inline-flex;
    gap: 0.5rem;
    align-items: center;
}

.reward-bubble .divider { opacity: 0.5; }
.reward-bubble .driver { opacity: 0.9; }

.rider-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-family: 'Overpass', sans-serif;
}

.rider-title {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
}

.info-button {
    margin-left: 0.2rem;
    height: 1.4em;
    min-width: 1.4em;
    border: none;
    border-radius: 0.4rem;
    background: rgb(196, 205, 230);
    color: rgb(0,0,0);
    font-weight: 800;
    cursor: pointer;
}

.rider-type {
    font-size: 1em;
    background: rgb(196, 205, 230);
    color: rgb(0, 0, 0);
    padding: 0.25rem 0.5rem 0.15rem 0.5rem;
    border-radius: 0.5rem;
    font-weight: 600;
    align-items: center;
    justify-content: center;
}

.ride-status {
    font-size: 1.5em;
    font-weight: 700;
    color: #010101;
    margin-top: 0.25rem;
    margin-bottom: 0.25rem;
    font-family: 'Overpass', sans-serif;

    &.center {
        text-align: center;
    }
}


.fare-display {
    font-size: 1.8em;
    color: #010101;
    margin-top: 0.25rem;
    margin-bottom: 0.25rem;
    font-family: 'Overpass', sans-serif;

    &.center {
        text-align: center;
    }

    &.small {
        font-size: 1.2em;
    }
}

.tip-note {
    font-size: 0.6em;
    color: #666666;
    font-weight: 400;
}

.rider-details {
    display: flex;
    margin-bottom: 0.5rem;
    font-family: 'Overpass', sans-serif;

    .rider-info {
        font-size: 1.1em;

        background: rgb(196, 205, 230);
        color: rgb(0, 0, 0);
        padding: 0.1rem 0.5rem 0.05rem 0.5rem;
        margin-left: 0.25em;
        margin-right: 0.25em;
        border-radius: 0.5rem;
    }

    &.center {
        justify-content: center;
    }
}

.state-button {
    width: 100%;
    padding: 0.75rem 0rem 0.65rem 0rem;
    background: #2f2bff;
    color: rgb(255, 255, 255);
    border: none;
    border-radius: 10px;
    font-size: 1.75em;
    font-weight: 600;
    font-family: 'Overpass', sans-serif;

    &.stop {
        background: #ff1744;
    }

    &.complete {
        background: #0f7b0f;
    }

    &:hover {
        transform: scale(1.02);
    }
}

.complete-overlay {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    justify-content: center;
    align-items: center;
    backdrop-filter: blur(2px);
}

.info-popover {
    position: absolute;
    bottom: 8.5rem;
    left: 0.75rem;
    right: 0.75rem;
    background: rgba(216, 224, 246, 0.98);
    color: rgb(0, 0, 0);
    border-radius: 12px;
    padding: 0.75rem;
    box-shadow: 0 8px 18px rgba(0,0,0,0.25);
    border: 1px solid rgba(0,0,0,0.1);
}
.info-title {
    font-weight: 700;
    margin-bottom: 0.25rem;
}
.info-body {
    font-weight: 500;
}
.info-close {
    margin-top: 0.5rem;
    width: 100%;
    padding: 0.5rem 0;
    background: #2f2bff;
    color: #fff;
    border: none;
    border-radius: 8px;
}

.complete-modal {
    background: rgb(216, 224, 246);
    font-weight: 600;
    padding: 1rem;
    border-radius: 20px;
    width: 90%;
    column-gap: 5rem;
    max-height: 80vh;
    overflow-y: auto;
    color: rgb(0, 0, 0);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(0,0,0,0.1);
}

.fare-header {
    display: flex;
    align-items: baseline;
    justify-content: center;
    gap: 0.75rem;
}
.fare-rating {
    font-size: 1em;
    font-weight: 700;
    background: rgba(196, 205, 230, 0.75);
    padding: 0.2rem 0.5rem;
    border-radius: 8px;
}

.fare-breakdown {
    margin: 1rem 0;
    padding: 0.5rem;
    background: rgba(196, 205, 230, 0.35);
    border-radius: 10px;
}

.breakdown-section {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.25rem 0;
    border-bottom: none;
}
.breakdown-section.clickable { cursor: pointer; }

.breakdown-section:last-child {
    border-bottom: none;
}

.breakdown-label {
    font-size: 1.1em;
    font-weight: 600;
    color: rgb(0, 0, 0);
}

.breakdown-amount {
    font-size: 1.1em;
    font-weight: 700;
    color: rgb(0, 0, 0);
}

.tip-breakdown-toggle {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem;
    margin-top: 0.5rem;
    cursor: pointer;
    font-weight: 600;
    color: rgb(0, 0, 0);
    border-top: none;
    border-radius: 8px;
    transition: background-color 0.2s ease;
    user-select: none;
    gap: 0.5rem;
}

.tip-breakdown-toggle:hover {
    background: rgba(196, 205, 230, 0.45);
}

.tip-breakdown-toggle:active {
    background: rgba(196, 205, 230, 0.6);
}

.toggle-right-group {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
}

.dropdown-icon {
    font-size: 1.2em;
    color: rgb(0, 0, 0);
    font-weight: bold;
    transition: transform 0.2s ease;
}

.dropdown-icon.open {
    transform: rotate(180deg);
}

.count-badge {
    background: #2f2bff;
    color: #ffffff;
    border-radius: 999px;
    padding: 0.05rem 0.45rem 0.1rem 0.45rem;
    font-size: 0.85em;
    line-height: 1.2;
}

.collapse-enter-active,
.collapse-leave-active {
    transition: max-height 0.25s ease, opacity 0.25s ease;
}
.collapse-enter-from,
.collapse-leave-to {
    max-height: 0;
    opacity: 0;
}
.collapse-enter-to,
.collapse-leave-from {
    max-height: 260px;
    opacity: 1;
}

.tip-breakdown {
    margin-top: 0.5rem;
    padding-top: 0.5rem;
    border-top: 1px solid rgba(0, 0, 0, 0.2);
}

.tip-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.2rem 0;
    font-size: 0.9em;
}

.tip-name {
    font-weight: 500;
    color: rgb(0, 0, 0);
}

.tip-amount {
    font-weight: 600;
    color: rgb(0, 0, 0);
    
    &.positive {
        color: #0f7b0f;
    }
    
    &.negative {
        color: #ff1744;
    }
}

.app-icon {
    font-size: 125%;
    color: rgb(0, 0, 0);
    align-content: center;
}

.x-icon {
    font-size: 1em;
    color: rgb(0, 0, 0);
    justify-content: center;
    align-items: center;
}

.close-button {
    font-size: 1.25em;
    height: 1.75em;
    width: 1.75em;
    border: none;
    background: rgb(196, 205, 230);
    border-radius: 0.5rem;
    float: right;

    &:hover {
        transform: scale(1.15);
    }
}

.disabled-overlay {
    position: absolute;
    top: 40px; /* Start below the phone header */
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    justify-content: center;
    align-items: center;
    backdrop-filter: blur(2px);
    z-index: 10; /* Lower z-index to not block phone navigation */
    pointer-events: none; /* Allow clicks to pass through to elements behind */
}

.disabled-modal {
    background: rgba(255, 255, 255, 0.95);
    color: rgb(0, 0, 0);
    padding: 3rem 2rem 2.5rem 2rem; /* Extra top padding for close button */
    border-radius: 20px;
    text-align: center;
    font-weight: 600;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.3);
    border: 2px solid rgba(0, 0, 0, 0.1);
    max-width: 85%;
    animation: fadeInUp 0.3s ease-out;
    position: relative; /* For absolute positioning of close button */
    pointer-events: auto; /* Allow interaction with the modal itself */
}

.disabled-icon {
    font-size: 3.5rem;
    margin-bottom: 1rem;
    opacity: 0.8;
}

.disabled-title {
    font-size: 1.8rem;
    font-weight: 700;
    margin-bottom: 0.75rem;
    color: rgb(100, 100, 100);
}

.disabled-message {
    font-size: 1.1rem;
    font-weight: 500;
    line-height: 1.4;
    color: rgb(80, 80, 80);
}

.disabled-close {
    position: absolute;
    top: 10px;
    right: 15px;
    background: rgba(0, 0, 0, 0.1);
    border: none;
    border-radius: 50%;
    width: 32px;
    height: 32px;
    font-size: 16px;
    font-weight: bold;
    color: rgb(100, 100, 100);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s ease;
    z-index: 11; /* Higher than overlay but lower than phone nav */
}

.disabled-close:hover {
    background: rgba(0, 0, 0, 0.2);
    transform: scale(1.1);
}

@keyframes fadeInUp {
    from {
        opacity: 0;
        transform: translateY(20px);
    }
    to {
        opacity: 1;
        transform: translateY(0);
    }
}
</style>

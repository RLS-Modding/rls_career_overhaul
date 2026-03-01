<template>
    <PhoneWrapper app-name="Rentals" status-font-color="#FFFFFF" status-blend-mode="normal">
        <div class="phone-rentals">
            <div class="section">
                <div class="section-title">Active Rentals</div>
                <div v-if="loading" class="section-card"><div class="none">Loading...</div></div>
                <div v-else-if="rentals.length === 0" class="section-card"><div class="none">No active rentals.</div></div>
                <div v-else class="rental-cards">
                    <div
                        v-for="rental in rentals"
                        :key="rental.garageId"
                        class="rental-card"
                        :class="statusClass(rental)"
                    >
                        <div class="rental-header">
                            <div class="rental-info">
                                <span class="rental-name">{{ rental.garageName }}</span>
                                <span class="rental-meta">
                                    {{ rental.type === 'upfront' ? 'Upfront lease' : rental.paymentsRemaining + ' payments left' }}
                                    &middot; {{ rental.type.charAt(0).toUpperCase() + rental.type.slice(1) }}
                                </span>
                            </div>
                            <div class="strike-dots" v-if="rental.warningLevel > 0">
                                <span class="strike-dot" v-for="s in rental.warningLevel" :key="s"></span>
                            </div>
                        </div>
                        <div class="rental-stats">
                            <div class="stat">
                                <span class="stat-label">Rent</span>
                                <span class="stat-val">${{ fmtPrice(rental.monthlyRent) }}</span>
                            </div>
                            <div class="stat">
                                <span class="stat-label">Time Left</span>
                                <span class="stat-val">{{ fmtTimeLeft(rental) }}</span>
                            </div>
                            <div class="stat">
                                <span class="stat-label">Paid</span>
                                <span class="stat-val">{{ rental.paymentsMade }}/{{ rental.leaseTerm }}</span>
                            </div>
                        </div>
                        <div class="rental-warning" v-if="rental.warningLevel === 1">
                            1 late payment — pay rent to avoid escalation.
                        </div>
                        <div class="rental-warning danger" v-if="rental.warningLevel >= 2">
                            Final notice — eviction imminent if rent is not paid!
                        </div>
                        <div class="rental-actions">
                            <button class="act-btn route-btn" @click="setRoute(rental.garageId)">Set Route</button>
                            <button class="act-btn danger-btn" @click="endLease(rental.garageId)">End Lease</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <Transition name="modal-fade">
            <div v-if="showEndLeaseConfirm && endLeaseTarget" class="end-lease-overlay" @click.self="showEndLeaseConfirm = false">
                <div class="end-lease-modal">
                    <p class="end-lease-title">End Lease Early?</p>
                    <p class="end-lease-property">{{ endLeaseTarget.garageName }}</p>
                    <div class="end-lease-fees">
                        <div class="fee-row">
                            <span>Deposit forfeited</span>
                            <span class="fee-val">${{ fmtPrice(endLeaseTarget.securityDeposit) }}</span>
                        </div>
                        <div class="fee-row">
                            <span>Termination fee</span>
                            <span class="fee-val">${{ fmtPrice(endLeaseTarget.monthlyRent) }}</span>
                        </div>
                        <div class="fee-divider"></div>
                        <div class="fee-row total">
                            <span>Total cost</span>
                            <span class="fee-val">${{ fmtPrice(endLeaseTarget.securityDeposit + endLeaseTarget.monthlyRent) }}</span>
                        </div>
                    </div>
                    <p class="end-lease-note">Vehicles in this garage will be relocated.</p>
                    <div class="end-lease-actions">
                        <button class="modal-btn cancel-btn" @click="showEndLeaseConfirm = false">Cancel</button>
                        <button class="modal-btn confirm-btn" @click="confirmEndLease">End Lease</button>
                    </div>
                </div>
            </div>
        </Transition>
    </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { lua, useBridge } from '@/bridge'

const { events } = useBridge()
const loading = ref(true)
const rentals = ref([])
const showEndLeaseConfirm = ref(false)
const endLeaseTarget = ref(null)

const fmtPrice = (price) => {
    if (price >= 1000000) return (price / 1000000).toFixed(1) + 'M'
    if (price >= 1000) return (price / 1000).toFixed(0) + 'K'
    return String(price)
}

const fmtTimeLeft = (rental) => {
    const totalSec = rental.leaseTimeRemaining || 0
    if (totalSec <= 0) return 'Expiring'
    const mins = Math.ceil(totalSec / 60)
    if (mins >= 60) {
        const h = Math.floor(mins / 60)
        const m = mins % 60
        return m > 0 ? `${h}h ${m}m` : `${h}h`
    }
    return `${mins}m`
}

const statusClass = (rental) => {
    if (rental.warningLevel >= 2) return 'status-danger'
    if (rental.warningLevel === 1) return 'status-warning'
    return 'status-ok'
}

const refreshRentals = async () => {
    loading.value = true
    try {
        const data = await lua.career_modules_propertyRentals.getAllRentals()
        if (data && typeof data === 'object' && !Array.isArray(data)) {
            rentals.value = Object.entries(data).map(([gId, r]) => ({
                garageId: gId,
                garageName: r.garageName || gId,
                type: r.type || 'fixed',
                monthlyRent: r.monthlyRent || 0,
                paymentsRemaining: r.paymentsRemaining || 0,
                paymentsMade: r.paymentsMade || 0,
                leaseTerm: r.leaseTerm || 12,
                securityDeposit: r.securityDeposit || 0,
                warningLevel: r.warningLevel || 0,
                leaseTimeRemaining: r.leaseTimeRemaining || 0,
            }))
        } else {
            rentals.value = []
        }
    } catch {
        rentals.value = []
    }
    loading.value = false
}

const setRoute = async (garageId) => {
    await lua.extensions.load('ui_phone_realEstate')
    lua.ui_phone_realEstate.setRouteToGarage(garageId)
}

const endLease = (garageId) => {
    const rental = rentals.value.find(r => r.garageId === garageId)
    if (!rental) return
    endLeaseTarget.value = rental
    showEndLeaseConfirm.value = true
}

const confirmEndLease = async () => {
    if (!endLeaseTarget.value) return
    const garageId = endLeaseTarget.value.garageId
    showEndLeaseConfirm.value = false
    endLeaseTarget.value = null
    await lua.career_modules_propertyRentals.endLeaseEarly(garageId)
    await refreshRentals()
}

let rentalUpdateHandler
onMounted(async () => {
    await lua.extensions.load('ui_phone_realEstate')
    await refreshRentals()
    rentalUpdateHandler = () => refreshRentals()
    events.on('rentals:updated', rentalUpdateHandler)
})

onBeforeUnmount(() => {
    if (rentalUpdateHandler) events.off('rentals:updated', rentalUpdateHandler)
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
    background:
        radial-gradient(110% 80% at 50% -10%, rgba(59, 130, 246, 0.3) 0%, rgba(59, 130, 246, 0) 70%),
        linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
}

.phone-rentals {
    padding: 12px;
    padding-top: 58px;
    color: #e2e8f0;
    height: 95%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;

    &::-webkit-scrollbar { width: 7px; }
    &::-webkit-scrollbar-track { background: rgba(148, 163, 184, 0.12); border-radius: 999px; }
    &::-webkit-scrollbar-thumb {
        background: rgba(148, 163, 184, 0.4);
        border-radius: 999px;
    }
}

.section { margin-bottom: 12px; }

.section-title {
    font-size: 0.75rem;
    letter-spacing: 0.11em;
    text-transform: uppercase;
    font-weight: 700;
    margin: 2px 3px 8px;
    color: #93c5fd;
    opacity: 0.95;
}

.section-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 10px;
    backdrop-filter: blur(12px);
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
}

.none { color: #cbd5e1; font-size: 0.85rem; }

.rental-cards {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.rental-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    backdrop-filter: blur(12px);
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);

    &.status-ok { border-left: 3px solid #22c55e; }
    &.status-warning { border-left: 3px solid #eab308; }
    &.status-danger { border-left: 3px solid #ef4444; }
}

.rental-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.rental-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.rental-name {
    font-size: 14px;
    font-weight: 700;
    color: #f8fafc;
}

.rental-meta {
    font-size: 11px;
    color: rgba(148, 163, 184, 0.8);
}

.strike-dots { display: flex; gap: 4px; }
.strike-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #ef4444;
}

.rental-stats {
    display: flex;
    gap: 8px;
}

.stat {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    background: rgba(255, 255, 255, 0.03);
    border-radius: 8px;
    padding: 8px 10px;
}

.stat-label {
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    color: rgba(148, 163, 184, 0.6);
    font-weight: 700;
}

.stat-val {
    font-size: 13px;
    font-weight: 700;
    color: #f8fafc;
    font-variant-numeric: tabular-nums;
}

.rental-warning {
    font-size: 11px;
    padding: 8px 10px;
    border-radius: 8px;
    background: rgba(234, 179, 8, 0.1);
    color: rgba(234, 179, 8, 0.9);
    border: 1px solid rgba(234, 179, 8, 0.2);

    &.danger {
        background: rgba(239, 68, 68, 0.1);
        color: rgba(239, 68, 68, 0.9);
        border-color: rgba(239, 68, 68, 0.2);
    }
}

.rental-actions {
    display: flex;
    gap: 8px;
}

.act-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 8px 14px;
    border-radius: 10px;
    border: none;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: opacity 0.15s ease;
    &:hover { opacity: 0.85; }
}

.route-btn {
    background: rgba(59, 130, 246, 0.2);
    color: #93c5fd;
    border: 1px solid rgba(59, 130, 246, 0.3);
}

.danger-btn {
    background: rgba(239, 68, 68, 0.15);
    color: #fca5a5;
    border: 1px solid rgba(239, 68, 68, 0.25);
}

.end-lease-overlay {
    position: absolute;
    inset: 0;
    z-index: 20;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
}

.end-lease-modal {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.95) 0%, rgba(15, 23, 42, 0.95) 100%);
    border: 1px solid rgba(148, 163, 184, 0.25);
    border-radius: 16px;
    padding: 20px;
    width: 100%;
    max-width: 320px;
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
}

.end-lease-title {
    margin: 0 0 4px;
    font-size: 16px;
    font-weight: 700;
    color: #f8fafc;
}

.end-lease-property {
    margin: 0 0 14px;
    font-size: 13px;
    color: #93c5fd;
    font-weight: 600;
}

.end-lease-fees {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-bottom: 12px;
    padding: 12px;
    background: rgba(0, 0, 0, 0.2);
    border-radius: 10px;
}

.fee-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 12px;
    color: rgba(148, 163, 184, 0.85);
}

.fee-row .fee-val {
    font-weight: 700;
    color: #fca5a5;
    font-variant-numeric: tabular-nums;
}

.fee-divider {
    height: 1px;
    background: rgba(148, 163, 184, 0.15);
}

.fee-row.total {
    font-weight: 700;
    color: #f8fafc;
}

.fee-row.total .fee-val {
    color: #ef4444;
    font-size: 13px;
}

.end-lease-note {
    margin: 0 0 16px;
    font-size: 11px;
    color: rgba(148, 163, 184, 0.6);
    line-height: 1.4;
}

.end-lease-actions {
    display: flex;
    gap: 8px;
}

.modal-btn {
    flex: 1;
    padding: 10px 14px;
    border-radius: 10px;
    border: none;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: opacity 0.15s ease;
    &:hover { opacity: 0.85; }
}

.cancel-btn {
    background: rgba(148, 163, 184, 0.12);
    color: #cbd5e1;
    border: 1px solid rgba(148, 163, 184, 0.2);
}

.confirm-btn {
    background: rgba(239, 68, 68, 0.85);
    color: #fff;
}

.modal-fade-enter-active,
.modal-fade-leave-active {
    transition: opacity 0.2s ease;
}
.modal-fade-enter-from,
.modal-fade-leave-to {
    opacity: 0;
}
</style>

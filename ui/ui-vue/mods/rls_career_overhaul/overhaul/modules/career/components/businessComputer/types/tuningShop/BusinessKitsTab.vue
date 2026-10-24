<!-- Business computer: Kits, house style. Title + hint with the storage meter (scaleX fill), then
     vehicle cards (photo first, one orange Create Kit each) and saved kit cards (facts Event / Time /
     Parts, neutral Apply, quiet-danger delete icon). Dialogs use the house .modal look. -->
<template>
    <div ref="actionRoot" class="kits-tab rls-house">
        <header class="page-head">
            <div class="page-copy">
                <h2 class="page-title">Kits</h2>
                <p class="hint">Save configurations from completable jobs and apply them to other vehicles</p>
            </div>
            <div class="capacity" :class="{ full: isAtMaxCapacity && kitsStore.maxKitStorage > 0 }">
                <span class="caption">Storage</span>
                <span class="capacity-text">{{ kitsStore.currentKitCount }} / {{ kitsStore.maxKitStorage }}</span>
                <span class="capacity-bar"><span :style="{ transform: `scaleX(${capacityScale})` }"></span></span>
            </div>
        </header>

        <!-- Active Completable Jobs Section -->
        <section v-if="completableJobs.length > 0" class="section">
            <h3 class="caption section-title">Business Vehicles</h3>
            <div class="card-grid">
                <article v-for="job in completableJobs" :key="job.jobId" class="vehicle-card">
                    <div class="photo">
                        <img v-if="job.vehicleImage" :src="job.vehicleImage" alt="" />
                        <BngIcon v-else class="photo-fallback" :type="icons.car" />
                    </div>
                    <div class="card-body">
                        <div class="card-copy">
                            <strong class="card-name">{{ job.vehicleName }}</strong>
                            <span class="card-sub">{{ job.raceLabel || job.raceType }}</span>
                        </div>
                        <div class="facts">
                            <div class="fact">
                                <span class="fact-key">Time</span>
                                <span class="fact-value">{{ formatTime(job.currentTime) }}</span>
                            </div>
                        </div>
                        <HouseButton block variant="primary" :icon="isAtMaxCapacity ? undefined : icons.plus"
                            :disabled="isAtMaxCapacity" :aria-disabled="actionBusy" :title="isAtMaxCapacity ? 'Kit storage is full' : ''"
                            @click.stop="showCreateKitDialog(job)" @mousedown.stop>
                            {{ isAtMaxCapacity ? 'Storage Full' : 'Create Kit' }}
                        </HouseButton>
                    </div>
                </article>
            </div>
        </section>

        <!-- Personal Vehicles Section -->
        <section v-if="personalVehiclesForKits.length > 0" class="section">
            <h3 class="caption section-title">Personal Vehicles</h3>
            <div class="card-grid">
                <article v-for="vehicle in personalVehiclesForKits" :key="vehicle.vehicleId" class="vehicle-card">
                    <div class="photo">
                        <img v-if="vehicle.vehicleImage" :src="vehicle.vehicleImage" alt="" />
                        <BngIcon v-else class="photo-fallback" :type="icons.car" />
                    </div>
                    <div class="card-body">
                        <div class="card-copy">
                            <strong class="card-name">{{ vehicle.vehicleName || vehicle.model_key }}</strong>
                            <span class="card-sub">Personal vehicle</span>
                        </div>
                        <HouseButton block variant="primary" :icon="isAtMaxCapacity ? undefined : icons.plus"
                            :disabled="isAtMaxCapacity" :aria-disabled="actionBusy" :title="isAtMaxCapacity ? 'Kit storage is full' : ''"
                            @click.stop="showCreateKitDialogPersonal(vehicle)" @mousedown.stop>
                            {{ isAtMaxCapacity ? 'Storage Full' : 'Create Kit' }}
                        </HouseButton>
                    </div>
                </article>
            </div>
        </section>

        <!-- Saved Kits Section -->
        <section v-if="kits.length > 0" class="section">
            <h3 class="caption section-title">Saved Kits</h3>
            <div class="card-grid">
                <article v-for="kit in kits" :key="kit.id" class="kit-card">
                    <div class="card-copy">
                        <strong class="card-name">{{ kit.name }}</strong>
                        <span class="card-sub">{{ kit.model_key }}</span>
                    </div>
                    <div class="facts">
                        <div class="fact">
                            <span class="fact-key">Event</span>
                            <span class="fact-value wrap">{{ kit.sourceJobEvent || '—' }}</span>
                        </div>
                        <div class="fact">
                            <span class="fact-key">Time</span>
                            <span class="fact-value">{{ formatTime(kit.sourceJobTime) }}</span>
                        </div>
                        <div class="fact">
                            <span class="fact-key">Parts</span>
                            <span class="fact-value">{{ countParts(kit) }}</span>
                        </div>
                    </div>
                    <div class="kit-actions">
                        <HouseButton class="apply-btn" :disabled="!canApplyKit(kit)" :aria-disabled="actionBusy"
                            @click.stop="handleApplyKit(kit)" @mousedown.stop>
                            Apply to Vehicle
                        </HouseButton>
                        <HouseButton variant="quiet-danger" :aria-disabled="actionBusy" :icon="icons.trashBin1" title="Delete kit" aria-label="Delete kit"
                            :data-fk="`kit-${kit.id}-delete`" @click.stop="handleDeleteKit(kit)" @mousedown.stop />
                    </div>
                    <p v-if="!canApplyKit(kit)" class="hint apply-hint">{{ applyHint(kit) }}</p>
                </article>
            </div>
        </section>

        <!-- Empty State -->
        <div v-if="completableJobs.length === 0 && personalVehiclesForKits.length === 0 && kits.length === 0" class="empty">
            <BngIcon class="empty-icon" :type="icons.wrench" />
            <h3>No Kits Available</h3>
            <p>Accept jobs or bring personal vehicles to create kits</p>
        </div>

        <!-- Create Kit Dialog -->
        <div v-if="showDialog" class="kit-overlay rls-house" @click.self="closeDialog">
            <div class="modal kit-modal" v-bng-blur v-bng-scoped-nav="createDialogScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeDialog">
                <h3>Create Kit</h3>
                <p>
                    Create a kit from <strong>{{ selectedJob?.vehicleName || selectedPersonalVehicle?.vehicleName || selectedPersonalVehicle?.model_key }}</strong>
                </p>
                <label class="field-block">
                    <span class="caption">Kit Name</span>
                    <input id="kit-name" v-model="kitName" :aria-disabled="actionBusy" type="text" placeholder="Enter kit name"
                        @keyup.enter="handleCreateKit" @keydown.esc.prevent="closeDialog" class="field"
                        @keydown.stop @keyup.stop @keypress.stop v-bng-text-input v-focus />
                </label>
                <p v-if="actionError" class="notice warn" role="alert">{{ actionError }}</p>
                <div class="modal-actions">
                    <HouseButton variant="quiet" :aria-disabled="actionBusy" @click.stop="closeDialog" @mousedown.stop>Cancel</HouseButton>
                    <HouseButton variant="primary" :disabled="!kitName.trim()" :aria-disabled="actionBusy" bng-scoped-nav-autofocus
                        @click.stop="handleCreateKit" @mousedown.stop>Create Kit</HouseButton>
                </div>
            </div>
        </div>
    </div>

    <!-- Delete Confirmation Dialog -->
    <Teleport to="body">
        <div v-if="showDeleteDialog" class="kit-overlay rls-house" @click.self="closeDeleteDialog">
            <div class="modal kit-modal" v-bng-blur v-bng-scoped-nav="deleteDialogScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeDeleteDialog">
                <h3>Delete Kit</h3>
                <p>
                    Are you sure you want to delete <strong>{{ selectedKit?.name }}</strong>?
                </p>
                <p v-if="actionError" class="notice warn" role="alert">{{ actionError }}</p>
                <div class="modal-actions">
                    <HouseButton variant="quiet" :aria-disabled="actionBusy" bng-scoped-nav-autofocus @click.stop="closeDeleteDialog" @mousedown.stop>Cancel</HouseButton>
                    <HouseButton variant="danger" :aria-disabled="actionBusy" @click.stop="confirmDeleteKit" @mousedown.stop>Delete</HouseButton>
                </div>
            </div>
        </div>
    </Teleport>

    <!-- Apply Confirmation Dialog -->
    <Teleport to="body">
        <div v-if="showApplyDialog" class="kit-overlay rls-house" @click.self="closeApplyDialog">
            <div class="modal kit-modal" v-bng-blur v-bng-scoped-nav="applyDialogScope" v-bc-modal-focus v-bng-on-ui-nav:back,menu="closeApplyDialog">
                <h3>Apply Kit</h3>
                <p>
                    Are you sure you want to apply <strong>{{ selectedKit?.name }}</strong> to the current vehicle?
                </p>
                <p class="notice warn" v-if="selectedKit">
                    This will replace all parts and tuning settings.
                </p>
                <p v-if="loadingCostBreakdown" class="hint">Calculating costs…</p>
                <div v-else-if="costBreakdown" class="sheet">
                    <div class="lines">
                        <div class="line">
                            <span class="cost-label">Parts to change</span>
                            <span class="cost-value">{{ costBreakdown.changedPartsCount || 0 }}</span>
                        </div>
                        <div class="line">
                            <span class="cost-label">Install time</span>
                            <span class="cost-value">{{ formatInstallTime(costBreakdown.installTimeSeconds) }}</span>
                        </div>
                        <div class="line">
                            <span class="cost-label">Cost of new parts</span>
                            <span class="cost-value money"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(costBreakdown.newPartsCost) }}</span>
                        </div>
                        <div class="line" v-if="costBreakdown.tradeInCredit > 0">
                            <span class="cost-label">Trade-in value (90%)</span>
                            <span class="cost-value money">-<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(costBreakdown.tradeInCredit) }}</span>
                        </div>
                        <div class="line total">
                            <span class="cost-label">Total cost</span>
                            <span class="cost-value money">{{ costBreakdown.totalCost < 0 ? "-" : "" }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCurrency(Math.abs(costBreakdown.totalCost || 0)) }}</span>
                        </div>
                    </div>
                </div>
                <p v-if="actionError" class="notice warn" role="alert">{{ actionError }}</p>
                <div class="modal-actions">
                    <HouseButton variant="quiet" :aria-disabled="actionBusy" bng-scoped-nav-autofocus @click.stop="closeApplyDialog" @mousedown.stop>Cancel</HouseButton>
                    <HouseButton variant="primary" :aria-disabled="actionBusy" :disabled="loadingCostBreakdown || !costBreakdown"
                        @click.stop="confirmApplyKit" @mousedown.stop>Apply Kit</HouseButton>
                </div>
            </div>
        </div>
    </Teleport>
</template>

<script setup>
import { useActionFocus } from "../../../../composables/useActionFocus.js"
import { safeLua } from "../../../../utils/safeLua.js"

import { ref, computed, Teleport, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useBusinessKitsStore } from "../../../../stores/businessComputer/businessKitsStore.js"
import { useBusinessSessionStore } from "../../../../stores/businessComputer/businessSessionStore.js"
import { useBridge, lua } from "@/bridge"
import { vBngTextInput, vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import useControls from "@/services/controls"
import { bcModalScope, vBcModalFocus } from "../../bcModalNav"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../../../house/index.js"

const kitsStore = useBusinessKitsStore()
const sessionStore = useBusinessSessionStore()
const { events } = useBridge()

// dialogs run their own controller scope; Create opens on its button (the name is prefilled), Delete on Cancel
const createDialogScope = bcModalScope("kit-create")
const deleteDialogScope = bcModalScope("kit-delete")
const applyDialogScope = bcModalScope("kit-apply")

const completableJobs = computed(() => {
    const activeJobs = sessionStore.activeJobs || []
    const pulledOutVehicles = sessionStore.pulledOutVehicles || []

    return activeJobs.filter(job => {
        const isPulledOut = pulledOutVehicles.some(v => String(v.jobId) === String(job.jobId))
        return isPulledOut && !job.techAssigned
    })
})
const personalVehiclesForKits = computed(() => {
    const pulledOutVehicles = sessionStore.pulledOutVehicles || []
    return pulledOutVehicles.filter(v => v.isPersonal === true)
})
const kits = computed(() => kitsStore.kits || [])
const capacityPercent = computed(() => {
    if (kitsStore.maxKitStorage === 0) return 0
    return Math.min(100, (kitsStore.currentKitCount / kitsStore.maxKitStorage) * 100)
})
// meter fill as a transform (0..1); NaN-safe when storage numbers are missing
const capacityScale = computed(() => {
    const pct = Number(capacityPercent.value)
    return Number.isFinite(pct) ? Math.max(0, Math.min(1, pct / 100)) : 0
})
const isAtMaxCapacity = computed(() => kitsStore.currentKitCount >= kitsStore.maxKitStorage)
const pulledOutVehicle = computed(() => sessionStore.pulledOutVehicle)

const handleKitsUpdated = async (data) => {
    if (data?.businessId && sessionStore.businessId && String(data.businessId) === String(sessionStore.businessId)) {
        await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    }
}

const handleKitApplied = async (data) => {
    if (data?.businessId && sessionStore.businessId && String(data.businessId) === String(sessionStore.businessId)) {
        await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    }
}

const handleKitInstallComplete = async (data) => {
    if (data?.businessId && sessionStore.businessId && String(data.businessId) === String(sessionStore.businessId)) {
        await sessionStore.loadBusinessData(sessionStore.businessType, sessionStore.businessId)
    }
}

onMounted(() => {
    events.on('businessComputer:onKitsUpdated', handleKitsUpdated)
    events.on('businessComputer:onKitApplied', handleKitApplied)
    events.on('businessComputer:onKitInstallComplete', handleKitInstallComplete)
})

onUnmounted(() => {
    events.off('businessComputer:onKitsUpdated', handleKitsUpdated)
    events.off('businessComputer:onKitApplied', handleKitApplied)
    events.off('businessComputer:onKitInstallComplete', handleKitInstallComplete)
})

const actionRoot = ref(null)
const { remember, restore } = useActionFocus(actionRoot)
const showDialog = ref(false)
const showDeleteDialog = ref(false)
const showApplyDialog = ref(false)
const selectedJob = ref(null)
const selectedKit = ref(null)
const kitName = ref('')
const costBreakdown = ref(null)
const loadingCostBreakdown = ref(false)
const actionBusy = ref(false)
const actionError = ref('')

// the kit name field takes focus for mouse/keyboard only: on a pad that would switch on CEF typing with no
// keyboard, and the name is already prefilled
const vFocus = {
    mounted: (el) => { if (!useControls().isControllerUsed) el.focus() }
}

const formatTime = (time) => {
    if (!time) return 'N/A'
    const numTime = Number(time)
    if (isNaN(numTime)) return 'N/A'

    if (numTime >= 60) {
        const minutes = Math.floor(numTime / 60)
        const seconds = Math.floor(numTime % 60)
        return `${minutes}:${seconds.toString().padStart(2, '0')}`
    }
    return `${numTime.toFixed(2)}s`
}

const formatCurrency = (value) => {
    if (value === null || value === undefined) return '0.00'
    return Number(value).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

const formatInstallTime = (seconds) => {
    if (!seconds || seconds <= 0) return 'Instant'
    const numSeconds = Number(seconds)
    if (isNaN(numSeconds)) return 'Instant'
    if (numSeconds < 60) return `${numSeconds} seconds`
    const minutes = Math.floor(numSeconds / 60)
    const remainingSeconds = numSeconds % 60
    if (remainingSeconds === 0) return `${minutes} minute${minutes !== 1 ? 's' : ''}`
    return `${minutes}m ${remainingSeconds}s`
}

const countParts = (kit) => {
    if (kit && kit.partCount !== undefined) return kit.partCount
    if (!kit || !kit.parts || typeof kit.parts !== 'object') return 0
    return Object.keys(kit.parts).length
}

const canApplyKit = (kit) => {
    if (!pulledOutVehicle.value) return false
    const vehicleModel = pulledOutVehicle.value.model_key || pulledOutVehicle.value.vehicleConfig?.model_key
    return vehicleModel === kit.model_key
}

// why Apply is unavailable (display only)
const applyHint = (kit) => {
    if (!pulledOutVehicle.value) return 'Pull out a vehicle to apply this kit'
    return kit?.model_key ? `Fits ${kit.model_key} only` : 'Does not fit the current vehicle'
}

const selectedPersonalVehicle = ref(null)

const showCreateKitDialog = (job) => {
    if (actionBusy.value || loadingCostBreakdown.value) return
    actionError.value = ''
    selectedJob.value = job
    selectedPersonalVehicle.value = null
    kitName.value = `${job.vehicleName} - ${job.raceLabel || job.raceType}`
    showDialog.value = true
}

const showCreateKitDialogPersonal = (vehicle) => {
    if (actionBusy.value || loadingCostBreakdown.value) return
    actionError.value = ''
    selectedJob.value = null
    selectedPersonalVehicle.value = vehicle
    kitName.value = `${vehicle.vehicleName || vehicle.model_key} - Personal`
    showDialog.value = true
}

const closeDialog = () => {
    if (actionBusy.value) return
    actionError.value = ''

    showDialog.value = false
    selectedJob.value = null
    selectedPersonalVehicle.value = null
    kitName.value = ''
}

const handleCreateKit = async () => {
    if (actionBusy.value || !showDialog.value) return
    if (!kitName.value.trim()) return
    if (!selectedJob.value && !selectedPersonalVehicle.value) return

    actionBusy.value = true
    actionError.value = ''
    let success = false
    try {
        const vehicleId = selectedPersonalVehicle.value?.vehicleId ?? selectedJob.value.jobId
        success = await kitsStore.createKit(vehicleId, kitName.value.trim())
        if (!success) actionError.value = 'Unable to create kit. Check kit storage and the source vehicle.'
    } catch (error) {
        actionError.value = error?.message || 'Unable to create kit.'
    } finally {
        actionBusy.value = false
    }
    
    if (success) {
        closeDialog()
    }
}

const handleApplyKit = async (kit) => {
    if (actionBusy.value || loadingCostBreakdown.value) return
    if (!canApplyKit(kit)) return
    if (!pulledOutVehicle.value) return

    selectedKit.value = kit
    actionError.value = ''
    costBreakdown.value = null
    loadingCostBreakdown.value = true
    showApplyDialog.value = true

    try {
        const breakdown = await lua.overhaul_career_business_tuningShop_kits.getKitCostBreakdown(
            sessionStore.businessId,
            pulledOutVehicle.value.vehicleId,
            kit.id
        )
        costBreakdown.value = breakdown
        if (!breakdown) actionError.value = 'Unable to calculate kit costs.'
    } catch (error) {
        actionError.value = error?.message || 'Unable to calculate kit costs.'
    } finally {
        loadingCostBreakdown.value = false
    }
}

const confirmApplyKit = async () => {
    if (actionBusy.value || loadingCostBreakdown.value || !costBreakdown.value || !showApplyDialog.value) return
    if (!selectedKit.value || !pulledOutVehicle.value) return

    actionBusy.value = true
    actionError.value = ''
    let success = false
    try {
        const result = await kitsStore.applyKit(pulledOutVehicle.value.vehicleId, selectedKit.value.id)
        success = result?.success === true
        if (!success) actionError.value = result?.error || 'Unable to apply kit.'
    } catch (error) {
        actionError.value = error?.message || 'Unable to apply kit.'
    } finally {
        actionBusy.value = false
    }
    if (success) closeApplyDialog()
}

const closeApplyDialog = () => {
    if (actionBusy.value) return
    actionError.value = ''
    showApplyDialog.value = false
    selectedKit.value = null
    costBreakdown.value = null
}

const handleDeleteKit = async (kit) => {
    if (actionBusy.value || loadingCostBreakdown.value) return
    actionError.value = ''
    remember()
    selectedKit.value = kit
    showDeleteDialog.value = true
}

const confirmDeleteKit = async () => {
    if (actionBusy.value || !showDeleteDialog.value || !selectedKit.value) return
    actionBusy.value = true
    actionError.value = ''
    let success = false
    try {
        success = await kitsStore.deleteKit(selectedKit.value.id)
        if (!success) actionError.value = 'Unable to delete kit.'
    } catch (error) {
        actionError.value = error?.message || 'Unable to delete kit.'
    } finally {
        actionBusy.value = false
    }
    if (success) {
        closeDeleteDialog()
        await restore()
    }
}

const closeDeleteDialog = () => {
    if (actionBusy.value) return
    actionError.value = ''
    showDeleteDialog.value = false
    selectedKit.value = null
}

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.kits-tab {
    display: flex;
    flex-direction: column;
    gap: 1.4em;
}

/* ---- title, hint and storage meter */
.page-head {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    justify-content: space-between;
    gap: 0.8em 2em;
}
.page-copy {
    display: grid;
    gap: 0.3em;
    min-width: 0;
}
.page-title {
    margin: 0;
    color: #fff;
    font-size: 1.4em;
    font-weight: 800;
    line-height: 1.15;
}
.page-copy .hint {
    font-size: 0.9em;
}
.capacity {
    display: grid;
    grid-template-columns: auto auto;
    align-items: baseline;
    column-gap: 1.2em;
    row-gap: 0.35em;
    min-width: 10em;
}
.capacity-text {
    justify-self: end;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
}
.capacity-bar {
    grid-column: 1 / -1;
    position: relative;
    display: block;
    height: 0.45em;
    border-radius: 1em;
    overflow: hidden;
    background: rgba(255, 255, 255, 0.12);
    > span {
        position: absolute;
        inset: 0;
        border-radius: inherit;
        background: var(--accent);
        transform-origin: left center;
        transition: transform 0.3s ease;
    }
}
.capacity.full {
    .capacity-text {
        color: var(--warn);
    }
    .capacity-bar > span {
        background: var(--warn);
    }
}

/* ---- sections and cards */
.section {
    display: grid;
    gap: 0.6em;
}
.section-title {
    margin: 0;
}
.card-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(17em, 1fr));
    gap: 0.75em;
}
.vehicle-card,
.kit-card {
    display: grid;
    align-content: start;
    min-width: 0;
    border-radius: var(--radius-panel);
    background: var(--panel);
    overflow: hidden;
}
.photo {
    display: grid;
    place-items: center;
    aspect-ratio: 16 / 9;
    background: var(--photo);
    img {
        display: block;
        width: 100%;
        height: 100%;
        object-fit: cover;
    }
}
.photo-fallback {
    font-size: 2.4em;
    color: rgba(255, 255, 255, 0.25);
}
.card-body {
    display: grid;
    gap: 0.8em;
    padding: 0.8em var(--inset) var(--inset);
}
.kit-card {
    gap: 0.8em;
    padding: var(--inset);
}
.card-copy {
    display: grid;
    gap: 0.2em;
    min-width: 0;
}
.card-name {
    font-size: 1.1em;
    font-weight: 800;
    line-height: 1.2;
    overflow-wrap: anywhere;
}
.card-sub {
    color: var(--faint);
    font-size: 0.82em;
    font-weight: 600;
    overflow-wrap: anywhere;
}
.fact-value {
    font-variant-numeric: tabular-nums;
    &.wrap {
        white-space: normal;
        overflow: visible;
        text-overflow: clip;
        overflow-wrap: anywhere;
    }
}
.kit-actions {
    display: flex;
    gap: 0.45em;
    .apply-btn {
        flex: 1 1 auto;
    }
}
.apply-hint {
    margin-top: -0.35em;
}

/* ---- empty state: plain glyph, no badge behind it */
.empty:not(.bng-button) {
    padding: 3em 1em;
    border-radius: var(--radius-panel);
    background: var(--panel);
}
.empty-icon {
    font-size: 2.6em;
    color: rgba(255, 255, 255, 0.3);
}

/* ---- dialogs (house .modal) */
.kit-overlay {
    position: fixed;
    inset: 0;
    z-index: 1000;
    display: grid;
    place-items: center;
    padding: 1em;
    background: rgba(0, 0, 0, 0.6);
    font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}
.kit-modal {
    width: min(26em, 100%);
    p strong {
        color: #fff;
    }
}
.modal-actions {
    display: flex;
    justify-content: space-between;
    gap: var(--space-2);
    margin-top: 0.2em;
}
.notice.warn {
    color: var(--money);
}
.sheet .line {
    font-size: 0.92em;
}
.cost-label {
    color: var(--muted);
    font-weight: 600;
}
.cost-value {
    font-weight: 700;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    &.money {
        color: var(--money);
    }
}
.line.total {
    .cost-label {
        color: #fff;
        font-weight: 800;
    }
    .cost-value {
        font-size: 1.12em;
        font-weight: 800;
    }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

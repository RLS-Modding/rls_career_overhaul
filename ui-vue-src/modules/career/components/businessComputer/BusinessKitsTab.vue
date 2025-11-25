<template>
    <div class="kits-tab">
        <div class="kits-header">
            <h2>Kits</h2>
            <p class="kits-description">Save configurations from completable jobs and apply them to other vehicles</p>
        </div>

        <!-- Active Completable Jobs Section -->
        <div v-if="completableJobs.length > 0" class="section">
            <h3 class="section-title">Pulled Out Vehicles</h3>
            <div class="jobs-grid">
                <div v-for="job in completableJobs" :key="job.jobId" class="job-card">
                    <div class="job-header">
                        <div class="job-info">
                            <div class="job-title">{{ job.vehicleName }}</div>
                            <div class="job-subtitle">{{ job.raceLabel || job.raceType }}</div>
                        </div>
                        <img v-if="job.vehicleImage" :src="job.vehicleImage" class="job-vehicle-image" />
                    </div>
                    <div class="job-stats">
                        <div class="stat">
                            <span class="stat-label">Time:</span>
                            <span class="stat-value">{{ formatTime(job.currentTime) }}</span>
                        </div>
                    </div>
                    <button @click.stop="showCreateKitDialog(job)" @mousedown.stop class="btn-create-kit">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                            stroke-width="2">
                            <path d="M12 5v14M5 12h14" />
                        </svg>
                        Create Kit
                    </button>
                </div>
            </div>
        </div>

        <!-- Saved Kits Section -->
        <div v-if="kits.length > 0" class="section">
            <h3 class="section-title">Saved Kits</h3>
            <div class="kits-grid">
                <div v-for="kit in kits" :key="kit.id" class="kit-card">
                    <div class="kit-header">
                        <div class="kit-info">
                            <div class="kit-name">{{ kit.name }}</div>
                            <div class="kit-subtitle">{{ kit.model_key }}</div>
                        </div>
                    </div>
                    <div class="kit-details">
                        <div class="detail">
                            <span class="detail-label">Event:</span>
                            <span class="detail-value">{{ kit.sourceJobEvent }}</span>
                        </div>
                        <div class="detail">
                            <span class="detail-label">Time:</span>
                            <span class="detail-value">{{ formatTime(kit.sourceJobTime) }}</span>
                        </div>
                        <div class="detail">
                            <span class="detail-label">Parts:</span>
                            <span class="detail-value">{{ countParts(kit.parts) }}</span>
                        </div>
                    </div>
                    <div class="kit-actions">
                        <button @click.stop="handleApplyKit(kit)" @mousedown.stop class="btn-apply"
                            :disabled="!canApplyKit(kit)">
                            Apply to Vehicle
                        </button>
                        <button @click.stop="handleDeleteKit(kit)" @mousedown.stop class="btn-delete">
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                                stroke-width="2">
                                <path
                                    d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
                            </svg>
                        </button>
                    </div>
                </div>
            </div>
        </div>

        <!-- Empty State -->
        <div v-if="completableJobs.length === 0 && kits.length === 0" class="empty-state">
            <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path
                    d="M20.38 3.4a2 2 0 0 0-2.83 0L12 8.94 6.45 3.4a2 2 0 0 0-2.83 2.83L9.17 11.77 3.62 17.32a2 2 0 0 0 2.83 2.83L12 14.6l5.55 5.55a2 2 0 0 0 2.83-2.83L14.83 11.77l5.55-5.55a2 2 0 0 0 0-2.82z" />
            </svg>
            <h3>No Kits Available</h3>
            <p>Accept jobs to create kits from their configurations</p>
        </div>

        <!-- Create Kit Dialog -->
        <div v-if="showDialog" class="dialog-overlay" @click.self="closeDialog">
            <div class="dialog" v-bng-blur>
                <div class="dialog-header">
                    <h3>Create Kit</h3>
                    <button @click.stop="closeDialog" @mousedown.stop class="btn-close">
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                            stroke-width="2">
                            <path d="M18 6L6 18M6 6l12 12" />
                        </svg>
                    </button>
                </div>
                <div class="dialog-body">
                    <p class="dialog-description">
                        Create a kit from <strong>{{ selectedJob?.vehicleName }}</strong>
                    </p>
                    <div class="form-group">
                        <label for="kit-name">Kit Name</label>
                        <input id="kit-name" v-model="kitName" type="text" placeholder="Enter kit name..."
                            @keyup.enter="handleCreateKit" class="input-text" @focus="onInputFocus" @blur="onInputBlur"
                            @keydown.stop @keyup.stop @keypress.stop v-bng-text-input v-focus />
                    </div>
                </div>
                <div class="dialog-footer">
                    <button @click.stop="closeDialog" @mousedown.stop class="btn-secondary">Cancel</button>
                    <button @click.stop="handleCreateKit" @mousedown.stop :disabled="!kitName.trim()"
                        class="btn-primary">Create Kit</button>
                </div>
            </div>
        </div>
    </div>

    <!-- Delete Confirmation Dialog -->
    <Teleport to="body">
        <div v-if="showDeleteDialog" class="dialog-overlay" @click.self="closeDeleteDialog">
            <div class="dialog" v-bng-blur>
                <div class="dialog-header">
                    <h3>Delete Kit</h3>
                    <button @click.stop="closeDeleteDialog" @mousedown.stop class="btn-close">
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                            stroke-width="2">
                            <path d="M18 6L6 18M6 6l12 12" />
                        </svg>
                    </button>
                </div>
                <div class="dialog-body">
                    <p class="dialog-description">
                        Are you sure you want to delete <strong>{{ selectedKit?.name }}</strong>?
                    </p>
                </div>
                <div class="dialog-footer">
                    <button @click.stop="closeDeleteDialog" @mousedown.stop class="btn-secondary">Cancel</button>
                    <button @click.stop="confirmDeleteKit" @mousedown.stop class="btn-danger">Delete</button>
                </div>
            </div>
        </div>
    </Teleport>

    <!-- Apply Confirmation Dialog -->
    <Teleport to="body">
        <div v-if="showApplyDialog" class="dialog-overlay" @click.self="closeApplyDialog">
            <div class="dialog" v-bng-blur>
                <div class="dialog-header">
                    <h3>Apply Kit</h3>
                    <button @click.stop="closeApplyDialog" @mousedown.stop class="btn-close">
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                            stroke-width="2">
                            <path d="M18 6L6 18M6 6l12 12" />
                        </svg>
                    </button>
                </div>
                <div class="dialog-body">
                    <p class="dialog-description">
                        Are you sure you want to apply <strong>{{ selectedKit?.name }}</strong> to the current vehicle?
                    </p>
                    <p class="dialog-warning" v-if="selectedKit">
                        This will replace all parts and tuning settings.
                    </p>
                    <div v-if="loadingCostBreakdown" class="cost-breakdown loading">
                        <p>Calculating costs...</p>
                    </div>
                    <div v-else-if="costBreakdown" class="cost-breakdown">
                        <div class="cost-row">
                            <span class="cost-label">Cost of new parts:</span>
                            <span class="cost-value">${{ formatCurrency(costBreakdown.newPartsCost) }}</span>
                        </div>
                        <div class="cost-row trade-in" v-if="costBreakdown.tradeInCredit > 0">
                            <span class="cost-label">Trade-in value (90%):</span>
                            <span class="cost-value negative">-${{ formatCurrency(costBreakdown.tradeInCredit) }}</span>
                        </div>
                        <div class="cost-row total">
                            <span class="cost-label">Total cost:</span>
                            <span class="cost-value total-value">${{ formatCurrency(costBreakdown.totalCost) }}</span>
                        </div>
                    </div>
                </div>
                <div class="dialog-footer">
                    <button @click.stop="closeApplyDialog" @mousedown.stop class="btn-secondary">Cancel</button>
                    <button @click.stop="confirmApplyKit" @mousedown.stop class="btn-primary" :disabled="loadingCostBreakdown">Apply Kit</button>
                </div>
            </div>
        </div>
    </Teleport>
</template>

<script setup>
import { ref, computed, Teleport, onMounted, onUnmounted } from 'vue'
import { useBusinessComputerStore } from '@/modules/career/stores/businessComputerStore'
import { useBridge, lua } from "@/bridge"
import { vBngTextInput, vBngBlur } from "@/common/directives"

const store = useBusinessComputerStore()
const { events } = useBridge()

const completableJobs = computed(() => {
    const activeJobs = store.activeJobs || []
    const pulledOutVehicles = store.pulledOutVehicles || []

    // Filter to only jobs that are pulled out in the garage
    return activeJobs.filter(job => {
        const isPulledOut = pulledOutVehicles.some(v => String(v.jobId) === String(job.jobId))
        return isPulledOut && !job.techAssigned
    })
})
const kits = computed(() => store.kits || [])
const pulledOutVehicle = computed(() => store.pulledOutVehicle)

const handleKitsUpdated = async (data) => {
    if (data?.businessId && store.businessId && String(data.businessId) === String(store.businessId)) {
        await store.loadBusinessData(store.businessType, store.businessId)
    }
}

// Listen for kit updates from Lua
onMounted(() => {
    events.on('businessComputer:onKitsUpdated', handleKitsUpdated)
})

onUnmounted(() => {
    events.off('businessComputer:onKitsUpdated', handleKitsUpdated)
})

const showDialog = ref(false)
const showDeleteDialog = ref(false)
const showApplyDialog = ref(false)
const selectedJob = ref(null)
const selectedKit = ref(null)
const kitName = ref('')
const costBreakdown = ref(null)
const loadingCostBreakdown = ref(false)

const vFocus = {
    mounted: (el) => el.focus()
}

const onInputFocus = () => {
    try { lua.setCEFTyping(true) } catch (_) { }
}

const onInputBlur = () => {
    try { lua.setCEFTyping(false) } catch (_) { }
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

const countParts = (parts) => {
    if (!parts || typeof parts !== 'object') return 0
    return Object.keys(parts).length
}

const canApplyKit = (kit) => {
    if (!pulledOutVehicle.value) return false
    const vehicleModel = pulledOutVehicle.value.model_key || pulledOutVehicle.value.vehicleConfig?.model_key
    return vehicleModel === kit.model_key
}

const showCreateKitDialog = (job) => {
    selectedJob.value = job
    kitName.value = `${job.vehicleName} - ${job.raceLabel || job.raceType}`
    showDialog.value = true
}

const closeDialog = () => {
    showDialog.value = false
    selectedJob.value = null
    kitName.value = ''
}

const handleCreateKit = async () => {
    if (!kitName.value.trim() || !selectedJob.value) return

    const success = await store.createKit(selectedJob.value.jobId, kitName.value.trim())
    if (success) {
        closeDialog()
    }
}

const handleApplyKit = async (kit) => {
    if (!canApplyKit(kit)) return
    if (!pulledOutVehicle.value) return

    selectedKit.value = kit
    costBreakdown.value = null
    loadingCostBreakdown.value = true
    showApplyDialog.value = true

    try {
        const breakdown = await lua.career_modules_business_tuningShopKits.getKitCostBreakdown(
            store.businessId,
            pulledOutVehicle.value.vehicleId,
            kit.id
        )
        costBreakdown.value = breakdown
    } catch (error) {
        console.error('Failed to get cost breakdown:', error)
    } finally {
        loadingCostBreakdown.value = false
    }
}

const confirmApplyKit = async () => {
    if (!selectedKit.value || !pulledOutVehicle.value) return

    const result = await store.applyKit(pulledOutVehicle.value.vehicleId, selectedKit.value.id)
    if (result.success) {
        console.log('Kit applied successfully, cost:', result.cost)
        closeApplyDialog()
    } else {
        console.error('Failed to apply kit:', result.error)
        closeApplyDialog()
    }
}

const closeApplyDialog = () => {
    showApplyDialog.value = false
    selectedKit.value = null
    costBreakdown.value = null
}

const handleDeleteKit = async (kit) => {
    selectedKit.value = kit
    showDeleteDialog.value = true
}

const confirmDeleteKit = async () => {
    if (!selectedKit.value) return
    const success = await store.deleteKit(selectedKit.value.id)
    if (success) {
        closeDeleteDialog()
    }
}

const closeDeleteDialog = () => {
    showDeleteDialog.value = false
    selectedKit.value = null
}
</script>

<style scoped>
.kits-tab {
    padding: 2rem;
    max-width: 1400px;
    margin: 0 auto;
}

.kits-header {
    margin-bottom: 2rem;
}

.kits-header h2 {
    font-size: 2rem;
    font-weight: 600;
    margin: 0 0 0.5rem 0;
    color: #fff;
}

.kits-description {
    color: #999;
    margin: 0;
}

.section {
    margin-bottom: 3rem;
}

.section-title {
    font-size: 1.25rem;
    font-weight: 600;
    margin: 0 0 1rem 0;
    color: #fff;
    border-bottom: 2px solid #333;
    padding-bottom: 0.5rem;
}

.jobs-grid,
.kits-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    gap: 1rem;
}

.job-card,
.kit-card {
    background: #1a1a1a;
    border: 1px solid #333;
    border-radius: 8px;
    padding: 1rem;
    transition: all 0.2s;
}

.job-card:hover {
    border-color: #555;
    transform: translateY(-2px);
}

.job-header,
.kit-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 1rem;
}

.job-info,
.kit-info {
    flex: 1;
}

.job-title,
.kit-name {
    font-size: 1rem;
    font-weight: 600;
    color: #fff;
    margin-bottom: 0.25rem;
}

.job-subtitle,
.kit-subtitle {
    font-size: 0.875rem;
    color: #999;
}

.job-vehicle-image {
    width: 80px;
    height: 60px;
    object-fit: cover;
    border-radius: 4px;
    margin-left: 1rem;
}

.job-stats,
.kit-details {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    margin-bottom: 1rem;
}

.stat,
.detail {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
}

.stat-label,
.detail-label {
    color: #999;
}

.stat-value,
.detail-value {
    color: #fff;
    font-weight: 500;
}

.btn-create-kit {
    width: 100%;
    padding: 0.75rem;
    background: #2563eb;
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    transition: background 0.2s;
}

.btn-create-kit:hover {
    background: #1d4ed8;
}

.kit-actions {
    display: flex;
    gap: 0.5rem;
}

.btn-apply {
    flex: 1;
    padding: 0.75rem;
    background: #16a34a;
    color: white;
    border: none;
    border-radius: 6px;
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.2s;
}

.btn-apply:hover:not(:disabled) {
    background: #15803d;
}

.btn-apply:disabled {
    background: #333;
    color: #666;
    cursor: not-allowed;
}

.btn-delete {
    padding: 0.75rem;
    background: #dc2626;
    color: white;
    border: none;
    border-radius: 6px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.2s;
}

.btn-delete:hover {
    background: #b91c1c;
}

.empty-state {
    text-align: center;
    padding: 4rem 2rem;
    color: #666;
}

.empty-state svg {
    margin: 0 auto 1rem;
    opacity: 0.5;
}

.empty-state h3 {
    font-size: 1.5rem;
    margin: 0 0 0.5rem 0;
    color: #999;
}

.empty-state p {
    margin: 0;
    color: #666;
}

/* Dialog Styles */
.dialog-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
}

.dialog {
    background: rgba(26, 26, 26, 0.95);
    border: 1px solid #333;
    border-radius: 8px;
    width: 90%;
    max-width: 400px;
    box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5);
}

.dialog-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 1rem;
    border-bottom: 1px solid #333;
}

.dialog-header h3 {
    margin: 0;
    font-size: 1.25rem;
    color: #fff;
}

.btn-close {
    background: none;
    border: none;
    color: #999;
    cursor: pointer;
    padding: 0.25rem;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;
}

.btn-close:hover {
    color: #fff;
}

.dialog-body {
    padding: 1rem;
}

.dialog-description {
    margin: 0 0 1rem 0;
    color: #ccc;
}

.form-group {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.form-group label {
    font-size: 0.875rem;
    font-weight: 500;
    color: #ccc;
}

.input-text {
    padding: 0.75rem;
    background: #0a0a0a;
    border: 1px solid #333;
    border-radius: 6px;
    color: #fff;
    font-size: 1rem;
    transition: border-color 0.2s;
}

.input-text:focus {
    outline: none;
    border-color: #2563eb;
}

.dialog-footer {
    display: flex;
    justify-content: flex-end;
    gap: 0.75rem;
    padding: 1rem;
    border-top: 1px solid #333;
}

.btn-secondary,
.btn-primary {
    padding: 0.75rem 1.5rem;
    border: none;
    border-radius: 6px;
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s;
}

.btn-secondary {
    background: #333;
    color: #ccc;
}

.btn-secondary:hover {
    background: #444;
}

.btn-primary {
    background: #2563eb;
    color: white;
}

.btn-primary:hover:not(:disabled) {
    background: #1d4ed8;
}

.btn-primary:disabled {
    background: #333;
    color: #666;
    cursor: not-allowed;
}

.btn-danger {
    padding: 0.75rem 1.5rem;
    border: none;
    border-radius: 6px;
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.2s;
    background: #dc2626;
    color: white;
}

.btn-danger:hover {
    background: #b91c1c;
}

.dialog-warning {
    color: #ef4444;
    font-size: 0.875rem;
    margin-top: 0.5rem;
}

.cost-breakdown {
    margin-top: 1rem;
    padding: 1rem;
    background: rgba(0, 0, 0, 0.3);
    border-radius: 6px;
    border: 1px solid #333;
}

.cost-breakdown.loading {
    text-align: center;
    color: #999;
}

.cost-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem 0;
    font-size: 0.9rem;
}

.cost-row:not(:last-child) {
    border-bottom: 1px solid #333;
}

.cost-label {
    color: #999;
}

.cost-value {
    color: #fff;
    font-weight: 500;
}

.cost-value.negative {
    color: #22c55e;
}

.cost-row.total {
    margin-top: 0.5rem;
    padding-top: 0.75rem;
    border-top: 2px solid #444;
}

.cost-row.total .cost-label {
    color: #fff;
    font-weight: 600;
}

.cost-row.total .total-value {
    color: #fbbf24;
    font-weight: 700;
    font-size: 1.1rem;
}
</style>

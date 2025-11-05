<template>
    <div v-if="open" class="cdm-overlay">
        <div class="cdm-content" @click.stop>
            <div class="cdm-header">
                <div class="cdm-header-left">
                    <div class="cdm-icon" />
                    <div>
                        <div class="cdm-title">{{ challenge?.name }}</div>
                        <div class="cdm-sub">
                            <span class="cdm-badge"
                                :class="'cdm-diff-' + (challenge?.difficulty || 'Easy').toLowerCase()">{{
                                    challenge?.difficulty }}</span>
                            <span v-if="challenge?.isLocal" class="cdm-badge cdm-badge-local">Local</span>
                            <span class="cdm-time">{{ challenge?.estimatedTime }}</span>
                        </div>
                    </div>
                </div>
                <button class="cdm-close" @click="onClose" @mousedown.stop>×</button>
            </div>

            <div class="cdm-body">
                <div class="cdm-section">
                    <div class="cdm-section-title">Starting Conditions</div>
                    <div class="cdm-grid">
                        <div class="cdm-card">
                            <div class="cdm-card-label">Starting Cash</div>
                            <div class="cdm-card-value cdm-green">{{ challenge?.startingCash }}</div>
                        </div>
                        <div class="cdm-card">
                            <div class="cdm-card-label">Debt Amount</div>
                            <div class="cdm-card-value cdm-red">{{ challenge?.loanAmount }}</div>
                        </div>
                        <div class="cdm-card">
                            <div class="cdm-card-label">Interest Rate</div>
                            <div class="cdm-card-value cdm-orange">{{ challenge?.interestRate || '—' }}</div>
                        </div>
                        <div class="cdm-card">
                            <div class="cdm-card-label">Payment Schedule</div>
                            <div class="cdm-card-value cdm-blue">{{ challenge?.paymentSchedule || '—' }}</div>
                        </div>
                    </div>
                </div>

                <div v-if="challenge && hasEconomy" class="cdm-section">
                    <div class="cdm-econ-container" :class="{ open: openEconomy }">
                        <button class="cdm-accordion" @click="openEconomy = !openEconomy">
                            <span>Economy Adjustments</span>
                            <span class="cdm-arrow" :class="{ open: openEconomy }">▸</span>
                        </button>
                        <div v-show="openEconomy" class="cdm-econ-split">
                            <div class="cdm-econ-col">
                                <div class="cdm-subtitle">Disabled</div>
                                <div class="cdm-econ">
                                    <div v-for="([key, mult]) in disabledEntries" :key="'d-'+key" class="cdm-econ-row">
                                        <span class="cdm-econ-key">{{ key }}</span>
                                        <span class="cdm-econ-zero">Disabled</span>
                                    </div>
                                </div>
                            </div>
                            <div class="cdm-econ-col">
                                <div class="cdm-subtitle">Enabled</div>
                                <div class="cdm-econ">
                                    <div v-for="([key, mult]) in enabledEntries" :key="'e-'+key" class="cdm-econ-row">
                                        <span class="cdm-econ-key">{{ key }}</span>
                                        <span :class="econClass(mult)">{{ formatMultiplier(mult) }}</span>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <div v-if="challengeVariables.length > 0" class="cdm-section">
                    <div class="cdm-section-title">Win Condition Settings</div>
                    <div class="cdm-grid">
                        <div v-for="variable in challengeVariables" :key="variable.name" class="cdm-card">
                            <div class="cdm-card-label">{{ variable.label }}</div>
                            <div class="cdm-card-value" :class="variable.colorClass">{{ variable.displayValue }}</div>
                        </div>
                    </div>
                </div>

                <div v-if="challenge?.specialRules" class="cdm-special">
                    <div class="cdm-special-title">Special Rules</div>
                    <div class="cdm-special-text">{{ challenge?.specialRules }}</div>
                </div>

                <div class="cdm-objective">
                    <div class="cdm-objective-title">Objective</div>
                    <div class="cdm-objective-text"><strong>{{ challenge?.objective }}</strong><template v-if="challenge?.objectiveDescription"> — {{ challenge?.objectiveDescription }}</template></div>
                </div>

                <div class="cdm-seed-section">
                    <div class="cdm-seed-title">Challenge Seed</div>
                    <div class="cdm-seed-row">
                        <input :value="challengeSeed" class="cdm-seed-input" readonly />
                        <button class="cdm-seed-copy" @click="copySeedToClipboard" @mousedown.stop>
                            {{ copyButtonText }}
                        </button>
                    </div>
                </div>

                <div class="cdm-footer">
                    <div v-if="challenge?.isLocal" class="cdm-footer-actions">
                        <button class="cdm-edit" @click="onEdit" @mousedown.stop>Edit</button>
                        <button class="cdm-delete" @click="onDelete" @mousedown.stop>Delete</button>
                    </div>
                    <div class="cdm-footer-main">
                        <button class="cdm-primary" @click="onSelect" @mousedown.stop>Select This Challenge</button>
                        <button class="cdm-outline" @click="onClose" @mousedown.stop>Cancel</button>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <teleport to="body">
        <div v-if="deleteConfirmOpen" class="cdm-delete-overlay" @click.stop @mousedown.stop>
            <div class="cdm-delete-modal" @click.stop @mousedown.stop>
                <div class="cdm-delete-header">
                    <div class="cdm-delete-title">Delete Challenge</div>
                    <button class="cdm-delete-close" @click.stop="deleteConfirmOpen = false" @mousedown.stop>×</button>
                </div>
                <div class="cdm-delete-body">
                    <p>Are you sure you want to delete "<strong>{{ challenge?.name }}</strong>"?</p>
                    <p class="cdm-delete-warning">This action cannot be undone.</p>
                </div>
                <div class="cdm-delete-footer">
                    <button class="cdm-delete-cancel" @click.stop="deleteConfirmOpen = false" @mousedown.stop>Cancel</button>
                    <button class="cdm-delete-confirm" @click.stop="confirmDelete" @mousedown.stop :disabled="deleting">
                        {{ deleting ? 'Deleting...' : 'Delete' }}
                    </button>
                </div>
            </div>
        </div>
    </teleport>
</template>

<script setup>
import { defineProps, defineEmits, computed, ref, watch } from 'vue'
import { lua } from '@/bridge'

const props = defineProps({
    open: { type: Boolean, default: false },
    challenge: { type: Object, default: null },
    editorData: { type: Object, default: () => ({ activityTypes: [] }) },
})

const emit = defineEmits(['close', 'select', 'edit', 'delete'])

const challengeSeed = ref('')
const copyButtonText = ref('Copy Seed')
const deleting = ref(false)
const deleteConfirmOpen = ref(false)

function onClose() { 
    if (!props.open) return
    emit('close') 
}
function onSelect() { 
    emit('select') 
}
async function onEdit() {
    if (!props.challenge || !props.challenge.id) return
    emit('edit', props.challenge.id)
    onClose()
}
function onDelete() {
    if (!props.challenge || !props.challenge.id) return
    deleteConfirmOpen.value = true
}
async function confirmDelete() {
    if (!props.challenge || !props.challenge.id) return
    if (deleting.value) return
    
    deleting.value = true
    try {
        const result = await lua.career_challengeModes.deleteChallenge(props.challenge.id)
        if (Array.isArray(result)) {
            const [success, message] = result
            if (success) {
                deleteConfirmOpen.value = false
                emit('delete', props.challenge.id)
                onClose()
            } else {
                console.error('Failed to delete challenge:', message)
                deleteConfirmOpen.value = false
            }
        } else if (result && result.success !== false) {
            deleteConfirmOpen.value = false
            emit('delete', props.challenge.id)
            onClose()
        } else {
            console.error('Failed to delete challenge')
            deleteConfirmOpen.value = false
        }
    } catch (err) {
        console.error('Failed to delete challenge:', err)
        deleteConfirmOpen.value = false
    } finally {
        deleting.value = false
    }
}

async function loadChallengeSeed() {
    if (!props.challenge || !props.challenge.id) {
        challengeSeed.value = ''
        return
    }
    try {
        const seed = await lua.career_challengeModes.getChallengeSeeded(props.challenge.id)
        challengeSeed.value = seed || ''
    } catch (err) {
        console.error('Failed to load challenge seed:', err)
        challengeSeed.value = ''
    }
}

async function copySeedToClipboard() {
    if (!challengeSeed.value) return
    try {
        await navigator.clipboard.writeText(challengeSeed.value)
        copyButtonText.value = 'Copied!'
        setTimeout(() => {
            copyButtonText.value = 'Copy Seed'
        }, 2000)
    } catch (err) {
        console.error('Failed to copy seed:', err)
        copyButtonText.value = 'Failed'
        setTimeout(() => {
            copyButtonText.value = 'Copy Seed'
        }, 2000)
    }
}

watch(() => props.open, (isOpen) => {
    if (!isOpen) {
        if (lua.setCEFTyping) {
            lua.setCEFTyping(false)
        }
        return
    }

    loadChallengeSeed()
    copyButtonText.value = 'Copy Seed'
    
    if (lua.setCEFTyping) {
        lua.setCEFTyping(true)
    }
})

watch(() => props.challenge, () => {
    if (props.open) {
        loadChallengeSeed()
    }
})

const openEconomy = ref(false)
const hasEconomy = computed(() => !!(props.challenge && props.challenge.economyAdjuster && Object.keys(props.challenge.economyAdjuster).length))
const allTypes = computed(() => {
    const raw = props.editorData && props.editorData.activityTypes
    const list = Array.isArray(raw) ? raw : []
    return list.map(t => t.id)
})

const challengeVariables = computed(() => {
    if (!props.challenge) return []
    const winCondition = props.editorData?.winConditions?.find(w => w.id === props.challenge.winCondition)
    if (!winCondition || !winCondition.variables) return []
    
    const result = []
    for (const [variableId, definition] of Object.entries(winCondition.variables)) {
        const value = props.challenge[variableId]
        if (value === undefined) continue
        
        let displayValue = value
        let colorClass = 'cdm-blue'
        
        if (definition.type === 'boolean') {
            displayValue = value ? 'Yes' : 'No'
            colorClass = value ? 'cdm-green' : 'cdm-red'
        } else if (definition.type === 'number' || definition.type === 'integer') {
            if (variableId.toLowerCase().includes('money') || variableId.toLowerCase().includes('cost') || variableId.toLowerCase().includes('price')) {
                displayValue = '$' + Number(value).toLocaleString()
                colorClass = 'cdm-green'
            } else {
                displayValue = Number(value).toLocaleString()
            }
        }
        
        result.push({
            name: variableId,
            label: definition.label || variableId,
            displayValue: displayValue,
            colorClass: colorClass
        })
    }
    
    result.sort((a, b) => {
        const da = (winCondition.variables[a.name]?.order) || 0
        const db = (winCondition.variables[b.name]?.order) || 0
        return da - db
    })
    
    return result
})
const econMap = computed(() => ({ ...(props.challenge?.economyAdjuster || {}) }))
const disabledEntries = computed(() => {
    const entries = allTypes.value.map(id => [id, econMap.value[id] ?? 1]).filter(([_, m]) => m === 0)
    entries.sort((a, b) => a[0].localeCompare(b[0]))
    return entries
})
const enabledEntries = computed(() => {
    const entries = allTypes.value.map(id => [id, econMap.value[id] ?? 1]).filter(([_, m]) => m !== 0)
    entries.sort((a, b) => b[1] - a[1])
    return entries
})
function econClass(mult) {
    if (mult === 0) return 'cdm-econ-zero'
    if (mult > 1) return 'cdm-econ-up'
    if (mult < 1) return 'cdm-econ-down'
    return 'cdm-econ-neutral'
}
function formatMultiplier(mult) {
    if (mult === 0) return 'Disabled'
    const pct = ((mult - 1) * 100)
    if (pct === 0) return '1.00x (no change)'
    const sign = pct > 0 ? '+' : ''
    return `${mult.toFixed(2)}x (${sign}${pct.toFixed(0)}%)`
}
</script>

<style scoped lang="scss">
.cdm-overlay {
    position: fixed;
    inset: 0;
    background: radial-gradient(ellipse at center, rgba(2, 8, 23, 0.6), rgba(2, 8, 23, 0.75));
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 3000;
}

.cdm-content {
    width: min(42rem, calc(100% - 2rem));
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 14px;
    box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
    color: #fff;
    padding: 1rem 1rem 0.75rem;
}

.cdm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.cdm-header-left {
    display: flex;
    gap: 0.75rem;
    align-items: center;
}

.cdm-icon {
    width: 36px;
    height: 36px;
    border-radius: 8px;
    background: rgba(100, 116, 139, 0.35);
}

.cdm-title {
    font-size: 1.1rem;
    font-weight: 600;
}

.cdm-sub {
    display: flex;
    gap: 0.5rem;
    align-items: center;
    margin-top: 0.25rem;
}

.cdm-badge {
    border: 1px solid;
    border-radius: 6px;
    padding: 2px 6px;
    font-size: 0.7rem;
}

.cdm-diff-easy {
    color: #34d399;
    border-color: rgba(52, 211, 153, 0.5);
    background: rgba(52, 211, 153, 0.15);
}

.cdm-diff-medium {
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.5);
    background: rgba(245, 158, 11, 0.15);
}

.cdm-diff-hard {
    color: #fb923c;
    border-color: rgba(251, 146, 60, 0.5);
    background: rgba(251, 146, 60, 0.15);
}

.cdm-diff-extreme {
    color: #f87171;
    border-color: rgba(248, 113, 113, 0.5);
    background: rgba(248, 113, 113, 0.15);
}

.cdm-diff-impossible {
    color: #dc2626;
    border-color: rgba(220, 38, 38, 0.5);
    background: rgba(220, 38, 38, 0.15);
}

.cdm-badge-local {
    color: #60a5fa;
    border-color: rgba(96, 165, 250, 0.5);
    background: rgba(96, 165, 250, 0.15);
}

.cdm-time {
    color: #94a3b8;
    font-size: 0.75rem;
}

.cdm-close {
    background: transparent;
    border: 0;
    color: #94a3b8;
    font-size: 1.25rem;
    cursor: pointer;
}

.cdm-body {
    margin-top: 1rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.cdm-section-title {
    font-weight: 600;
    margin-bottom: 0.5rem;
}

.cdm-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.75rem;
}

.cdm-card {
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    border-radius: 10px;
    padding: 0.75rem;
}

.cdm-card-label {
    color: #94a3b8;
    font-size: 0.8rem;
    margin-bottom: 0.35rem;
}

.cdm-card-value {
    font-weight: 600;
}

.cdm-green {
    color: #34d399;
}

.cdm-red {
    color: #f87171;
}

.cdm-orange {
    color: #fb923c;
}

.cdm-blue {
    color: #60a5fa;
}

.cdm-special {
    background: rgba(245, 158, 11, 0.12);
    border: 1px solid rgba(245, 158, 11, 0.35);
    border-radius: 10px;
    padding: 0.75rem;
}

.cdm-special-title {
    color: #fbbf24;
    font-weight: 600;
    margin-bottom: 0.25rem;
}

.cdm-special-text {
    color: #fde68a;
    font-size: 0.9rem;
}

.cdm-objective {
    background: rgba(59, 130, 246, 0.12);
    border: 1px solid rgba(59, 130, 246, 0.35);
    border-radius: 10px;
    padding: 0.75rem;
}

.cdm-objective-title {
    color: #93c5fd;
    font-weight: 600;
    margin-bottom: 0.25rem;
}

.cdm-objective-text {
    color: #bfdbfe;
}

.cdm-footer {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding-top: 0.75rem;
}

.cdm-footer-actions {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-start;
}

.cdm-footer-main {
    display: flex;
    gap: 0.5rem;
    justify-content: flex-end;
}

.cdm-edit {
    background: rgba(59, 130, 246, 0.2);
    border: 1px solid rgba(59, 130, 246, 0.5);
    color: #60a5fa;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.875rem;
}

.cdm-edit:hover {
    background: rgba(59, 130, 246, 0.3);
}

.cdm-delete {
    background: rgba(239, 68, 68, 0.2);
    border: 1px solid rgba(239, 68, 68, 0.5);
    color: #f87171;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.875rem;
}

.cdm-delete:hover {
    background: rgba(239, 68, 68, 0.3);
}

.cdm-primary {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.6rem 1rem;
    border-radius: 8px;
    cursor: pointer;
}

.cdm-outline {
    background: transparent;
    border: 1px solid rgba(100, 116, 139, 0.5);
    color: #cbd5e1;
    padding: 0.6rem 1rem;
    border-radius: 8px;
    cursor: pointer;
}

.cdm-accordion {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    color: #e2e8f0;
    border-radius: 10px;
    padding: 0.5rem 0.75rem;
    cursor: pointer;
}

.cdm-arrow {
    transition: transform 0.15s ease;
}

.cdm-arrow.open {
    transform: rotate(90deg);
}

.cdm-econ-container {
    border: 1px solid rgba(100, 116, 139, 0.35);
    border-radius: 10px;
    overflow: hidden;
}

.cdm-econ-container .cdm-accordion {
    border-radius: 10px 10px 0 0;
    border-bottom: 1px solid rgba(100, 116, 139, 0.35);
}

.cdm-econ-container.open {
    box-shadow: inset 0 0 0 1px rgba(100, 116, 139, 0.15);
}

.cdm-econ-split { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem 0.75rem; padding: 0.5rem; background: rgba(15,23,42,0.6); align-items: stretch; }

.cdm-econ-col { display: flex; flex-direction: column; gap: 0.35rem; min-height: 0; }

.cdm-subtitle { color:#94a3b8; font-weight: 600; font-size: 0.85rem; margin-bottom: 0.15rem; }

.cdm-econ { display: grid; grid-template-columns: 1fr auto; gap: 0.25rem 0.75rem; background: rgba(30,41,59,0.6); border: 1px solid rgba(100,116,139,0.35); border-radius: 8px; padding: 0.4rem 0.6rem; height: 250px; overflow: auto; }

.cdm-econ-row {
    display: contents;
}

.cdm-econ-key { color: #e2e8f0; line-height: 1.2; }

.cdm-econ-up { color: #34d399; line-height: 1.2; }

.cdm-econ-down { color: #f87171; line-height: 1.2; }

.cdm-econ-zero { color: #f87171; line-height: 1.2; }

.cdm-econ-neutral { color: #e5e7eb; line-height: 1.2; }

.cdm-seed-section {
    background: rgba(59, 130, 246, 0.08);
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: 10px;
    padding: 0.75rem;
}

.cdm-seed-title {
    color: #93c5fd;
    font-weight: 600;
    margin-bottom: 0.5rem;
}

.cdm-seed-row {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 0.5rem;
    align-items: center;
}

.cdm-seed-input {
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    color: #e2e8f0;
    border-radius: 8px;
    padding: 0.5rem;
    font-family: 'Courier New', monospace;
    font-size: 0.9rem;
    cursor: text;
    user-select: all;
}

.cdm-seed-copy {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.5rem 1rem;
    border-radius: 8px;
    cursor: pointer;
    white-space: nowrap;
    font-size: 0.9rem;
    transition: opacity 0.2s;
}

.cdm-seed-copy:hover {
    opacity: 0.9;
}

.cdm-delete-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.75);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 3000;
}

.cdm-delete-modal {
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 12px;
    padding: 0;
    width: 90%;
    max-width: 400px;
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.5);
}

.cdm-delete-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1.25rem 1.5rem;
    border-bottom: 1px solid rgba(71, 85, 105, 0.6);
}

.cdm-delete-title {
    font-size: 1.25rem;
    font-weight: 600;
    color: #e2e8f0;
}

.cdm-delete-close {
    background: transparent;
    border: 0;
    color: #94a3b8;
    font-size: 1.5rem;
    cursor: pointer;
    padding: 0;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
}

.cdm-delete-close:hover {
    color: #e2e8f0;
}

.cdm-delete-body {
    padding: 1.5rem;
    color: #e2e8f0;
}

.cdm-delete-body p {
    margin: 0 0 0.75rem 0;
    font-size: 0.95rem;
    line-height: 1.5;
}

.cdm-delete-body p:last-child {
    margin-bottom: 0;
}

.cdm-delete-body strong {
    color: #60a5fa;
}

.cdm-delete-warning {
    color: #f87171 !important;
    font-size: 0.875rem;
}

.cdm-delete-footer {
    display: flex;
    gap: 0.75rem;
    padding: 1rem 1.5rem;
    border-top: 1px solid rgba(71, 85, 105, 0.6);
    justify-content: flex-end;
}

.cdm-delete-cancel {
    background: transparent;
    border: 1px solid rgba(100, 116, 139, 0.5);
    color: #cbd5e1;
    padding: 0.6rem 1.25rem;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.9rem;
}

.cdm-delete-cancel:hover {
    background: rgba(100, 116, 139, 0.2);
    border-color: rgba(100, 116, 139, 0.7);
}

.cdm-delete-confirm {
    background: linear-gradient(90deg, #ef4444, #dc2626);
    border: 0;
    color: #fff;
    padding: 0.6rem 1.25rem;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.9rem;
    font-weight: 500;
}

.cdm-delete-confirm:hover:not(:disabled) {
    background: linear-gradient(90deg, #f87171, #ef4444);
}

.cdm-delete-confirm:disabled {
    opacity: 0.6;
    cursor: not-allowed;
}
</style>

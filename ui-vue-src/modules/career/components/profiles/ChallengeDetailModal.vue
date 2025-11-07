<template>
    <div v-if="open" class="cdm-overlay">
        <div class="cdm-content" @click.stop>
            <div class="cdm-header">
                <div class="cdm-header-left">
                    <div class="cdm-icon" />
                    <div>
                        <div class="cdm-title-row">
                            <div class="cdm-title">{{ challenge?.name }}</div>
                            <span class="cdm-badge"
                                :class="'cdm-diff-' + (displayChallenge?.difficulty || 'Easy').toLowerCase()">{{
                                    displayChallenge?.difficulty || 'Medium' }}</span>
                            <span v-if="challenge?.isLocal" class="cdm-badge cdm-badge-local">Local</span>
                        </div>
                        <div class="cdm-sub">
                            <span class="cdm-time">{{ challenge?.estimatedTime }}</span>
                        </div>
                        <div v-if="challenge?.shortDescription" class="cdm-desc">{{ challenge?.shortDescription }}</div>
                    </div>
                </div>
                <button class="cdm-close" @click="onClose" @mousedown.stop>×</button>
            </div>

            <div class="cdm-body">
                <div class="cdm-overview">
                    <div class="cdm-overview-main">
                        <div class="cdm-starting-cash">
                            <div class="cdm-starting-cash-label">Starting Cash</div>
                            <div class="cdm-starting-cash-value cdm-green">{{ challenge?.startingCash }}</div>
                        </div>
                        <div v-if="hasDebt" class="cdm-debt-compact">
                            <span class="cdm-debt-label">Debt:</span>
                            <span class="cdm-debt-value">{{ debtSummary }}</span>
                        </div>
                    </div>
                    <div v-if="startingGaragesDisplay || startingMapDisplay" class="cdm-starting-location">
                        <div v-if="startingGaragesDisplay" class="cdm-location-item">
                            <span class="cdm-location-label">Starting Garages:</span>
                            <span class="cdm-location-value">{{ startingGaragesDisplay }}</span>
                        </div>
                        <div v-if="startingMapDisplay" class="cdm-location-item">
                            <span class="cdm-location-label">Starting Map:</span>
                            <span class="cdm-location-value">{{ startingMapDisplay }}</span>
                        </div>
                    </div>
                </div>

                <div v-if="challenge && hasEconomy" class="cdm-section">
                    <button class="cdm-econ-button" @click="openEconomyModal = true" @mousedown.stop>
                        <span>View Economy Adjustments</span>
                        <span class="cdm-econ-button-icon">→</span>
                    </button>
                </div>

                <div v-if="challenge?.specialRules" class="cdm-special">
                    <div class="cdm-special-title">Special Rules</div>
                    <div class="cdm-special-text">{{ challenge?.specialRules }}</div>
                </div>

                <div class="cdm-objective">
                    <div class="cdm-objective-header">
                        <div class="cdm-objective-title">Objective</div>
                        <div class="cdm-objective-text"><strong>{{ challenge?.objective }}</strong><template v-if="challenge?.objectiveDescription"> — {{ challenge?.objectiveDescription }}</template></div>
                    </div>
                    <div v-if="challengeVariables.length > 0" class="cdm-objective-settings">
                        <div v-for="variable in challengeVariables" :key="variable.name" class="cdm-setting-group">
                            <div class="cdm-setting-label">{{ variable.label }}</div>
                            <template v-if="variable.items">
                                <div v-if="variable.items.length" class="cdm-chip-list">
                                    <span v-for="item in variable.items" :key="item" class="cdm-chip">{{ item }}</span>
                                </div>
                                <div v-else class="cdm-chip-empty">None</div>
                            </template>
                            <template v-else>
                                <div class="cdm-setting-value" :class="variable.colorClass">{{ variable.displayValue }}</div>
                            </template>
                        </div>
                    </div>
                </div>

                <div class="cdm-seed-section">
                    <div class="cdm-seed-title">Challenge Seed</div>
                    <div class="cdm-seed-row">
                        <input :value="challengeSeed" class="cdm-seed-input" readonly :placeholder="challengeSeed ? '' : 'Loading seed...'" />
                        <button class="cdm-seed-copy" @click="copySeedToClipboard" @mousedown.stop :disabled="!challengeSeed">
                            {{ copyButtonText }}
                        </button>
                    </div>
                    <div v-if="!challengeSeed" class="cdm-seed-debug">Seed not loaded (check console for details)</div>
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
        <div v-if="openEconomyModal" class="cdm-econ-overlay" @click.stop="openEconomyModal = false" @mousedown.stop>
            <div class="cdm-econ-modal" @click.stop @mousedown.stop>
                <div class="cdm-econ-modal-header">
                    <div class="cdm-econ-modal-title">Economy Adjustments</div>
                    <button class="cdm-econ-modal-close" @click.stop="openEconomyModal = false" @mousedown.stop>×</button>
                </div>
                <div class="cdm-econ-modal-body">
                    <div class="cdm-econ-modal-split">
                        <div class="cdm-econ-modal-col">
                            <div class="cdm-econ-modal-subtitle">Decreased</div>
                            <div class="cdm-econ-modal-list">
                                <div v-for="([key, mult]) in decreasedEntries" :key="'d-'+key" class="cdm-econ-modal-item">
                                    <span class="cdm-econ-modal-key">{{ key }}</span>
                                    <span class="cdm-econ-modal-value" :class="econClass(mult)">{{ formatMultiplier(mult) }}</span>
                                </div>
                                <div v-if="decreasedEntries.length === 0" class="cdm-econ-modal-empty">No decreased activities</div>
                            </div>
                        </div>
                        <div class="cdm-econ-modal-col">
                            <div class="cdm-econ-modal-subtitle">Increased</div>
                            <div class="cdm-econ-modal-list">
                                <div v-for="([key, mult]) in increasedEntries" :key="'i-'+key" class="cdm-econ-modal-item">
                                    <span class="cdm-econ-modal-key">{{ key }}</span>
                                    <span class="cdm-econ-modal-value" :class="econClass(mult)">{{ formatMultiplier(mult) }}</span>
                                </div>
                                <div v-if="increasedEntries.length === 0" class="cdm-econ-modal-empty">No increased activities</div>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="cdm-econ-modal-footer">
                    <button class="cdm-econ-modal-close-btn" @click.stop="openEconomyModal = false" @mousedown.stop>Close</button>
                </div>
            </div>
        </div>
    </teleport>
</template>

<script setup>
import { defineProps, defineEmits, computed, ref, watch, onMounted, onBeforeUnmount } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'

const events = useEvents()

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
const mapOptions = ref([])
const fullChallengeData = ref(null)
const openEconomyModal = ref(false)

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

function handleChallengeSeedResponse(payload) {
    if (!payload || payload.challengeId !== props.challenge?.id) {
        return
    }
    
    if (!payload.success) {
        console.error('[ChallengeDetailModal] Seed encoding failed:', payload.error)
        challengeSeed.value = ''
        return
    }
    
    if (payload.seed && typeof payload.seed === 'string' && payload.seed.trim() !== '') {
        challengeSeed.value = payload.seed
    } else {
        challengeSeed.value = ''
    }
}

function loadChallengeSeed() {
    if (!props.challenge || !props.challenge.id) {
        challengeSeed.value = ''
        return
    }
    
    if (!lua.career_challengeModes) {
        console.error('[ChallengeDetailModal] lua.career_challengeModes is not available!')
        challengeSeed.value = ''
        return
    }
    
    if (typeof lua.career_challengeModes.requestChallengeSeeded !== 'function') {
        console.error('[ChallengeDetailModal] requestChallengeSeeded is not a function!')
        challengeSeed.value = ''
        return
    }
    
    challengeSeed.value = ''
    
    try {
        lua.career_challengeModes.discoverChallenges()
        lua.career_challengeModes.requestChallengeSeeded(props.challenge.id)
    } catch (err) {
        console.error('[ChallengeDetailModal] Error calling Lua functions:', err)
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

function handleChallengeEditDataResponse(payload) {
    if (!payload || !payload.success || !payload.data) {
        console.error('[ChallengeDetailModal] Failed to load challenge data:', payload?.error)
        return
    }
    
    if (payload.challengeId !== props.challenge?.id) {
        return
    }
    
    fullChallengeData.value = payload.data
}

async function loadMaps() {
    if (!lua.overhaul_maps?.getCompatibleMaps) return
    try {
        const maps = await lua.overhaul_maps.getCompatibleMaps()
        if (maps && Object.keys(maps).length > 0) {
            mapOptions.value = Object.entries(maps).map(([key, value]) => ({
                id: key,
                name: value
            }))
        }
    } catch (error) {
        console.error('[ChallengeDetailModal] Failed to load maps:', error)
    }
}

watch(() => props.open, (isOpen) => {
    if (!isOpen) {
        if (lua.setCEFTyping) {
            lua.setCEFTyping(false)
        }
        fullChallengeData.value = null
        return
    }

    if (props.challenge?.id) {
        try {
            lua.career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            console.error('[ChallengeDetailModal] Error requesting challenge data:', err)
        }
    }

    loadChallengeSeed()
    loadMaps()
    copyButtonText.value = 'Copy Seed'
    
    if (lua.setCEFTyping) {
        lua.setCEFTyping(true)
    }
})

watch(() => props.challenge, () => {
    if (props.open && props.challenge?.id) {
        loadChallengeSeed()
        try {
            lua.career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            console.error('[ChallengeDetailModal] Error requesting challenge data on change:', err)
        }
    }
}, { immediate: true, deep: true })

watch(() => props.editorData, () => {
    // EditorData changed
}, { immediate: true, deep: true })


onMounted(() => {
    events.on('challengeSeedResponse', handleChallengeSeedResponse)
    events.on('challengeEditDataResponse', handleChallengeEditDataResponse)
    
    if (props.open && props.challenge?.id) {
        try {
            lua.career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            console.error('[ChallengeDetailModal] Error requesting challenge data on mount:', err)
        }
        loadChallengeSeed()
        loadMaps()
        copyButtonText.value = 'Copy Seed'
        
        if (lua.setCEFTyping) {
            lua.setCEFTyping(true)
        }
    }
})

onBeforeUnmount(() => {
    events.off('challengeSeedResponse', handleChallengeSeedResponse)
    events.off('challengeEditDataResponse', handleChallengeEditDataResponse)
})

const displayChallenge = computed(() => {
    return fullChallengeData.value || props.challenge
})

const hasEconomy = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    return !!(challenge && challenge.economyAdjuster && Object.keys(challenge.economyAdjuster).length)
})
const allTypes = computed(() => {
    const raw = props.editorData && props.editorData.activityTypes
    const list = Array.isArray(raw) ? raw : []
    return list.map(t => t.id)
})

const challengeVariables = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return []
    
    let winConditionId = challenge.winCondition
    if (!winConditionId && challenge.objective) {
        const winCondition = props.editorData?.winConditions?.find(w => w.name === challenge.objective)
        if (winCondition) {
            winConditionId = winCondition.id
        }
    }
    
    if (!winConditionId) {
        return []
    }
    
    const winCondition = props.editorData?.winConditions?.find(w => w.id === winConditionId)
    if (!winCondition || !winCondition.variables) {
        return []
    }
    
    const availableGarages = props.editorData?.availableGarages || []
    const garageMap = new Map()
    availableGarages.forEach(garage => {
        if (garage.id && garage.name) {
            garageMap.set(garage.id, garage.name)
        }
    })
    
    const result = []
    for (const [variableId, definition] of Object.entries(winCondition.variables)) {
        let value = challenge[variableId]
        if (value === undefined && definition.default !== undefined) {
            value = definition.default
        }
        
        if (definition.type === 'array' || definition.type === 'multiselect') {
            if (value === undefined || value === null) {
                value = []
            }
        }
        
        if (value === undefined) {
            continue
        }
        
        let displayValue = value
        let colorClass = 'cdm-blue'
        
        if (definition.type === 'boolean') {
            displayValue = value ? 'Yes' : 'No'
            colorClass = value ? 'cdm-green' : 'cdm-red'
        } else if (definition.type === 'number' || definition.type === 'integer') {
            if (variableId.toLowerCase().includes('money') || variableId.toLowerCase().includes('cost') || variableId.toLowerCase().includes('price')) {
                displayValue = '$' + Number(value).toLocaleString()
                colorClass = 'cdm-green'
            } else if (variableId.toLowerCase().includes('speed')) {
                displayValue = Number(value).toLocaleString() + ' MPH'
            } else {
                displayValue = Number(value).toLocaleString()
            }
        } else if (definition.type === 'string') {
            displayValue = String(value)
        } else if (definition.type === 'array' || definition.type === 'multiselect') {
            if (Array.isArray(value) && value.length > 0) {
                if (variableId.toLowerCase().includes('garage')) {
                    const garageNames = value.map(id => garageMap.get(id) || id).filter(Boolean)
                    displayValue = garageNames.length > 0 ? garageNames.join(', ') : value.join(', ')
                    result.push({
                        name: variableId,
                        label: definition.label || variableId,
                        items: garageNames.length > 0 ? garageNames : value,
                        colorClass: colorClass
                    })
                    continue
                } else {
                    displayValue = value.join(', ')
                    result.push({
                        name: variableId,
                        label: definition.label || variableId,
                        items: value,
                        colorClass: colorClass
                    })
                    continue
                }
            } else {
                displayValue = 'None'
                colorClass = 'cdm-orange'
                result.push({
                    name: variableId,
                    label: definition.label || variableId,
                    items: [],
                    colorClass: colorClass
                })
                continue
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
const hasDebt = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return false
    
    if (challenge.loans && challenge.loans.amount && challenge.loans.amount > 0) {
        return true
    }
    
    const loanAmount = challenge.loanAmount
    if (loanAmount && typeof loanAmount === 'string') {
        const numAmount = parseFloat(loanAmount.replace(/[^0-9.]/g, ''))
        return numAmount > 0
    }
    
    return (typeof loanAmount === 'number' && loanAmount > 0) || false
})
const debtAmount = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return '—'
    
    let amount = 0
    if (challenge.loans && challenge.loans.amount) {
        amount = challenge.loans.amount
    } else if (challenge.loanAmount) {
        if (typeof challenge.loanAmount === 'string') {
            amount = parseFloat(challenge.loanAmount.replace(/[^0-9.]/g, '')) || 0
        } else {
            amount = challenge.loanAmount
        }
    }
    
    return amount > 0 ? '$' + Number(amount).toLocaleString() : '—'
})
const interestRate = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return '—'
    
    let interest = challenge.loans?.interest || challenge.loanInterest || challenge.interestRate
    if (interest === undefined || interest === null) return '—'
    
    if (typeof interest === 'string') {
        interest = parseFloat(interest.replace(/[^0-9.]/g, '')) / 100
    }
    
    return (Number(interest) * 100).toFixed(0) + '%'
})
const paymentSchedule = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return '—'
    
    let payments = challenge.loans?.payments || challenge.loanPayments || challenge.paymentSchedule
    if (payments === undefined || payments === null) return '—'
    
    if (typeof payments === 'string') {
        return payments
    }
    
    return (Number(payments) * 5) + ' min total (' + payments + ' payments)'
})

const debtSummary = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge || !hasDebt.value) return ''
    
    let amount = 0
    if (challenge.loans && challenge.loans.amount) {
        amount = challenge.loans.amount
    } else if (challenge.loanAmount) {
        if (typeof challenge.loanAmount === 'string') {
            amount = parseFloat(challenge.loanAmount.replace(/[^0-9.]/g, '')) || 0
        } else {
            amount = challenge.loanAmount
        }
    }
    
    let interest = challenge.loans?.interest || challenge.loanInterest || challenge.interestRate
    if (interest === undefined || interest === null) return ''
    
    if (typeof interest === 'string') {
        interest = parseFloat(interest.replace(/[^0-9.]/g, '')) / 100
    }
    
    let payments = challenge.loans?.payments || challenge.loanPayments
    if (payments === undefined || payments === null) {
        const paymentSchedule = challenge.paymentSchedule
        if (paymentSchedule && typeof paymentSchedule === 'string') {
            const match = paymentSchedule.match(/(\d+)\s+payments/)
            if (match) {
                payments = parseInt(match[1])
            } else {
                return ''
            }
        } else {
            return ''
        }
    }
    
    if (typeof payments === 'string') {
        const match = payments.match(/(\d+)\s+payments/)
        if (match) {
            payments = parseInt(match[1])
        } else {
            const numPayments = parseInt(payments)
            if (!isNaN(numPayments)) {
                payments = numPayments
            } else {
                return ''
            }
        }
    }
    
    const amountStr = amount >= 1000000 
        ? '$' + (amount / 1000000).toFixed(1).replace(/\.0$/, '') + ' million'
        : '$' + Number(amount).toLocaleString()
    
    const interestStr = (Number(interest) * 100).toFixed(0) + '%'
    
    const perPayment = amount / payments
    const perPaymentStr = perPayment >= 1000
        ? '$' + (perPayment / 1000).toFixed(1).replace(/\.0$/, '') + 'k'
        : '$' + Math.round(perPayment).toLocaleString()
    
    return `${amountStr} at ${interestStr}. ${payments} payment${payments !== 1 ? 's' : ''} (${perPaymentStr} per payment)`
})
const econMap = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    return { ...(challenge?.economyAdjuster || {}) }
})
const decreasedEntries = computed(() => {
    const entries = allTypes.value.map(id => [id, econMap.value[id] ?? 1]).filter(([_, m]) => m < 1)
    entries.sort((a, b) => a[1] - b[1])
    return entries
})
const increasedEntries = computed(() => {
    const entries = allTypes.value.map(id => [id, econMap.value[id] ?? 1]).filter(([_, m]) => m > 1)
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

const startingGaragesDisplay = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge?.startingGarages || !Array.isArray(challenge.startingGarages) || challenge.startingGarages.length === 0) {
        return null
    }
    
    const availableGarages = props.editorData?.availableGarages || []
    const garageMap = new Map()
    availableGarages.forEach(garage => {
        if (garage.id && garage.name) {
            garageMap.set(garage.id, garage.name)
        }
    })
    
    const garageNames = challenge.startingGarages
        .map(id => garageMap.get(id) || id)
        .filter(Boolean)
    
    return garageNames.length > 0 ? garageNames.join(', ') : null
})

const startingMapDisplay = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge?.map) return null
    
    const map = mapOptions.value.find(m => m.id === challenge.map)
    return map ? map.name : challenge.map
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

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
    width: min(60em, 90vw);
    max-width: calc(100vw - 2em);
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 14px;
    box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
    color: #fff;
    padding: 1em 1em 0.75em;
    font-size: calc-ui-em();
    max-height: 90vh;
    overflow-y: auto;
}

.cdm-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding-bottom: 1em;
    border-bottom: 1px solid rgba(100, 116, 139, 0.2);
}

.cdm-header-left {
    display: flex;
    gap: 0.875em;
    align-items: flex-start;
    flex: 1;
}

.cdm-icon {
    width: 2.5em;
    height: 2.5em;
    border-radius: 10px;
    background: rgba(59, 130, 246, 0.2);
    border: 1px solid rgba(59, 130, 246, 0.3);
    flex-shrink: 0;
    aspect-ratio: 1;
}

.cdm-title-row {
    display: flex;
    align-items: center;
    gap: 0.75em;
    flex-wrap: wrap;
}

.cdm-title {
    font-size: 1.25em;
    font-weight: 600;
    line-height: 1.3;
}

.cdm-sub {
    display: flex;
    gap: 0.5em;
    align-items: center;
    margin-top: 0.4em;
    flex-wrap: wrap;
}

.cdm-desc {
    color: #cbd5e1;
    font-size: 0.9em;
    margin-top: 0.5em;
    line-height: 1.5;
    max-width: 50em;
}

.cdm-badge {
    border: 1px solid;
    border-radius: 6px;
    padding: 2px 6px;
    font-size: 0.7em;
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

.cdm-diff-exteme {
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
    font-size: 0.75em;
}

.cdm-close {
    background: transparent;
    border: 0;
    color: #94a3b8;
    font-size: 1.5em;
    cursor: pointer;
    padding: 0.25em;
    line-height: 1;
    transition: color 0.2s ease;
    flex-shrink: 0;
}

.cdm-close:hover {
    color: #e2e8f0;
}

.cdm-body {
    margin-top: 1.25em;
    display: flex;
    flex-direction: column;
    gap: 1.25em;
}

.cdm-overview {
    background: rgba(30, 41, 59, 0.4);
    border: 1px solid rgba(100, 116, 139, 0.3);
    border-radius: 12px;
    padding: 1.25em;
    display: flex;
    flex-direction: column;
    gap: 1em;
}

.cdm-overview-main {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 1em;
    align-items: center;
}

.cdm-starting-cash {
    text-align: left;
}

.cdm-starting-cash-label {
    color: #94a3b8;
    font-size: 0.8em;
    margin-bottom: 0.4em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 500;
}

.cdm-starting-cash-value {
    font-size: 1.85em;
    font-weight: 700;
    line-height: 1.2;
}

.cdm-starting-location {
    padding-top: 0.75em;
    border-top: 1px solid rgba(100, 116, 139, 0.25);
    display: flex;
    flex-direction: column;
    gap: 0.5em;
}

.cdm-location-item {
    display: flex;
    gap: 0.5em;
    align-items: baseline;
}

.cdm-location-label {
    color: #94a3b8;
    font-size: 0.85em;
    font-weight: 500;
    min-width: fit-content;
}

.cdm-location-value {
    color: #60a5fa;
    font-size: 0.9em;
}

.cdm-debt-compact {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.4);
    border-radius: 8px;
    padding: 0.6em 1em;
    display: flex;
    gap: 0.5em;
    align-items: baseline;
    white-space: nowrap;
}

.cdm-debt-label {
    color: #fca5a5;
    font-weight: 600;
    font-size: 0.85em;
}

.cdm-debt-value {
    color: #fee2e2;
    font-size: 0.9em;
}

.cdm-section-title {
    font-weight: 600;
    margin-bottom: 0.5em;
}

.cdm-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.75em;
}

.cdm-card {
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    border-radius: 10px;
    padding: 0.75em;
}

.cdm-card-label {
    color: #94a3b8;
    font-size: 0.8em;
    margin-bottom: 0.35em;
}

.cdm-card-value {
    font-weight: 600;
}

.cdm-chip-list {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5em;
    margin-top: 0.5em;
}

.cdm-chip {
    background: rgba(59, 130, 246, 0.15);
    border: 1px solid rgba(59, 130, 246, 0.4);
    color: #93c5fd;
    padding: 0.4em 0.75em;
    border-radius: 6px;
    font-size: 0.85em;
    line-height: 1.3;
    font-weight: 500;
    transition: all 0.2s ease;
}

.cdm-chip:hover {
    background: rgba(59, 130, 246, 0.25);
    border-color: rgba(59, 130, 246, 0.6);
    transform: translateY(-1px);
}

.cdm-chip-empty {
    color: #94a3b8;
    font-size: 0.9em;
    font-style: italic;
    margin-top: 0.5em;
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
    background: rgba(245, 158, 11, 0.1);
    border: 1px solid rgba(245, 158, 11, 0.3);
    border-radius: 12px;
    padding: 1em;
}

.cdm-special-title {
    color: #fbbf24;
    font-weight: 600;
    margin-bottom: 0.5em;
    font-size: 0.95em;
}

.cdm-special-text {
    color: #fde68a;
    font-size: 0.9em;
    line-height: 1.5;
}

.cdm-objective {
    background: rgba(59, 130, 246, 0.1);
    border: 1px solid rgba(59, 130, 246, 0.3);
    border-radius: 12px;
    padding: 1.25em;
}

.cdm-objective-header {
    margin-bottom: 1em;
}

.cdm-objective-title {
    color: #93c5fd;
    font-weight: 600;
    font-size: 1.05em;
    margin-bottom: 0.5em;
}

.cdm-objective-text {
    color: #bfdbfe;
    line-height: 1.5;
    font-size: 0.95em;
}

.cdm-objective-settings {
    display: flex;
    flex-direction: column;
    gap: 1em;
}

.cdm-setting-group {
    display: flex;
    flex-direction: column;
    gap: 0.5em;
}

.cdm-setting-label {
    color: #94a3b8;
    font-size: 0.85em;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.03em;
}

.cdm-setting-value {
    font-weight: 600;
    font-size: 1em;
    line-height: 1.4;
}

.cdm-footer {
    display: flex;
    flex-direction: column;
    gap: 0.75em;
    padding-top: 0.5em;
    border-top: 1px solid rgba(100, 116, 139, 0.2);
    margin-top: 0.5em;
}

.cdm-footer-actions {
    display: flex;
    gap: 0.5em;
    justify-content: flex-start;
}

.cdm-footer-main {
    display: flex;
    gap: 0.5em;
    justify-content: flex-end;
}

.cdm-edit {
    background: rgba(59, 130, 246, 0.2);
    border: 1px solid rgba(59, 130, 246, 0.5);
    color: #60a5fa;
    padding: 0.5em 1em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
}

.cdm-edit:hover {
    background: rgba(59, 130, 246, 0.3);
}

.cdm-delete {
    background: rgba(239, 68, 68, 0.2);
    border: 1px solid rgba(239, 68, 68, 0.5);
    color: #f87171;
    padding: 0.5em 1em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
}

.cdm-delete:hover {
    background: rgba(239, 68, 68, 0.3);
}

.cdm-primary {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.6em 1em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
}

.cdm-outline {
    background: transparent;
    border: 1px solid rgba(100, 116, 139, 0.5);
    color: #cbd5e1;
    padding: 0.6em 1em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
}

.cdm-econ-button {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: rgba(59, 130, 246, 0.15);
    border: 1px solid rgba(59, 130, 246, 0.4);
    color: #93c5fd;
    border-radius: 10px;
    padding: 0.75em 1em;
    cursor: pointer;
    font-size: inherit;
    font-weight: 500;
    transition: all 0.2s ease;
}

.cdm-econ-button:hover {
    background: rgba(59, 130, 246, 0.25);
    border-color: rgba(59, 130, 246, 0.6);
    transform: translateY(-1px);
}

.cdm-econ-button-icon {
    font-size: 1.1em;
    transition: transform 0.2s ease;
}

.cdm-econ-button:hover .cdm-econ-button-icon {
    transform: translateX(3px);
}

.cdm-econ-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.75);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 4000;
    backdrop-filter: blur(4px);
}

.cdm-econ-modal {
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 14px;
    width: 90%;
    max-width: 50em;
    max-height: 85vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 30px 80px rgba(0, 0, 0, 0.6);
    font-size: calc-ui-em();
}

.cdm-econ-modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1.25em 1.5em;
    border-bottom: 1px solid rgba(71, 85, 105, 0.6);
}

.cdm-econ-modal-title {
    font-size: 1.25em;
    font-weight: 600;
    color: #e2e8f0;
}

.cdm-econ-modal-close {
    background: transparent;
    border: 0;
    color: #94a3b8;
    font-size: 1.5em;
    cursor: pointer;
    padding: 0.25em;
    line-height: 1;
    transition: color 0.2s ease;
    width: 1.5em;
    height: 1.5em;
    display: flex;
    align-items: center;
    justify-content: center;
}

.cdm-econ-modal-close:hover {
    color: #e2e8f0;
}

.cdm-econ-modal-body {
    padding: 1.5em;
    overflow-y: auto;
    flex: 1;
}

.cdm-econ-modal-split {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5em;
    align-items: start;
}

.cdm-econ-modal-col {
    display: flex;
    flex-direction: column;
    gap: 0.75em;
}

.cdm-econ-modal-subtitle {
    color: #93c5fd;
    font-weight: 600;
    font-size: 0.95em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding-bottom: 0.5em;
    border-bottom: 1px solid rgba(100, 116, 139, 0.3);
}

.cdm-econ-modal-list {
    display: flex;
    flex-direction: column;
    gap: 0.5em;
    max-height: 20em;
    overflow-y: auto;
    padding-right: 0.5em;
}

.cdm-econ-modal-list::-webkit-scrollbar {
    width: 6px;
}

.cdm-econ-modal-list::-webkit-scrollbar-track {
    background: rgba(30, 41, 59, 0.5);
    border-radius: 3px;
}

.cdm-econ-modal-list::-webkit-scrollbar-thumb {
    background: rgba(100, 116, 139, 0.5);
    border-radius: 3px;
}

.cdm-econ-modal-list::-webkit-scrollbar-thumb:hover {
    background: rgba(100, 116, 139, 0.7);
}

.cdm-econ-modal-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    border-radius: 8px;
    padding: 0.75em 1em;
    transition: all 0.2s ease;
}

.cdm-econ-modal-item:hover {
    background: rgba(30, 41, 59, 0.8);
    border-color: rgba(100, 116, 139, 0.5);
}

.cdm-econ-modal-key {
    color: #e2e8f0;
    font-weight: 500;
    flex: 1;
}

.cdm-econ-modal-value {
    font-weight: 600;
    margin-left: 1em;
    white-space: nowrap;
}

.cdm-econ-modal-empty {
    color: #94a3b8;
    font-style: italic;
    text-align: center;
    padding: 1em;
    font-size: 0.9em;
}

.cdm-econ-up { color: #34d399; }
.cdm-econ-down { color: #f87171; }
.cdm-econ-zero { color: #f87171; }
.cdm-econ-neutral { color: #e5e7eb; }

.cdm-econ-modal-footer {
    padding: 1em 1.5em;
    border-top: 1px solid rgba(71, 85, 105, 0.6);
    display: flex;
    justify-content: flex-end;
}

.cdm-econ-modal-close-btn {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.6em 1.25em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
    font-weight: 500;
    transition: opacity 0.2s ease;
}

.cdm-econ-modal-close-btn:hover {
    opacity: 0.9;
}

.cdm-seed-section {
    background: rgba(59, 130, 246, 0.08);
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: 12px;
    padding: 1em;
}

.cdm-seed-title {
    color: #93c5fd;
    font-weight: 600;
    margin-bottom: 0.75em;
    font-size: 0.95em;
}

.cdm-seed-row {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 0.5em;
    align-items: center;
}

.cdm-seed-input {
    background: rgba(30, 41, 59, 0.6);
    border: 1px solid rgba(100, 116, 139, 0.35);
    color: #e2e8f0;
    border-radius: 8px;
    padding: 0.5em;
    font-family: 'Courier New', monospace;
    font-size: 0.9em;
    cursor: text;
    user-select: all;
}

.cdm-seed-copy {
    background: linear-gradient(90deg, #2563eb, #1d4ed8);
    border: 0;
    color: #fff;
    padding: 0.5em 1em;
    border-radius: 8px;
    cursor: pointer;
    white-space: nowrap;
    font-size: inherit;
    transition: opacity 0.2s;
}

.cdm-seed-copy:hover:not(:disabled) {
    opacity: 0.9;
}

.cdm-seed-copy:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.cdm-seed-debug {
    margin-top: 0.5em;
    font-size: 0.75em;
    color: #94a3b8;
    font-style: italic;
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
    max-width: 25em;
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.5);
    font-size: calc-ui-rem();
}

.cdm-delete-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1.25em 1.5em;
    border-bottom: 1px solid rgba(71, 85, 105, 0.6);
}

.cdm-delete-title {
    font-size: 1.25em;
    font-weight: 600;
    color: #e2e8f0;
}

.cdm-delete-close {
    background: transparent;
    border: 0;
    color: #94a3b8;
    font-size: 1.5em;
    cursor: pointer;
    padding: 0;
    width: 1.5em;
    height: 1.5em;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
    aspect-ratio: 1;
}

.cdm-delete-close:hover {
    color: #e2e8f0;
}

.cdm-delete-body {
    padding: 1.5em;
    color: #e2e8f0;
}

.cdm-delete-body p {
    margin: 0 0 0.75em 0;
    font-size: 0.95em;
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
    font-size: 0.875em;
}

.cdm-delete-footer {
    display: flex;
    gap: 0.75em;
    padding: 1em 1.5em;
    border-top: 1px solid rgba(71, 85, 105, 0.6);
    justify-content: flex-end;
}

.cdm-delete-cancel {
    background: transparent;
    border: 1px solid rgba(100, 116, 139, 0.5);
    color: #cbd5e1;
    padding: 0.6em 1.25em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
}

.cdm-delete-cancel:hover {
    background: rgba(100, 116, 139, 0.2);
    border-color: rgba(100, 116, 139, 0.7);
}

.cdm-delete-confirm {
    background: linear-gradient(90deg, #ef4444, #dc2626);
    border: 0;
    color: #fff;
    padding: 0.6em 1.25em;
    border-radius: 8px;
    cursor: pointer;
    font-size: inherit;
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

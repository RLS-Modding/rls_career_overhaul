<!--
  Map of components/ChallengeDetailModal.vue
  Challenge detail owns the open session, preview data, seed-copy feedback and deletion action.
  Read props and preview state, event responses, lifecycle, actions, then derived challenge rows.
  This file keeps the preview template and its scoped skin; the challenge encoder remains the Lua owner.
-->
<template>
    <!-- Teleported dialogs need their own navigation scopes. -->
    <div
        v-if="open"
        v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (onClose(), false) }"
        class="cdm-overlay">
        <div class="rls-house cdm-content" @click.stop>
            <div class="cdm-header">
                <div class="cdm-header-left">
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
                <HouseButton aria-label="Close" class="cdm-close" @click="onClose" @mousedown.stop>×</HouseButton>
            </div>

            <div class="cdm-body">
                <div class="cdm-overview">
                    <div class="cdm-overview-main">
                        <div class="cdm-starting-cash">
                            <div class="cdm-starting-cash-label">Starting Cash</div>
                            <div class="cdm-starting-cash-value cdm-green"><BngIcon v-if="startingCashDisplay" class="cur" :type="icons.beamCurrency" />{{ startingCashDisplay }}</div>
                        </div>
                        <div v-if="hasDebt" class="cdm-debt-compact">
                            <span class="cdm-debt-label">Debt:</span>
                            <span class="cdm-debt-value"><template v-if="debtSummary"><BngIcon class="cur" :type="icons.beamCurrency" />{{ debtSummary.amount }} at {{ debtSummary.interest }}. {{ debtSummary.payments }} payment{{ debtSummary.payments !== 1 ? 's' : '' }} (<BngIcon class="cur" :type="icons.beamCurrency" />{{ debtSummary.perPayment }} per payment)</template></span>
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
                    <HouseButton class="cdm-econ-button" @click="openEconomyModal = true" @mousedown.stop>
                        <span>View Economy Adjustments</span>
                        <span class="cdm-econ-button-icon">→</span>
                    </HouseButton>
                </div>

                <div v-if="challenge?.specialRules" class="cdm-special">
                    <div class="cdm-special-title">Special Rules</div>
                    <div class="cdm-special-text">{{ challenge?.specialRules }}</div>
                </div>

                <div class="cdm-objective">
                    <div class="cdm-objective-header">
                        <div class="cdm-objective-title">Objective</div>
                        <div class="cdm-objective-text"><strong>{{ objectiveDisplay }}</strong><template v-if="objectiveDescriptionDisplay"> — {{ objectiveDescriptionDisplay }}</template></div>
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
                                <div class="cdm-setting-value" :class="variable.colorClass"><BngIcon v-if="variable.isMoney" class="cur" :type="icons.beamCurrency" />{{ variable.displayValue }}</div>
                            </template>
                        </div>
                    </div>
                </div>

                <div class="cdm-seed-section">
                    <div class="cdm-seed-title">Challenge Seed</div>
                    <div class="cdm-seed-row">
                        <input :value="challengeSeed" class="cdm-seed-input" readonly :placeholder="challengeSeed ? '' : 'Loading seed...'" />
                        <HouseButton class="cdm-seed-copy" @click="copySeedToClipboard" @mousedown.stop :disabled="!challengeSeed">
                            {{ copyButtonText }}
                        </HouseButton>
                    </div>
                    <div v-if="!challengeSeed" class="cdm-seed-debug">Seed not loaded (check console for details)</div>
                </div>

                <div class="cdm-footer">
                    <div v-if="challenge?.isLocal" class="cdm-footer-actions">
                        <HouseButton class="cdm-edit" @click="onEdit" @mousedown.stop>Edit</HouseButton>
                        <HouseButton class="cdm-delete" variant="quiet-danger" @click="onDelete" @mousedown.stop>Delete</HouseButton>
                    </div>
                    <div class="cdm-footer-main">
                        <HouseButton class="cdm-primary" variant="primary" @click="onSelect" @mousedown.stop>Select This Challenge</HouseButton>
                        <HouseButton bng-scoped-nav-autofocus class="cdm-outline" variant="quiet" @click="onClose" @mousedown.stop>Cancel</HouseButton>
                    </div>
                </div>
            </div>
        </div>
    </div>
    <teleport to="body">
        <div
            v-if="deleteConfirmOpen"
            v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => ((deleteConfirmOpen = false), false) }"
            class="cdm-delete-overlay"
            @click.stop
            @mousedown.stop>
            <div class="rls-house cdm-delete-modal" @click.stop @mousedown.stop>
                <div class="cdm-delete-header">
                    <div class="cdm-delete-title">Delete Challenge</div>
                    <HouseButton aria-label="Close" class="cdm-delete-close" @click.stop="deleteConfirmOpen = false" @mousedown.stop>×</HouseButton>
                </div>
                <div class="cdm-delete-body">
                    <p>Are you sure you want to delete "<strong>{{ challenge?.name }}</strong>"?</p>
                    <p class="cdm-delete-warning">This action cannot be undone.</p>
                </div>
                <div class="cdm-delete-footer">
                    <HouseButton class="cdm-delete-cancel" variant="quiet" @click.stop="deleteConfirmOpen = false" @mousedown.stop>Cancel</HouseButton>
                    <HouseButton class="cdm-delete-confirm" variant="danger" @click.stop="confirmDelete" @mousedown.stop :disabled="deleting">
                        {{ deleting ? 'Deleting...' : 'Delete' }}
                    </HouseButton>
                </div>
            </div>
        </div>
        <div
            v-if="openEconomyModal"
            v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => ((openEconomyModal = false), false) }"
            class="cdm-econ-overlay"
            @click.stop="openEconomyModal = false"
            @mousedown.stop>
            <div class="rls-house cdm-econ-modal" @click.stop @mousedown.stop>
                <div class="cdm-econ-modal-header">
                    <div class="cdm-econ-modal-title">Economy Adjustments</div>
                    <HouseButton aria-label="Close" class="cdm-econ-modal-close" @click.stop="openEconomyModal = false" @mousedown.stop>×</HouseButton>
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
                    <HouseButton class="cdm-econ-modal-close-btn" variant="primary" @click.stop="openEconomyModal = false" @mousedown.stop>Close</HouseButton>
                </div>
            </div>
        </div>
    </teleport>
</template>

<script setup>
import HouseButton from '../../components/house/HouseButton.vue'
import { computed, ref, watch, onMounted, onBeforeUnmount } from 'vue'
import { vBngScopedNav } from '@/common/directives'
import { returnFocusToOpener } from '../../composables/useScreenEntryFocus'
import { safeLua } from '../../utils/safeLua.js'
import { lua, useBridge } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'

const { units } = useBridge()

const events = useEvents()

const COPY_FEEDBACK_MS = 2000

// Diagnostics go through safeLua: each context warns once, under the Overhaul prefix.
const reportFailure = (why, error) => safeLua(() => { throw error }, why)

// This read-only dialog leaves controller menu input enabled.
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

watch(deleteConfirmOpen, isOpen => {
    if (!isOpen && props.open) returnFocusToOpener(() => document.querySelector('.cdm-overlay .cdm-delete'))
})
watch(openEconomyModal, isOpen => {
    if (!isOpen && props.open) returnFocusToOpener(() => document.querySelector('.cdm-overlay .cdm-econ-button'))
})

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
        const result = await lua.overhaul_career_challengeModes.deleteChallenge(props.challenge.id)
        if (Array.isArray(result)) {
            const [success, message] = result
            if (success) {
                deleteConfirmOpen.value = false
                emit('delete', props.challenge.id)
                onClose()
            } else {
                reportFailure('ChallengeDetailModal: delete reported failure', message)
                deleteConfirmOpen.value = false
            }
        } else if (result && result.success !== false) {
            deleteConfirmOpen.value = false
            emit('delete', props.challenge.id)
            onClose()
        } else {
            reportFailure('ChallengeDetailModal: delete returned no success', result)
            deleteConfirmOpen.value = false
        }
    } catch (err) {
        reportFailure('ChallengeDetailModal: delete threw', err)
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
        reportFailure('ChallengeDetailModal: seed encoding failed', payload.error)
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

    if (!lua.overhaul_career_challengeModes) {
        reportFailure('ChallengeDetailModal: challenge modes bridge missing', new Error('lua.overhaul_career_challengeModes is not available'))
        challengeSeed.value = ''
        return
    }

    if (typeof lua.overhaul_career_challengeModes.requestChallengeSeeded !== 'function') {
        reportFailure('ChallengeDetailModal: requestChallengeSeeded missing', new Error('requestChallengeSeeded is not a function'))
        challengeSeed.value = ''
        return
    }

    challengeSeed.value = ''

    try {
        lua.overhaul_career_challengeModes.discoverChallenges()
        lua.overhaul_career_challengeModes.requestChallengeSeeded(props.challenge.id)
    } catch (err) {
        reportFailure('ChallengeDetailModal: seed Lua call failed', err)
    }
}

async function copySeedToClipboard() {
    if (!challengeSeed.value) return
    try {
        await navigator.clipboard.writeText(challengeSeed.value)
        copyButtonText.value = 'Copied!'
        setTimeout(() => {
            copyButtonText.value = 'Copy Seed'
        }, COPY_FEEDBACK_MS)
    } catch (err) {
        reportFailure('ChallengeDetailModal: copy seed failed', err)
        copyButtonText.value = 'Failed'
        setTimeout(() => {
            copyButtonText.value = 'Copy Seed'
        }, COPY_FEEDBACK_MS)
    }
}

function handleChallengeEditDataResponse(payload) {
    if (!payload || !payload.success || !payload.data) {
        reportFailure('ChallengeDetailModal: challenge data load failed', payload?.error)
        return
    }

    if (payload.challengeId !== props.challenge?.id) {
        return
    }

    fullChallengeData.value = payload.data
}

async function loadMaps() {
    if (!lua.overhaul_world_maps?.getCompatibleMaps) return
    try {
        const maps = await lua.overhaul_world_maps.getCompatibleMaps()
        if (maps && Object.keys(maps).length > 0) {
            mapOptions.value = Object.entries(maps)
                .map(([key, value]) => ({
                    id: key,
                    name: value
                }))
                .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
        }
    } catch (error) {
        reportFailure('ChallengeDetailModal: map load failed', error)
    }
}

watch(() => props.open, (isOpen) => {
    if (!isOpen) {
        fullChallengeData.value = null
        return
    }

    if (props.challenge?.id) {
        try {
            lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            reportFailure('ChallengeDetailModal: edit data request failed', err)
        }
    }

    loadChallengeSeed()
    loadMaps()
    copyButtonText.value = 'Copy Seed'

})

watch(() => props.challenge, () => {
    if (props.open && props.challenge?.id) {
        loadChallengeSeed()
        try {
            lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            reportFailure('ChallengeDetailModal: edit data request on change failed', err)
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
            lua.overhaul_career_challengeModes.requestChallengeDataForEdit(props.challenge.id)
        } catch (err) {
            reportFailure('ChallengeDetailModal: edit data request on mount failed', err)
        }
        loadChallengeSeed()
        loadMaps()
        copyButtonText.value = 'Copy Seed'
    }
})

onBeforeUnmount(() => {
    events.off('challengeSeedResponse', handleChallengeSeedResponse)
    events.off('challengeEditDataResponse', handleChallengeEditDataResponse)
})

const displayChallenge = computed(() => {
    return fullChallengeData.value || props.challenge
})

// Host-locale toLocaleString, not units.formatMoney: that rounds to fixed decimals, this keeps up to three.
const startingCashDisplay = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return null

    // Check multiple possible field names
    const amount = challenge.startingCash || challenge.startingCapital
    if (amount !== undefined && amount !== null) {
        // Template adds the currency glyph; strip a legacy "$" from pre-formatted strings.
        if (typeof amount === 'string') return amount.replace(/^\$/, '')
        return Number(amount).toLocaleString()
    }
    return null
})

const objectiveDisplay = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return null

    // If we have a direct objective name, use it
    if (challenge.objective) return challenge.objective

    // Otherwise look up the win condition name
    if (challenge.winCondition && props.editorData?.winConditions) {
        const wc = props.editorData.winConditions.find(w => w.id === challenge.winCondition)
        if (wc) return wc.name
    }

    return null
})

const objectiveDescriptionDisplay = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return null

    // If we have a direct description, use it
    if (challenge.objectiveDescription) return challenge.objectiveDescription

    // Otherwise look up the win condition description
    if (challenge.winCondition && props.editorData?.winConditions) {
        const wc = props.editorData.winConditions.find(w => w.id === challenge.winCondition)
        if (wc) return wc.description
    }

    return null
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
        let isMoney = false

        if (definition.type === 'boolean') {
            displayValue = value ? 'Yes' : 'No'
            colorClass = value ? 'cdm-green' : 'cdm-red'
        } else if (definition.type === 'number' || definition.type === 'integer') {
            if (variableId.toLowerCase().includes('money') || variableId.toLowerCase().includes('cost') || variableId.toLowerCase().includes('price')) {
                displayValue = Number(value).toLocaleString()
                isMoney = true
                colorClass = 'cdm-green'
            } else if (variableId.toLowerCase().includes('speed')) {
                // Challenge speed targets are stored in mph (challengeModes.lua); show in the player's unit.
                displayValue = units.buildString('speed', Number(value) * 0.44704, 0)
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
            isMoney: isMoney,
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
function parseLegacyLoanAmount(amount) {
    return parseFloat(amount.replace(/[^0-9.]/g, ''))
}

function parseLoanInterest(interest) {
    return typeof interest === 'string'
        ? parseFloat(interest.replace(/[^0-9.]/g, '')) / 100
        : interest
}

const hasDebt = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge) return false

    if (challenge.loans && challenge.loans.amount && challenge.loans.amount > 0) {
        return true
    }

    const loanAmount = challenge.loanAmount
    if (loanAmount && typeof loanAmount === 'string') {
        const numAmount = parseLegacyLoanAmount(loanAmount)
        return numAmount > 0
    }

    return (typeof loanAmount === 'number' && loanAmount > 0) || false
})
// Compact million/k forms and per-payment rounding are the modal's own wording, not units.formatMoney output.
const debtSummary = computed(() => {
    const challenge = fullChallengeData.value || props.challenge
    if (!challenge || !hasDebt.value) return null

    let amount = 0
    if (challenge.loans && challenge.loans.amount) {
        amount = challenge.loans.amount
    } else if (challenge.loanAmount) {
        if (typeof challenge.loanAmount === 'string') {
            amount = parseLegacyLoanAmount(challenge.loanAmount) || 0
        } else {
            amount = challenge.loanAmount
        }
    }

    let interest = challenge.loans?.interest || challenge.loanInterest || challenge.interestRate
    if (interest === undefined || interest === null) return null

    interest = parseLoanInterest(interest)

    let payments = challenge.loans?.payments || challenge.loanPayments
    if (payments === undefined || payments === null) {
        const paymentSchedule = challenge.paymentSchedule
        if (paymentSchedule && typeof paymentSchedule === 'string') {
            const match = paymentSchedule.match(/(\d+)\s+payments/)
            if (match) {
                payments = parseInt(match[1])
            } else {
                return null
            }
        } else {
            return null
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
                return null
            }
        }
    }

    const amountStr = amount >= 1000000
        ? (amount / 1000000).toFixed(1).replace(/\.0$/, '') + ' million'
        : Number(amount).toLocaleString()

    const interestStr = (Number(interest) * 100).toFixed(0) + '%'

    const perPayment = amount / payments * (1 + (Number(interest) || 0))
    const perPaymentStr = perPayment >= 1000
        ? (perPayment / 1000).toFixed(1).replace(/\.0$/, '') + 'k'
        : Math.round(perPayment).toLocaleString()

    // Pieces, so the template can put the currency glyph before each amount.
    return { amount: amountStr, interest: interestStr, payments, perPayment: perPaymentStr }
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
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

@use "@/styles/modules/mixins" as *;

.cdm-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 3000;
}

.cdm-content {
    width: min(60em, 90vw);
    max-width: calc(100vw - 2em);
    background: #1a1a1c;
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
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
    border-bottom: 1px solid var(--line);
}

.cdm-header-left {
    display: flex;
    gap: 0.875em;
    align-items: flex-start;
    flex: 1;
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
    color: var(--muted);
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
    color: var(--ok);
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
    color: var(--bad);
    border-color: rgba(248, 113, 113, 0.5);
    background: rgba(248, 113, 113, 0.15);
}

.cdm-diff-impossible {
    color: #dc2626;
    border-color: rgba(220, 38, 38, 0.5);
    background: rgba(220, 38, 38, 0.15);
}

.cdm-badge-local {
    color: var(--muted);
    border-color: var(--line);
    background: var(--panel);
}

.cdm-time {
    color: var(--faint);
    font-size: 0.75em;
}

.cdm-body {
    margin-top: 1.25em;
    display: flex;
    flex-direction: column;
    gap: 1.25em;
}

.cdm-overview {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
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
    color: var(--faint);
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
    border-top: 1px solid var(--line);
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
    color: var(--faint);
    font-size: 0.85em;
    font-weight: 500;
    min-width: fit-content;
}

.cdm-location-value {
    color: var(--muted);
    font-size: 0.9em;
}

.cdm-debt-compact {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.4);
    border-radius: var(--radius-control);
    padding: 0.6em 1em;
    display: flex;
    gap: 0.5em;
    align-items: baseline;
    white-space: normal;
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
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
    padding: 0.75em;
}

.cdm-card-label {
    color: var(--faint);
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
    background: var(--panel);
    border: 1px solid var(--line);
    color: #fff;
    padding: 0.4em 0.75em;
    border-radius: 6px;
    font-size: 0.85em;
    line-height: 1.3;
    font-weight: 500;

}

.cdm-chip:hover {
    background: var(--panel);
    border-color: var(--line);
    transform: translateY(-1px);
}

.cdm-chip-empty {
    color: var(--faint);
    font-size: 0.9em;
    font-style: italic;
    margin-top: 0.5em;
}

.cdm-green {
    color: var(--ok);
}

.cdm-red {
    color: var(--bad);
}

.cdm-orange {
    color: #fb923c;
}

.cdm-blue {
    color: var(--muted);
}

.cdm-special {
    background: rgba(245, 158, 11, 0.1);
    border: 1px solid rgba(245, 158, 11, 0.3);
    border-radius: var(--radius-control);
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
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
    padding: 1.25em;
}

.cdm-objective-header {
    margin-bottom: 1em;
}

.cdm-objective-title {
    color: #fff;
    font-weight: 600;
    font-size: 1.05em;
    margin-bottom: 0.5em;
}

.cdm-objective-text {
    color: var(--muted);
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
    color: var(--faint);
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
    border-top: 1px solid var(--line);
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

.cdm-econ-button-icon {
    font-size: 1.1em;
    transition: transform 0.2s ease;
}

.cdm-econ-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.75);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 4000;
}

.cdm-econ-modal {
    background: #1a1a1c;
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
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
    border-bottom: 1px solid var(--line);
}

.cdm-econ-modal-title {
    font-size: 1.25em;
    font-weight: 600;
    color: #fff;
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
    color: #fff;
    font-weight: 600;
    font-size: 0.95em;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding-bottom: 0.5em;
    border-bottom: 1px solid var(--line);
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
    background: var(--panel);
    border-radius: 3px;
}

.cdm-econ-modal-list::-webkit-scrollbar-thumb {
    background: var(--line);
    border-radius: 3px;
}

.cdm-econ-modal-list::-webkit-scrollbar-thumb:hover {
    background: var(--line);
}

.cdm-econ-modal-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
    padding: 0.75em 1em;

}

.cdm-econ-modal-item:hover {
    background: var(--panel);
    border-color: var(--line);
}

.cdm-econ-modal-key {
    color: #fff;
    font-weight: 500;
    flex: 1;
}

.cdm-econ-modal-value {
    font-weight: 600;
    margin-left: 1em;
    white-space: normal;
}

.cdm-econ-modal-empty {
    color: var(--faint);
    font-style: italic;
    text-align: center;
    padding: 1em;
    font-size: 0.9em;
}

.cdm-econ-up { color: var(--ok); }
.cdm-econ-down { color: var(--bad); }
.cdm-econ-zero { color: var(--bad); }
.cdm-econ-neutral { color: #fff; }

.cdm-econ-modal-footer {
    padding: 1em 1.5em;
    border-top: 1px solid var(--line);
    display: flex;
    justify-content: flex-end;
}

.cdm-seed-section {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
    padding: 1em;
}

.cdm-seed-title {
    color: #fff;
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
    background: var(--panel);
    border: 1px solid var(--line);
    color: #fff;
    border-radius: var(--radius-control);
    padding: 0.5em;
    font-family: inherit;
    font-size: 0.9em;
    cursor: text;
    user-select: all;
}

.cdm-seed-debug {
    margin-top: 0.5em;
    font-size: 0.75em;
    color: var(--faint);
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
    background: #1a1a1c;
    border: 1px solid var(--line);
    border-radius: var(--radius-control);
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
    border-bottom: 1px solid var(--line);
}

.cdm-delete-title {
    font-size: 1.25em;
    font-weight: 600;
    color: #fff;
}

.cdm-delete-body {
    padding: 1.5em;
    color: #fff;
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
    color: var(--muted);
}

.cdm-delete-warning {
    color: var(--bad) !important;
    font-size: 0.875em;
}

.cdm-delete-footer {
    display: flex;
    gap: 0.75em;
    padding: 1em 1.5em;
    border-top: 1px solid var(--line);
    justify-content: flex-end;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
    margin-right: 0.1em;
    transform: translateY(0.08em);
}


.cdm-seed-input { @include house-focus; min-width: 0; }
.cdm-starting-cash-value, .cdm-econ-modal-value { font-variant-numeric: tabular-nums; }
.cdm-content, .cdm-econ-modal, .cdm-delete-modal { scrollbar-width: thin; scrollbar-color: var(--panel-hover) transparent; }
.cdm-footer-main { flex-wrap: wrap; }
.cdm-econ-button { width: 100%; }
.cdm-econ-button :deep(.btn-label) { display: flex; justify-content: space-between; width: 100%; gap: 0.75em; }
.cdm-econ-modal-close, .cdm-delete-close, .cdm-close { padding: 0.5em; }
</style>

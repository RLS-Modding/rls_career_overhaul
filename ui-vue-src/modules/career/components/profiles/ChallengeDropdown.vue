<template>
    <div class="cd-root">
        <button class="cd-trigger" @click="toggle">
            <div class="cd-left">
                <div class="cd-icon" :class="selectedChallenge ? 'cd-icon-selected' : 'cd-icon-default'" />
                <div class="cd-labels">
                    <template v-if="selectedChallenge">
                        <div class="cd-name">{{ selectedChallenge.name }}</div>
                        <div class="cd-meta">
                            <span class="cd-badge" :class="'cd-diff-' + selectedChallenge.difficulty.toLowerCase()">{{
                                selectedChallenge.difficulty }}</span>
                            <span v-if="selectedChallenge.isLocal" class="cd-badge cd-badge-local">Local</span>
                        </div>
                    </template>
                    <template v-else>
                        <div class="cd-placeholder">Select Challenge</div>
                    </template>
                </div>
            </div>
            <div class="cd-chevron">▾</div>
        </button>

        <teleport to="body">
            <div v-if="open" class="cd-content cd-fixed" :style="fixedStyle">
                <div v-if="modelValue" class="cd-item" @click="clear">
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-title">No Challenge (Free Play)</div>
                    </div>
                </div>
                <div class="cd-sep" />
                <div class="cd-item" @click.stop="openCreate" @mousedown.stop>
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-main">
                            <div class="cd-row">
                                <div class="cd-item-title">Create New Challenge…</div>
                            </div>
                            <div class="cd-sub">Define money, loan, economy, and objective</div>
                        </div>
                    </div>
                </div>
                <div class="cd-sep" />
                <div v-for="c in challenges" :key="c.id" class="cd-item" @click="select(c)">
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-main">
                            <div class="cd-row">
                                <div class="cd-item-title">{{ c.name }}</div>
                                <span class="cd-badge" :class="'cd-diff-' + c.difficulty.toLowerCase()">{{ c.difficulty
                                    }}</span>
                                <span v-if="c.isLocal" class="cd-badge cd-badge-local">Local</span>
                            </div>
                            <div class="cd-sub">{{ c.shortDescription }}</div>
                            <div class="cd-time">{{ c.estimatedTime }}</div>
                        </div>
                    </div>
                    <button class="cd-info" @click.stop="openDetails(c)" @mousedown.stop>i</button>
                </div>
            </div>
        </teleport>

        <teleport to="body">
            <ChallengeDetailModal v-if="detailOpen" :open="detailOpen" :challenge="detailChallenge" :editorData="editorData"
                @close="detailOpen = false; detailChallenge = null" @select="selectFromModal" 
                @edit="onEditChallenge" @delete="onDeleteChallenge" />
        </teleport>
        <teleport to="body">
            <ChallengeCreateModal v-if="createOpen" :key="'create-challenge'" :open="createOpen" :editorData="editorData" 
                :editChallengeData="editChallengeData"
                :editChallengeId="editChallengeId"
                @close="() => { createOpen = false; editChallengeData = null; editChallengeId = null }"
                @saved="onCreated" />
        </teleport>
    </div>
</template>

<script setup>
import { computed, ref, nextTick, onMounted, onBeforeUnmount, watch } from 'vue'
import { lua } from '@/bridge'
import ChallengeDetailModal from './ChallengeDetailModal.vue'
import ChallengeCreateModal from './ChallengeCreateModal.vue'

const props = defineProps({
    modelValue: { type: String, default: null }
})
const emit = defineEmits(['update:modelValue'])

const open = ref(false)
const fixedStyle = ref('')
const detailOpen = ref(false)
const detailChallenge = ref(null)
const createOpen = ref(false)
const editChallengeData = ref(null)
const editChallengeId = ref(null)
const editorData = ref({
  winConditions: [],
  activityTypes: [],
  availableGarages: [],
  defaults: {}
})

const challenges = ref([])
const loading = ref(false)
const error = ref(null)

const selectedChallenge = computed(() => challenges.value.find(c => c.id === props.modelValue))

function toggle() {
    open.value = !open.value
    if (open.value) {
        nextTick(position)
        if (lua.setCEFTyping) {
            lua.setCEFTyping(true)
        }
    } else {
        if (lua.setCEFTyping) {
            lua.setCEFTyping(false)
        }
    }
}
function position() {
    const trigger = document.querySelector('.cd-trigger')
    if (!trigger) return
    const rect = trigger.getBoundingClientRect()
    const triggerStyle = window.getComputedStyle(trigger)
    const baseFontSize = parseFloat(triggerStyle.fontSize) || 16
    const minWidth = 28 * baseFontSize
    const width = Math.max(rect.width * 1.5, minWidth)
    const margin = 8
    const left = Math.max(margin, Math.min(rect.left - (width - rect.width) / 2, window.innerWidth - width - margin))
    const top = rect.bottom + margin
    fixedStyle.value = `position:fixed;z-index:2000;top:${top}px;left:${left}px;width:${width}px;`
}
function onDocClick(e) {
    if (!open.value) return
    if (createOpen.value || detailOpen.value) {
        return
    }
    const target = e.target
    const panel = document.querySelector('.cd-content.cd-fixed')
    const trigger = document.querySelector('.cd-trigger')
    const creator = document.querySelector('.ccm-overlay')
    const detailer = document.querySelector('.cdm-overlay')
    if (panel && panel.contains(target)) return
    if (trigger && trigger.contains(target)) return
    if (creator) {
        return
    }
    if (detailer) return
    open.value = false
}
async function fetchChallenges() {
    loading.value = true
    error.value = null
    try {
        // ensure discovery is run then fetch compact options for the UI
        await lua.career_challengeModes.discoverChallenges()
        const ed = await lua.career_challengeModes.getChallengeEditorData()
        editorData.value = (ed && typeof ed === 'object') ? ed : {}
        const list = await lua.career_challengeModes.getChallengeOptionsForCareerCreation()
        // Map to UI structure expected by this component
        const safeList = Array.isArray(list) ? list : []
        challenges.value = safeList.map(c => ({
            id: c.id,
            name: c.name,
            difficulty: c.difficulty || 'Medium',
            shortDescription: c.description || '',
            startingCash: c.startingCapital ? ('$' + c.startingCapital) : undefined,
            loanAmount: c.loanAmount ? ('$' + c.loanAmount) : (c.hasLoans ? '$' + (c.loanAmount || 0) : undefined),
            interestRate: (typeof c.loanInterest === 'number') ? ((c.loanInterest * 100).toFixed(0) + '%') : undefined,
            paymentSchedule: (typeof c.loanPayments === 'number') ? ((c.loanPayments * 5) + ' min total (' + c.loanPayments + ' payments)') : undefined,
            objective: c.winConditionName || c.winCondition || '',
            objectiveDescription: c.winConditionDescription || '',
            winCondition: c.winCondition,
            targetMoney: c.targetMoney,
            targetGarages: c.targetGarages,
            economyAdjuster: c.economyAdjuster || {},
            estimatedTime: c.estimatedTime || '',
            isLocal: c.isLocal || false
        }))
    } catch (e) {
        console.warn('ChallengeDropdown: failed to fetch challenges', e)
        error.value = 'Failed to load challenges'
    } finally {
        loading.value = false
    }
}

onMounted(() => {
    document.addEventListener('mousedown', onDocClick)
    window.addEventListener('resize', position)
    window.addEventListener('scroll', position, true)
    fetchChallenges()
})
onBeforeUnmount(() => {
    document.removeEventListener('mousedown', onDocClick)
    window.removeEventListener('resize', position)
    window.removeEventListener('scroll', position, true)
    if (lua.setCEFTyping) {
        lua.setCEFTyping(false)
    }
})

watch([detailOpen, createOpen], ([detail, create]) => {
    const anyModalOpen = detail || create
    if (!anyModalOpen && !open.value) {
        if (lua.setCEFTyping) {
            lua.setCEFTyping(false)
        }
    }
})

function select(c) { 
    emit('update:modelValue', c.id)
    open.value = false
    if (lua.setCEFTyping) {
        lua.setCEFTyping(false)
    }
}
function clear() { 
    emit('update:modelValue', null)
    open.value = false
    if (lua.setCEFTyping) {
        lua.setCEFTyping(false)
    }
}
function openDetails(c) { 
    detailChallenge.value = c
    detailOpen.value = true
    open.value = false
}
function selectFromModal() { if (detailChallenge.value) { select(detailChallenge.value); detailOpen.value = false; detailChallenge.value = null } }
function openCreate(e) { 
    if (e) {
        e.preventDefault()
        e.stopPropagation()
    }
    createOpen.value = true
}
async function onCreated(challengeId) { 
    await fetchChallenges()
    if (challengeId) {
        emit('update:modelValue', challengeId)
    }
    editChallengeData.value = null
    editChallengeId.value = null
}

async function onEditChallenge(challengeId) {
    editChallengeId.value = challengeId
    createOpen.value = true
}

async function onDeleteChallenge(challengeId) {
    await fetchChallenges()
    if (props.modelValue === challengeId) {
        emit('update:modelValue', null)
    }
}

defineExpose({
    detailOpen,
    createOpen
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;

.cd-root {
    position: relative;
}

.cd-trigger {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: rgba(30, 41, 59, 0.9);
    border: 1px solid rgba(71, 85, 105, 0.5);
    color: #fff;
    padding: 0.75em;
    border-radius: 10px;
    cursor: pointer;
}

.cd-left {
    display: flex;
    gap: 0.75em;
    align-items: center;
}

.cd-icon {
    width: 1.75em;
    height: 1.75em;
    border-radius: 6px;
    flex-shrink: 0;
    aspect-ratio: 1;
}

.cd-icon-default {
    background: rgba(249, 115, 22, 0.2);
}

.cd-icon-selected {
    background: rgba(59, 130, 246, 0.25);
}

.cd-labels {
    display: flex;
    flex-direction: column;
}

.cd-name {
    font-weight: 600;
    font-size: 0.95em;
}

.cd-placeholder {
  color: #e5e7eb;
  font-size: 0.95em;
}

.cd-meta {
    display: flex;
    align-items: center;
    gap: 0.5em;
    margin-top: 0.15em;
}

.cd-badge {
    border: 1px solid;
    border-radius: 6px;
    padding: 2px 6px;
    font-size: 0.65em;
}

.cd-diff-easy {
    color: #34d399;
    border-color: rgba(52, 211, 153, 0.5);
    background: rgba(52, 211, 153, 0.15);
}

.cd-diff-medium {
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.5);
    background: rgba(245, 158, 11, 0.15);
}

.cd-diff-hard {
    color: #fb923c;
    border-color: rgba(251, 146, 60, 0.5);
    background: rgba(251, 146, 60, 0.15);
}

.cd-diff-extreme {
    color: #f87171;
    border-color: rgba(248, 113, 113, 0.5);
    background: rgba(248, 113, 113, 0.15);
}

.cdm-diff-impossible {
    color: #dc2626;
    border-color: rgba(220, 38, 38, 0.5);
    background: rgba(220, 38, 38, 0.15);
}

.cd-badge-local {
    color: #60a5fa;
    border-color: rgba(96, 165, 250, 0.5);
    background: rgba(96, 165, 250, 0.15);
}

.cd-chevron {
    opacity: 0.8;
}

.cd-content {
    position: absolute;
    z-index: 100;
    margin-top: 0.5em;
    width: 100%;
    left: 0;
    background: rgba(15, 23, 42, 0.98);
    border: 1px solid rgba(71, 85, 105, 0.6);
    border-radius: 10px;
    padding: 0.25em;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
    max-height: 28em;
    overflow: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
    font-size: calc-ui-rem();
}

.cd-content::-webkit-scrollbar { width: 10px; }
.cd-content::-webkit-scrollbar-track { background: rgba(100, 116, 139, 0.2); border-radius: 10px; }
.cd-content::-webkit-scrollbar-thumb {
    background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
    border-radius: 10px;
    border: 2px solid rgba(15, 23, 42, 0.98);
}
.cd-content::-webkit-scrollbar-thumb:hover {
    background-image: linear-gradient(180deg, #ff8a2a, #f86f10);
}

.cd-fixed {
    position: fixed;
    left: auto;
    margin-top: 0;
    z-index: 2000;
}

/* Removed section title as list is now diverse */

.cd-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5em;
    border-radius: 8px;
    cursor: pointer;
}

.cd-item:hover {
    background: rgba(30, 41, 59, 0.6);
}

.cd-item-left {
    display: flex;
    gap: 0.5em;
    align-items: flex-start;
}

.cd-mini-icon {
    width: 1.625em;
    height: 1.625em;
    min-width: 1.625em;
    min-height: 1.625em;
    max-width: 1.625em;
    max-height: 1.625em;
    flex-shrink: 0;
    border-radius: 6px;
    background: rgba(71, 85, 105, 0.5);
    aspect-ratio: 1;
}

.cd-item-main {
    display: flex;
    flex-direction: column;
}

.cd-row {
    display: flex;
    align-items: center;
    gap: 0.35em;
}

.cd-item-title {
    color: #fff;
    font-size: 0.9em;
    font-weight: 600;
}

.cd-sub {
    color: #94a3b8;
    font-size: 0.75em;
    margin-top: 0.1em;
}

.cd-time {
    color: #64748b;
    font-size: 0.7em;
    margin-top: 0.2em;
    display: flex;
    align-items: center;
    gap: 0.25em;
}

.cd-info {
    background: transparent;
    border: 0;
    color: #cbd5e1;
    width: 1.75em;
    height: 1.75em;
    border-radius: 6px;
    cursor: pointer;
    flex-shrink: 0;
    aspect-ratio: 1;
}

.cd-info:hover {
    background: rgba(30, 41, 59, 0.6);
}
</style>

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

                <div v-if="challenge?.targetMoney" class="cdm-section">
                    <div class="cdm-section-title">Target</div>
                    <div class="cdm-grid">
                        <div class="cdm-card">
                            <div class="cdm-card-label">Target Money</div>
                            <div class="cdm-card-value cdm-green">${{ Number(challenge?.targetMoney).toLocaleString() }}</div>
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

                <div class="cdm-footer">
                    <button class="cdm-primary" @click="onSelect" @mousedown.stop>Select This Challenge</button>
                    <button class="cdm-outline" @click="onClose" @mousedown.stop>Cancel</button>
                </div>
            </div>
        </div>
    </div>
</template>

<script setup>
import { defineProps, defineEmits, computed, ref } from 'vue'

const props = defineProps({
    open: { type: Boolean, default: false },
    challenge: { type: Object, default: null },
    editorData: { type: Object, default: () => ({ activityTypes: [] }) },
})

const emit = defineEmits(['close', 'select'])

function onClose() { 
    emit('close') 
}
function onSelect() { 
    emit('select') 
}

const openEconomy = ref(false)
const hasEconomy = computed(() => !!(props.challenge && props.challenge.economyAdjuster && Object.keys(props.challenge.economyAdjuster).length))
const allTypes = computed(() => {
    const raw = props.editorData && props.editorData.activityTypes
    const list = Array.isArray(raw) ? raw : []
    return list.map(t => t.id)
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
    gap: 0.5rem;
    padding-top: 0.75rem;
    justify-content: flex-end;
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
</style>

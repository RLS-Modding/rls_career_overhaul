<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!--
  Map of components/ChallengeDropdown.vue
  Challenge picker owns open state, search, selection and keyboard focus.
  Read input state and filters, selection and close actions, keyboard handling, then lifecycle.
  Scoped styling stays beside the picker so the teleported menu uses the same rules.
-->
<template>
    <div ref="rootRef" class="rls-house cd-root" :class="{ 'cd-root--open': open && inline }">
        <button ref="triggerRef" type="button" class="cd-trigger" @click.stop="toggle" @mousedown.stop>
            <div class="cd-left">
                <div class="cd-icon" :class="selectedChallenge ? 'cd-icon-selected' : 'cd-icon-default'" />
                <div class="cd-labels">
                    <template v-if="selectedChallenge">
                        <div class="cd-name">{{ selectedChallenge.name }}</div>
                        <div class="cd-meta">
                            <span class="cd-badge" :class="'cd-diff-' + (selectedChallenge.difficulty || 'Medium').toLowerCase()">{{
                                selectedChallenge.difficulty || 'Medium' }}</span>
                            <span v-if="selectedChallenge.isLocal" class="cd-badge cd-badge-local">Local</span>
                        </div>
                    </template>
                    <template v-else>
                        <div class="cd-placeholder">{{ storyLabels ? 'Select Story' : 'Select Challenge' }}</div>
                    </template>
                </div>
            </div>
            <div class="cd-chevron">▾</div>
        </button>

        <teleport to="body" :disabled="inline">
            <div
                v-if="open"
                ref="menuPanelRef"
                class="rls-house cd-content"
                :class="{ 'cd-fixed': !inline, 'cd-inline': inline }"
                :style="inline ? undefined : fixedStyle"
                v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (closeList(), false) }"
                v-bng-on-ui-nav:menu="closeList"
                @click.stop
                @mousedown.stop>
                <!-- Teleported menus need their own navigation scopes. -->
                <div v-if="modelValue && !storyLabels" class="cd-item" role="button" tabindex="0" bng-nav-item @click="clear" @keydown.enter.prevent="clear">
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-title">No Challenge (Free Play)</div>
                    </div>
                </div>
                <div class="cd-sep" />
                <div class="cd-item" role="button" tabindex="0" bng-nav-item @click.stop="openCreate" @keydown.enter.prevent="openCreate" @mousedown.stop>
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-main">
                            <div class="cd-row">
                                <div class="cd-item-title">{{ storyLabels ? 'Create New Story…' : 'Create New Challenge…' }}</div>
                            </div>
                            <div class="cd-sub">Define money, loan, economy, and objective</div>
                        </div>
                    </div>
                </div>
                <div class="cd-sep" />
                <div
                    v-for="c in sortedChallenges"
                    :key="c.id"
                    class="cd-item"
                    role="button"
                    tabindex="0"
                    bng-nav-item
                    :bng-scoped-nav-autofocus="c.id === modelValue ? '' : null"
                    @click="select(c)"
                    @keydown.enter.self.prevent="select(c)">
                    <div class="cd-item-left">
                        <div class="cd-mini-icon" />
                        <div class="cd-item-main">
                            <div class="cd-row">
                                <div class="cd-item-title">{{ c.name }}</div>
                                <span class="cd-badge" :class="'cd-diff-' + (c.difficulty || 'Medium').toLowerCase()">{{ c.difficulty || 'Medium'
                                    }}</span>
                                <span v-if="c.isLocal" class="cd-badge cd-badge-local">Local</span>
                            </div>
                            <div v-if="storyLabels" class="cd-bullets">
                                <div v-for="(line, bulletIndex) in storyBulletsFor(c)" :key="bulletIndex" class="cd-bullet"><template v-if="line.money != null"><BngIcon class="cur" :type="icons.beamCurrency" />{{ line.money }}</template>{{ line.text }}</div>
                            </div>
                            <template v-else>
                                <div class="cd-sub">{{ c.shortDescription }}</div>
                                <div class="cd-time">{{ c.estimatedTime }}</div>
                            </template>
                        </div>
                    </div>
                    <button :aria-label="`Information about ${c.name}`" bng-nav-item class="cd-info" @click.stop="openDetails(c)" @mousedown.stop>i</button>
                </div>
            </div>
        </teleport>

        <teleport to="body">
            <ChallengeDetailModal v-if="detailOpen" :open="detailOpen" :challenge="detailChallenge" :editorData="editorData"
                @close="closeDetail" @select="selectFromModal"
                @edit="onEditChallenge" @delete="onDeleteChallenge" />
        </teleport>
        <teleport to="body">
            <ChallengeCreateModal v-if="createOpen" :key="'create-challenge'" :open="createOpen" :editorData="editorData"
                :editChallengeData="editChallengeData"
                :editChallengeId="editChallengeId"
                @close="closeCreate"
                @saved="onCreated" />
        </teleport>
    </div>
</template>

<script setup>
import { computed, ref, nextTick, onMounted, onBeforeUnmount } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'
import { asLuaArray } from './start/luaTableUtils.js'
import { useMapCatalog } from "./start/useStartMaps.js"
import ChallengeDetailModal from './ChallengeDetailModal.vue'
import ChallengeCreateModal from './ChallengeCreateModal.vue'
import { getStoryBullets, mapStoryChallengeEntry } from './start/storyChallengeBullets.js'
import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { returnFocusToOpener } from '../../composables/useScreenEntryFocus'
import { acquireScope } from '../../utils/luaScopes'
import { safeLua } from '../../utils/safeLua.js'

// Diagnostics go through safeLua: each context warns once, under the Overhaul prefix.
const reportFailure = (why, error) => safeLua(() => { throw error }, why)

const events = useEvents()

const props = defineProps({
    modelValue: { type: String, default: null },
    storyLabels: { type: Boolean, default: false },
    preload: { type: Boolean, default: false },
    inline: { type: Boolean, default: false },
})
const emit = defineEmits(['update:modelValue'])

const rootRef = ref(null)
const triggerRef = ref(null)
const menuPanelRef = ref(null)
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
const { mapLabels, loadMaps: loadMapLabels } = useMapCatalog()
const loading = ref(false)
const error = ref(null)
const hasFetched = ref(false)

const difficultyOrder = { 'Easy': 0, 'Medium': 1, 'Hard': 2, 'Impossible': 3 }

const sortedChallenges = computed(() => {
    return [...challenges.value].sort((a, b) => {
        const diffA = difficultyOrder[a.difficulty || 'Medium'] ?? 99
        const diffB = difficultyOrder[b.difficulty || 'Medium'] ?? 99
        if (diffA !== diffB) {
            return diffA - diffB
        }
        return (a.name || '').localeCompare(b.name || '')
    })
})

const selectedChallenge = computed(() => challenges.value.find(c => c.id === props.modelValue))

function storyBulletsFor(challenge) {
    return getStoryBullets(challenge, mapLabels.value)
}

const refocusTrigger = () => returnFocusToOpener(() => triggerRef.value)
const refocusListOrTrigger = () => returnFocusToOpener(() =>
    (open.value && menuPanelRef.value?.querySelector('[bng-nav-item]')) || triggerRef.value)

function closeList() {
    if (!open.value) return
    open.value = false
    refocusTrigger()
}

function closeDetail() {
    detailOpen.value = false
    detailChallenge.value = null
    refocusListOrTrigger()
}

function closeCreate() {
    createOpen.value = false
    editChallengeData.value = null
    editChallengeId.value = null
    refocusListOrTrigger()
}

function toggle() {
    if (open.value) {
        closeList()
        return
    }
    open.value = true
    if (!hasFetched.value) {
        fetchChallenges()
    }
    if (!props.inline) {
        nextTick(position)
    }
}
function position() {
    const trigger = triggerRef.value
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
    if (props.inline) {
        if (rootRef.value?.contains(target)) return
    } else {
        const panel = menuPanelRef.value
        const trigger = triggerRef.value
        if (panel?.contains(target)) return
        if (trigger?.contains(target)) return
        const creator = document.querySelector('.ccm-overlay')
        const detailer = document.querySelector('.cdm-overlay')
        if (creator) return
        if (detailer) return
    }
    closeList()
}
async function fetchChallenges() {
    loading.value = true
    error.value = null
    try {
        await acquireScope(lua, 'profiles.challengeModes')

        let data = null

        if (lua.overhaul_career_challengeModes.getChallengeDropdownDataLight) {
            try {
                data = await lua.overhaul_career_challengeModes.getChallengeDropdownDataLight()
            } catch (err) {
                reportFailure('ChallengeDropdown: light fetch failed, using fallback', err)
            }
        }

        const lightList = asLuaArray(data?.challenges)
        if (lightList.length > 0) {
            editorData.value = (data.editorData && typeof data.editorData === 'object') ? data.editorData : {}
            challenges.value = lightList.map(c => mapStoryChallengeEntry(c)).filter(Boolean)
        } else {
            await lua.overhaul_career_challengeModes.discoverChallenges(true)
            const ed = await lua.overhaul_career_challengeModes.getChallengeEditorData()
            editorData.value = (ed && typeof ed === 'object') ? ed : {}
            const list = await lua.overhaul_career_challengeModes.getChallengeOptionsForCareerCreation()
            const safeList = asLuaArray(list)
            challenges.value = safeList.map(c => mapStoryChallengeEntry({
                ...c,
                winConditionName: c.winConditionName,
                hasLoans: c.hasLoans,
                loanAmount: c.loanAmount,
            })).filter(Boolean)
        }
        hasFetched.value = true
    } catch (e) {
        reportFailure('ChallengeDropdown: fetch failed', e)
        error.value = 'Failed to load challenges'
    } finally {
        loading.value = false
    }
}

function handleChallengeCreated(payload) {
    if (!payload || !payload.id) return

    const existing = challenges.value.findIndex(c => c.id === payload.id)
    const mapped = mapStoryChallengeEntry(payload)
    if (!mapped) return

    if (existing >= 0) {
        challenges.value[existing] = mapped
    } else {
        challenges.value.push(mapped)
    }
}

onMounted(() => {
    document.addEventListener('mousedown', onDocClick)
    if (!props.inline) {
        window.addEventListener('resize', position)
        window.addEventListener('scroll', position, true)
    }
    events.on('challengeCreated', handleChallengeCreated)
    if (props.storyLabels) {
        loadMapLabels()
    }
    if (props.preload) {
        fetchChallenges()
    }
})
onBeforeUnmount(() => {
    document.removeEventListener('mousedown', onDocClick)
    if (!props.inline) {
        window.removeEventListener('resize', position)
        window.removeEventListener('scroll', position, true)
    }
    events.off('challengeCreated', handleChallengeCreated)
})

function select(c) {
    emit('update:modelValue', c.id)
    open.value = false
    refocusTrigger()
}
function clear() {
    emit('update:modelValue', null)
    open.value = false
    refocusTrigger()
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
function onCreated(challengeId) {
    // The challengeCreated guihook handles adding to the list
    // We just need to select the new challenge
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
    if (props.modelValue === challengeId) {
        emit('update:modelValue', null)
    }
    const idx = challenges.value.findIndex(c => c.id === challengeId)
    if (idx >= 0) {
        challenges.value.splice(idx, 1)
    }
}

defineExpose({
    detailOpen,
    createOpen,
    isDropdownOpen: () => open.value,
    isModalOpen: () => detailOpen.value || createOpen.value || open.value,
    fetchChallenges,
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
@use "@/styles/modules/mixins" as *;

.cd-root {
    position: relative;
}

.cd-root--open {
    z-index: 5;
}

.cd-trigger {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--panel-2);
    border: 1px solid var(--panel-2);
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
    background: var(--panel-2);
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

.cd-diff-impossible {
    color: #dc2626;
    border-color: rgba(220, 38, 38, 0.5);
    background: rgba(220, 38, 38, 0.15);
}

.cd-badge-local {
    color: var(--muted);
    border-color: var(--panel-2);
    background: var(--panel-2);
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
    background: #1a1a1c;
    border: 1px solid var(--panel-2);
    border-radius: 10px;
    padding: 0.25em;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
    max-height: 28em;
    overflow: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 122, 26, 0.75) var(--line);
    font-size: calc-ui-rem();
}

.cd-content::-webkit-scrollbar { width: 10px; }
.cd-content::-webkit-scrollbar-track { background: var(--line); border-radius: 10px; }
.cd-content::-webkit-scrollbar-thumb {
    background-image: linear-gradient(180deg, #ff7a1a, #e85f00);
    border-radius: 10px;
    border: 2px solid #1a1a1c;
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

.cd-inline {
    width: 100%;
    max-height: 16em;
    z-index: 30;
}

.cd-bullets {
    display: flex;
    flex-direction: column;
    gap: 0.12em;
    margin-top: 0.2em;
}

.cd-bullet {
    color: var(--faint);
    font-size: 0.72em;
    line-height: 1.35;

    &::before {
        content: "• ";
        color: rgba(255, 122, 26, 0.85);
    }
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

.cd-item:hover,
.cd-item:focus {
    background: var(--panel-2);
    outline: none;
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
    background: var(--panel-2);
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
    color: var(--faint);
    font-size: 0.75em;
    margin-top: 0.1em;
}

.cd-time {
    color: var(--faint);
    font-size: 0.7em;
    margin-top: 0.2em;
    display: flex;
    align-items: center;
    gap: 0.25em;
}

.cd-info {
    background: transparent;
    border: 0;
    color: var(--muted);
    width: 1.75em;
    height: 1.75em;
    border-radius: 6px;
    cursor: pointer;
    flex-shrink: 0;
    aspect-ratio: 1;
}

.cd-info:hover {
    background: var(--panel-2);
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
    margin-right: 0.1em;
    transform: translateY(0.08em);
}

.cd-trigger, .cd-info { @include house-focus; }
.cd-item { @include house-focus(var(--focus-inset)); }
</style>

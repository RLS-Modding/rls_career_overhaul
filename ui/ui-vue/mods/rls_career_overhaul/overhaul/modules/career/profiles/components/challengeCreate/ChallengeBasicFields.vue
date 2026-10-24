<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="ccm-basic-section">
    <div class="ccm-grid2">
      <div class="ccm-field">
        <label>Name</label>
        <input v-bng-text-input v-model="nameModel" type="text" class="ccm-input" placeholder="My Challenge" />
      </div>
      <div class="ccm-field">
        <label>ID</label>
        <input v-bng-text-input v-model="idModel" type="text" class="ccm-input" placeholder="myChallengeId" :disabled="idLocked" />
      </div>
    </div>

    <div class="ccm-grid2">
      <div class="ccm-field">
        <label>Difficulty</label>
        <div class="ccm-difficulty-dropdown" :ref="setDifficultyContainer">
          <button
            type="button"
            class="ccm-difficulty-trigger"
            @click.stop="emit('toggleDifficulty')"
            @mousedown.stop
          >
            <span>{{ difficulty }}</span>
            <span class="ccm-difficulty-chevron">▾</span>
          </button>
          <teleport to="body">
            <div
              v-if="difficultyOpen"
              v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (emit('closeDifficulty'), false) }"
              class="rls-house menu-list scroll ccm-difficulty-content"
              :style="difficultyStyle"
              @click.stop
              @mousedown.stop
            >
              <div
                v-for="diff in difficultyOptions"
                :key="diff"
                class="menu-item ccm-difficulty-option"
                :class="{ 'ccm-difficulty-selected': diff === difficulty }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="diff === difficulty ? '' : null"
                @click.stop="emit('selectDifficulty', diff)"
                @mousedown.stop
              >
                {{ diff }}
              </div>
            </div>
          </teleport>
        </div>
      </div>
      <div class="ccm-field">
        <label>Starting Map</label>
        <div class="ccm-map-dropdown" :ref="setMapContainer">
          <button
            type="button"
            class="ccm-map-trigger"
            @click.stop="emit('toggleMap')"
            @mousedown.stop
          >
            <span>{{ mapLabel }}</span>
            <span class="ccm-map-chevron">▾</span>
          </button>
          <teleport to="body">
            <div
              v-if="mapOpen"
              v-bng-scoped-nav="{ activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (emit('closeMap'), false) }"
              class="rls-house menu-list scroll ccm-map-content"
              :style="mapStyle"
              @click.stop
              @mousedown.stop
            >
              <div
                class="menu-item ccm-map-option"
                :class="{ 'ccm-map-selected': mapId === null }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="mapId === null ? '' : null"
                @click.stop="emit('selectMap', null)"
                @mousedown.stop
              >
                Any
              </div>
              <div v-if="mapOptions.length > 0" class="ccm-map-sep"></div>
              <div
                v-for="map in mapOptions"
                :key="map.id"
                class="menu-item ccm-map-option"
                :class="{ 'ccm-map-selected': map.id === mapId }"
                role="button"
                tabindex="0"
                bng-nav-item
                :bng-scoped-nav-autofocus="map.id === mapId ? '' : null"
                @click.stop="emit('selectMap', map.id)"
                @mousedown.stop
              >
                {{ map.name }}
              </div>
            </div>
          </teleport>
        </div>
      </div>
    </div>

    <div class="ccm-field">
      <label>Description</label>
      <textarea v-bng-text-input v-model="descriptionModel" class="ccm-textarea" rows="2" />
    </div>
  </div>
</template>

<script setup>
// Name, ID, description, and the two dropdown fields. The parent owns the values and both useDropdown
// instances, and registers their listeners. Each dropdown's wrapper element is handed back through a function
// prop, so this component never writes into a ref the parent owns. The dropdown menus are teleported.
import { computed } from 'vue'
import { vBngScopedNav, vBngTextInput } from '@/common/directives'

const difficultyOptions = ['Easy', 'Medium', 'Hard', 'Impossible']

const props = defineProps({
  name: { default: '' },
  fieldId: { default: '' },
  description: { default: '' },
  idLocked: { type: Boolean, default: false },
  difficulty: { default: undefined },
  difficultyOpen: { type: Boolean, default: false },
  difficultyStyle: { default: '' },
  mapLabel: { default: undefined },
  mapId: { default: null },
  mapOptions: { type: Array, default: () => [] },
  mapOpen: { type: Boolean, default: false },
  mapStyle: { default: '' },
  setDifficultyContainer: { type: Function, required: true },
  setMapContainer: { type: Function, required: true },
})
const emit = defineEmits([
  'update:name', 'update:fieldId', 'update:description',
  'toggleDifficulty', 'selectDifficulty', 'closeDifficulty',
  'toggleMap', 'selectMap', 'closeMap',
])

const nameModel = computed({ get: () => props.name, set: value => emit('update:name', value) })
const idModel = computed({ get: () => props.fieldId, set: value => emit('update:fieldId', value) })
const descriptionModel = computed({ get: () => props.description, set: value => emit('update:description', value) })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.ccm-basic-section {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.ccm-textarea {
  resize: vertical;
}

.ccm-difficulty-dropdown,
.ccm-map-dropdown {
  position: relative;
}

.ccm-difficulty-trigger,
.ccm-map-trigger {
  appearance: none;
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  margin: 0;
  padding: 0.72em 0.8em 0.5em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  font: inherit;
  font-weight: 400;
  line-height: 1.2;
  text-align: left;
  cursor: pointer;
  &:hover {
    background: var(--panel-2);
  }
  &:focus {
    outline: none;
  }
  &.focus-visible {
    box-shadow: var(--focus);
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.ccm-difficulty-chevron,
.ccm-map-chevron {
  color: var(--faint);
  font-size: 0.9em;
}

.ccm-difficulty-content,
.ccm-map-content {
  position: fixed;
  // The shared menu owns colours, spacing, scrolling and focus; only teleport geometry differs.
  inset: auto;
  min-width: 0;
  max-height: 12.5em;
  z-index: 3001;
  font-size: inherit;
}

.ccm-difficulty-option.ccm-difficulty-selected,
.ccm-map-option.ccm-map-selected {
  color: var(--accent-soft);
}

.ccm-map-sep {
  height: 1px;
  margin: 0.25em 0.35em;
  background: rgba(255, 255, 255, 0.1);
}
</style>

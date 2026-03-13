<template>
  <PhoneWrapper app-name="Skill Details">
    <div class="phone-skill-details">
      <div v-if="loading" class="state-card">
        <div class="state-title">Loading skill details...</div>
      </div>

      <div v-else-if="error" class="state-card error">
        <div class="state-title">Could not load skill details</div>
        <button class="retry-btn" @click="refreshSkills">Retry</button>
      </div>

      <div v-else-if="!skill" class="state-card">
        <div class="state-title">Skill not found</div>
      </div>

      <template v-else>
        <section class="summary-card">
          <div class="summary-name">{{ $ctx_t(skill.name) }}</div>
          <div class="summary-row">
            <span class="summary-pill">Level {{ skill.level }}<span v-if="skill.levelCap">/{{ skill.levelCap }}</span></span>
            <span class="summary-pill">XP {{ skill.progressLabel }}</span>
          </div>
          <div class="summary-hint">{{ skill.progressHint }}</div>
        </section>

        <section v-if="skill.unlockInfo.length === 0" class="state-card">
          <div class="state-title">No unlock tiers for this skill.</div>
        </section>

        <div v-else class="tiers-list">
          <article
            v-for="tier in skill.unlockInfo"
            :key="tier.index"
            class="tier-card"
            :class="tierClass(tier)"
          >
            <div class="tier-head">
              <div class="tier-level">Level {{ tier.index }}</div>
              <div class="tier-state">{{ getTierStateLabel(tier) }}</div>
            </div>

            <div class="tier-xp">
              <span v-if="tier.isInDevelopment">Coming Soon</span>
              <span v-else>Required XP: {{ tier.xpRequired >= 0 ? tier.xpRequired : '-' }}</span>
            </div>

            <div
              v-if="tier.description.heading || tier.description.description"
              class="tier-description"
            >
              <div v-if="tier.description.heading" class="tier-description-heading">
                {{ $ctx_t(tier.description.heading) }}
              </div>
              <div v-if="tier.description.description" class="tier-description-text">
                {{ $ctx_t(tier.description.description) }}
              </div>
            </div>

            <div class="tier-unlocks">
              <div v-if="tier.list.length === 0" class="unlock-empty">No specific unlock listed.</div>

              <template v-else>
                <div
                  v-for="(item, idx) in tier.list"
                  :key="`${tier.index}-${idx}`"
                  class="unlock-item"
                >
                  <template v-if="item.type === 'tasklist' && item.tasklistData && item.tasklistData.tasks">
                    <div class="unlock-title">{{ $ctx_t(item.heading || 'Requirements') }}</div>
                    <div
                      v-for="(task, taskIdx) in item.tasklistData.tasks"
                      :key="`${tier.index}-${idx}-task-${taskIdx}`"
                      class="task-row"
                    >
                      <BngIcon
                        class="task-icon"
                        :type="task.done ? icons.checkboxOn : icons.checkboxOff"
                      />
                      <div class="task-content">
                        <div class="task-label">{{ $ctx_t(task.label) }}</div>
                        <div v-if="task.description" class="task-description">{{ $ctx_t(task.description) }}</div>
                      </div>
                    </div>
                  </template>

                  <template v-else>
                    <div class="unlock-row">
                      <BngIcon class="unlock-icon" :type="resolveUnlockIcon(item.icon)" />
                      <div>
                        <div class="unlock-title">{{ $ctx_t(item.heading || item.label || 'Unlock') }}</div>
                        <div v-if="item.description" class="unlock-description">{{ $ctx_t(item.description) }}</div>
                      </div>
                    </div>
                  </template>
                </div>
              </template>
            </div>
          </article>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { BngIcon, icons } from '@/common/components/base'
import PhoneWrapper from './PhoneWrapper.vue'
import { usePhoneSkillsData } from '../composables/usePhoneSkillsData'

const route = useRoute()
const { loading, error, loadPhoneSkills, hydratePhoneSkillDetails, getPhoneSkillById } = usePhoneSkillsData()

function parseSkillId(value) {
  if (value == null) return ''
  const raw = String(value)
  try {
    return decodeURIComponent(raw).trim()
  } catch (_) {
    return raw.trim()
  }
}

const skillId = computed(() => parseSkillId(route.params.skillId))
const skill = computed(() => getPhoneSkillById(skillId.value))

function isTierUnlocked(tier) {
  if (!skill.value) return false
  return skill.value.level >= tier.index
}

function getTierStateLabel(tier) {
  if (!skill.value) return 'Locked'
  if (isTierUnlocked(tier)) return 'Unlocked'
  if (skill.value.level + 1 === tier.index) return 'Next'
  return 'Locked'
}

function tierClass(tier) {
  if (!skill.value) return 'locked'
  if (isTierUnlocked(tier)) return 'unlocked'
  if (skill.value.level + 1 === tier.index) return 'next'
  return 'locked'
}

function resolveUnlockIcon(iconName) {
  if (typeof iconName === 'string' && icons[iconName]) {
    return icons[iconName]
  }
  return icons.info
}

async function refreshSkills() {
  try {
    await loadPhoneSkills(true)
  } catch (_) {
    // Handled by shared error state.
  }
}

onMounted(async () => {
  try {
    await loadPhoneSkills()
    await hydratePhoneSkillDetails(skillId.value)
  } catch (_) {
    // Handled by shared error state.
  }
})

watch(() => route.params.skillId, async () => {
  try {
    if (!skill.value && !loading.value) {
      await loadPhoneSkills()
    }
    await hydratePhoneSkillDetails(skillId.value)
  } catch (_) {
    // Handled by shared error state.
  }
})
</script>

<style scoped lang="scss">
.phone-skill-details {
  height: 100%;
  overflow-y: auto;
  padding: calc(2.45rem + env(safe-area-inset-top, 0px)) 0.75rem 0.75rem;
  background: linear-gradient(180deg, #0b1220 0%, #101826 100%);
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
}

.summary-card {
  border: 1px solid rgba(112, 145, 210, 0.5);
  border-radius: 0.75rem;
  background: linear-gradient(160deg, rgba(36, 55, 88, 0.95), rgba(20, 30, 48, 0.95));
  padding: 0.75rem;
}

.summary-name {
  color: #f3f8ff;
  font-size: 0.95rem;
  font-weight: 800;
  line-height: 1.2;
}

.summary-row {
  margin-top: 0.5rem;
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
}

.summary-pill {
  border: 1px solid rgba(145, 185, 255, 0.5);
  border-radius: 999px;
  padding: 0.2rem 0.48rem;
  color: #d4e6ff;
  font-size: 0.73rem;
  font-weight: 700;
}

.summary-hint {
  margin-top: 0.4rem;
  color: #9ec0ef;
  font-size: 0.72rem;
}

.tiers-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding-bottom: 0.5rem;
}

.tier-card {
  border-radius: 0.7rem;
  padding: 0.6rem;
  border: 1px solid rgba(88, 104, 138, 0.4);
  background: rgba(14, 22, 37, 0.95);
}

.tier-card.unlocked {
  border-color: rgba(94, 224, 163, 0.55);
  background: linear-gradient(170deg, rgba(20, 50, 42, 0.75), rgba(14, 22, 37, 0.95));
}

.tier-card.next {
  border-color: rgba(123, 169, 255, 0.75);
  background: linear-gradient(170deg, rgba(27, 45, 72, 0.85), rgba(14, 22, 37, 0.95));
}

.tier-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.5rem;
}

.tier-level {
  color: #f1f6ff;
  font-size: 0.8rem;
  font-weight: 800;
}

.tier-state {
  color: #b3ccf8;
  font-size: 0.7rem;
  font-weight: 700;
  text-transform: uppercase;
}

.tier-xp {
  margin-top: 0.3rem;
  color: #95b8ef;
  font-size: 0.68rem;
  font-weight: 600;
}

.tier-description {
  margin-top: 0.35rem;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding-top: 0.35rem;
}

.tier-description-heading {
  color: #e6efff;
  font-size: 0.72rem;
  font-weight: 700;
}

.tier-description-text {
  margin-top: 0.16rem;
  color: #bdd0f2;
  font-size: 0.69rem;
}

.tier-unlocks {
  margin-top: 0.45rem;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
}

.unlock-item {
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5rem;
  background: rgba(4, 9, 18, 0.55);
  padding: 0.45rem;
}

.unlock-row {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.45rem;
  align-items: start;
}

.unlock-icon {
  font-size: 1.05rem;
  color: #99bcf2;
  margin-top: 0.05rem;
}

.unlock-title {
  color: #e9f1ff;
  font-size: 0.71rem;
  font-weight: 700;
  line-height: 1.2;
}

.unlock-description {
  margin-top: 0.14rem;
  color: #b6c9ea;
  font-size: 0.67rem;
  line-height: 1.2;
}

.task-row {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.38rem;
  align-items: start;
  margin-top: 0.3rem;
}

.task-row:first-of-type {
  margin-top: 0.35rem;
}

.task-icon {
  font-size: 0.93rem;
  color: #94b7ef;
  margin-top: 0.08rem;
}

.task-content {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
}

.task-label {
  color: #deebff;
  font-size: 0.68rem;
  font-weight: 700;
}

.task-description {
  color: #aac0e5;
  font-size: 0.64rem;
}

.unlock-empty {
  color: #93a8c9;
  font-size: 0.66rem;
}

.state-card {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 0.75rem;
  background: rgba(10, 16, 29, 0.92);
  padding: 0.9rem;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
}

.state-card.error {
  border-color: rgba(255, 107, 107, 0.65);
}

.state-title {
  font-size: 0.85rem;
  color: #e7edf9;
  text-align: center;
}

.retry-btn {
  border: 1px solid rgba(145, 186, 255, 0.8);
  border-radius: 0.55rem;
  background: rgba(37, 74, 132, 0.9);
  color: #f5f9ff;
  font-size: 0.76rem;
  font-weight: 600;
  padding: 0.35rem 0.7rem;
}
</style>

<template>
  <div class="phone-skill-details" :class="{ 'classic-theme': isClassicTheme }">
    <div v-if="loading" class="state-card">
      <div class="state-title">Loading skill...</div>
    </div>

    <div v-else-if="error" class="state-card error">
      <div class="state-title">Could not load skill</div>
      <button class="action-btn" @click="refreshSkills">Retry</button>
    </div>

    <div v-else-if="!skill" class="state-card">
      <div class="state-title">Skill not found</div>
    </div>

    <template v-else>
      <section class="skill-hero">
        <div class="hero-heading">
          <BngIcon class="hero-icon" :type="resolveUnlockIcon(skill.icon)" />
          <div class="hero-copy">
            <div class="hero-name">{{ $ctx_t(skill.name) }}</div>
            <div class="hero-description">{{ $ctx_t(skill.description || 'Complete activities to build this discipline.') }}</div>
          </div>
          <div class="level-badge">
            <span>LV</span>
            <strong>{{ skill.level }}</strong>
            <small v-if="skill.levelCap">/{{ skill.levelCap }}</small>
          </div>
        </div>

        <div class="xp-heading">
          <span>{{ skill.isMaxLevel ? 'Mastered' : `${skill.xpCurrent} / ${skill.xpNeeded} XP` }}</span>
          <span v-if="!skill.isMaxLevel">Next: LV {{ skill.level + 1 }}</span>
        </div>
        <div class="xp-track" aria-hidden="true">
          <div class="xp-fill" :style="{ width: `${skillProgress}%` }"></div>
        </div>

        <div class="hero-actions">
        <button v-if="hasContractLicenses" class="contracts-link" @click="openLicenses">
          <span>Contracts, sponsors &amp; licenses</span>
          <span class="link-arrow">›</span>
        </button>
        <button
          class="theme-btn"
          type="button"
          :aria-pressed="isClassicTheme"
          @click="toggleSkillsTheme"
        >
          {{ isClassicTheme ? 'Modern look' : 'Classic look' }}
        </button>
        </div>
      </section>

      <section class="reward-section">
        <div class="section-heading">
          <div>
            <div class="section-title">Reward Track</div>
            <div class="section-subtitle">{{ rewardTrackSummary }}</div>
          </div>
          <button class="track-toggle" @click="showFullTrack = !showFullTrack">
            {{ showFullTrack ? 'Focus' : 'View all' }}
          </button>
        </div>

        <div v-if="!skill.unlockInfo || skill.unlockInfo.length === 0" class="empty-track">No level rewards listed.</div>

        <div v-else class="reward-track">
          <div v-if="!showFullTrack && earlierTierCount > 0" class="track-summary-row">
            <BngIcon :type="icons.checkboxOn" />
            <span>{{ earlierTierCount }} earlier level{{ earlierTierCount === 1 ? '' : 's' }} complete</span>
          </div>

          <article
            v-for="tier in visibleTiers"
            :key="tier.index"
            class="reward-row"
            :class="tierClass(tier)"
          >
            <div class="level-marker">
              <BngIcon v-if="isTierUnlocked(tier)" :type="icons.checkboxOn" />
              <span v-else>{{ tier.index }}</span>
            </div>

            <div class="reward-copy">
              <div class="reward-level">
                LV {{ tier.index }}
                <span v-if="isNextTier(tier)" class="next-label">NEXT</span>
              </div>

              <div v-if="tier.list.length" class="reward-items">
                <div v-for="(item, idx) in tier.list" :key="`${tier.index}-${idx}`" class="reward-item">
                  <template v-if="item.type === 'tasklist' && item.tasklistData?.tasks?.length">
                    <span>{{ $ctx_t(item.heading || 'Requirements') }}</span>
                    <small>{{ item.tasklistData.tasks.map(task => $ctx_t(task.label)).join(' • ') }}</small>
                  </template>
                  <template v-else>
                    <span>{{ $ctx_t(item.heading || item.label || 'Reward') }}</span>
                  </template>
                </div>
              </div>
              <div v-else class="reward-item muted">No new reward</div>
            </div>

            <div class="reward-xp">
              <span v-if="tier.isInDevelopment">SOON</span>
              <span v-else-if="tier.xpRequired >= 0">{{ formatNumber(tier.xpRequired) }}</span>
              <small v-if="!tier.isInDevelopment && tier.xpRequired >= 0">XP</small>
            </div>
          </article>

          <button v-if="!showFullTrack && hiddenTierCount > 0" class="show-more" @click="showFullTrack = true">
            Show {{ hiddenTierCount }} more level{{ hiddenTierCount === 1 ? '' : 's' }}
          </button>
        </div>
      </section>
    </template>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../../utils/safeLua"

import { computed, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { BngIcon, icons } from '@/common/components/base'
import { lua } from '@/bridge'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { usePhoneSkillsData } from '../../composables/usePhoneSkillsData'
import { useSkillsTheme } from '../../composables/useSkillsTheme'

const route = useRoute()
const { loading, error, loadPhoneSkills, hydratePhoneSkillDetails, getPhoneSkillById } = usePhoneSkillsData()
const { isClassicTheme, toggleSkillsTheme } = useSkillsTheme()
const showFullTrack = ref(false)

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
const licenseSkillIds = new Set([
  'careerSkills-offroad', 'careerSkills-speed', 'careerSkills-mayhem', 'careerSkills-circuitRacing',
  'careerSkills-drag', 'careerSkills-drift', 'careerSkills-roadracing',
  'offroad', 'speed', 'mayhem', 'circuitRacing', 'drag', 'drift', 'roadracing',
])
const hasContractLicenses = computed(() => licenseSkillIds.has(skillId.value))

const skillProgress = computed(() => {
  if (skill.value?.isMaxLevel) return 100
  const needed = Number(skill.value?.xpNeeded || 0)
  if (needed <= 0) return 0
  return Math.max(0, Math.min(100, (Number(skill.value?.xpCurrent || 0) / needed) * 100))
})

const currentTierIndex = computed(() => {
  const tiers = skill.value?.unlockInfo || []
  if (!tiers.length) return 0
  return Math.max(1, Math.min(Number(skill.value?.level || 1), tiers.length))
})

const focusedTiers = computed(() => {
  const tiers = skill.value?.unlockInfo || []
  if (!tiers.length) return []
  const currentPosition = tiers.findIndex(tier => tier.index === currentTierIndex.value)
  const start = currentPosition >= 0 ? currentPosition : 0
  return tiers.slice(start, start + 7)
})

const visibleTiers = computed(() => (
  showFullTrack.value ? (skill.value?.unlockInfo || []) : focusedTiers.value
))

const earlierTierCount = computed(() => Math.max(0, currentTierIndex.value - 1))
const hiddenTierCount = computed(() => Math.max(0, (skill.value?.unlockInfo?.length || 0) - focusedTiers.value.length - earlierTierCount.value))
const rewardTrackSummary = computed(() => {
  if (skill.value?.isMaxLevel) return 'All levels complete'
  return `Level ${skill.value?.level || 1} of ${skill.value?.levelCap || skill.value?.unlockInfo?.length || '?'}`
})

function isTierUnlocked(tier) {
  return Number(skill.value?.level || 0) >= Number(tier.index || 0)
}

function isNextTier(tier) {
  return Number(skill.value?.level || 0) + 1 === Number(tier.index || 0)
}

function tierClass(tier) {
  if (isNextTier(tier)) return 'next'
  return isTierUnlocked(tier) ? 'unlocked' : 'locked'
}

function resolveUnlockIcon(iconName) {
  if (typeof iconName === 'string' && icons[iconName]) return icons[iconName]
  return icons.star
}

function formatNumber(value) {
  return Math.max(0, Number(value || 0)).toLocaleString('en-US')
}

async function openLicenses() {
  const defaultLane = {
    'careerSkills-offroad': 'offroad', 'careerSkills-speed': 'drag',
    'careerSkills-mayhem': 'drift', 'careerSkills-circuitRacing': 'roadracing',
    'careerSkills-drag': 'drag', 'careerSkills-drift': 'drift', 'careerSkills-roadracing': 'roadracing',
    offroad: 'offroad', drag: 'drag', drift: 'drift', roadracing: 'roadracing',
  }[skillId.value]
  if (defaultLane) {
    try { localStorage.setItem('phoneFreContracts:selectedDiscipline', defaultLane) } catch (_) { reportUiFailure(_, "open licenses (PhoneSkillDetails)") }
  }
  await lua.extensions.ui_router.navigate('phone-fre-contracts')
}

async function refreshSkills() {
  try {
    await loadPhoneSkills(true)
    await hydratePhoneSkillDetails(skillId.value)
  } catch (_) { reportUiFailure(_, "refresh skills (PhoneSkillDetails)") }
}

async function loadDetails() {
  try {
    await loadPhoneSkills()
    await hydratePhoneSkillDetails(skillId.value)
  } catch (_) { reportUiFailure(_, "load details (PhoneSkillDetails)") }
}

onMounted(loadDetails)

watch(() => route.params.skillId, async () => {
  showFullTrack.value = false
  await loadDetails()
})
usePhoneScreen({ title: computed(() => skill.value?.name || 'Skill') })
</script>

<style scoped lang="scss">
.phone-skill-details {
  height: 100%;
  overflow-y: auto;
  padding: calc(2.45rem + env(safe-area-inset-top, 0px)) 0.58rem 0.8rem;
  display: flex;
  flex-direction: column;
  gap: 0.58rem;
  background:
    radial-gradient(circle at 100% 0%, rgba(255, 102, 0, 0.1), transparent 34%),
    linear-gradient(180deg, #0d0f12 0%, #15181c 100%);
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 105, 0, 0.7) rgba(255, 255, 255, 0.05);
}

.skill-hero,
.reward-section {
  position: relative;
  flex: 0 0 auto;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 0.58rem;
  background: linear-gradient(145deg, rgba(31, 34, 38, 0.98), rgba(16, 18, 21, 0.98));
}

.skill-hero::after {
  content: '';
  position: absolute;
  inset: 0;
  background: linear-gradient(120deg, transparent 62%, rgba(255, 255, 255, 0.035) 62% 74%, transparent 74%);
  pointer-events: none;
}

.skill-hero {
  padding: 0.72rem;
  border-left: 3px solid #ff6500;
}

.hero-heading {
  position: relative;
  z-index: 1;
  display: grid;
  grid-template-columns: 2rem minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.55rem;
}

.hero-icon {
  color: #ff6900;
  font-size: 1.95rem;
}

.hero-copy {
  min-width: 0;
}

.hero-name {
  color: #f7f7f7;
  font-size: 1.15rem;
  font-weight: 850;
  line-height: 1;
}

.hero-description {
  margin-top: 0.22rem;
  color: #aeb2b7;
  font-size: 0.61rem;
  line-height: 1.25;
}

.level-badge {
  min-width: 2.55rem;
  padding: 0.28rem 0.34rem;
  display: flex;
  align-items: baseline;
  justify-content: center;
  gap: 0.12rem;
  border: 1px solid rgba(255, 105, 0, 0.55);
  border-radius: 0.38rem;
  background: rgba(0, 0, 0, 0.42);
  color: #ff7a18;
}

.level-badge span,
.level-badge small {
  font-size: 0.48rem;
  font-weight: 800;
}

.level-badge strong {
  font-size: 0.92rem;
  line-height: 1;
}

.xp-heading {
  position: relative;
  z-index: 1;
  margin-top: 0.7rem;
  display: flex;
  justify-content: space-between;
  color: #d3d5d8;
  font-size: 0.58rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.xp-track {
  position: relative;
  z-index: 1;
  height: 0.38rem;
  margin-top: 0.3rem;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.72);
}

.xp-fill {
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, #ff5700, #ffa23e);
  box-shadow: 0 0 0.45rem rgba(255, 95, 0, 0.65);
}

.hero-actions {
  position: relative;
  z-index: 1;
  margin-top: 0.65rem;
  display: flex;
  align-items: stretch;
  gap: 0.38rem;
}

.contracts-link {
  position: relative;
  z-index: 1;
  flex: 1 1 auto;
  padding: 0.42rem 0.55rem;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: 1px solid rgba(255, 105, 0, 0.48);
  border-radius: 0.38rem;
  background: rgba(255, 99, 0, 0.09);
  color: #f0f0f0;
  font-size: 0.65rem;
  font-weight: 750;
  text-align: left;
}

.theme-btn {
  flex: 0 0 auto;
  padding: 0.42rem 0.5rem;
  border: 1px solid rgba(255, 105, 0, 0.48);
  border-radius: 0.38rem;
  background: rgba(255, 99, 0, 0.09);
  color: #ff8a2b;
  font-size: 0.56rem;
  font-weight: 800;
  white-space: nowrap;
  cursor: pointer;
}

.theme-btn:hover,
.theme-btn.focus-visible {
  background: rgba(255, 99, 0, 0.18);
  outline: none;
}

.contracts-link:hover,
.contracts-link.focus-visible {
  background: rgba(255, 99, 0, 0.18);
  outline: none;
}

.link-arrow {
  color: #ff7200;
  font-size: 1.05rem;
  line-height: 0.7;
}

.reward-section {
  padding: 0.68rem;
}

.section-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.7rem;
  padding-bottom: 0.55rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.section-title {
  color: #f4f4f4;
  font-size: 0.82rem;
  font-weight: 850;
  text-transform: uppercase;
  letter-spacing: 0.035em;
}

.section-subtitle {
  margin-top: 0.08rem;
  color: #8f949a;
  font-size: 0.57rem;
}

.track-toggle,
.show-more,
.action-btn {
  border: 1px solid rgba(255, 105, 0, 0.55);
  border-radius: 0.34rem;
  background: rgba(255, 101, 0, 0.1);
  color: #ff8a2b;
  font-size: 0.59rem;
  font-weight: 800;
  padding: 0.32rem 0.52rem;
}

.reward-track {
  display: flex;
  flex-direction: column;
}

.track-summary-row {
  display: flex;
  align-items: center;
  gap: 0.38rem;
  padding: 0.46rem 0.16rem;
  color: #8d9298;
  font-size: 0.58rem;
  font-weight: 700;
}

.track-summary-row :deep(svg) {
  color: #ff6900;
}

.reward-row {
  position: relative;
  display: grid;
  grid-template-columns: 1.5rem minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.48rem;
  min-height: 3.25rem;
  padding: 0.42rem 0.18rem;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}

.reward-row.next {
  margin: 0.16rem -0.2rem;
  padding: 0.5rem 0.38rem;
  border: 1px solid rgba(255, 105, 0, 0.58);
  border-radius: 0.38rem;
  background: linear-gradient(90deg, rgba(255, 91, 0, 0.13), rgba(255, 121, 0, 0.035));
}

.reward-row.locked {
  opacity: 0.74;
}

.level-marker {
  width: 1.48rem;
  height: 1.48rem;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid rgba(255, 255, 255, 0.22);
  border-radius: 50%;
  background: #111316;
  color: #b7bbc0;
  font-size: 0.59rem;
  font-weight: 850;
}

.reward-row.unlocked .level-marker,
.reward-row.next .level-marker {
  border-color: #ff6900;
  color: #ff7200;
}

.reward-copy {
  min-width: 0;
}

.reward-level {
  color: #91969c;
  font-size: 0.5rem;
  font-weight: 850;
  letter-spacing: 0.05em;
}

.next-label {
  margin-left: 0.24rem;
  color: #ff7200;
}

.reward-items {
  margin-top: 0.12rem;
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
}

.reward-item {
  color: #e6e6e6;
  font-size: 0.66rem;
  font-weight: 720;
  line-height: 1.15;
}

.reward-item small {
  display: block;
  margin-top: 0.12rem;
  color: #92979d;
  font-size: 0.53rem;
  font-weight: 600;
}

.reward-item.muted {
  color: #74797f;
  font-weight: 600;
}

.reward-xp {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  color: #b8bbc0;
  font-size: 0.59rem;
  font-weight: 800;
  white-space: nowrap;
}

.reward-xp small {
  color: #71767c;
  font-size: 0.45rem;
}

.show-more {
  width: 100%;
  margin-top: 0.48rem;
}

.empty-track,
.state-card {
  padding: 0.85rem;
  color: #aeb2b7;
  font-size: 0.68rem;
  text-align: center;
}

.state-card {
  margin-top: 0.5rem;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 0.5rem;
  background: rgba(15, 17, 20, 0.96);
}

.state-card.error {
  border-color: rgba(255, 98, 74, 0.65);
}

.state-title + .action-btn {
  margin-top: 0.55rem;
}

.phone-skill-details.classic-theme {
  box-sizing: border-box;
  padding-right: 0.5rem;
  padding-left: 0.5rem;
  border: 0.42rem solid transparent;
  border-radius: 0.9rem;
  background:
    repeating-linear-gradient(0deg, rgba(255, 255, 255, 0.018) 0 1px, transparent 1px 4px) padding-box,
    radial-gradient(circle at 30% 10%, rgba(112, 96, 61, 0.14), transparent 34%) padding-box,
    linear-gradient(#171712, #171712) padding-box,
    repeating-linear-gradient(90deg, #716a56 0 2.4rem, #2e2c24 2.4rem 2.55rem, #4d493c 2.55rem 4.8rem, #24231c 4.8rem 4.95rem) top left / 100% 0.42rem no-repeat border-box,
    repeating-linear-gradient(90deg, #4d493c 0 2.4rem, #24231c 2.4rem 2.55rem, #716a56 2.55rem 4.8rem, #2e2c24 4.8rem 4.95rem) bottom left / 100% 0.42rem no-repeat border-box,
    repeating-linear-gradient(0deg, #716a56 0 2.2rem, #2e2c24 2.2rem 2.35rem, #4d493c 2.35rem 4.5rem, #24231c 4.5rem 4.65rem) top left / 0.42rem 100% no-repeat border-box,
    repeating-linear-gradient(0deg, #4d493c 0 2.2rem, #24231c 2.2rem 2.35rem, #716a56 2.35rem 4.5rem, #2e2c24 4.5rem 4.65rem) top right / 0.42rem 100% no-repeat border-box,
    linear-gradient(#5b5545, #302e26) border-box;
  box-shadow:
    0 0 0 2px #17150f,
    inset 0 0 0 2px #847b64,
    inset 0 0 0 5px #2a2820,
    inset 0.2rem 0.2rem 0.45rem rgba(0, 0, 0, 0.55);
  scrollbar-color: #9b7a28 #17140e;
  font-family: var(--fnt-mono, "Courier New", monospace);
}

.classic-theme .skill-hero,
.classic-theme .reward-section {
  border: 0.34rem solid transparent;
  border-radius: 0.72rem;
  background:
    repeating-linear-gradient(135deg, rgba(255, 255, 255, 0.014) 0 1px, transparent 1px 5px) padding-box,
    linear-gradient(145deg, #34332c, #23231d) padding-box,
    repeating-linear-gradient(90deg, #6f6854 0 2.7rem, #29271f 2.7rem 2.84rem, #504c3e 2.84rem 5.4rem, #25231c 5.4rem 5.55rem) top left / 100% 0.34rem no-repeat border-box,
    repeating-linear-gradient(90deg, #504c3e 0 2.7rem, #25231c 2.7rem 2.84rem, #6f6854 2.84rem 5.4rem, #29271f 5.4rem 5.55rem) bottom left / 100% 0.34rem no-repeat border-box,
    repeating-linear-gradient(0deg, #6f6854 0 2.7rem, #29271f 2.7rem 2.84rem, #504c3e 2.84rem 5.4rem, #25231c 5.4rem 5.55rem) top left / 0.34rem 100% no-repeat border-box,
    repeating-linear-gradient(0deg, #504c3e 0 2.7rem, #25231c 2.7rem 2.84rem, #6f6854 2.84rem 5.4rem, #29271f 5.4rem 5.55rem) top right / 0.34rem 100% no-repeat border-box,
    linear-gradient(#575141, #2b2921) border-box;
  box-shadow: 0 0 0 2px #12120e, inset 0 0 0 2px #92886e, 0 0.2rem 0.4rem rgba(0, 0, 0, 0.45);
}

.classic-theme .skill-hero {
  border-left-width: 3px;
}

.classic-theme .skill-hero::after {
  display: none;
}

.classic-theme .hero-icon {
  color: #c9bd94;
  filter: drop-shadow(2px 2px #000);
}

.classic-theme .hero-name,
.classic-theme .section-title {
  color: #f0ce46;
  font-family: var(--fnt-mono, "Courier New", monospace);
  text-shadow: 1px 1px #000;
}

.classic-theme .hero-description,
.classic-theme .section-subtitle,
.classic-theme .xp-heading {
  color: #ded5bf;
  text-shadow: 1px 1px #000;
}

.classic-theme .level-badge {
  border: 2px solid #9a8135;
  border-radius: 0.28rem;
  background: #24231d;
  box-shadow: inset 1px 1px #c1aa62, inset -1px -1px #0c0c09;
  color: #f0ce46;
  text-shadow: 1px 1px #000;
}

.classic-theme .xp-track {
  height: 0.42rem;
  border: 2px solid #080906;
  border-radius: 0.18rem;
  background: #080a07;
  box-shadow: 0 0 0 1px #5d594b;
}

.classic-theme .xp-fill {
  border-radius: 0.08rem;
  background: linear-gradient(90deg, #4f8d20, #9bc344);
  box-shadow: inset 0 1px rgba(255, 255, 255, 0.32);
}

.classic-theme .contracts-link,
.classic-theme .theme-btn,
.classic-theme .track-toggle,
.classic-theme .show-more,
.classic-theme .action-btn {
  border: 2px solid #8d7837;
  border-radius: 0.28rem;
  background: linear-gradient(#4b4739, #28271f);
  box-shadow: inset 1px 1px #c0aa65, inset -1px -1px #111;
  color: #f0ce4b;
  text-shadow: 1px 1px #000;
}

.classic-theme .section-heading {
  border-bottom-color: #6e6856;
}

.classic-theme .track-summary-row {
  color: #bcb39f;
}

.classic-theme .track-summary-row :deep(svg) {
  color: #76a83c;
}

.classic-theme .reward-row {
  border-top-color: #514e41;
}

.classic-theme .reward-row.next {
  border: 2px solid #c29d2b;
  border-radius: 0.38rem;
  background: linear-gradient(90deg, rgba(136, 107, 28, 0.28), rgba(59, 52, 33, 0.2));
  box-shadow: inset 1px 1px #ead16c, inset -1px -1px #17130a;
}

.classic-theme .reward-row.locked {
  opacity: 0.68;
}

.classic-theme .level-marker {
  border: 2px solid #5e594a;
  border-radius: 0.28rem;
  background: #191913;
  color: #d8cfba;
  box-shadow: inset 1px 1px #77705b, inset -1px -1px #080806;
}

.classic-theme .reward-row.unlocked .level-marker,
.classic-theme .reward-row.next .level-marker,
.classic-theme .next-label {
  border-color: #b79631;
  color: #f0ce46;
}

.classic-theme .reward-level,
.classic-theme .reward-xp {
  color: #bdb49e;
}

.classic-theme .reward-item {
  color: #eee5d1;
  text-shadow: 1px 1px #000;
}

.classic-theme .reward-item small,
.classic-theme .reward-xp small,
.classic-theme .reward-item.muted {
  color: #a69e8c;
}
</style>

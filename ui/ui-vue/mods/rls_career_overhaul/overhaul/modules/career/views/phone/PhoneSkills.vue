<template>
  <div class="phone-skills" :class="{ 'classic-theme': isClassicTheme }">
    <div v-if="loading" class="state-card">
      <div class="state-title">{{ $ctx_t('Loading skills...') }}</div>
    </div>

    <div v-else-if="error" class="state-card error">
      <div class="state-title">{{ $ctx_t('Could not load skills') }}</div>
      <button class="retry-btn" @click="refreshSkills">{{ $ctx_t('Retry') }}</button>
    </div>

    <div v-else-if="skills.length === 0" class="state-card">
      <div class="state-title">{{ $ctx_t('No skills found') }}</div>
    </div>

    <template v-else>
      <div class="skills-intro">
        <BngIcon class="intro-icon" :type="icons.info" />
        <span>{{ $ctx_t('Activities build their parent skill. Higher levels improve rewards and unlock jobs.') }}</span>
        <button
          class="theme-btn"
          type="button"
          :aria-pressed="isClassicTheme"
          @click="toggleSkillsTheme"
        >
          {{ $ctx_t(isClassicTheme ? 'Modern look' : 'Classic look') }}
        </button>
      </div>

      <div class="skills-grid">
        <button
          v-for="skill in rootSkills"
          :key="skill.id"
          class="skill-card"
          @click="openSkill(skill.id)"
        >
          <BngIcon class="skill-icon" :type="resolveSkillIcon(skill.icon)" />

          <div class="skill-copy">
            <div class="skill-name">{{ $ctx_t(skill.name) }}</div>
            <div class="skill-stats">
              <span>{{ $ctx_t('LV') }} {{ skill.level }}</span>
              <span class="stat-divider"></span>
              <span>{{ skill.isMaxLevel ? 'MAX' : `${skill.xpCurrent} / ${skill.xpNeeded} XP` }}</span>
            </div>
            <div class="progress-track" aria-hidden="true">
              <div class="progress-fill" :style="{ width: `${skillProgress(skill)}%` }"></div>
            </div>
          </div>

          <span class="skill-arrow">›</span>
        </button>
      </div>

      <div class="skills-footer">
        <span>{{ rootSkills.length }} {{ $ctx_t('disciplines') }}</span>
        <span>{{ $ctx_t('One shared progression system') }}</span>
      </div>
    </template>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../../utils/safeLua"

import { onMounted } from 'vue'
import { BngIcon, icons } from '@/common/components/base'
import { lua } from '@/bridge'
import { usePhoneSkillsData } from '../../composables/usePhoneSkillsData'
import { useSkillsTheme } from '../../composables/useSkillsTheme'

const {
  skills,
  rootSkills,
  loading,
  error,
  loadPhoneSkills,
} = usePhoneSkillsData()
const { isClassicTheme, toggleSkillsTheme } = useSkillsTheme()

async function refreshSkills() {
  try {
    await loadPhoneSkills(true)
  } catch (_) { reportUiFailure(_, "refresh skills (PhoneSkills)") }
}

function openSkill(skillId) {
  lua.extensions.ui_router.navigate('phone-skills-details', { skillId })
}

function resolveSkillIcon(iconName) {
  if (typeof iconName === 'string' && icons[iconName]) return icons[iconName]
  return icons.star
}

function skillProgress(skill) {
  if (skill?.isMaxLevel) return 100
  const needed = Number(skill?.xpNeeded || 0)
  if (needed <= 0) return 0
  return Math.max(0, Math.min(100, (Number(skill?.xpCurrent || 0) / needed) * 100))
}

onMounted(async () => {
  try {
    // Skill data is shared at module scope so navigating away preserves the
    // list. Always refresh when the app is opened, however, because rewards
    // can change XP (and even the current level bounds) while the cache lives.
    await loadPhoneSkills(true)
  } catch (_) { reportUiFailure(_, "optional action (PhoneSkills)") }
})
</script>

<style scoped lang="scss">
.phone-skills {
  height: 100%;
  overflow-y: auto;
  padding: calc(2.45rem + env(safe-area-inset-top, 0px)) 0.55rem 0.75rem;
  background:
    radial-gradient(circle at 100% 0%, rgba(255, 102, 0, 0.09), transparent 34%),
    linear-gradient(180deg, #0d0f12 0%, #15181c 100%);
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 105, 0, 0.7) rgba(255, 255, 255, 0.05);
}

.skills-intro {
  position: relative;
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  gap: 0.55rem;
  margin-bottom: 0.55rem;
  padding: 0.58rem 0.68rem;
  border: 1px solid rgba(255, 255, 255, 0.13);
  border-left: 3px solid #ff6500;
  border-radius: 0.45rem;
  background: linear-gradient(110deg, rgba(28, 31, 35, 0.98), rgba(17, 19, 22, 0.98));
  color: #cdd1d6;
  font-size: 0.66rem;
  line-height: 1.3;
}

.intro-icon {
  color: #ff6a00;
  font-size: 1.15rem;
}

.theme-btn {
  flex: 0 0 auto;
  padding: 0.3rem 0.42rem;
  border: 1px solid rgba(255, 105, 0, 0.58);
  border-radius: 0.34rem;
  background: rgba(255, 101, 0, 0.1);
  color: #ff8a2b;
  font-size: 0.54rem;
  font-weight: 800;
  white-space: nowrap;
  cursor: pointer;
}

.theme-btn:hover,
.theme-btn.focus-visible {
  background: rgba(255, 101, 0, 0.2);
  outline: none;
}

.skills-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.42rem;
}

.skill-card {
  position: relative;
  isolation: isolate;
  overflow: hidden;
  min-height: 5.15rem;
  padding: 0.58rem 1.15rem 0.5rem 0.55rem;
  display: grid;
  grid-template-columns: 1.7rem minmax(0, 1fr);
  align-items: center;
  gap: 0.45rem;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 0.55rem;
  background: linear-gradient(145deg, rgba(31, 34, 38, 0.98), rgba(16, 18, 21, 0.98));
  color: #f3f3f3;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.14s ease, background 0.14s ease, transform 0.1s ease;
}

.skill-card::after {
  content: '';
  position: absolute;
  inset: 0;
  z-index: -1;
  background: linear-gradient(120deg, transparent 62%, rgba(255, 255, 255, 0.035) 62% 73%, transparent 73%);
  pointer-events: none;
}

.skill-card:hover,
.skill-card.focus-visible {
  border-color: rgba(255, 111, 0, 0.75);
  background: linear-gradient(145deg, rgba(40, 39, 37, 0.98), rgba(18, 19, 21, 0.98));
  outline: none;
}

.skill-card:active {
  transform: translateY(1px);
}

.skill-icon {
  color: #ff6900;
  font-size: 1.65rem;
  filter: drop-shadow(0 0 0.28rem rgba(255, 92, 0, 0.18));
}

.skill-copy {
  min-width: 0;
}

.skill-name {
  min-height: 1.72rem;
  display: flex;
  align-items: flex-end;
  color: #f7f7f7;
  font-size: 0.88rem;
  font-weight: 800;
  line-height: 0.98;
  letter-spacing: -0.015em;
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
}

.skill-stats {
  margin-top: 0.32rem;
  display: flex;
  align-items: center;
  gap: 0.32rem;
  min-width: 0;
  color: #c8cbd0;
  font-size: 0.54rem;
  font-weight: 700;
  white-space: nowrap;
}

.stat-divider {
  width: 1px;
  height: 0.65rem;
  background: rgba(255, 255, 255, 0.25);
}

.progress-track {
  height: 0.24rem;
  margin-top: 0.38rem;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.65);
}

.progress-fill {
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, #ff5700, #ff9b2f);
  box-shadow: 0 0 0.35rem rgba(255, 100, 0, 0.6);
}

.skill-arrow {
  position: absolute;
  right: 0.42rem;
  top: 50%;
  transform: translateY(-53%);
  color: #ff6900;
  font-size: 1.35rem;
  font-weight: 300;
  line-height: 1;
}

.skills-footer {
  margin-top: 0.55rem;
  padding: 0.55rem 0.65rem;
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  border-left: 3px solid #ff6500;
  background: rgba(11, 12, 14, 0.76);
  color: #969ba1;
  font-size: 0.56rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.state-card {
  margin-top: 0.5rem;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 0.55rem;
  background: rgba(15, 17, 20, 0.96);
  padding: 0.9rem;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
}

.state-card.error {
  border-color: rgba(255, 98, 74, 0.65);
}

.state-title {
  color: #e7e7e7;
  font-size: 0.78rem;
  text-align: center;
}

.retry-btn {
  border: 1px solid #ff6a00;
  border-radius: 0.38rem;
  background: linear-gradient(180deg, #ff7600, #e75300);
  color: #111;
  font-size: 0.7rem;
  font-weight: 800;
  padding: 0.34rem 0.7rem;
}

.phone-skills.classic-theme {
  box-sizing: border-box;
  padding-right: 0.48rem;
  padding-left: 0.48rem;
  border: 0.42rem solid transparent;
  border-radius: 0.9rem;
  background:
    repeating-linear-gradient(0deg, rgba(255, 255, 255, 0.018) 0 1px, transparent 1px 4px) padding-box,
    radial-gradient(circle at 28% 12%, rgba(112, 96, 61, 0.14), transparent 33%) padding-box,
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

.classic-theme .skills-intro {
  border: 2px solid #746c56;
  border-left-width: 2px;
  border-radius: 0.42rem;
  background: linear-gradient(180deg, rgba(64, 61, 50, 0.96), rgba(37, 36, 30, 0.98));
  box-shadow: inset 0 1px 0 #a09679, inset 0 -2px 0 #15140f, 0 0 0 2px #25231c;
  color: #e5ddc9;
  text-shadow: 1px 1px #000;
}

.classic-theme .intro-icon {
  color: #d9b73c;
  filter: drop-shadow(1px 1px #000);
}

.classic-theme .theme-btn {
  border: 2px solid #9b8132;
  border-radius: 0.28rem;
  background: linear-gradient(#4b4739, #28271f);
  box-shadow: inset 1px 1px 0 #c0aa65, inset -1px -1px 0 #111;
  color: #f0ce4b;
  text-shadow: 1px 1px #000;
}

.classic-theme .skills-grid {
  gap: 0.22rem;
  padding: 0.16rem;
  border: 0.34rem solid transparent;
  border-radius: 0.72rem;
  background:
    linear-gradient(#22211b, #22211b) padding-box,
    repeating-linear-gradient(90deg, #6f6854 0 2.7rem, #29271f 2.7rem 2.84rem, #504c3e 2.84rem 5.4rem, #25231c 5.4rem 5.55rem) top left / 100% 0.34rem no-repeat border-box,
    repeating-linear-gradient(90deg, #504c3e 0 2.7rem, #25231c 2.7rem 2.84rem, #6f6854 2.84rem 5.4rem, #29271f 5.4rem 5.55rem) bottom left / 100% 0.34rem no-repeat border-box,
    repeating-linear-gradient(0deg, #6f6854 0 2.7rem, #29271f 2.7rem 2.84rem, #504c3e 2.84rem 5.4rem, #25231c 5.4rem 5.55rem) top left / 0.34rem 100% no-repeat border-box,
    repeating-linear-gradient(0deg, #504c3e 0 2.7rem, #25231c 2.7rem 2.84rem, #6f6854 2.84rem 5.4rem, #29271f 5.4rem 5.55rem) top right / 0.34rem 100% no-repeat border-box,
    linear-gradient(#575141, #2b2921) border-box;
  box-shadow: 0 0 0 2px #12120e, inset 0 0 0 2px #92886e, 0 0.2rem 0.4rem rgba(0, 0, 0, 0.45);
}

.classic-theme .skill-card {
  min-height: 5.2rem;
  padding: 0.55rem 0.55rem 0.48rem;
  grid-template-columns: 2.05rem minmax(0, 1fr);
  gap: 0.52rem;
  border: 1px solid #575346;
  border-radius: 0.38rem;
  background:
    repeating-linear-gradient(135deg, rgba(255, 255, 255, 0.014) 0 1px, transparent 1px 5px),
    linear-gradient(145deg, #34332c, #25251f);
  box-shadow: inset 1px 1px 0 #716c59, inset -2px -2px 0 #151510;
  color: #eee6d3;
}

.classic-theme .skill-card::before {
  content: '';
  position: absolute;
  inset: 0.13rem;
  z-index: -1;
  border: 1px solid rgba(176, 166, 135, 0.2);
  border-radius: 0.27rem;
  pointer-events: none;
}

.classic-theme .skill-card::after {
  display: none;
}

.classic-theme .skill-card:hover,
.classic-theme .skill-card.focus-visible {
  border-color: #d1a928;
  background: linear-gradient(145deg, #423e2e, #29271e);
  box-shadow: inset 0 0 0 1px #f0c63d, inset 2px 2px 0 #6d654d;
}

.classic-theme .skill-icon {
  color: #c9bd94;
  font-size: 1.9rem;
  filter: drop-shadow(2px 2px 0 #050505);
}

.classic-theme .skill-name {
  color: #f0ce46;
  font-family: var(--fnt-mono, "Courier New", monospace);
  font-size: 0.82rem;
  font-weight: 800;
  letter-spacing: 0;
  text-shadow: 1px 1px 0 #000;
}

.classic-theme .skill-stats {
  color: #eee5d1;
  font-size: 0.56rem;
  text-shadow: 1px 1px #000;
}

.classic-theme .stat-divider {
  background: #7f7862;
}

.classic-theme .progress-track {
  height: 0.32rem;
  border: 2px solid #090a07;
  border-radius: 0.18rem;
  background: #080a07;
  box-shadow: 0 0 0 1px #5d594b;
}

.classic-theme .progress-fill {
  border-radius: 0.08rem;
  background: linear-gradient(90deg, #4f8d20, #9bc344);
  box-shadow: inset 0 1px rgba(255, 255, 255, 0.32);
}

.classic-theme .skill-arrow {
  display: none;
}

.classic-theme .skills-footer {
  border: 2px solid #6f6853;
  border-left-width: 2px;
  border-radius: 0.42rem;
  background: linear-gradient(#39372e, #25241e);
  box-shadow: inset 0 1px #91876d, inset 0 -2px #11110e;
  color: #d9cfb8;
  text-transform: none;
  text-shadow: 1px 1px #000;
}
</style>

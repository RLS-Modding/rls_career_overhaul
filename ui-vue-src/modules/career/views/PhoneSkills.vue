<template>
  <PhoneWrapper app-name="Skills">
    <div class="phone-skills">
      <div v-if="loading" class="state-card">
        <div class="state-title">Loading skills...</div>
      </div>

      <div v-else-if="error" class="state-card error">
        <div class="state-title">Could not load skills</div>
        <button class="retry-btn" @click="refreshSkills">Retry</button>
      </div>

      <div v-else-if="skills.length === 0" class="state-card">
        <div class="state-title">No skills found</div>
      </div>

      <div v-else class="skills-grid">
        <button
          v-for="skill in skills"
          :key="skill.id"
          class="skill-tile"
          @click="openSkill(skill.id)"
        >
          <div class="skill-name">{{ $ctx_t(skill.name) }}</div>
          <div class="skill-meta">
            <span class="skill-level">
              Lv {{ skill.level }}
              <span v-if="skill.levelCap" class="level-cap">/{{ skill.levelCap }}</span>
            </span>
            <span class="tile-progress">XP {{ skill.progressLabel }}</span>
          </div>
        </button>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { onMounted } from 'vue'
import { useRouter } from 'vue-router'
import PhoneWrapper from './PhoneWrapper.vue'
import { usePhoneSkillsData } from '../composables/usePhoneSkillsData'

const router = useRouter()
const { skills, loading, error, loadPhoneSkills } = usePhoneSkillsData()

async function refreshSkills() {
  try {
    await loadPhoneSkills(true)
  } catch (_) {
    // Handled by shared error state.
  }
}

function openSkill(skillId) {
  router.push({
    name: 'phone-skills-details',
    params: { skillId },
  })
}

onMounted(async () => {
  try {
    await loadPhoneSkills()
  } catch (_) {
    // Handled by shared error state.
  }
})
</script>

<style scoped lang="scss">
.phone-skills {
  height: 100%;
  overflow-y: auto;
  padding: calc(2.45rem + env(safe-area-inset-top, 0px)) 0.55rem 0.55rem;
  background: linear-gradient(180deg, #0b1220 0%, #101826 100%);
}

.skills-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.4rem;
}

.skill-tile {
  border: 1px solid rgba(106, 123, 157, 0.35);
  border-radius: 0.7rem;
  background: linear-gradient(170deg, rgba(34, 50, 78, 0.95), rgba(20, 30, 48, 0.96));
  color: #f1f5ff;
  padding: 0.35rem 0.45rem;
  min-height: 3.4rem;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.24rem;
  text-align: center;
  transition: transform 0.12s ease, border-color 0.12s ease;
}

.skill-tile:active {
  transform: translateY(1px);
}

.skill-tile:hover,
.skill-tile:focus-visible {
  border-color: rgba(125, 167, 255, 0.8);
}

.skill-name {
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.06rem;
  font-weight: 700;
  line-height: 1.04;
  min-height: 1.38rem;
  overflow: hidden;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
}

.skill-meta {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.4rem;
  white-space: nowrap;
}

.skill-level {
  font-size: 0.68rem;
  color: #d6e0f5;
  font-weight: 700;
}

.tile-progress {
  font-size: 0.68rem;
  color: #9ec1ff;
  font-weight: 700;
}

.level-cap {
  color: #9db3d7;
}

.state-card {
  margin-top: 0.5rem;
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

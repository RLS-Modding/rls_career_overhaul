import { computed, ref } from 'vue'

const STORAGE_KEY = 'rlsCareer:skillsTheme'

function loadSavedTheme() {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'classic' ? 'classic' : 'modern'
  } catch (_) {
    return 'modern'
  }
}

const skillsTheme = ref(loadSavedTheme())
const isClassicTheme = computed(() => skillsTheme.value === 'classic')

function setSkillsTheme(theme) {
  skillsTheme.value = theme === 'classic' ? 'classic' : 'modern'
  try {
    localStorage.setItem(STORAGE_KEY, skillsTheme.value)
  } catch (_) {
    // The in-memory choice still works when storage is unavailable.
  }
}

function toggleSkillsTheme() {
  setSkillsTheme(isClassicTheme.value ? 'modern' : 'classic')
}

export function useSkillsTheme() {
  return {
    skillsTheme,
    isClassicTheme,
    setSkillsTheme,
    toggleSkillsTheme,
  }
}

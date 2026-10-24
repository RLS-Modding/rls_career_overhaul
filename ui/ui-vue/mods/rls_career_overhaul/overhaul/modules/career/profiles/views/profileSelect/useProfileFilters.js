// Search, sort and filter over the saves the picker holds. Owns the search text, the sort mode and the three filter sets,
// and projects the saves into the list the strip shows. The view owns the dropdown menus that choose these values.
import { computed, reactive, ref } from "vue"
import { getProfileDifficultyLabel, getProfilePathLabel } from "../../components/start/careerStartModes.js"

export const SORT_OPTIONS = [
  { value: "lastPlayed", label: "Last Played" },
  { value: "moneyDesc", label: "Money (High to Low)" },
  { value: "moneyAsc", label: "Money (Low to High)" },
  { value: "skillDesc", label: "Top Skill (High to Low)" },
  { value: "skillAsc", label: "Top Skill (Low to High)" },
]

function getProfileChallengeName(p) {
  if (!p.activeChallenge) return null
  return typeof p.activeChallenge === "string" ? p.activeChallenge : p.activeChallenge.name || null
}

function getTopSkillLevel(p) {
  const skills = Array.isArray(p.freSkills) ? p.freSkills : Object.values(p.freSkills || {})
  if (!skills.length) return 0
  return Math.max(...skills.map(s => Number(s.level) || 0))
}

export function useProfileFilters({ profiles, activeProfileId }) {
  const searchQuery = ref("")
  const sortMode = ref("lastPlayed")
  const activePaths = reactive(new Set())
  const activeDifficulties = reactive(new Set())
  const activeChallenges = reactive(new Set())

  const selectedSortLabel = computed(() => SORT_OPTIONS.find(o => o.value === sortMode.value)?.label || "Last Played")

  const challengeFilterOptions = computed(() => {
    if (!profiles.value) return []
    const names = new Set()
    for (const p of profiles.value) {
      const ch = p.activeChallenge
      if (!ch) continue
      const name = typeof ch === "string" ? ch : ch.name
      if (name) names.add(name)
    }
    return [...names].sort()
  })

  const activeFilterCount = computed(() => activePaths.size + activeDifficulties.size + activeChallenges.size)

  const hasAnyProfile = computed(() => !!profiles.value && profiles.value.length > 0)

  /** Nothing to search, sort or filter until there is more than one save. */
  const showToolbar = computed(() => !!profiles.value && profiles.value.length > 1)

  const filteredProfiles = computed(() => {
    if (!profiles.value) return []
    let list = [...profiles.value]

    const q = searchQuery.value.trim().toLowerCase()
    if (q) list = list.filter(p => p.id.toLowerCase().includes(q))

    if (activePaths.size > 0) {
      list = list.filter(p => activePaths.has(getProfilePathLabel(p)))
    }

    // A profile whose payload carries no difficulty is unknown, not Standard — it
    // stays out of the results rather than being filed under a guess.
    if (activeDifficulties.size > 0) {
      list = list.filter(p => activeDifficulties.has(getProfileDifficultyLabel(p)))
    }

    if (activeChallenges.size > 0) {
      list = list.filter(p => {
        const name = getProfileChallengeName(p)
        return name && activeChallenges.has(name)
      })
    }

    const activeId = activeProfileId.value
    const active = activeId ? list.find(p => p.id === activeId) : null
    let rest = active ? list.filter(p => p.id !== activeId) : list

    switch (sortMode.value) {
      case "moneyDesc":
        rest.sort((a, b) => (b.money?.value || 0) - (a.money?.value || 0))
        break
      case "moneyAsc":
        rest.sort((a, b) => (a.money?.value || 0) - (b.money?.value || 0))
        break
      case "skillDesc":
        rest.sort((a, b) => getTopSkillLevel(b) - getTopSkillLevel(a))
        break
      case "skillAsc":
        rest.sort((a, b) => getTopSkillLevel(a) - getTopSkillLevel(b))
        break
      default:
        rest.sort((a, b) => new Date(b.date) - new Date(a.date))
    }

    return active ? [active, ...rest] : rest
  })

  /** Only an empty *result* — a profile list that is genuinely empty is not a dead end. */
  const hasNoMatches = computed(() => {
    if (!hasAnyProfile.value) return false
    return filteredProfiles.value.length === 0
  })

  function togglePathFilter(p) {
    if (activePaths.has(p)) activePaths.delete(p)
    else activePaths.add(p)
  }

  function toggleDifficultyFilter(d) {
    if (activeDifficulties.has(d)) activeDifficulties.delete(d)
    else activeDifficulties.add(d)
  }

  function toggleChallengeFilter(c) {
    if (activeChallenges.has(c)) activeChallenges.delete(c)
    else activeChallenges.add(c)
  }

  function clearFilters() {
    activePaths.clear()
    activeDifficulties.clear()
    activeChallenges.clear()
  }

  function clearSearchAndFilters() {
    searchQuery.value = ""
    clearFilters()
  }

  return {
    searchQuery,
    sortMode,
    sortOptions: SORT_OPTIONS,
    selectedSortLabel,
    activePaths,
    activeDifficulties,
    activeChallenges,
    challengeFilterOptions,
    activeFilterCount,
    hasAnyProfile,
    showToolbar,
    filteredProfiles,
    hasNoMatches,
    togglePathFilter,
    toggleDifficultyFilter,
    toggleChallengeFilter,
    clearFilters,
    clearSearchAndFilters,
  }
}

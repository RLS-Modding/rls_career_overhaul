/**
 * Two independent axes, kept separate:
 *
 *   PATH       what kind of run this is        career | story | custom
 *   DIFFICULTY the economy behind it           easy | normal | hard | hardcore
 *
 * `careerStartMode` records the path (it has no gameplay consumers in Lua, it is
 * only read back for the profile card and the filters). `difficultyMode` is the
 * field that actually does the work.
 */

export const CAREER_START_MODES = [
  {
    id: "career",
    label: "Career",
    tagline: "The main way to play",
    description: "Pick a difficulty and go. Casual, Standard or Hardcore — everything else is yours to set.",
  },
  {
    id: "story",
    label: "Story",
    tagline: "Curated",
    description: "Play a challenge with set goals, starting conditions and rules. Pick a story or create your own.",
  },
  {
    id: "custom",
    label: "Custom",
    tagline: "Full control",
    description: "Start from a difficulty, then change anything: payouts per activity, XP per skill, cash, cheats.",
  },
]

/**
 * The numbers are the ones in lua/ge/extensions/career/modules/difficultyMode.lua:8-13.
 * They are shown to the player verbatim — if that Lua table changes, change these.
 */
export const CAREER_DIFFICULTIES = [
  {
    id: "casual",
    difficultyMode: "easy",
    label: "Casual",
    money: 3,
    xp: 2,
    startingCash: 25000,
    blurb: "Progress quickly and buy what you like.",
  },
  {
    id: "standard",
    difficultyMode: "normal",
    label: "Standard",
    money: 1,
    xp: 1,
    startingCash: 15000,
    blurb: "The intended balance.",
  },
  {
    id: "hard",
    difficultyMode: "hard",
    label: "Hard",
    money: 0.5,
    xp: 0.5,
    startingCash: 10000,
    blurb: "Everything costs more of your time.",
  },
  {
    id: "hardcore",
    difficultyMode: "hardcore",
    label: "Hardcore",
    money: 0.5,
    xp: 0.25,
    startingCash: 0,
    blurb: "Fixed rules. No second chances.",
    // Applied by the Lua whenever difficultyMode == "hardcore", whatever the UI sends.
    // Three lines, because the card shows these instead of the settings and a
    // scrollbar in a list this short reads worse than tighter copy.
    locks: [
      "Random junkyard beater",
      "No starting garage, half capacity",
      "10× fines, worse resale, police always on",
    ],
  },
]

/** The three offered on the Career path. `hard` stays reachable through Custom. */
export const CAREER_PATH_DIFFICULTY_IDS = ["casual", "standard", "hardcore"]

/**
 * Custom honours everything the player sets, so it cannot seed from Hardcore:
 * difficultyMode == "hardcore" makes the Lua override the garage and police
 * after the fact, which would silently contradict the panel.
 */
export const CUSTOM_SEED_DIFFICULTY_IDS = ["casual", "standard", "hard"]

export const CREATE_CARD_DEFAULT_DESCRIPTION =
  "Hover a path below to learn more, then click to set up your new career."

export const CREATE_CARD_DEFAULT_PREVIEW = ""

export function getCareerStartMode(modeId) {
  return CAREER_START_MODES.find(m => m.id === modeId) || null
}

export function getCareerStartModeLabel(modeId) {
  return getCareerStartMode(modeId)?.label || "Career"
}

export function getCareerStartModeDescription(modeId) {
  return getCareerStartMode(modeId)?.description || CREATE_CARD_DEFAULT_DESCRIPTION
}

export function getCareerStartModePreview(modeId, mapMetadata) {
  return mapMetadata?.startPreviews?.[modeId] || mapMetadata?.preview || CREATE_CARD_DEFAULT_PREVIEW
}

export function getDifficulty(difficultyId) {
  return CAREER_DIFFICULTIES.find(d => d.id === difficultyId) || null
}

export function getDifficultyByMode(difficultyMode) {
  const mode = typeof difficultyMode === "string" ? difficultyMode.toLowerCase() : ""
  return CAREER_DIFFICULTIES.find(d => d.difficultyMode === mode) || null
}

export function getDifficulties(ids) {
  return ids.map(getDifficulty).filter(Boolean)
}

/* -------------------------------------------------------------------------- */
/* Reading saves back                                                          */
/* -------------------------------------------------------------------------- */

/**
 * Saves written before the restructure carry the old four-mode vocabulary.
 * Nothing is rewritten on disk — old values are translated on read.
 *
 *   freeroam  cheats on, and cheats are Custom-only now  -> custom
 *   sandbox   the same override path, new name           -> custom
 *   hardcore  already difficultyMode: "hardcore"         -> career
 */
const LEGACY_START_MODES = {
  freeroam: "custom",
  sandbox: "custom",
  hardcore: "career",
  story: "story",
}

export function resolveProfileStartMode(profile) {
  if (!profile) return null

  const mode = profile.careerStartMode
  if (typeof mode !== "string") return null

  if (CAREER_START_MODES.some(m => m.id === mode)) return mode
  return LEGACY_START_MODES[mode] || null
}

/**
 * The difficulty a save is actually running, or null when the profile payload
 * did not carry enough to know. This never guesses — an unknown difficulty is
 * not the same thing as Standard.
 */
export function resolveProfileDifficulty(profile) {
  if (!profile) return null

  const byMode = getDifficultyByMode(profile.difficultyMode)
  if (byMode) return byMode

  // Legacy Freeroam+ saves are easy + cheats even when difficultyMode is absent.
  if (profile.cheatsMode && profile.careerStartMode === "freeroam") return getDifficulty("casual")

  return null
}

export function getProfileDifficultyLabel(profile) {
  return resolveProfileDifficulty(profile)?.label || null
}

export function getProfilePathLabel(profile) {
  const startMode = resolveProfileStartMode(profile)
  if (startMode) return getCareerStartModeLabel(startMode)

  if (!profile) return null

  // No start mode recorded: infer from what the save carries.
  if (profile.cheatsMode) return "Custom"
  if (profile.activeChallenge) return "Story"
  if (resolveProfileDifficulty(profile)) return "Career"
  return null
}

/** The chip on the profile card: the most informative single word about the save. */
export function getProfileModeChipLabel(profile) {
  if (!profile) return null

  const path = getProfilePathLabel(profile)

  if (path === "Story") {
    const ch = profile.activeChallenge
    const name = typeof ch === "string" ? ch : ch?.name
    return name || "Story"
  }

  // Career is the default path, so the difficulty is the interesting part.
  if (path === "Career") return getProfileDifficultyLabel(profile) || "Career"

  return path
}

export const PATH_FILTER_OPTIONS = CAREER_START_MODES.map(m => m.label)

export const DIFFICULTY_FILTER_OPTIONS = CAREER_DIFFICULTIES.map(d => d.label)

import { getDifficulty } from "./careerStartModes.js"

export const APPRENTICESHIP_CHOICE_ENABLED = false

export function resolveGaragePreference(garageValue) {
  if (garageValue === "no_garage") {
    return { startingGarageMode: "none", startingGarageId: null }
  }
  if (garageValue === "default_garage" || !garageValue) {
    return { startingGarageMode: "default", startingGarageId: null }
  }
  return { startingGarageMode: "default", startingGarageId: garageValue }
}

/**
 * Custom is a named difficulty plus overrides — which is how difficultyMode.lua
 * already stores it (a base mode plus optional xpMultiplier / rewardMultiplier /
 * startingCapital, resolved together at read time).
 *
 * An override is only sent when it differs from the seed, so a Custom career left
 * untouched behaves identically to the difficulty it started from.
 */
function resolveOverrides(panelConfig) {
  const seed = getDifficulty(panelConfig.baseDifficulty) || getDifficulty("standard")
  const overrides = { xpMultiplier: null, economyMultiplier: null, startingCash: null }

  if (typeof panelConfig.xpMultiplier === "number" && panelConfig.xpMultiplier !== seed.xp) {
    overrides.xpMultiplier = panelConfig.xpMultiplier
  }
  if (typeof panelConfig.economyMultiplier === "number" && panelConfig.economyMultiplier !== seed.money) {
    overrides.economyMultiplier = panelConfig.economyMultiplier
  }
  if (
    typeof panelConfig.startingCash === "number" &&
    panelConfig.startingCash >= 0 &&
    panelConfig.startingCash !== seed.startingCash
  ) {
    overrides.startingCash = Math.floor(panelConfig.startingCash)
  }

  return { seed, overrides }
}

/** Map panel getStartConfig() output to legacy createOrLoadCareerAndStart args. */
export function buildCareerStartParams(modeId, panelConfig) {
  const garage = resolveGaragePreference(panelConfig.startingGarage)

  switch (modeId) {
    case "career": {
      const difficulty = getDifficulty(panelConfig.difficulty) || getDifficulty("standard")
      // The Lua overrides garage and police for hardcore regardless of what we
      // send; send what it will actually use so the save matches what was shown.
      // Maintenance is optional on hardcore and follows the panel toggle.
      const isHardcore = difficulty.difficultyMode === "hardcore"

      return {
        careerStartMode: "career",
        difficultyMode: difficulty.difficultyMode,
        cheatsMode: false,
        challengeId: null,
        startingMap: panelConfig.startingMap || null,
        experimentalMaintenanceEnabled: panelConfig.maintenanceEnabled === true,
        startingGarageMode: isHardcore ? "none" : garage.startingGarageMode,
        startingGarageId: isHardcore ? null : garage.startingGarageId,
        policeEnabled: isHardcore ? true : panelConfig.policeEnabled !== false,
        employmentApprenticeship: panelConfig.employmentApprenticeship !== false,
        xpMultiplier: null,
        economyMultiplier: null,
        startingCash: null,
      }
    }

    case "story":
      return {
        careerStartMode: "story",
        difficultyMode: "normal",
        cheatsMode: false,
        challengeId: panelConfig.challengeId || null,
        startingMap: null,
        experimentalMaintenanceEnabled: panelConfig.maintenanceEnabled === true,
        startingGarageMode: "default",
        startingGarageId: null,
        policeEnabled: panelConfig.policeEnabled !== false,
        employmentApprenticeship: panelConfig.employmentApprenticeship !== false,
        xpMultiplier: null,
        economyMultiplier: null,
        startingCash: null,
      }

    case "custom": {
      const { seed, overrides } = resolveOverrides(panelConfig)

      return {
        careerStartMode: "custom",
        difficultyMode: seed.difficultyMode,
        cheatsMode: panelConfig.cheatsEnabled === true,
        challengeId: null,
        startingMap: panelConfig.startingMap || null,
        experimentalMaintenanceEnabled: panelConfig.maintenanceEnabled === true,
        startingGarageMode: garage.startingGarageMode,
        startingGarageId: garage.startingGarageId,
        policeEnabled: panelConfig.policeEnabled !== false,
        employmentApprenticeship: panelConfig.employmentApprenticeship !== false,
        xpMultiplier: overrides.xpMultiplier,
        economyMultiplier: overrides.economyMultiplier,
        startingCash: overrides.startingCash,
        sandboxEconomyProfile: panelConfig.sandboxEconomyProfile || null,
        sandboxXpProfile: panelConfig.sandboxXpProfile || null,
      }
    }

    default:
      return {
        careerStartMode: "career",
        difficultyMode: "normal",
        cheatsMode: false,
        challengeId: null,
        startingMap: null,
        experimentalMaintenanceEnabled: false,
        startingGarageMode: "default",
        startingGarageId: null,
        policeEnabled: true,
        employmentApprenticeship: true,
        xpMultiplier: null,
        economyMultiplier: null,
        startingCash: null,
      }
  }
}

export const STORY_MIGRATION_TITLE_KEY = "rls_career_start_story_migration_seen"

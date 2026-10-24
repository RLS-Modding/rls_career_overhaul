// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

// Translation stays bound to this drop-off screen.
export function createCargoRewardLevels({ $translate }) {
  const normalizeBranchLevels = (branchLevels) => {
  const sourceLevels = Array.isArray(branchLevels) ? branchLevels : Object.values(branchLevels || {})
  return sourceLevels
    .filter(level => level && Number.isFinite(Number(level.requiredValue)))
    .map(level => ({ ...level, requiredValue: Number(level.requiredValue) }))
    .sort((a, b) => a.requiredValue - b.requiredValue)
  }

  const getLevelFromValue = (value, reward) => {
  const branchLevels = normalizeBranchLevels(reward.branchLevels)
  if (!branchLevels.length) {
    return {
      min: 0,
      max: 0,
      displayValue: 0,
      levelLabel: reward?.animationData?.levelLabel || "Level 1",
      level: 1,
      maxLevel: true
    }
  }

  const numericValue = Number(value) || 0
  let levelIndex = 0
  for (let i = 0; i < branchLevels.length; i++) {
    if (numericValue >= branchLevels[i].requiredValue) {
      levelIndex = i
    } else {
      break
    }
  }

  const currentLevelData = branchLevels[levelIndex]
  const nextLevelData = branchLevels[levelIndex + 1]
  const maxLevel = !(nextLevelData && nextLevelData.requiredValue != undefined)
  const displayValue = numericValue - currentLevelData.requiredValue

  return {
    min: 0,
    max: maxLevel ? displayValue : nextLevelData.requiredValue - currentLevelData.requiredValue,
    displayValue: displayValue,
    levelLabel: reward.type == "reputation"
      ? $translate.contextTranslate({ txt: "ui.career.cargoDropOff.reputationLevel", context: { label: currentLevelData.label || "Reputation", level: levelIndex - 1 } }, true)
      : (currentLevelData.levelLabel || ("Level " + (levelIndex + 1))),
    level: levelIndex + 1,
    maxLevel: maxLevel
  }
  }

  return { normalizeBranchLevels, getLevelFromValue }
}

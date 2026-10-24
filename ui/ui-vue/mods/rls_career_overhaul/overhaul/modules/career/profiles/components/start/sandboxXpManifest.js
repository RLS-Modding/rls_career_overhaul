/**
 * UI mirror of xpAdjusterPolicy.lua XP_SECTIONS.
 * Relative tuning constants match economy umbrellas (shared slider range).
 */
import {
  SANDBOX_ECONOMY_DEFAULT,
  SANDBOX_ECONOMY_MAX,
  SANDBOX_ECONOMY_MIN,
  SANDBOX_ECONOMY_SECTIONS,
  SANDBOX_ECONOMY_STEP,
  clampRelative,
  isDefaultRelative,
} from "./sandboxEconomyManifest.js"

export const SANDBOX_XP_MIN = SANDBOX_ECONOMY_MIN
export const SANDBOX_XP_MAX = SANDBOX_ECONOMY_MAX
export const SANDBOX_XP_STEP = SANDBOX_ECONOMY_STEP
export const SANDBOX_XP_DEFAULT = SANDBOX_ECONOMY_DEFAULT

/** Umbrella rows only — delivery XP uses logistics-delivery (no per-parcel XP keys). */
export const SANDBOX_XP_SECTIONS = SANDBOX_ECONOMY_SECTIONS.map((section) => ({
  ...section,
  children: (section.children || []).map((child) => ({
    id: child.id,
    label: child.label,
    skillKey: child.skillKey,
  })),
}))

export { clampRelative, isDefaultRelative }

export function sanitizeSandboxXpProfile(profile) {
  const src = profile && typeof profile === "object" ? profile : {}
  const umbrellas = {}

  if (src.umbrellas && typeof src.umbrellas === "object") {
    for (const [key, value] of Object.entries(src.umbrellas)) {
      const clamped = clampRelative(value)
      if (!isDefaultRelative(clamped)) {
        umbrellas[key] = clamped
      }
    }
  }

  if (Object.keys(umbrellas).length === 0) {
    return null
  }

  return { umbrellas }
}

export function hasSandboxXpOverrides(profile) {
  return sanitizeSandboxXpProfile(profile) !== null
}

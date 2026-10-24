// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { formatMoney } from "../../../utils/units.js"

// No currency symbol: the bullet renderer puts the game currency glyph before `money`.
// Adapter over units.formatMoney (en-US, 0 decimals, Intl half-expand). Two outputs differ from it and are kept here:
// a non-finite amount is "0", not the dash, and an amount that rounds to zero keeps its sign ("-0" for -0.4).
export function formatStoryMoney(amount) {
  const value = Number(amount)
  if (!Number.isFinite(value)) return "0"
  const text = formatMoney(value, { decimals: 0, locale: "en-US" })
  return (value < 0 || Object.is(value, -0)) && text === "0" ? "-0" : text
}

export function formatStoryMapLabel(mapId, mapLabels = {}) {
  if (!mapId) return null
  if (mapLabels[mapId]) return mapLabels[mapId]
  return String(mapId)
    .split("_")
    .filter(Boolean)
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

export function getStoryBullets(challenge, mapLabels = {}) {
  if (!challenge) return []

  const bullets = []
  // Bullets are { money?, text }: money (formatted, no symbol) renders with the currency glyph.
  bullets.push({ money: formatStoryMoney(challenge.startingCapital ?? 10000), text: " starting cash" })

  if (challenge.winConditionName) {
    bullets.push({ text: `Goal: ${challenge.winConditionName}` })
  }

  const mapLabel = formatStoryMapLabel(challenge.map, mapLabels)
  if (mapLabel) {
    bullets.push({ text: mapLabel })
  } else {
    bullets.push({ text: "Any map" })
  }

  if (challenge.hasLoans && Number(challenge.loanAmount) > 0) {
    bullets.push({ money: formatStoryMoney(challenge.loanAmount), text: " starting debt" })
  }

  return bullets
}

export function mapStoryChallengeEntry(entry) {
  if (!entry) return null
  return {
    id: entry.id,
    name: entry.name,
    difficulty: entry.difficulty || "Medium",
    description: entry.description || "",
    shortDescription: entry.description || "",
    isLocal: entry.isLocal || false,
    startingCapital: entry.startingCapital ?? 10000,
    winConditionName: entry.winConditionName || null,
    map: entry.map || null,
    hasLoans: entry.hasLoans === true,
    loanAmount: entry.loanAmount || 0,
  }
}

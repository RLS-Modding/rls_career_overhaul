// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { useBridge } from '@/bridge'

/** Avatar tints, cycled by a stable hash of the person's name. */
const AVATAR_COLOURS = ['#ffb27a', '#9ec8ff', '#a5e2b6', '#e7b6ff', '#ffd166']

/**
 * Buyer/seller archetype keys come from the base game's negotiationPersonalities.json.
 * These labels are what the offers inbox and the negotiate header show as a trait chip.
 */
const ARCHETYPE_LABELS = {
  aggressive: 'Hard bargainer',
  friendly: 'Friendly',
  professional: 'Professional',
  cautious: 'Cautious',
  casual: 'Casual',
  enthusiastic: 'Keen',
  desperate: 'Motivated',
  delusional: 'Lowballer',
}

export function avatarColour(name) {
  const text = String(name || '')
  if (!text) return AVATAR_COLOURS[1]
  let hash = 0
  for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 997
  return AVATAR_COLOURS[hash % AVATAR_COLOURS.length]
}

export function avatarInitials(name) {
  const words = String(name || '').trim().split(/\s+/).filter(Boolean)
  if (!words.length) return '?'
  return words.map(w => w[0]).join('').slice(0, 2).toUpperCase()
}

export function traitLabel(archetype, isDealership) {
  if (isDealership) return 'Dealer'
  const key = String(archetype || '').trim()
  if (ARCHETYPE_LABELS[key]) return ARCHETYPE_LABELS[key]
  if (!key) return 'Private buyer'
  // unknown archetype from a mod/level: camelCase -> Title Case rather than showing a raw key
  const spaced = key.replace(/[_-]+/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2')
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

/** mm:ss for offer expiry countdowns. */
export function countdownText(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0))
  const mins = Math.floor(total / 60)
  return `${mins}:${String(total % 60).padStart(2, '0')}`
}

/** Free-roam entries are lap times, except drift events which store a score. */
export function freeroamValueText(raceName, value) {
  const num = Number(value)
  if (!Number.isFinite(num)) return '—'
  if (String(raceName || '').toLowerCase().includes('drift')) return `${Math.round(num)} pts`
  const mins = Math.floor(num / 60)
  return `${mins}:${(num - mins * 60).toFixed(2).padStart(5, '0')}`
}

export function mileageText(mileageMeters) {
  const meters = Number(mileageMeters)
  if (!Number.isFinite(meters) || meters <= 0) return '0 mi'
  return `${Math.round(meters / 1609.344).toLocaleString('en-US')} mi`
}

/**
 * How an asking price or an offer sits against estimated market value.
 * Returns null when there is no market value to compare against, so callers can hide the chip.
 */
export function marketDelta(value, marketValue, { overIsGood = false } = {}) {
  const price = Number(value)
  const market = Number(marketValue)
  if (!Number.isFinite(price) || !Number.isFinite(market) || market <= 0) return null

  const percent = Math.round(((price - market) / market) * 100)
  const good = overIsGood ? percent >= 0 : percent <= 0
  return {
    percent,
    good,
    text: percent === 0 ? 'At est. market' : `${Math.abs(percent)}% ${percent > 0 ? 'over' : 'under'} est. market`,
    tone: percent === 0 ? 'neutral' : good ? 'good' : 'warn',
  }
}

/** Whole marketplace amounts. Render the currency glyph in the consuming markup. */
export function moneyText(value) {
  const num = Number(value)
  if (!Number.isFinite(num)) return '0'
  return Math.round(num).toLocaleString('en-US')
}

export function usePhoneMarketplaceMoney() {
  const { units } = useBridge()
  return { units, money: moneyText }
}

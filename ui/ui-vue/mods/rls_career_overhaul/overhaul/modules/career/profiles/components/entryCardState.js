// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Entry card view model: newest local save, loading/empty/ready copy, and compact saved metadata.

// What a first-time player is offered, shown only while there is no Overhaul save yet.
export const FIRST_CAREER_FEATURES = Object.freeze([
  { id: "jobs", label: "Jobs", icon: "deliveryTruck" },
  { id: "businesses", label: "Businesses", icon: "beamCurrency" },
  { id: "garages", label: "Garages", icon: "garage01" },
  { id: "phone", label: "Phone apps", icon: "smartphone1" },
])
const STATES = Object.freeze({
  loading: { title: "Loading Overhaul careers", action: "Resume" },
  empty: { title: "Start your Overhaul career", action: "Start new career" },
  ready: { action: "Resume" },
  error: { title: "Careers could not be read", action: "Open" },
})

export function latestProfile(profiles) {
  return Object.values(profiles || {}).filter(profile => profile?.id && !profile.saveDataMissing && !profile.importSource)
    .sort((a, b) => String(b.date || "").localeCompare(String(a.date || "")) || String(a.id).localeCompare(String(b.id)))[0] || null
}

export function entryCardState(profiles, ready, error = "") {
  const profile = latestProfile(profiles)
  const state = error ? "error" : !ready ? "loading" : profile ? "ready" : "empty"
  return { ...STATES[state], state, profile, title: state === "ready" ? profile.displayName || profile.id : STATES[state].title }
}

export function playedAgo(date, now = Date.now()) {
  const timestamp = Date.parse(date)
  if (!Number.isFinite(timestamp)) return null
  const minutes = Math.max(0, Math.floor((now - timestamp) / 60000))
  if (minutes < 1) return "Just now"
  const unit = minutes < 60 ? "minute" : minutes < 1440 ? "hour" : "day"
  const count = Math.floor(minutes / ({ minute: 1, hour: 60, day: 1440 }[unit]))
  return `${count} ${unit}${count === 1 ? "" : "s"} ago`
}

const compactCash = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", notation: "compact", maximumFractionDigits: 2 })

// One stat block per saved fact; a fact the save lacks shows a dash so the blocks never shift.
export function profileStats(profile, now) {
  const money = Number(profile?.money?.value)
  return [
    { key: "money", label: "Money", value: Number.isFinite(money) ? compactCash.format(money) : "—" },
    { key: "day", label: "Day", value: Number.isFinite(profile?.day) ? String(profile.day) : "—" },
    { key: "played", label: "Last played", value: playedAgo(profile?.date, now) || "—" },
  ]
}

// Highest skills first (level, then points); progress is the share of the current level already earned.
export function topSkills(profile, count = 3) {
  return Object.values(profile?.branches || {}).filter(skill => skill?.label && Number.isFinite(skill.level))
    .sort((a, b) => b.level - a.level || (b.value || 0) - (a.value || 0) || String(a.label).localeCompare(String(b.label)))
    .slice(0, count)
    .map(skill => ({
      id: skill.id || skill.label, label: skill.label, icon: skill.icon, level: skill.level,
      progress: skill.neededForNext > 0 ? Math.min(1, Math.max(0, (skill.curLvlProgress || 0) / skill.neededForNext)) : 1,
    }))
}

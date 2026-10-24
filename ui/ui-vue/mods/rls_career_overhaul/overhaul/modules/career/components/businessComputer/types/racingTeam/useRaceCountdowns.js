// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private race countdowns; retain wall-clock precedence and each simulation/snapshot fallback.
// The screen supplies the shared subscribed clock.
export function useRaceCountdowns({ racingTeamStore, scheduleUiSecondTick }) {
  const formatCooldownCounter = (totalSec) => {
    const s = Math.max(0, Math.floor(Number(totalSec) || 0))
    if (s <= 0) return "0:00"
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    const r = s % 60
    if (h > 0) {
      return `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`
    }
    return `${m}:${String(r).padStart(2, "0")}`
  }

  /** Matches scheduled-race countdown: prefer wall epoch so the UI ticks every second. */
  const remainingSecondsForPostRaceCooldown = (tech) => {
    const wallDue = Number(tech?.postRaceCooldownReadyWallEpoch)
    void scheduleUiSecondTick.value
    if (Number.isFinite(wallDue)) {
      return Math.max(0, wallDue - scheduleUiSecondTick.value)
    }
    if (Number.isFinite(tech?.postRaceCooldownExpiresAtSeconds)) {
      return Math.max(0, Math.ceil(tech.postRaceCooldownExpiresAtSeconds - scheduleUiSecondTick.value))
    }
    const until = Number(tech?.racingCooldownUntilSimTime)
    const now = Number(racingTeamStore.racingTeamCareerSimTime)
    if (Number.isFinite(until) && Number.isFinite(now)) {
      return Math.max(0, Math.floor(until - now))
    }
    const snap = Number(tech?.postRaceCooldownRemainingSec)
    return Number.isFinite(snap) ? Math.max(0, Math.floor(snap)) : 0
  }

  const remainingSecondsForScheduledDriver = (t) => {
    const pr = t?.pendingRaceOffer
    const wallDue = Number(pr?.scheduledRaceReadyWallEpoch ?? t?.scheduledRaceReadyWallEpoch)
    void scheduleUiSecondTick.value
    if (Number.isFinite(wallDue)) {
      return Math.max(0, wallDue - scheduleUiSecondTick.value)
    }
    if (Number.isFinite(t.scheduledRaceExpiresAtSeconds)) {
      return Math.max(0, Math.ceil(t.scheduledRaceExpiresAtSeconds - scheduleUiSecondTick.value))
    }
    const due = Number(t.scheduledRaceSimTime)
    const now = Number(racingTeamStore.racingTeamCareerSimTime)
    if (Number.isFinite(due) && Number.isFinite(now)) {
      return Math.max(0, Math.floor(due - now))
    }
    const fallback = Number(t.secondsUntilScheduledRace)
    if (Number.isFinite(fallback)) {
      return Math.max(0, Math.floor(fallback))
    }
    return null
  }
  return { formatCooldownCounter, remainingSecondsForPostRaceCooldown, remainingSecondsForScheduledDriver }
}

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Read timers through the screen so offer labels retain its sync clock.
export function createFreContractLabels({ displaySanctionedMinutes, displayRemaining, disciplineLabel, tierLabel }) {
  const CLASS_BRANCHES = ['stock', 'modified', 'super', 'open']

  function normalizeClassTier(text) {
    const t = String(text || '').toLowerCase()
    if (t.includes('entry') || t.includes('low') || t.includes('lower')) return 'entry'
    if (t.includes('upper') || t.includes('high')) return 'upper'
    if (t.includes('mid') || t.includes('medium')) return 'mid'
    return ''
  }

  function formatClassLabelCompact(label, branch) {
    const src = String(label || '').toLowerCase()
    const fromBranch = String(branch || '').toLowerCase()
    const b = CLASS_BRANCHES.find(v => src.includes(v)) || CLASS_BRANCHES.find(v => fromBranch.includes(v)) || ''
    const tier = normalizeClassTier(src)
    if (b && tier) return `${b}-${tier}`
    return b || '—'
  }

  function pwBucketX1000(pw) {
    const n = Number(pw)
    if (!Number.isFinite(n) || n <= 0) return null
    return Math.floor((n * 1000) / 50) * 50
  }

  function formatSanctionedClassBadge(o) {
    if (!o) return '—'
    return formatClassLabelCompact(o.hpBracketLabel, o.hpBracketBranch)
  }

  function sanctionedRouteHintFor(o) {
    if (!o?.useAltRoute) return 'Main circuit'
    return 'Short track (alt)'
  }
  function sanctionedLapsLabelFor(o) {
    const n = Math.max(1, Math.floor(Number(o?.lapCount) || 3))
    return n === 1 ? '1 lap' : `${n} laps`
  }
  function sanctionedPwBucketSummary(o) {
    if (!o) return ''
    const branch = String(o.hpBracketBranch || o.hpBracketLabel || '').toLowerCase()
    if (branch.includes('open')) return 'PWx1000 500+'
    const src = o.classPwMin ?? o.classPwMax
    const b = pwBucketX1000(src)
    if (b != null) return `PWx1000 ${b}`
    return ''
  }
  function sanctionedRefreshLabelFor(o) {
    const m = o?.minutesUntilRefresh
    if (m == null) return '—'
    return `Offer refresh in ${formatMinutes(displaySanctionedMinutes(m))}`
  }
  function sanctionedStartLabelFor(o) {
    const m = o?.minutesUntilStartDeadline
    if (m == null) return ''
    return formatMinutes(displaySanctionedMinutes(m))
  }
  function sanctionedPlacesForOffer(o) {
    if (!o) return []
    return [
      { label: '1st', value: o.payoutFirst, xp: o.xpFirst },
      { label: '2nd', value: o.payoutSecond, xp: o.xpSecond },
      { label: '3rd', value: o.payoutThird, xp: o.xpThird },
    ]
  }

  function formatTime(seconds) {
    const total = Number(seconds || 0)
    const minutes = Math.floor(total / 60)
    const secs = total - minutes * 60
    if (minutes >= 1) return `${minutes}:${String(Math.floor(secs)).padStart(2, '0')}`
    if (secs >= 10) return secs.toFixed(1)
    return secs.toFixed(2)
  }

  function formatMinutes(minutes) {
    const totalSeconds = Math.max(0, Math.floor(Number(minutes || 0) * 60))
    if (totalSeconds <= 0) return '0s'
    const totalMinutes = Math.floor(totalSeconds / 60)
    if (totalMinutes >= 60) {
      const hours = Math.floor(totalMinutes / 60)
      const minutesRemainder = totalMinutes % 60
      return minutesRemainder > 0 ? `${hours}h ${minutesRemainder}m` : `${hours}h`
    }
    const wholeMinutes = Math.floor(totalSeconds / 60)
    const seconds = totalSeconds % 60
    if (wholeMinutes <= 0) return `${seconds}s`
    return `${wholeMinutes}m ${seconds}s`
  }

  function formatPercent(value) {
    return `${Math.round(Number(value || 0) * 1000) / 10}%`
  }

  function bonusLabel(sponsor) {
    const amount = `${Math.round(Number(sponsor?.bonusPercent || 0) * 1000) / 10}%`
    const type = sponsor?.bonusType === 'disciplineXP' ? 'XP' : sponsor?.bonusType === 'both' ? 'Money + XP' : 'Money'
    return `${amount} ${type}`
  }

  function inferRouteTypeFromLabel(label) {
    const text = String(label || '').toLowerCase()
    return text.includes('alt route') || text.includes('alternative route') || text.includes('(alt)') ? 'alt' : 'main'
  }

  function routeLabel(routeType, fallbackLabel) {
    const normalized = String(routeType || '').toLowerCase() || inferRouteTypeFromLabel(fallbackLabel)
    return normalized === 'alt' ? 'Alt Route' : 'Main Route'
  }

  function contractRaceLabel(contract) {
    const raceLabel = contract?.raceLabel || contract?.raceName || 'Race'
    const routeType = String(contract?.raceRouteType || '').toLowerCase()
    if (routeType === 'alt') {
      return `${raceLabel} (Alt Route)`
    }
    return raceLabel
  }

  function contractVehicleLabel(contract) {
    return contract?.requiredModelLabel || contract?.requiredModelFamily || contract?.requiredModel || 'Any model'
  }

  function contractTitle(contract) {
    return `${disciplineLabel(contract?.disciplineId)} - ${tierLabel(contract?.tier)}`
  }

  function sponsorTitle(sponsor) {
    return `${disciplineLabel(sponsor?.disciplineId)} ${tierLabel(sponsor?.tier)} - ${sponsor?.name || 'Sponsor'}`
  }

  function sponsorRequirementHeadline(sponsor) {
    const raceLabel = sponsor?.requiredRaceLabel || sponsor?.requiredRaceName
    const targetLabel = formatTargetLabel(sponsor)
    return raceLabel && targetLabel ? `${targetLabel} on ${raceLabel}` : '1 valid event per upkeep'
  }

  function sponsorStatusLabel(sponsor) {
    const status = String(sponsor?.requirementStatus || 'pending')
    if (status === 'warning') return 'Warning'
    if (status === 'satisfied') return 'Satisfied'
    if (status === 'probation') return 'Probation'
    return 'Pending'
  }

  function sponsorStatusTone(sponsor) {
    const status = String(sponsor?.requirementStatus || 'pending')
    if (status === 'warning') return 'warning'
    if (status === 'satisfied') return 'good'
    if (status === 'probation') return 'neutral'
    return 'neutral'
  }

  function sponsorOfferTone(sponsor) {
    const minutes = displayRemaining(sponsor?.minutesRemaining)
    if (minutes < 1) return 'urgent'
    if (minutes <= 3) return 'soon'
    return 'normal'
  }

  function sponsorOfferLabel(sponsor) {
    return `${formatMinutes(displayRemaining(sponsor?.minutesRemaining))} left`
  }

  function normalizeTargetType(targetType) {
    const normalized = String(targetType || '').toLowerCase()
    if (normalized === 'driftscore') return 'driftScore'
    if (normalized === 'maxdamagepct') return 'maxDamagePct'
    if (normalized === 'pulldistance') return 'pullDistance'
    return 'time'
  }

  function formatTargetLabel(entry) {
    const targetType = normalizeTargetType(entry?.targetType)
    if (targetType === 'driftScore') {
      const targetScore = Math.max(0, Math.floor(Number(entry?.targetDriftScore || 0)))
      return targetScore > 0 ? `Score ${targetScore}` : ''
    }
    if (targetType === 'maxDamagePct') {
      const targetDamage = Number(entry?.targetDamagePctMax)
      if (!Number.isFinite(targetDamage)) return ''
      const pct = Math.max(0, Math.min(100, Math.round(targetDamage * 100)))
      return `Max ${pct}% damage`
    }
    if (targetType === 'pullDistance') {
      const meters = Number(entry?.targetDistanceMeters)
      if (!Number.isFinite(meters) || meters <= 0) return ''
      const sled = entry?.requiredSledLabel || entry?.requiredSledId
      return `Pull ${(meters * 3.280839895).toFixed(1)} ft${sled ? ` / ${sled}` : ''}`
    }
    const target = Number(entry?.targetTime)
    return Number.isFinite(target) && target > 0 ? `Target ${formatTime(target)}` : ''
  }

  function contractTargetLabel(contract) {
    return formatTargetLabel(contract)
  }

  function objectiveStatusLabel(contract) {
    const requiredCount = Math.max(1, Math.floor(Number(contract?.requiredCount || 1)))
    const progress = Math.max(0, Math.floor(Number(contract?.progress || 0)))
    if (contract?.objectiveType === 'laps') {
      const unit = requiredCount === 1 ? 'Lap' : 'Laps'
      return `${progress}/${requiredCount} ${unit}`
    }
    const unit = requiredCount === 1 ? 'Event' : 'Events'
    return `${progress}/${requiredCount} ${unit}`
  }

  function availableContractObjectiveLabel(contract) {
    const requiredCount = Math.max(1, Math.floor(Number(contract?.requiredCount || 1)))
    if (contract?.objectiveType === 'laps') {
      const unit = requiredCount === 1 ? 'Lap' : 'Laps'
      return `${requiredCount} ${unit}`
    }
    const unit = requiredCount === 1 ? 'Event' : 'Events'
    return `${requiredCount} ${unit}`
  }

  function contractUrgencyTone(contract) {
    const minutes = displayRemaining(contract?.minutesRemaining)
    if (minutes < 1) return 'urgent'
    if (minutes <= 3) return 'soon'
    return 'normal'
  }

  function contractUrgencyLabel(contract) {
    return `${formatMinutes(displayRemaining(contract?.minutesRemaining))} left`
  }

  return {
    CLASS_BRANCHES, normalizeClassTier, formatClassLabelCompact, pwBucketX1000, formatSanctionedClassBadge,
    sanctionedRouteHintFor, sanctionedLapsLabelFor, sanctionedPwBucketSummary, sanctionedRefreshLabelFor, sanctionedStartLabelFor,
    sanctionedPlacesForOffer, formatTime, formatMinutes, formatPercent, bonusLabel,
    inferRouteTypeFromLabel, routeLabel, contractRaceLabel, contractVehicleLabel, contractTitle,
    sponsorTitle, sponsorRequirementHeadline, sponsorStatusLabel, sponsorStatusTone, sponsorOfferTone,
    sponsorOfferLabel, normalizeTargetType, formatTargetLabel, contractTargetLabel, objectiveStatusLabel,
    availableContractObjectiveLabel, contractUrgencyTone, contractUrgencyLabel,
  }
}

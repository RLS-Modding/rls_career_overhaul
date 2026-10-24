// Snapshot intake owns anchors; components derive time without rewriting shared state.
export function secondsUntil(expiresAt, nowSeconds) {
  return Number.isFinite(expiresAt) ? Math.max(0, Math.ceil(expiresAt - nowSeconds)) : 0
}

export function techProgressAt(tech, nowSeconds) {
  if (!tech?.jobId || !(tech.totalSeconds > 0) || !Number.isFinite(tech.startTime)) {
    return Math.min(1, Math.max(0, Number(tech?.progress) || 0))
  }
  return Math.min(1, Math.max(0, (nowSeconds - tech.startTime) / tech.totalSeconds))
}

function anchorTech(tech, nowSeconds) {
  let anchored = tech
  if (tech.jobId && tech.totalSeconds > 0 && !Number.isFinite(tech.startTime)) {
    const elapsed = tech.elapsedSeconds ?? (tech.totalSeconds - (tech.remainingSeconds ?? tech.totalSeconds))
    anchored = { ...anchored, startTime: nowSeconds - elapsed }
  }
  for (const [duration, expiry] of [
    ["postRaceCooldownRemainingSec", "postRaceCooldownExpiresAtSeconds"],
    ["secondsUntilScheduledRace", "scheduledRaceExpiresAtSeconds"],
  ]) {
    if (typeof tech[duration] === "number" && !Number.isFinite(tech[expiry])) {
      anchored = { ...anchored, [expiry]: nowSeconds + Math.max(0, tech[duration]) }
    }
  }
  return anchored
}

function anchorJob(job, nowSeconds) {
  if (Number.isFinite(job.expiresAtSeconds) || typeof job.expiresInSeconds !== "number") return job
  return { ...job, expiresAtSeconds: nowSeconds + Math.max(0, job.expiresInSeconds) }
}

function anchorVehicle(vehicle, nowSeconds) {
  if (!vehicle) return vehicle
  let anchored = vehicle
  for (const [duration, expiry] of [
    ["kitInstallTimeRemaining", "kitInstallExpiresAtSeconds"],
    ["deliverySecondsRemaining", "deliveryExpiresAtSeconds"],
  ]) {
    if (typeof vehicle[duration] === "number" && !Number.isFinite(vehicle[expiry])) {
      anchored = { ...anchored, [expiry]: nowSeconds + Math.max(0, vehicle[duration]) }
    }
  }
  return anchored
}

export function anchorBusinessTimers(data, nowSeconds = Math.floor(Date.now() / 1000)) {
  const anchored = { ...data }
  if (data.techs) anchored.techs = (Array.isArray(data.techs) ? data.techs : Object.values(data.techs)).map(tech => anchorTech(tech, nowSeconds))
  if (Array.isArray(data.newJobs)) anchored.newJobs = data.newJobs.map(job => anchorJob(job, nowSeconds))
  if (Array.isArray(data.vehicles)) anchored.vehicles = data.vehicles.map(vehicle => anchorVehicle(vehicle, nowSeconds))
  else if (data.vehicles && typeof data.vehicles === "object") {
    anchored.vehicles = Object.fromEntries(Object.entries(data.vehicles).map(([id, vehicle]) => [id, anchorVehicle(vehicle, nowSeconds)]))
  }
  if (Array.isArray(data.pulledOutVehicles)) anchored.pulledOutVehicles = data.pulledOutVehicles.map(vehicle => anchorVehicle(vehicle, nowSeconds))
  if (data.pulledOutVehicle) anchored.pulledOutVehicle = anchorVehicle(data.pulledOutVehicle, nowSeconds)
  if (typeof data.managerTimeRemaining === "number" && !Number.isFinite(data.managerExpiresAtSeconds)) {
    anchored.managerExpiresAtSeconds = nowSeconds + Math.max(0, data.managerTimeRemaining)
  }
  if (typeof data.racingTeamManagerAssignIntervalRemainingSec === "number" && !Number.isFinite(data.racingManagerExpiresAtSeconds)) {
    anchored.racingManagerExpiresAtSeconds = nowSeconds + Math.max(0, data.racingTeamManagerAssignIntervalRemainingSec)
  }
  if (data.racingTeamFleetCooldowns && !data.fleetCooldownExpiresAtSeconds) {
    anchored.fleetCooldownExpiresAtSeconds = Object.fromEntries(Object.entries(data.racingTeamFleetCooldowns)
      .map(([id, seconds]) => [id, nowSeconds + Math.max(0, Number(seconds) || 0)]))
  }
  return anchored
}

// Keep stable lists and objects intact when a reconciliation read repeats them.
export function assignChanged(target, source) {
  for (const [key, value] of Object.entries(source)) {
    if (Object.is(target[key], value)) continue
    if (value && typeof value === "object" && JSON.stringify(target[key]) === JSON.stringify(value)) continue
    target[key] = value
  }
}

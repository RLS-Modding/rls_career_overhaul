export const formatCurrency = (amount) => {
  if (amount === null || amount === undefined) return '$0'
  const num = Math.abs(amount)
  const sign = amount < 0 ? '-' : ''
  if (num >= 1000000) return sign + '$' + (num / 1000000).toFixed(2) + 'M'
  if (num >= 1000) return sign + '$' + (num / 1000).toFixed(1) + 'k'
  return sign + '$' + Math.floor(num).toLocaleString()
}

export const formatPrice = (price) => {
  const rounded = Math.round(price * 100) / 100
  return rounded.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 })
}

export const formatTime = (time, decimalPlaces = 0) => {
  if (typeof time !== 'number' || isNaN(time)) return time || '0s'
  if (time >= 3600) {
    const hours = Math.floor(time / 3600)
    const minutes = Math.floor((time % 3600) / 60)
    return minutes >= 1 ? `${hours}h ${minutes}m` : `${hours}h`
  }
  if (time >= 60) {
    const minutes = Math.floor(time / 60)
    const seconds = Math.round(time % 60)
    return seconds >= 1 ? `${minutes}m ${seconds}s` : `${minutes}m`
  }
  return decimalPlaces > 0 ? `${time.toFixed(decimalPlaces)}s` : `${Math.round(time)}s`
}

export const formatPhase = (tech, short = false) => {
  const map = {
    baseline: short ? "Baseline" : "Baseline Run",
    validation: short ? "Validating" : "Validation Run",
    postUpdate: short ? "Verifying" : "Verification",
    completed: short ? "Done" : "Completed",
    failed: "Failed",
    idle: "Idle",
    build: "Building",
    update: "Tuning",
    cooldown: short ? "Cooldown" : "Cooling Down"
  }
  return tech.label || map[tech.phase] || tech.action || "Working"
}

export const formatExpiry = (seconds) => {
  if (typeof seconds !== 'number') return 'Unknown'
  if (seconds <= 0) return 'Expired'
  return formatTime(seconds)
}

export const normalizeId = (id) => {
  if (id === undefined || id === null) return null
  const num = Number(id)
  return isNaN(num) ? String(id) : num
}

export const getConditionText = (mileage) => {
  if (mileage < 10000) return 'Excellent'
  if (mileage < 50000) return 'Good'
  if (mileage < 100000) return 'Fair'
  return 'Poor'
}

export const getConditionClass = (mileage) => {
  if (mileage < 10000) return 'condition-excellent'
  if (mileage < 50000) return 'condition-good'
  if (mileage < 100000) return 'condition-fair'
  return 'condition-poor'
}

export const getConditionClassFromText = (text) => {
  const classes = {
    'Excellent': 'condition-excellent',
    'Good': 'condition-good',
    'Fair': 'condition-fair',
    'Poor': 'condition-poor'
  }
  return classes[text] || ''
}


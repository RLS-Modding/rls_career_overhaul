// Display helpers for the Loading Work phone screen.
// Each function takes every value it reads as an argument, so the panels and the view share them without shared state.

export const SECONDS_PER_HOUR = 3600
export const EXPIRING_SOON_HOURS = 1
export const EXPIRING_WARNING_HOURS = 2
export const LOW_STOCK_RATIO = 0.2
export const MEDIUM_STOCK_RATIO = 0.5

export const formatNumber = (num) => {
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M'
  if (num >= 1000) return (num / 1000).toFixed(1) + 'k'
  return Math.round(num).toString()
}

export const formatDistance = (distance) => {
  if (!distance) return 'Unknown'
  if (distance < 1000) {
    return Math.round(distance) + ' m'
  }
  return (distance / 1000).toFixed(1) + ' km'
}

export const getTierClass = (tier) => {
  return `tier-${tier || 1}`
}

// The sim clock is null until the first state update carries one.
export const getTimeRemaining = (contract, currentSimTime) => {
  if (!contract) return 0
  if (contract.expiresAtSimTime && currentSimTime !== null) {
    const secondsRemaining = contract.expiresAtSimTime - currentSimTime
    return Math.max(0, secondsRemaining / SECONDS_PER_HOUR)
  }
  if (contract.hoursRemaining !== undefined) {
    return contract.hoursRemaining
  }
  return 0
}

export const formatTimeRemaining = (contract, currentSimTime) => {
  if (!contract) return 'No expiration'

  let secondsRemaining = 0
  if (contract.expiresAtSimTime && currentSimTime !== null) {
    secondsRemaining = contract.expiresAtSimTime - currentSimTime
    secondsRemaining = Math.max(0, secondsRemaining)
  } else if (contract.hoursRemaining !== undefined) {
    secondsRemaining = contract.hoursRemaining * SECONDS_PER_HOUR
  } else {
    return 'No expiration'
  }

  if (secondsRemaining <= 0) return 'Expired'

  const totalSeconds = Math.floor(secondsRemaining)
  const hours = Math.floor(totalSeconds / SECONDS_PER_HOUR)
  const minutes = Math.floor((totalSeconds % SECONDS_PER_HOUR) / 60)
  const seconds = totalSeconds % 60

  if (hours > 0) {
    return `${hours}h ${minutes}m ${seconds}s`
  } else if (minutes > 0) {
    return `${minutes}m ${seconds}s`
  } else {
    return `${seconds}s`
  }
}

export const getExpirationClass = (hoursRemaining) => {
  if (hoursRemaining <= EXPIRING_SOON_HOURS) return 'expiring-soon'
  if (hoursRemaining <= EXPIRING_WARNING_HOURS) return 'expiring-warning'
  return 'expiring-normal'
}

export const getMaterialDelivered = (progress, materialKey) => {
  if (!progress.deliveredItemsByMaterial) return 0
  return progress.deliveredItemsByMaterial[materialKey] || 0
}

export const getMaterialProgressPercent = (progress, mat) => {
  if (!mat || !mat.required || mat.required === 0) return 0
  const delivered = getMaterialDelivered(progress, mat.materialKey) || 0
  return Math.min(100, (delivered / mat.required) * 100)
}

export const mergeMaterialNameAndUnit = (materialName, units) => {
  if (!materialName || !units) return materialName || units || ''

  const nameLower = materialName.toLowerCase()
  const unitLower = units.toLowerCase()
  const unitSingular = unitLower.replace(/s$/, '')

  if (nameLower.includes(unitSingular) || nameLower.includes(unitLower)) {
    return materialName
  }

  return `${materialName} ${units}`
}

// No template reads this one.
export const getMaterialDisplayName = (matKey, zone) => {
  if (!zone || !zone.stock || !zone.stock.materialStocks) return matKey

  const stockData = zone.stock.materialStocks[matKey]
  if (stockData && stockData.materialName) {
    return stockData.materialName
  }

  const matIndex = zone.materialKeys ? zone.materialKeys.indexOf(matKey) : -1
  if (matIndex >= 0 && zone.materials && zone.materials[matIndex]) {
    return zone.materials[matIndex]
  }

  return matKey
}

export const getMaterialDisplayNameWithUnits = (matKey, zone) => {
  if (!zone || !zone.stock || !zone.stock.materialStocks) return matKey

  const stockData = zone.stock.materialStocks[matKey]
  if (stockData && stockData.materialName && stockData.units) {
    return mergeMaterialNameAndUnit(stockData.materialName, stockData.units)
  }

  const matIndex = zone.materialKeys ? zone.materialKeys.indexOf(matKey) : -1
  if (matIndex >= 0 && zone.materials && zone.materials[matIndex]) {
    return zone.materials[matIndex]
  }

  return matKey
}

// No template reads this one.
export const formatBlockRequirements = (blocks) => {
  if (!blocks) return '? blocks'
  const parts = []
  if (blocks.big > 0) {
    parts.push(`${blocks.big} Large`)
  }
  if (blocks.small > 0) {
    parts.push(`${blocks.small} Small`)
  }
  if (parts.length === 0) return '? blocks'
  return parts.join(' + ') + ' block' + (blocks.total > 1 ? 's' : '')
}

// No template reads this one.
export const formatBlockProgress = (delivered, required) => {
  if (!delivered || !required) return 'Loading...'
  const parts = []
  if (required.big > 0) {
    parts.push(`${delivered.big || 0}/${required.big} Large`)
  }
  if (required.small > 0) {
    parts.push(`${delivered.small || 0}/${required.small} Small`)
  }
  if (parts.length === 0) return '0 blocks'
  return parts.join(', ')
}

export const getStockLevelClass = (current, max) => {
  if (max <= 0) return 'empty'
  const percent = current / max
  if (percent < LOW_STOCK_RATIO) return 'low'
  if (percent < MEDIUM_STOCK_RATIO) return 'medium'
  return 'high'
}

export const getTruckStatusIcon = (status) => {
  const icons = {
    none: '',
    spawning: '⏳',
    arriving: '🚚',
    at_zone: '✅',
    delivering: '🚛',
    at_destination: '📍'
  }
  return icons[status] || ''
}

export const getTruckStatusText = (status) => {
  const texts = {
    none: 'No truck',
    spawning: 'Truck spawning',
    arriving: 'Truck arriving',
    at_zone: 'Truck at zone',
    delivering: 'Truck delivering',
    at_destination: 'Truck at destination'
  }
  return texts[status] || status
}

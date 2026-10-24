// Rounding that runs when a numeric field is committed (Enter or blur). Each function returns the value to
// store, or undefined when nothing should be stored. Rounding is half-up to the nearest step.
function roundToStep(value, step) {
  return Math.floor((value / step) + 0.5) * step
}

export function roundVariableValue(value, props) {
  if (value === undefined || value === null) return undefined

  const step = props.step || 1
  if (step <= 0) return undefined

  let rounded = roundToStep(value, step)

  // Enforce min/max constraints
  const min = props.min
  const max = props.max
  if (min !== undefined && rounded < min) {
    rounded = min
  }
  if (max !== undefined && rounded > max) {
    rounded = max
  }
  return rounded
}

export function roundEconomyValue(value) {
  if (value === undefined || value === null) return undefined

  const step = 0.25
  const min = 0.0  // Allow 0 for disabled modules
  const max = 10.0

  let rounded = roundToStep(value, step)

  // Enforce min/max constraints
  if (rounded < min) {
    rounded = min
  }
  if (rounded > max) {
    rounded = max
  }
  return rounded
}

export function roundLoanValue(value, loansRequired) {
  if (value === undefined || value === null) return undefined

  const step = 1000
  const min = loansRequired ? 10000 : 0
  const max = 10000000

  let rounded = roundToStep(value, step)

  // Enforce min/max constraints
  if (rounded < min) {
    rounded = min
  }
  if (rounded > max) {
    rounded = max
  }
  return rounded
}

export function roundCapitalValue(value) {
  if (value === undefined || value === null) return undefined

  const step = 500

  let rounded = roundToStep(value, step)

  // Enforce min constraint (no max)
  if (rounded < 0) {
    rounded = 0
  }
  return rounded
}

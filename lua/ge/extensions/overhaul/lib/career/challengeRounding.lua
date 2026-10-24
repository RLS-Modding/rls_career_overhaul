-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Rounding and validation for challenge settings: economy multipliers, loan amounts and starting capital.
-- Each setting snaps to its step and clamps to its range; a non-number falls back to its default.
local M = {}

-- Zero disables an activity and must survive rounding.
M.ECONOMY_MULTIPLIER_STEP = 0.25
M.ECONOMY_MULTIPLIER_MIN = 0.0
M.ECONOMY_MULTIPLIER_MAX = 10.0

M.LOAN_AMOUNT_STEP = 1000
M.LOAN_AMOUNT_MIN = 0
M.LOAN_AMOUNT_MAX = 10000000

M.STARTING_CAPITAL_STEP = 500
M.STARTING_CAPITAL_MIN = 0
M.STARTING_CAPITAL_MAX = 4294967000

-- Rounds to the nearest step, then clamps to the range.
local function snap(value, step, minValue, maxValue)
  local rounded = math.floor((value / step) + 0.5) * step
  if minValue and rounded < minValue then rounded = minValue end
  if maxValue and rounded > maxValue then rounded = maxValue end
  return rounded
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
M.isFiniteNumber = isFiniteNumber

-- True when the value sits on a step, allowing for float error of 0.01.
local function isStepMultiple(value, step)
  local remainder = value % step
  return math.abs(remainder) <= 0.01 or math.abs(remainder - step) <= 0.01
end

function M.roundEconomyMultiplier(value)
  if not isFiniteNumber(value) then
    return 1.0
  end
  return snap(value, M.ECONOMY_MULTIPLIER_STEP, M.ECONOMY_MULTIPLIER_MIN, M.ECONOMY_MULTIPLIER_MAX)
end

function M.roundLoanAmount(value)
  if not isFiniteNumber(value) then
    return M.LOAN_AMOUNT_MIN
  end
  return snap(value, M.LOAN_AMOUNT_STEP, M.LOAN_AMOUNT_MIN, M.LOAN_AMOUNT_MAX)
end

function M.roundStartingCapital(value)
  if not isFiniteNumber(value) then
    return M.STARTING_CAPITAL_MIN
  end
  return snap(value, M.STARTING_CAPITAL_STEP, M.STARTING_CAPITAL_MIN, M.STARTING_CAPITAL_MAX)
end

function M.economyMultiplierToSteps(multiplier)
  return math.floor((M.roundEconomyMultiplier(multiplier) / M.ECONOMY_MULTIPLIER_STEP) + 0.5)
end

function M.stepsToEconomyMultiplier(steps)
  return (tonumber(steps) or 0) * M.ECONOMY_MULTIPLIER_STEP
end

-- Returns true, or false and the message to show the player.
function M.validateEconomyMultiplier(value)
  if not isFiniteNumber(value) then
    return false, "Invalid multiplier value"
  end
  if value < M.ECONOMY_MULTIPLIER_MIN or value > M.ECONOMY_MULTIPLIER_MAX then
    return false, string.format("Multiplier must be between %.2f and %.2f", M.ECONOMY_MULTIPLIER_MIN, M.ECONOMY_MULTIPLIER_MAX)
  end
  if value == 0 then
    return true
  end
  if not isStepMultiple(value, M.ECONOMY_MULTIPLIER_STEP) then
    return false, string.format("Multiplier must be a multiple of %.2f", M.ECONOMY_MULTIPLIER_STEP)
  end
  return true
end

function M.validateLoanAmount(value)
  if not isFiniteNumber(value) then
    return false, "Invalid loan amount value"
  end
  if value < M.LOAN_AMOUNT_MIN or value > M.LOAN_AMOUNT_MAX then
    return false, string.format("Loan amount must be between %d and %d", M.LOAN_AMOUNT_MIN, M.LOAN_AMOUNT_MAX)
  end
  if not isStepMultiple(value, M.LOAN_AMOUNT_STEP) then
    return false, string.format("Loan amount must be a multiple of %d", M.LOAN_AMOUNT_STEP)
  end
  return true
end

function M.validateStartingCapital(value)
  if not isFiniteNumber(value) then
    return false, "Invalid starting capital value"
  end
  if value < M.STARTING_CAPITAL_MIN then
    return false, "Starting capital must be non-negative"
  end
  if not isStepMultiple(value, M.STARTING_CAPITAL_STEP) then
    return false, string.format("Starting capital must be a multiple of %d", M.STARTING_CAPITAL_STEP)
  end
  return true
end

return M

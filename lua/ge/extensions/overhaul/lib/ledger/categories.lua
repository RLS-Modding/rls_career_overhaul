-- Categories attached to new ledger postings and historical money rows.
-- Existing persisted category names stay unchanged so old rows keep their meaning.
local M = {}

M.UNKNOWN = "unknown"

-- Values are one of BASE or "activity:<id>"; rows without one, including every historic row, read as "unknown".
M.BASE = {
  purchase = true,    -- vehicles, parts, garages, businesses, upgrades
  sale = true,        -- selling vehicles, parts, property, businesses
  repair = true,
  fuel = true,
  fine = true,
  insurance = true,
  gambling = true,
  transfer = true,    -- moving money between the player's own wallet and accounts
  loan = true,        -- loan disbursement and repayment
  property = true,    -- mortgage and rent
  service = true,     -- taxi fares and other paid services
  business = true,    -- business operating income and costs
  interest = true,    -- savings interest
  refund = true,
  reward = true,      -- milestones, challenges and other non-activity rewards
  cheat = true,       -- debug and tester changes
}

-- The stored category for a caller-supplied value, or nil when none was given.
function M.normalize(value)
  if value == nil then return nil end
  if type(value) ~= "string" then return M.UNKNOWN end
  if M.BASE[value] then return value end
  local activity = value:match("^activity:([%w_%-%.]+)$")
  if activity then return value end
  return M.UNKNOWN
end

-- The category a row reads as; an absent or invalid one reads as "unknown".
function M.of(row)
  local value = type(row) == "table" and row.category or nil
  return M.normalize(value) or M.UNKNOWN
end

function M.activity(id)
  return "activity:" .. tostring(id)
end

-- Display name: "Unknown" for a missing category.
function M.label(category)
  if category == nil or category == M.UNKNOWN then return "Unknown" end
  local activity = category:match("^activity:(.+)$")
  if activity then return activity end
  return category:sub(1, 1):upper() .. category:sub(2)
end

return M

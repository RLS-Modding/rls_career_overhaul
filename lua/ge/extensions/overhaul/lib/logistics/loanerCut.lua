-- Loaner organization cut rows for a delivery's reward breakdown, shared by cargo and vehicle deliveries.
-- One delivery pays one cut: the largest cut among the loaning organizations, never more than the money
-- earned before the cut. Every other loaning organization still gets its reputation row.
local M = {}

-- Cut taken when the organization has no reputation level data.
local DEFAULT_CUT = 0.5

-- The organization's cut (0..1) at its current reputation level. Level tables start at level -1, so level L is entry L+2.
function M.cutFor(organization)
  local level = organization and organization.reputation and organization.reputation.level
  local levelInfo = level and organization.reputationLevels and organization.reputationLevels[level + 2]
  return levelInfo and levelInfo.loanerCut and levelInfo.loanerCut.value or DEFAULT_CUT
end

local function sortedIds(organizationIds)
  local ids = {}
  for organizationId in pairs(organizationIds or {}) do table.insert(ids, organizationId) end
  table.sort(ids)
  return ids
end

-- Breakdown rows for the loaning organizations.
-- request.organizationIds: set of loaning organization ids
-- request.baseMoney: the delivery's original money reward, which the cut is a share of
-- request.moneyEarned: money earned so far (base plus earlier rows); the cut never takes more than this
-- request.getOrganization(id): organization data or nil
-- request.reputationFor(id): reputation the organization gains from the delivery
-- request.label(cut): row label for a cut
-- request.paysOwnCut(id): optional; true when the organization's cut is settled elsewhere (employer on shift)
function M.breakdownRows(request)
  local ids = sortedIds(request.organizationIds)
  local cuts, payerId = {}, nil
  for _, organizationId in ipairs(ids) do
    cuts[organizationId] = M.cutFor(request.getOrganization(organizationId))
    local settledElsewhere = request.paysOwnCut and request.paysOwnCut(organizationId)
    if not settledElsewhere and (not payerId or cuts[organizationId] > cuts[payerId]) then
      payerId = organizationId
    end
  end

  local rows = {}
  for _, organizationId in ipairs(ids) do
    local isPayer = organizationId == payerId
    local row = {
      label = request.label(isPayer and cuts[organizationId] or 0),
      rewards = {},
      simpleBreakdownType = "loaner",
    }
    if isPayer then
      local cutMoney = cuts[organizationId] * (tonumber(request.baseMoney) or 0)
      local moneyEarned = math.max(0, tonumber(request.moneyEarned) or 0)
      row.rewards.money = -math.min(cutMoney, moneyEarned)
    end
    row.rewards[organizationId .. "Reputation"] = request.reputationFor(organizationId)
    table.insert(rows, row)
  end
  return rows
end

-- Money a breakdown has added so far on top of the base reward.
function M.moneyEarned(baseMoney, breakdown)
  local total = tonumber(baseMoney) or 0
  for _, row in ipairs(breakdown or {}) do
    total = total + (tonumber(row.rewards and row.rewards.money) or 0)
  end
  return total
end

return M

-- Population-weighted draws from an already filtered dealer catalog.
-- No vehicle/model names or additional mod metadata are needed here.
local M = {}

function M.populationWeight(value)
  local number = tonumber(value)
  -- Missing/malformed metadata keeps the existing fallback of one. Explicit
  -- zero or negative population contributes no stock; never average or round it.
  if not number or number ~= number or number == math.huge or number == -math.huge then return 1 end
  return math.max(0, number)
end

function M.build(vehicles, configKey, stockPopulationWeight)
  stockPopulationWeight = stockPopulationWeight or M.populationWeight
  local pool = {categories = {}, byConfig = {}, byModel = {}}
  local categoriesByIndex = {}
  for _, vehicle in ipairs(vehicles) do
    local key = configKey(vehicle)
    local weight = stockPopulationWeight(vehicle.Population)
    if weight > 0 and not pool.byConfig[key] then
      local record = {vehicle = vehicle, key = key, weight = weight, memberships = {}}
      pool.byConfig[key] = record
      local model = vehicle.model_key
      pool.byModel[model] = pool.byModel[model] or {}
      table.insert(pool.byModel[model], record)
      local filters = vehicle.precomputedFilters
      if type(filters) ~= 'table' or not next(filters) then
        filters = {{filter = vehicle.precomputedFilter, probability = vehicle.subFilterProbability}}
      end
      local seen = {}
      for _, filter in ipairs(filters) do
        local index = filter.selectionIndex or (filter.filter and filter.filter._selectionIndex) or 1
        if not seen[index] then
          seen[index] = true
          local category = categoriesByIndex[index]
          if not category then
            category = {selectionIndex = index, probability = M.populationWeight(filter.probability), entries = {}}
            categoriesByIndex[index] = category
            table.insert(pool.categories, category)
          end
          table.insert(category.entries, record)
          table.insert(record.memberships, {category = category, index = #category.entries})
        end
      end
    end
  end
  table.sort(pool.categories, function(a, b) return a.selectionIndex < b.selectionIndex end)
  for _, category in ipairs(pool.categories) do
    local size = 1
    while size < #category.entries do size = size * 2 end
    category.size = size
    category.tree = {}
    for index = 1, size do
      category.tree[size + index - 1] = category.entries[index] and category.entries[index].weight or 0
    end
    for node = size - 1, 1, -1 do
      category.tree[node] = category.tree[node * 2] + category.tree[node * 2 + 1]
    end
  end
  return pool
end

-- Sparse tree updates preserve the immutable catalog and avoid rescanning it for each draw.
local function drawWeightedCategory(
  pool, validate, uniqueModels, random, modelLimit, blocked, deferred, selected, modelCounts,
  value, setWeight, block, blockModel, category
)
  local cursor, node = random() * value(category, 1), 1
  while node < category.size do
    local left = node * 2
    local weight = value(category, left)
    -- Rounded upper-bound draws must skip empty, padded or blocked subtrees.
    if cursor < weight or value(category, left + 1) <= 0 then
      node = left
    else
      cursor = cursor - weight
      node = left + 1
    end
  end
  local record = category.entries[node - category.size + 1]
  block(record) -- removes this config from every overlapping sub-filter
  if not validate or validate(record.vehicle) then
    table.insert(selected, {vehicle = record.vehicle, selectionIndex = category.selectionIndex})
    local model = record.vehicle.model_key
    modelCounts[model] = (modelCounts[model] or 0) + 1
    if modelLimit and modelCounts[model] >= modelLimit then blockModel(model) end
    if uniqueModels then
      for _, sibling in ipairs(pool.byModel[record.vehicle.model_key]) do
        if not blocked[sibling.key] then
          deferred[sibling.key] = sibling
          setWeight(sibling, 0)
        end
      end
    end
  end
end

local function drawWeights(pool, changes, blocked)
  local function value(category, node)
    local changed = changes[category]
    if changed and changed[node] ~= nil then return changed[node] end
    return category.tree[node]
  end
  local function setWeight(record, weight)
    for _, membership in ipairs(record.memberships) do
      local category = membership.category
      local changed = changes[category]
      if not changed then changed = {}; changes[category] = changed end
      local node = category.size + membership.index - 1
      changed[node] = weight
      while node > 1 do
        node = math.floor(node / 2)
        changed[node] = value(category, node * 2) + value(category, node * 2 + 1)
      end
    end
  end
  local function block(record)
    blocked[record.key] = true
    setWeight(record, 0)
  end
  local function blockModel(model)
    for _, record in ipairs(pool.byModel[model] or {}) do block(record) end
  end
  return {value = value, setWeight = setWeight, block = block, blockModel = blockModel}
end

local function chooseAvailableCategory(available, totalProbability, random)
  local category = available[#available]
  if totalProbability <= 0 then
    category = available[math.min(#available, math.floor(random() * #available) + 1)]
  else
    local cursor = random() * totalProbability
    for _, candidate in ipairs(available) do
      if cursor < candidate.probability then category = candidate; break end
      cursor = cursor - candidate.probability
    end
  end
  return category
end

function M.draw(pool, count, excludedKeys, validate, uniqueModels, random, modelLimit, stockedModels)
  random = random or math.random
  count = tonumber(count) or 0
  if count ~= count or count == math.huge then return {} end
  count = math.max(0, math.floor(count))
  if count == 0 then return {} end
  local changes, blocked, deferred, selected = {}, {}, {}, {}
  local modelCounts = {}
  modelLimit = tonumber(modelLimit)
  if modelLimit and (modelLimit ~= modelLimit or modelLimit <= 0 or modelLimit == math.huge) then
    modelLimit = nil
  end
  for model, amount in pairs(stockedModels or {}) do modelCounts[model] = amount end
  local weights = drawWeights(pool, changes, blocked)
  for key, excluded in pairs(excludedKeys or {}) do
    if excluded and pool.byConfig[key] then weights.block(pool.byConfig[key]) end
  end
  if modelLimit then
    for model, amount in pairs(modelCounts) do
      if amount >= modelLimit then weights.blockModel(model) end
    end
  end

  while #selected < count do
    local available, totalProbability = {}, 0
    for _, category in ipairs(pool.categories) do
      if weights.value(category, 1) > 0 then
        table.insert(available, category)
        totalProbability = totalProbability + category.probability
      end
    end
    if #available == 0 then
      if not next(deferred) then break end
      -- Prefer distinct models until every available model has had a turn.
      for key, record in pairs(deferred) do
        if not blocked[key] then weights.setWeight(record, record.weight) end
      end
      deferred = {}
      uniqueModels = false
    else
      local category = chooseAvailableCategory(available, totalProbability, random)
      drawWeightedCategory(
        pool, validate, uniqueModels, random, modelLimit, blocked, deferred, selected, modelCounts,
        weights.value, weights.setWeight, weights.block, weights.blockModel, category
      )
    end
  end
  return selected
end

return M

-- Blueprint retirement, dependency checks and permanent shop-record deletion.
-- Physical packages and manufacturing provenance belong to their inventory owners.
local M = {}

function M.new(inputs)
  local recipeRules = require("overhaul/career/parts/engines/enginePackages/packages/recipes")
  local host, sales = inputs.host, inputs.sales
  local pendingInstalls = {}
  local api = {}

  local function matches(record, blueprint)
    local blueprintId = record.blueprintId or record.revisionId
    if blueprintId ~= nil then return tostring(blueprintId) == tostring(blueprint.id) end
    if blueprint.recipeSignature == nil or record.recipeSignature ~= blueprint.recipeSignature then return false end
    if record.recipe and blueprint.recipe and blueprint.recipe.tree then
      return recipeRules.recipesMatch(record.recipe, blueprint.recipe)
    end
    -- Older pending records may carry only a signature; keep their safety block.
    return true
  end

  local function recipeInList(recipes, recipe)
    for _, candidate in ipairs(recipes or {}) do
      if recipeRules.recipesMatch(candidate, recipe) then return true end
    end
    return false
  end

  local function removeRecipe(recipes, recipe)
    for index = #recipes, 1, -1 do
      if recipeRules.recipesMatch(recipes[index], recipe) then table.remove(recipes, index) end
    end
  end

  function api.isRecipeExcluded(state, recipe)
    local exclusion = (state.deletedBlueprintSignatures or {})[recipe.signature]
    if exclusion == true then return true end
    if type(exclusion) ~= "table" then return false end
    if exclusion.allRecipes then return not recipeInList(exclusion.restoredRecipes, recipe) end
    return recipeInList(exclusion.recipes, recipe)
  end

  function api.clearRecipeExclusion(state, recipe)
    local exclusions = state.deletedBlueprintSignatures or {}
    local exclusion = exclusions[recipe.signature]
    -- A legacy hash-wide exclusion has no recipe to recover. Allow only the paid
    -- recipe back, leaving other colliding packages excluded.
    if exclusion == true then exclusion = {allRecipes = true, restoredRecipes = {}}; exclusions[recipe.signature] = exclusion end
    if type(exclusion) ~= "table" then return end
    if exclusion.allRecipes then
      exclusion.restoredRecipes = exclusion.restoredRecipes or {}
      if not recipeInList(exclusion.restoredRecipes, recipe) then
        exclusion.restoredRecipes[#exclusion.restoredRecipes + 1] = deepcopy(recipe)
      end
    else
      removeRecipe(exclusion.recipes, recipe)
      if #exclusion.recipes == 0 then exclusions[recipe.signature] = nil end
    end
  end

  local function excludeRecipe(state, blueprint)
    local signature, recipe = blueprint.recipeSignature, blueprint.recipe
    if not signature then return end
    state.deletedBlueprintSignatures = state.deletedBlueprintSignatures or {}
    local exclusions = state.deletedBlueprintSignatures
    if not recipe or not recipe.tree then exclusions[signature] = true; return end
    local exclusion = exclusions[signature]
    if exclusion == true then return end
    if not exclusion then exclusion = {recipes = {}}; exclusions[signature] = exclusion end
    if exclusion.allRecipes then
      removeRecipe(exclusion.restoredRecipes, recipe)
    elseif not recipeInList(exclusion.recipes, recipe) then
      exclusion.recipes[#exclusion.recipes + 1] = deepcopy(recipe)
    end
  end

  function api.reset()
    pendingInstalls = {}
  end

  -- A failed install can return stock after it has temporarily left the warehouse.
  function api.beginWarehouseInstall(businessId, blueprintId)
    local installs = pendingInstalls
    local key = tostring(businessId) .. ":" .. tostring(blueprintId)
    installs[key] = (installs[key] or 0) + 1
    local finished = false
    return function()
      if finished or installs ~= pendingInstalls then return false end
      finished = true
      installs[key] = installs[key] - 1
      if installs[key] == 0 then installs[key] = nil end
      return true
    end
  end

  function api.deleteBlockedReason(businessId, state, blueprint)
    local blueprintId = tostring(blueprint.id)
    if pendingInstalls[tostring(businessId) .. ":" .. blueprintId] then
      return "Wait for this engine's installation to finish before deleting its blueprint."
    end
    for _, line in ipairs(state.lines) do
      -- The last completed unit can leave a fractional frame on an idle line.
      if tostring(line.blueprintId) == blueprintId and (line.running or line.attemptStarted) then
        return blueprint.removed and "Restore this blueprint and finish its production attempt before deleting it."
          or "Stop production and finish any current attempt before deleting this blueprint."
      end
    end
    if (tonumber(state.rawStock[blueprintId]) or 0) > 0 then
      return blueprint.removed and "Restore this blueprint and use its remaining raw material before deleting it."
        or "Use the remaining raw material before deleting this blueprint."
    end
    if (tonumber((state.legacyFinishedToMaterialize or {})[blueprintId]) or 0) > 0 then
      return "Make room in the warehouse and clear this engine's saved stock before deleting its blueprint."
    end
    if #host.warehousePackages(businessId, blueprintId) > 0 then
      return "Sell, install or junk this engine's warehouse stock before deleting its blueprint."
    end
    for _, reservation in pairs(state.reservations) do
      if matches(reservation, blueprint) and reservation.status ~= "delivered" and reservation.status ~= "cancelled" then
        return "Collect pending material orders and use their material before deleting this blueprint."
      end
    end
    for _, job in pairs(state.certificationJobs) do
      if not job.completed and matches(job, blueprint) then
        return "Wait for this engine's certification to finish before deleting its blueprint."
      end
    end
    for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
      local certification = package.engineShopCertification
      if certification and certification.status == "pending" and matches(certification, blueprint) then
        return "Wait for this engine's stress test to finish before deleting its blueprint."
      end
    end
  end

  function api.setBlueprintRemoved(businessId, blueprintId, removed)
    if not inputs.owned(businessId) then return {success = false, message = "This Engine Workshop is not owned."} end
    local state = host.ensureState(businessId)
    local blueprint = state.blueprints[tostring(blueprintId)]
    if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
    blueprint.removed = removed == true
    if blueprint.removed then
      blueprint.listed = false
      for _, line in ipairs(state.lines) do
        if tostring(line.blueprintId) == tostring(blueprintId) then line.running = false end
      end
    end
    sales.ensureSalesCycle(businessId, state)
    local message = " restored. Production and sales can be started again."
    if blueprint.removed then message = " removed. Production and sales are paused; its history is kept."
    elseif blueprint.certification.status ~= "passed" then
      message = " restored. A passing certification is required before production or sales can resume."
    end
    return {success = true, message = blueprint.name .. message}
  end

  local function removeRows(rows, blueprint)
    for index = #rows, 1, -1 do
      if matches(rows[index], blueprint) then table.remove(rows, index) end
    end
  end

  local function removeLegacyRecords(state, blueprint)
    local blueprintId = tostring(blueprint.id)
    if state.revisions then state.revisions[blueprintId] = nil end
    if state.finishedStock then state.finishedStock[blueprintId] = nil end
    for productId, product in pairs(state.products or {}) do
      for index = #(product.revisionIds or {}), 1, -1 do
        if tostring(product.revisionIds[index]) == blueprintId then table.remove(product.revisionIds, index) end
      end
      if tostring(product.activeRevisionId) == blueprintId then product.activeRevisionId = nil end
      if tostring(product.salesRevisionId) == blueprintId then product.salesRevisionId, product.listed = nil, false end
      if #(product.revisionIds or {}) == 0 then state.products[productId] = nil end
    end
  end

  function api.deleteBlueprint(businessId, blueprintId, confirmedName)
    if not inputs.owned(businessId) then return {success = false, message = "This Engine Workshop is not owned."} end
    local state = host.ensureState(businessId)
    blueprintId = tostring(blueprintId)
    local blueprint = state.blueprints[blueprintId]
    if not blueprint then return {success = false, message = "Certified engine blueprint not found."} end
    if confirmedName ~= blueprint.name then
      return {success = false, message = "Review and confirm deletion of " .. blueprint.name .. "."}
    end
    local reason = api.deleteBlockedReason(businessId, state, blueprint)
    if reason then return {success = false, message = reason} end
    -- Keep only an import exclusion, so surviving certified packages cannot recreate
    -- the deleted recipe on refresh. A new paid certification clears this exclusion.
    excludeRecipe(state, blueprint)
    for _, line in ipairs(state.lines) do
      if tostring(line.blueprintId) == blueprintId then
        line.blueprintId, line.running, line.progressSeconds, line.attemptStarted = nil, false, 0, false
      end
      removeRows(line.attempts, blueprint)
    end
    for key, job in pairs(state.certificationJobs) do
      if matches(job, blueprint) then state.certificationJobs[key] = nil end
    end
    for key, reservation in pairs(state.reservations) do
      if matches(reservation, blueprint) then state.reservations[key] = nil end
    end
    removeRows(state.salesHistory, blueprint)
    removeLegacyRecords(state, blueprint)
    state.rawStock[blueprintId] = nil
    if state.legacyFinishedToMaterialize then state.legacyFinishedToMaterialize[blueprintId] = nil end
    if state.salesCurrentBlueprintId == blueprintId then sales.resetSalesCycle(state) end
    if state.salesCursorBlueprintId == blueprintId then state.salesCursorBlueprintId = nil end
    state.blueprints[blueprintId] = nil
    sales.ensureSalesCycle(businessId, state)
    return {success = true, message = blueprint.name .. " permanently deleted. Existing engines are unchanged."}
  end

  return api
end

return M

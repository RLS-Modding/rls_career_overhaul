-- Engine recipes: manufactured parts, package references and warehouse transfers.
-- Read the named sections below in order; the final API binds the owner's game hooks.

local recipes = {}

function recipes.create(inputs)
  local parts = inputs.parts

  -- Dependencies -------------------------------------------------------------------------------------

  local packageStore = inputs.packageStore
  local packageReferenceGuardIndices = {}

  -- Signatures and compatibility keys ------------------------------------------------------------------

  local function stableEncode(value)
    local kind = type(value)
    if kind ~= "table" then return kind .. ":" .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {"{"}
    for _, key in ipairs(keys) do
      out[#out + 1] = stableEncode(key)
      out[#out + 1] = "="
      out[#out + 1] = stableEncode(value[key])
      out[#out + 1] = ";"
    end
    out[#out + 1] = "}"
    return table.concat(out)
  end

  -- FNV-1a over the encoded text, so the same recipe always gets the same signature.
  local function hashText(text)
    local hash = 2166136261
    for index = 1, #text do
      hash = (hash * 16777619 + string.byte(text, index)) % 4294967296
    end
    return string.format("%08x", hash)
  end

  local function computeRecipeSignature(recipe)
    local normalized = deepcopy(recipe or {})
    normalized.signature = nil
    normalized.recipeSignature = nil
    return "ep2-" .. hashText(stableEncode(normalized))
  end

  -- The exact engine attachment surfaces on the spawned vehicle, not just its model name. Retail stock uses this key so two configurations of the same model do not share incompatible stock.
  local function attachmentSurfacesOf(runtimeData)
    local surfaces = {}
    for _, candidate in ipairs(parts.capture.findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
      surfaces[#surfaces + 1] = {
        path = tostring(candidate.path or ""),
        slotName = tostring(candidate.slotName or ""),
        parentPartName = tostring(candidate.parentPartName or "")
      }
    end
    table.sort(surfaces, function(a, b)
      return (a.path .. "|" .. a.slotName .. "|" .. a.parentPartName)
        < (b.path .. "|" .. b.slotName .. "|" .. b.parentPartName)
    end)
    return surfaces
  end

  local function getEngineCompatibilityKey(inventoryId)
    inventoryId = tonumber(inventoryId)
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local runtimeData = parts.capture.getRuntimeVehicleData(inventoryId)
    if not vehicle or not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
      return nil, "The selected vehicle is not spawned."
    end
    local surfaces = attachmentSurfacesOf(runtimeData)
    if #surfaces == 0 then return nil, "No combustion-engine attachment point was found." end
    return computeRecipeSignature({vehicleModel = tostring(vehicle.model), attachmentSurfaces = surfaces})
  end

  -- Recipes and values ---------------------------------------------------------------------------------

  local function recipeTreeFromPackageNode(node)
    if type(node) ~= "table" or not node.name then return nil end
    local result = {name = node.name, slotName = node.slotName or node.relativeSlot, children = {}}
    for slotName, child in pairs(node.children or {}) do
      result.children[slotName] = recipeTreeFromPackageNode(child)
    end
    return result
  end

  local function getRecipeFromPackage(packageId)
    local package = type(packageId) == "table" and packageId or inputs.getPackageById(packageId)
    if not package or type(package.tree) ~= "table" then return nil, "Engine Package not found." end
    local recipe = {
      vehicleModel = package.createdModel or package.lastInstalledModel,
      rootSlotName = package.rootSlotName,
      rootPath = package.rootPath,
      rootEngineName = package.rootEngineName or package.tree.name,
      rootEngineNiceName = package.rootEngineNiceName or package.rootEngineName or package.tree.name,
      tree = recipeTreeFromPackageNode(package.tree),
      tuning = deepcopy(package.tuning or {})
    }
    if not recipe.vehicleModel or not recipe.rootSlotName or not recipe.tree then
      return nil, "Engine Package compatibility metadata is incomplete."
    end
    recipe.signature = computeRecipeSignature(recipe)
    return recipe
  end

  -- Sum of the authored value of every part in the recipe tree, at the vehicle model's own catalog prices.
  local function getFreshPackageValue(packageId)
    local package = type(packageId) == "table" and packageId or inputs.getPackageById(packageId)
    local recipe, err = getRecipeFromPackage(package)
    if not recipe then return nil, err end
    local ioCtx
    local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
    if FS:directoryExists(vehicleDir) then ioCtx = inputs.jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) end
    if not ioCtx then return nil, "The package vehicle model is unavailable." end
    local available = inputs.jbeamIO.getAvailableParts(ioCtx) or {}
    local total = 0
    local function visit(node)
      local info = available[node.name] or {}
      local data = inputs.jbeamIO.getPart(ioCtx, node.name) or {}
      total = total + math.max(0, tonumber(info.value)
        or tonumber(info.information and info.information.value)
        or tonumber(data.information and data.information.value) or 0)
      for _, child in pairs(node.children or {}) do visit(child) end
    end
    visit(recipe.tree)
    return math.max(1, math.floor(total + 0.5)), recipe
  end

  local function setEngineShopCertification(packageId, certification)
    local package = inputs.getPackageById(packageId)
    if not package or inputs.isBusinessPackage(package) then return false, "Personal Engine Package not found." end
    package.engineShopCertification = certification and deepcopy(certification) or nil
    package.updatedAt = os.time()
    inputs.sendUIData()
    return true
  end

  -- Drops a certification whose recipe has changed since the test was run.
  local function refreshCertificationValidity(package)
    local certification = package and package.engineShopCertification
    if not certification or not certification.recipeSignature then return end
    local recipe = getRecipeFromPackage(package)
    if not recipe or tostring(recipe.signature) ~= tostring(certification.recipeSignature) then
      package.engineShopCertification = nil
    end
  end

  -- Reference guards -----------------------------------------------------------------------------------

  -- A stable owner replaces stale callbacks after reload; unowned callbacks use their identity.
  local function registerPackageReferenceGuard(callback, owner)
    if type(callback) ~= "function" then return false end
    local key = owner or callback
    local index = packageReferenceGuardIndices[key]
    if index then
      if inputs.packageReferenceGuards[index] ~= callback then inputs.packageReferenceGuards[index] = callback end
      return true
    end
    inputs.packageReferenceGuards[#inputs.packageReferenceGuards + 1] = callback
    packageReferenceGuardIndices[key] = #inputs.packageReferenceGuards
    return true
  end

  -- The first guard that refuses the package gives the reason; otherwise nil.
  local function firstReferenceRefusal(package)
    for _, guard in ipairs(inputs.packageReferenceGuards) do
      local ok, reason = guard(package)
      if ok == false then return reason or "Package is protected." end
    end
  end

  local function removeBusinessPackage(packageId)
    local package = inputs.getPackageById(packageId)
    if not inputs.isBusinessPackage(package) then return false, "Business package not found." end
    local refusal = firstReferenceRefusal(package)
    if refusal then return false, refusal end
    inputs.clearPackageFlags(package)
    inputs.removePackage(package.id, false)
    return true
  end

  -- Personal clones -----------------------------------------------------------------------------------

  local function addPersonalRecipeNode(node, packageId, vehicleModel, manufacturedYear, parentSlot, path, created)
    local copy = {name = node.name, slotName = node.slotName, children = {}}
    local before = {}
    for id in pairs(inputs.getPartInventory()) do before[tostring(id)] = true end
    overhaul_career_parts_partInventory.addPartToInventory({
      name = node.name,
      vehicleModel = vehicleModel,
      value = parts.capture.getAuthoredPartValue(vehicleModel, node.name),
      slot = node.slotName or parentSlot,
      containingSlot = path or "/",
      location = 0,
      enginePackageId = packageId,
      year = manufacturedYear,
      manufacturedYear = manufacturedYear,
      engineShopManufactured = true,
      factoryPackageId = tostring(packageId),
      tags = {engineShopManufactured = true, manufacturedYear = manufacturedYear, factoryPackageId = tostring(packageId)},
      mainPart = true,
      partCondition = {integrityValue = 1, visualValue = 1, odometer = 0}
    })
    for id in pairs(inputs.getPartInventory()) do
      if not before[tostring(id)] then copy.partId = tonumber(id) or id break end
    end
    if not copy.partId then return nil, "Could not create a physical engine part." end
    if created then created[#created + 1] = copy.partId end
    -- Newer career saves reload the inventory as a list keyed by each row's explicit partId. The vanilla insertion helper only assigns the table key, so generated packages must mirror that key into the persisted record.
    inputs.getPartInventory()[copy.partId].partId = copy.partId
    for slotName, child in pairs(node.children or {}) do
      local childCopy, err = addPersonalRecipeNode(child, packageId, vehicleModel, manufacturedYear,
        slotName, (path or "/") .. slotName .. "/", created)
      if not childCopy then return nil, err end
      copy.children[slotName] = childCopy
    end
    return copy
  end

  local function addBusinessRecipeNode(node, packageId, vehicleModel, businessId, revisionId, manufacturedYear, parentSlot, path, created)
    local copy = {name = node.name, slotName = node.slotName, children = {}}
    local partId = overhaul_career_business_partInventory.addPart({
      name = node.name,
      vehicleModel = vehicleModel,
      slot = node.slotName or parentSlot,
      containingSlot = path or "/",
      partPath = (path or "/") .. tostring(node.name or ""),
      location = 0,
      enginePackageId = packageId,
      productRevisionId = revisionId,
      year = manufacturedYear,
      manufacturedYear = manufacturedYear,
      engineShopManufactured = true,
      factoryPackageId = tostring(packageId),
      tags = {engineShopManufactured = true, manufacturedYear = manufacturedYear, factoryPackageId = tostring(packageId)},
      mainPart = true,
      partCondition = {integrityValue = 1, visualValue = 1, odometer = 0}
    }, businessId)
    if not partId then return nil, "Could not create a physical business engine part." end
    copy.partId = partId
    if created then created[#created + 1] = partId end
    for slotName, child in pairs(node.children or {}) do
      local childCopy, err = addBusinessRecipeNode(child, packageId, vehicleModel, businessId, revisionId,
        manufacturedYear, slotName, (path or "/") .. slotName .. "/", created)
      if not childCopy then return nil, err end
      copy.children[slotName] = childCopy
    end
    return copy
  end

  local function cloneFreshPackageFromRecipe(recipe, name)
    if type(recipe) ~= "table" or type(recipe.tree) ~= "table" then return nil, "Recipe is incomplete." end
    if type(recipe.vehicleModel) ~= "string" or inputs.trim(recipe.vehicleModel) == "" then return nil, "Recipe has no compatible vehicle model." end
    local packageId = tostring(packageStore.nextPackageId)
    local manufacturedYear = inputs.getCurrentManufacturingYear()
    local created = {}
    local tree, err = addPersonalRecipeNode(recipe.tree, packageId, recipe.vehicleModel, manufacturedYear, recipe.rootSlotName, "/", created)
    if not tree then
      local inventory = inputs.getPartInventory()
      for _, partId in ipairs(created) do inventory[partId] = nil end
      return nil, err
    end
    local package = {
      id = packageId,
      ownerType = "personal",
      name = parts.capture.uniquePackageName(name or recipe.name or "Manufactured Engine Package"),
      rootSlotName = recipe.rootSlotName,
      rootPath = recipe.rootPath,
      rootEngineName = tree.name,
      rootEngineNiceName = recipe.rootEngineNiceName or tree.name,
      tree = tree,
      tuning = deepcopy(recipe.tuning or {}),
      manufacturedYear = manufacturedYear,
      engineShopManufactured = true,
      manufacturedAt = os.time(),
      createdModel = recipe.vehicleModel,
      lastInstalledModel = recipe.vehicleModel,
      createdAt = os.time(), updatedAt = os.time()
    }
    packageStore.nextPackageId = packageStore.nextPackageId + 1
    packageStore.packages[#packageStore.packages + 1] = package
    return package
  end

  -- Stamps a retail listing's provenance and condition onto every part of a personal package.
  local function applyRetailCondition(package, metadata, manufacturedYear)
    local integrity = math.max(0, math.min(1, tonumber(metadata.integrity) or 1))
    local odometer = math.max(0, tonumber(metadata.odometer) or 0)
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do
      local part = inputs.getPartInventory()[tonumber(partId) or partId]
      if part then
        part.year = manufacturedYear
        part.manufacturedYear = manufacturedYear
        part.partCondition = {
          integrityValue = integrity,
          visualValue = math.max(0.2, math.min(1, tonumber(metadata.visual) or integrity)),
          odometer = odometer
        }
        part.tags = type(part.tags) == "table" and part.tags or {}
        part.tags.engineRetailListingId = package.engineRetailListingId
        part.tags.engineRetailShopId = package.engineRetailShopId
        part.tags.aftermarketUnknown = package.aftermarketUnknown
        part.engineShopManufactured = nil
        part.factoryPackageId = nil
        part.tags.engineShopManufactured = nil
        part.tags.factoryPackageId = nil
        part.tags.engineRetail = true
      end
    end
  end

  -- Retail and other systems can materialize a used or new physical package from a recipe without duplicating the package/inventory invariants maintained here.
  local function clonePersonalPackageFromRecipe(recipe, name, metadata)
    local package, err = cloneFreshPackageFromRecipe(recipe, name)
    if not package then return nil, err end
    metadata = metadata or {}
    local manufacturedYear = math.max(1, math.floor(tonumber(metadata.manufacturedYear)
      or package.manufacturedYear or inputs.getCurrentManufacturingYear()))
    package.manufacturedYear = manufacturedYear
    package.engineRetailListingId = metadata.listingId and tostring(metadata.listingId) or nil
    package.engineRetailShopId = metadata.shopId and tostring(metadata.shopId) or nil
    package.engineRetailType = metadata.type
    package.reliability = metadata.reliability
    package.aftermarketUnknown = metadata.aftermarketUnknown == true
    package.updatedAt = os.time()
    package.engineShopManufactured = nil
    package.factoryPackageId = nil
    package.manufacturedAt = nil
    package.engineRetailAcquiredAt = os.time()
    applyRetailCondition(package, metadata, manufacturedYear)
    if metadata.certification then
      package.engineShopCertification = deepcopy(metadata.certification)
    end
    return package
  end

  -- Value of a recipe: catalog value of every part, or, when retail metadata is given, the condition-adjusted value of the exact listing.
  local function getRecipeValue(recipe, existingIoCtx, metadata)
    if type(recipe) ~= "table" or type(recipe.tree) ~= "table" or not recipe.vehicleModel then
      return nil, "Recipe is incomplete."
    end
    local vehicleDir = string.format("/vehicles/%s/", recipe.vehicleModel)
    local ioCtx = existingIoCtx or (FS:directoryExists(vehicleDir) and inputs.jbeamIO.startLoading({vehicleDir, "/vehicles/common/"}) or nil)
    if not ioCtx then return nil, "The recipe vehicle model is unavailable." end
    local available, total = inputs.jbeamIO.getAvailableParts(ioCtx) or {}, 0
    local function partValueFor(node)
      local info = available[node.name] or {}
      local data = inputs.jbeamIO.getPart(ioCtx, node.name) or {}
      local value = math.max(0, tonumber(info.value)
        or tonumber(info.information and info.information.value)
        or tonumber(data.information and data.information.value) or 0)
      if metadata then
        -- Use the exact provenance and condition materialized by the retail clone.
        value = overhaul_career_market_valueCalculator.getPartValue({
          value = value,
          manufacturedYear = math.max(1, math.floor(tonumber(metadata.manufacturedYear) or inputs.getCurrentManufacturingYear())),
          partCondition = {
            odometer = math.max(0, tonumber(metadata.odometer) or 0),
            integrityValue = math.max(0, math.min(1, tonumber(metadata.integrity) or 1))
          }
        })
      end
      return value
    end
    local function visit(node)
      total = total + partValueFor(node)
      for _, child in pairs(node.children or {}) do visit(child) end
    end
    visit(recipe.tree)
    return math.max(1, math.floor(total + 0.5))
  end

  -- The recipe the installed engine would become if stored, and what its parts are worth now.
  local function getInstalledRecipeAndValue(inventoryId)
    inventoryId = tonumber(inventoryId)
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    local runtimeData = parts.capture.getRuntimeVehicleData(inventoryId)
    if not vehicle or not runtimeData or not runtimeData.config then return nil, "The selected vehicle is not spawned." end
    local engine = parts.capture.getPrimaryEngine(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not engine then return nil, "No installed engine was found." end
    local physicalTree, err = parts.capture.makePackageTree(engine.node, inventoryId)
    if not physicalTree then return nil, err end
    local enginePartName = engine.combustionPartName or parts.capture.findCombustionEnginePartName(engine.node, runtimeData.ioCtx)
      or physicalTree.name
    local recipe = {
      vehicleModel = vehicle.model,
      rootSlotName = engine.slotName,
      rootPath = engine.path,
      rootEngineName = enginePartName,
      rootEngineNiceName = parts.capture.getPartNiceName(runtimeData.ioCtx, enginePartName),
      tree = recipeTreeFromPackageNode(physicalTree),
      tuning = parts.capture.captureTuning(physicalTree, runtimeData, vehicle.config)
    }
    recipe.signature = computeRecipeSignature(recipe)
    local value = 0
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(physicalTree)) do
      local part = inputs.getPartInventory()[tonumber(partId) or partId]
      if part then
        value = value + math.max(0, tonumber(overhaul_career_market_valueCalculator.getPartValue(part)) or 0)
      end
    end
    return recipe, math.floor(value + 0.5)
  end

  -- Removes a stored personal package and its parts, as a trade-in or a failed install needs.
  local function consumeStoredPersonalPackage(packageId)
    local package = inputs.getPackageById(packageId)
    if not package or inputs.isBusinessPackage(package) then return false, "Personal Engine Package not found." end
    if inputs.getPackageStatus(package) ~= "stored" then return false, "Only a stored Engine Package can be traded in." end
    local refusal = firstReferenceRefusal(package)
    if refusal then return false, refusal end
    local inventory = inputs.getPartInventory()
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do inventory[tonumber(partId) or partId] = nil end
    inputs.removePackage(package.id, false)
    overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
    return true
  end

  -- Fit -----------------------------------------------------------------------------------------------

  -- Every engine slot on the vehicle that the recipe's tree validates against.
  local function collectRecipeFitCandidates(recipe, runtimeData, availableParts)
    local matches = {}
    local seenPaths = {}
    local function tryCandidate(candidate)
      local path = tostring(candidate.path or "")
      if seenPaths[path] then return end
      seenPaths[path] = true
      local ok = parts.capture.validatePackageTreeFits(recipe.tree, candidate.parentPartName, candidate.slotName, runtimeData.ioCtx, availableParts)
      if ok then matches[#matches + 1] = candidate end
    end
    local remembered = parts.capture.rememberedAttachmentCandidate(recipe, runtimeData.config.partsTree)
    if remembered then tryCandidate(remembered) end
    for _, candidate in ipairs(parts.capture.findEngineCandidates(runtimeData.config.partsTree, true, runtimeData.ioCtx)) do
      tryCandidate(candidate)
    end
    if #matches == 0 then
      for _, candidate in ipairs(parts.capture.collectDeclaredEngineBayCandidates(runtimeData.config.partsTree, availableParts, runtimeData.ioCtx)) do
        tryCandidate(candidate)
      end
    end
    return matches
  end

  local function findCompatibleRecipeTarget(recipe, inventoryId)
    if type(recipe) ~= "table" or type(recipe.tree) ~= "table" then return nil, "Recipe is incomplete." end
    if parts.capture.vehicleIsElectric(inventoryId) then return nil, "Electric vehicles cannot swap engines." end
    local runtimeData = parts.capture.getRuntimeVehicleData(inventoryId)
    if not runtimeData or not runtimeData.config or not runtimeData.config.partsTree or not runtimeData.ioCtx then
      return nil, "The selected vehicle is not spawned."
    end
    local matches = collectRecipeFitCandidates(recipe, runtimeData, inputs.jbeamIO.getAvailableParts(runtimeData.ioCtx))
    if #matches == 0 then return nil, "This engine recipe does not fit the selected vehicle." end
    for _, candidate in ipairs(matches) do
      if candidate.slotName == recipe.rootSlotName then
        return {slotName = candidate.slotName, path = candidate.path, parentPartName = candidate.parentPartName}
      end
    end
    if #matches > 1 then return nil, "More than one compatible engine slot was found." end
    local candidate = matches[1]
    return {slotName = candidate.slotName, path = candidate.path, parentPartName = candidate.parentPartName}
  end

  -- Business clones and transfers ----------------------------------------------------------------------

  local function cloneFreshBusinessPackageFromRecipe(recipe, name, businessType, businessId, metadata)
    if type(recipe) ~= "table" or type(recipe.tree) ~= "table" or not recipe.vehicleModel then
      return nil, "Recipe is incomplete."
    end
    local packageId = tostring(packageStore.nextPackageId)
    local revisionId = metadata and (metadata.blueprintId or metadata.productRevisionId)
    local manufacturedYear = math.max(1, math.floor(tonumber(metadata and metadata.manufacturedYear)
      or inputs.getCurrentManufacturingYear()))
    local created = {}
    local tree, err = addBusinessRecipeNode(recipe.tree, packageId, recipe.vehicleModel, tostring(businessId),
      revisionId, manufacturedYear, recipe.rootSlotName, "/", created)
    if not tree then
      for _, partId in ipairs(created) do overhaul_career_business_partInventory.removePart(partId) end
      return nil, err
    end
    local package = {
      id = packageId,
      ownerType = "business",
      businessType = businessType,
      businessId = tostring(businessId),
      name = name or recipe.name or "Manufactured Engine Package",
      rootSlotName = recipe.rootSlotName,
      rootPath = recipe.rootPath,
      rootEngineName = tree.name,
      rootEngineNiceName = recipe.rootEngineNiceName or tree.name,
      tree = tree,
      tuning = deepcopy(recipe.tuning or {}),
      recipe = deepcopy(recipe),
      recipeSignature = recipe.signature or computeRecipeSignature(recipe),
      productRevisionId = revisionId,
      warehouseStock = true,
      manufacturedYear = manufacturedYear,
      engineShopManufactured = true,
      createdModel = recipe.vehicleModel,
      lastInstalledModel = recipe.vehicleModel,
      createdAt = os.time(), updatedAt = os.time()
    }
    for key, value in pairs(metadata or {}) do package[key] = deepcopy(value) end
    packageStore.nextPackageId = packageStore.nextPackageId + 1
    packageStore.packages[#packageStore.packages + 1] = package
    return package
  end

  -- Copies one warehouse part node into personal inventory, then its children. Returns the new tree node.
  local function copyWarehouseNodeToPersonal(node, transfer)
    local source = transfer.businessInventory[tonumber(node.partId) or node.partId]
    if not source then return nil, "A physical warehouse part is missing." end
    local personalInventory = transfer.personalInventory
    local before = {}
    for id in pairs(personalInventory) do before[tostring(id)] = true end
    local part = deepcopy(source)
    part.location, part.businessId, part.productRevisionId = 0, nil, nil
    part.partId = nil
    inputs.markPartAsManufactured(part, transfer.manufacturedYear, transfer.package.id)
    part.vehicleModel = part.vehicleModel or transfer.fallbackVehicleModel or transfer.package.createdModel
      or transfer.package.lastInstalledModel or transfer.package.vehicleModel or (transfer.package.recipe and transfer.package.recipe.vehicleModel)
    if not part.vehicleModel then return nil, "The warehouse engine has no compatible vehicle model." end
    part.enginePackageId, part.mainPart = tostring(transfer.package.id), true
    overhaul_career_parts_partInventory.addPartToInventory(part)
    local newId
    for id in pairs(personalInventory) do if not before[tostring(id)] then newId = tonumber(id) or id break end end
    if not newId then return nil, "Could not transfer a warehouse engine part." end
    personalInventory[newId].partId = newId
    transfer.createdIds[#transfer.createdIds + 1] = newId
    local result = {name = node.name, slotName = node.slotName, relativeSlot = node.relativeSlot, partId = newId, children = {}}
    for slotName, child in pairs(node.children or {}) do
      local childResult, childError = copyWarehouseNodeToPersonal(child, transfer)
      if not childResult then return nil, childError end
      result.children[slotName] = childResult
    end
    return result
  end

  -- Moves a warehouse engine into personal storage: new part rows, the package tree rewritten, and the warehouse rows released.
  local function transferBusinessPackageToPersonal(packageId, fallbackVehicleModel)
    local package = inputs.getPackageById(packageId)
    if not inputs.isBusinessPackage(package) then return nil, "Business Engine Package not found." end
    local manufacturedYear = math.max(1, math.floor(tonumber(package.manufacturedYear)
      or inputs.getCurrentManufacturingYear()))
    local transfer = {
      package = package, businessInventory = inputs.getInventoryForPackage(package), personalInventory = inputs.getPartInventory(),
      createdIds = {}, manufacturedYear = manufacturedYear, fallbackVehicleModel = fallbackVehicleModel
    }
    inputs.markPackageAsManufactured(package, manufacturedYear)
    local newTree, err = copyWarehouseNodeToPersonal(package.tree, transfer)
    if not newTree then
      for _, partId in ipairs(transfer.createdIds) do transfer.personalInventory[partId] = nil end
      return nil, err
    end
    local oldIds = inputs.getPartIdsFromPackageTree(package.tree)
    package.tree = newTree
    package.ownerType = "personal"
    package.createdModel = package.createdModel or fallbackVehicleModel or package.lastInstalledModel
      or package.vehicleModel or (package.recipe and package.recipe.vehicleModel)
    package.lastInstalledModel = package.lastInstalledModel or package.createdModel
    package.manufacturedYear = manufacturedYear
    package.engineShopManufactured = true
    package.businessType, package.businessId, package.warehouseStock = nil, nil, nil
    package.productRevisionId, package.blueprintId = nil, nil
    package.updatedAt = os.time()
    for _, partId in ipairs(oldIds) do overhaul_career_business_partInventory.removePart(partId) end
    inputs.repairPackageFlags()
    return package
  end

  -- Copies one personal part node into the warehouse, then its children. Returns the new tree node.
  local function copyPersonalNodeToWarehouse(node, transfer)
    local source = transfer.personalInventory[tonumber(node.partId) or node.partId]
    if not source or tonumber(source.location) ~= 0 then return nil, "A stored engine part is missing." end
    local part = deepcopy(source)
    part.location, part.businessId, part.productRevisionId = 0, transfer.businessId, transfer.businessFields.productRevisionId
    part.enginePackageId, part.mainPart = tostring(transfer.package.id), true
    local newId = overhaul_career_business_partInventory.addPart(part, transfer.businessId)
    if not newId then return nil, "Could not return an engine part to the warehouse." end
    transfer.createdIds[#transfer.createdIds + 1] = newId
    local result = {name = node.name, slotName = node.slotName, relativeSlot = node.relativeSlot, partId = newId, children = {}}
    for slotName, child in pairs(node.children or {}) do
      local childResult, childError = copyPersonalNodeToWarehouse(child, transfer)
      if not childResult then return nil, childError end
      result.children[slotName] = childResult
    end
    return result
  end

  -- Reverses transferBusinessPackageToPersonal for a stored package, e.g. when its install fails.
  local function transferPersonalPackageToBusiness(packageId, businessFields)
    local package = inputs.getPackageById(packageId)
    if not package or package.ownerType ~= "personal" or package.installedInventoryId then
      return nil, "The engine package is no longer in personal storage."
    end
    businessFields = businessFields or {}
    local businessId = businessFields.businessId and tostring(businessFields.businessId)
    if not businessId then return nil, "The engine package has no business to return to." end
    local personalInventory = inputs.getPartInventory()
    local transfer = {package = package, personalInventory = personalInventory, businessId = businessId,
      businessFields = businessFields, createdIds = {}}
    local newTree, err = copyPersonalNodeToWarehouse(package.tree, transfer)
    if not newTree then
      for _, partId in ipairs(transfer.createdIds) do overhaul_career_business_partInventory.removePart(partId) end
      return nil, err
    end
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do personalInventory[partId] = nil end
    package.tree = newTree
    package.ownerType = "business"
    package.businessType, package.businessId, package.warehouseStock = businessFields.businessType, businessId, true
    package.productRevisionId, package.blueprintId = businessFields.productRevisionId, businessFields.blueprintId
    package.updatedAt = os.time()
    inputs.repairPackageFlags()
    return package
  end

  -- Year repair -----------------------------------------------------------------------------------------

  -- Repairs pre-provenance Engine Works output without touching ordinary old parts. The caller supplies IDs recorded by successful production attempts. This also catches already-dismantled output: load-time package flag repair temporarily retains its former package ID in orphanedEnginePackageId.
  local function repairManufacturedPackageYears(manufacturedPackageIds, fallbackYear)
    local wanted = {}
    for key, value in pairs(manufacturedPackageIds or {}) do
      local packageId = type(key) == "number" and value or key
      if value == true then packageId = key end
      if packageId ~= nil then wanted[tostring(packageId)] = true end
    end
    fallbackYear = math.max(1, math.floor(tonumber(fallbackYear) or inputs.getCurrentManufacturingYear()))
    local changed, repairedParts = false, 0
    for _, package in ipairs(packageStore.packages) do
      if wanted[tostring(package.id)] or package.engineShopManufactured == true
        or (package.manufacturedAt ~= nil and package.recipeSignature ~= nil) then
        changed = inputs.markPackageAsManufactured(package, package.manufacturedYear or fallbackYear) or changed
        wanted[tostring(package.id)] = true
      end
    end
    for _, part in pairs(inputs.getPartInventory()) do
      local formerId = tostring(part.factoryPackageId or part.orphanedEnginePackageId or "")
      if formerId ~= "" and wanted[formerId] then
        if inputs.markPartAsManufactured(part, part.manufacturedYear or fallbackYear, formerId) then repairedParts = repairedParts + 1 end
        part.orphanedEnginePackageId = nil
        changed = true
      end
    end
    if changed then
      inputs.repairPackageFlags()
    end
    return {changed = changed, repairedParts = repairedParts, manufacturedYear = fallbackYear}
  end

  -- Vehicle swaps ----------------------------------------------------------------------------------------

  -- Points the store at the vehicle and runs the swap action. Returns false with the reason when it cannot start.
  local function startVehicleSwap(inventoryId, callback, startAction, failureMessage)
    if packageStore.transactionBusy then return false, "Another engine package transaction is in progress." end
    packageStore.currentInventoryId = tonumber(inventoryId)
    if not packageStore.currentInventoryId then return false, "Target vehicle not found." end
    packageStore.activeInstallCallback = type(callback) == "function" and callback or nil
    startAction()
    if not packageStore.transactionBusy then
      packageStore.activeInstallCallback = nil
      return false, failureMessage
    end
    return true
  end

  local function installPackageIntoVehicle(packageId, inventoryId, callback)
    return startVehicleSwap(inventoryId, callback, function() parts.install.installPackage(packageId) end,
      "The engine installation could not be started.")
  end

  local function storePackageFromVehicle(packageId, inventoryId, callback)
    return startVehicleSwap(inventoryId, callback, function() parts.install.storeInstalledPackage(packageId) end,
      "The installed engine could not be removed.")
  end

  -- Public API -----------------------------------------------------------------------------------------

  return {
    cloneFreshBusinessPackageFromRecipe = cloneFreshBusinessPackageFromRecipe,
    cloneFreshPackageFromRecipe = cloneFreshPackageFromRecipe,
    clonePersonalPackageFromRecipe = clonePersonalPackageFromRecipe,
    computeRecipeSignature = computeRecipeSignature,
    consumeStoredPersonalPackage = consumeStoredPersonalPackage,
    findCompatibleRecipeTarget = findCompatibleRecipeTarget,
    getEngineCompatibilityKey = getEngineCompatibilityKey,
    getFreshPackageValue = getFreshPackageValue,
    getInstalledRecipeAndValue = getInstalledRecipeAndValue,
    getRecipeFromPackage = getRecipeFromPackage,
    getRecipeValue = getRecipeValue,
    installPackageIntoVehicle = installPackageIntoVehicle,
    refreshCertificationValidity = refreshCertificationValidity,
    registerPackageReferenceGuard = registerPackageReferenceGuard,
    removeBusinessPackage = removeBusinessPackage,
    repairManufacturedPackageYears = repairManufacturedPackageYears,
    setEngineShopCertification = setEngineShopCertification,
    storePackageFromVehicle = storePackageFromVehicle,
    transferBusinessPackageToPersonal = transferBusinessPackageToPersonal,
    transferPersonalPackageToBusiness = transferPersonalPackageToBusiness,
  }
end

return recipes

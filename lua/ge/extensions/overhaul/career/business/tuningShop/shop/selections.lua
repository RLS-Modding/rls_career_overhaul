-- Tuning shop: brand and race selection, blacklists, notification and manager lists.
-- Read: factory models, saved selection records, the blacklist and list writers, the picker data, then exports.

local QUALITY_OF_LIFE_TREE = "quality-of-life"
local AUTOMATION_TREE = "automation"

local installer = {}

function installer.new(inputs)
  -- State ----------------------------------------------------------------------------------------
  local parts = inputs.parts
  local operations = {}

  -- Inputs ----------------------------------------------------------------------------------------
  local shop = inputs.shop
  local blacklistedModels = inputs.blacklistedModels

  -- Factory models --------------------------------------------------------------------------------
  local function isFactoryConfig(vehicleInfo)
    local configType = vehicleInfo["Config Type"]
    if not configType and vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"] then
      configType = next(vehicleInfo.aggregates["Config Type"])
    end
    return configType == "Factory"
  end

  local function getFactoryConfigs()
    if shop.factoryConfigs then
      return shop.factoryConfigs
    end

    local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false) or {}
    shop.factoryConfigs = {}
    for _, vehicleInfo in ipairs(eligibleVehicles) do
      if isFactoryConfig(vehicleInfo) and not blacklistedModels[vehicleInfo.model_key] then
        table.insert(shop.factoryConfigs, vehicleInfo)
      end
    end
    return shop.factoryConfigs
  end

  operations.getAvailableVehiclesForBlacklist = function(businessId)
    local modelKeys = {}
    local seen = {}
    for _, config in ipairs(getFactoryConfigs()) do
      if config and config.model_key then
        local modelKey = config.model_key
        if not seen[modelKey] then
          seen[modelKey] = true
          table.insert(modelKeys, modelKey)
        end
      end
    end
    return modelKeys
  end

  -- Saved records ---------------------------------------------------------------------------------

  -- The saved selection record for a business, created on first write.
  local function selectionRecord(businessId)
    if not shop.businessSelections[businessId] then
      shop.businessSelections[businessId] = {}
    end
    return shop.businessSelections[businessId]
  end

  -- An empty choice clears the saved value.
  local function selectionOrNil(value)
    if value == "" or value == nil then
      return nil
    end
    return value
  end

  local function keepSetMembers(set, keep)
    local kept = {}
    for modelKey in pairs(set) do
      if keep(modelKey) then
        kept[modelKey] = true
      end
    end
    return kept
  end

  local function keepListEntries(list, keep)
    local kept = {}
    for _, entry in ipairs(list) do
      if entry and entry.model_key and keep(entry.model_key) then
        table.insert(kept, entry)
      end
    end
    return kept
  end

  local function setKeys(set)
    local keys = {}
    for modelKey in pairs(set) do
      table.insert(keys, modelKey)
    end
    return keys
  end

  local function getBlacklist(businessId)
    return parts.persist.loadBusinessSelections(businessId).blacklist or {}
  end

  local function getNotificationList(businessId)
    return parts.persist.loadBusinessSelections(businessId).notificationList or {}
  end

  local function getManagerBlacklist(businessId)
    return parts.persist.loadBusinessSelections(businessId).managerBlacklist or {}
  end

  -- Drops picks for models that are no longer on the factory list.
  local function cleanupInvalidVehiclesFromLists(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return
    end

    local availableSet = {}
    for _, modelKey in ipairs(operations.getAvailableVehiclesForBlacklist(businessId)) do
      availableSet[modelKey] = true
    end
    local function isAvailable(modelKey)
      return availableSet[modelKey]
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if not selections then
      return
    end
    if selections.blacklist then
      selections.blacklist = keepSetMembers(selections.blacklist, isAvailable)
    end
    if selections.notificationList then
      selections.notificationList = keepListEntries(selections.notificationList, isAvailable)
    end
    if selections.managerBlacklist then
      selections.managerBlacklist = keepSetMembers(selections.managerBlacklist, isAvailable)
    end
  end

  -- Blacklisted models leave the notification and manager lists; the blacklist itself stays.
  local function removeBlacklistedFromOtherLists(businessId, blacklist)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not blacklist then
      return
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if not selections then
      return
    end
    local function notBlacklisted(modelKey)
      return not blacklist[modelKey]
    end
    if selections.notificationList then
      selections.notificationList = keepListEntries(selections.notificationList, notBlacklisted)
    end
    if selections.managerBlacklist then
      selections.managerBlacklist = keepSetMembers(selections.managerBlacklist, notBlacklisted)
    end
  end

  -- Brand and race --------------------------------------------------------------------------------
  local function setBrandSelection(businessId, brand)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return false
    end
    selectionRecord(businessId).brand = selectionOrNil(brand)
    cleanupInvalidVehiclesFromLists(businessId)
    return true
  end

  local function getRaceSelection(businessId)
    return parts.persist.loadBusinessSelections(businessId).raceType
  end

  local function setRaceSelection(businessId, raceType)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return false
    end
    selectionRecord(businessId).raceType = selectionOrNil(raceType)
    return true
  end

  -- Blacklist -------------------------------------------------------------------------------------
  local function getBlacklistLevel(businessId)
    return parts.garage.getSkillTreeLevel(businessId, QUALITY_OF_LIFE_TREE, "blacklist")
  end

  local function setBlacklist(businessId, modelKeys)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return false
    end

    local blacklist = {}
    if modelKeys and type(modelKeys) == "table" then
      for _, modelKey in ipairs(modelKeys) do
        if modelKey and modelKey ~= "" then
          blacklist[modelKey] = true
        end
      end
    end

    selectionRecord(businessId).blacklist = blacklist
    removeBlacklistedFromOtherLists(businessId, blacklist)
    return true
  end

  local function addToBlacklist(businessId, modelKey)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey or modelKey == "" then
      return false
    end

    local record = selectionRecord(businessId)
    record.blacklist = record.blacklist or {}
    record.blacklist[modelKey] = true
    removeBlacklistedFromOtherLists(businessId, record.blacklist)
    return true
  end

  local function removeFromBlacklist(businessId, modelKey)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey then
      return false
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if not shop.businessSelections[businessId] then
      shop.businessSelections[businessId] = selections
    end
    local record = shop.businessSelections[businessId]
    record.blacklist = record.blacklist or {}
    record.blacklist[modelKey] = nil
    return true
  end

  local function updateBlacklist(businessId, modelKeys)
    local level = getBlacklistLevel(businessId)
    if level <= 0 then
      return false, "Blacklist skill not unlocked"
    end
    if modelKeys and #modelKeys > level then
      return false, "Maximum " .. level .. " vehicles allowed"
    end
    return setBlacklist(businessId, modelKeys)
  end

  -- Notification list -----------------------------------------------------------------------------
  local function getNotificationListLevel(businessId)
    return parts.garage.getSkillTreeLevel(businessId, QUALITY_OF_LIFE_TREE, "notified-jobs")
  end

  local function getMaxNotificationSlots(businessId)
    return getNotificationListLevel(businessId)
  end

  local function addToNotificationList(businessId, modelKey, autoAccept)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey or modelKey == "" then
      return false
    end

    local record = selectionRecord(businessId)
    record.notificationList = record.notificationList or {}
    for i, entry in ipairs(record.notificationList) do
      if entry.model_key == modelKey then
        record.notificationList[i].autoAccept = autoAccept == true
        return true
      end
    end
    table.insert(record.notificationList, {model_key = modelKey, autoAccept = autoAccept == true})
    return true
  end

  local function removeFromNotificationList(businessId, modelKey)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey then
      return false
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if selections.notificationList then
      for i = #selections.notificationList, 1, -1 do
        if selections.notificationList[i].model_key == modelKey then
          table.remove(selections.notificationList, i)
          break
        end
      end
    end
    return true
  end

  local function updateNotificationAutoAccept(businessId, modelKey, autoAccept)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey then
      return false
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    for _, entry in ipairs(selections.notificationList or {}) do
      if entry.model_key == modelKey then
        entry.autoAccept = autoAccept == true
        return true
      end
    end
    return false
  end

  local function updateNotificationList(businessId, entries)
    local maxSlots = getMaxNotificationSlots(businessId)
    if entries and #entries > maxSlots then
      return false, "Maximum " .. maxSlots .. " vehicles allowed"
    end
    if not entries then
      entries = {}
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if not shop.businessSelections[businessId] then
      shop.businessSelections[businessId] = selections
    end
    shop.businessSelections[businessId].notificationList = entries
    return true
  end

  -- Manager blacklist -----------------------------------------------------------------------------
  local function getManagerBlacklistLevel(businessId)
    return parts.garage.getSkillTreeLevel(businessId, AUTOMATION_TREE, "manager-blacklist")
  end

  local function getMaxManagerBlacklistSlots(businessId)
    return getManagerBlacklistLevel(businessId) * 2
  end

  local function addToManagerBlacklist(businessId, modelKey)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey or modelKey == "" then
      return false
    end

    local record = selectionRecord(businessId)
    record.managerBlacklist = record.managerBlacklist or {}
    record.managerBlacklist[modelKey] = true
    return true
  end

  local function removeFromManagerBlacklist(businessId, modelKey)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not modelKey then
      return false
    end

    local selections = parts.persist.loadBusinessSelections(businessId)
    if not shop.businessSelections[businessId] then
      shop.businessSelections[businessId] = selections
    end
    local record = shop.businessSelections[businessId]
    record.managerBlacklist = record.managerBlacklist or {}
    record.managerBlacklist[modelKey] = nil
    return true
  end

  local function updateManagerBlacklist(businessId, modelKeys)
    local maxSlots = getMaxManagerBlacklistSlots(businessId)
    if modelKeys and #modelKeys > maxSlots then
      return false, "Maximum " .. maxSlots .. " vehicles allowed"
    end
    if not modelKeys then
      modelKeys = {}
    end

    local blacklist = {}
    for _, modelKey in ipairs(modelKeys) do
      if modelKey and modelKey ~= "" then
        blacklist[modelKey] = true
      end
    end
    selectionRecord(businessId).managerBlacklist = blacklist
    return true
  end

  -- Picker data -----------------------------------------------------------------------------------
  local function candidateRows(modelKeys, excluded)
    local rows = {}
    for _, modelKey in ipairs(modelKeys) do
      if not (excluded and excluded[modelKey]) then
        local modelInfo = parts.persist.getModelInfo(modelKey)
        if modelInfo then
          table.insert(rows, {modelKey = modelKey, name = modelInfo.name or modelKey, brand = modelInfo.brand or ""})
        end
      end
    end
    return rows
  end

  local function getBlacklistData(businessId)
    local blacklist = getBlacklist(businessId)
    local availableVehicles = operations.getAvailableVehiclesForBlacklist(businessId)
    local level = getBlacklistLevel(businessId)
    local multiplier = parts.generation.calculateJobGenerationMultiplier(businessId)
    return {
      blacklist = setKeys(blacklist),
      availableVehicles = candidateRows(availableVehicles),
      level = level,
      maxSlots = level,
      unlocked = level > 0,
      generationMultiplier = multiplier,
    }
  end

  local function getNotificationListData(businessId)
    local notificationList = getNotificationList(businessId)
    local availableVehicles = operations.getAvailableVehiclesForBlacklist(businessId)
    local blacklist = getBlacklist(businessId)
    local level = getNotificationListLevel(businessId)
    local maxSlots = getMaxNotificationSlots(businessId)
    return {
      notificationList = notificationList,
      availableVehicles = candidateRows(availableVehicles, blacklist),
      level = level,
      maxSlots = maxSlots,
    }
  end

  local function getManagerBlacklistData(businessId)
    local managerBlacklist = getManagerBlacklist(businessId)
    local availableVehicles = operations.getAvailableVehiclesForBlacklist(businessId)
    local blacklist = getBlacklist(businessId)
    local level = getManagerBlacklistLevel(businessId)
    local maxSlots = getMaxManagerBlacklistSlots(businessId)
    return {
      managerBlacklist = setKeys(managerBlacklist),
      availableVehicles = candidateRows(availableVehicles, blacklist),
      level = level,
      maxSlots = maxSlots,
    }
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    addToBlacklist = addToBlacklist,
    addToManagerBlacklist = addToManagerBlacklist,
    addToNotificationList = addToNotificationList,
    getAvailableVehiclesForBlacklist = operations.getAvailableVehiclesForBlacklist,
    getBlacklist = getBlacklist,
    getBlacklistData = getBlacklistData,
    getFactoryConfigs = getFactoryConfigs,
    getManagerBlacklist = getManagerBlacklist,
    getManagerBlacklistData = getManagerBlacklistData,
    getNotificationList = getNotificationList,
    getNotificationListData = getNotificationListData,
    getRaceSelection = getRaceSelection,
    removeFromBlacklist = removeFromBlacklist,
    removeFromManagerBlacklist = removeFromManagerBlacklist,
    removeFromNotificationList = removeFromNotificationList,
    setBrandSelection = setBrandSelection,
    setRaceSelection = setRaceSelection,
    updateBlacklist = updateBlacklist,
    updateManagerBlacklist = updateManagerBlacklist,
    updateNotificationAutoAccept = updateNotificationAutoAccept,
    updateNotificationList = updateNotificationList,
  }
end

return installer

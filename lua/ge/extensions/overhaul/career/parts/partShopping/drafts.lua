-- Part shop drafts: saved carts, legacy migration and ordered part restoration.
-- Map: Config; State; Draft files; Restoration queue; Public API.

local M = {}

local saveStore = require("overhaul/lib/save/store")

-- Config ------------------------------------------------------------------------------------------

local CART_DRAFT_VERSION = 2

-- Each shop load gets independent draft memory and restoration progress.
function M.create(inputs)
  -- The facade pauses restoration while its retained session has unavailable vehicle context.
  local canRestoreParts = inputs.canRestoreParts or function() return true end
  -- State -----------------------------------------------------------------------------------------

  local saveForLaterEnabled = false
  local restoreQueue = {}
  local restoreInProgress = false
  local restoreTotal = 0
  local restoreCurrent = 0
  -- In-memory backup so same-session reopen still works if the file write fails.
  local memoryCartDrafts = {}

  -- Draft files -----------------------------------------------------------------------------------

  local function toBool(value)
    return value == true or value == 1 or value == "true" or value == "1"
  end

  local function getCartDraftPath()
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then
      return nil
    end
    -- The career directory exists before the first draft write.
    return currentSavePath .. "/career/partShoppingCartDrafts.json"
  end

  local function getLegacyCartDraftPath()
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then
      return nil
    end
    return currentSavePath .. "/career/rls_career/partShoppingCartDrafts.json"
  end

  local function inventoryIdToDraftKey(inventoryId)
    return tostring(inventoryId)
  end

  local function draftPartsCount(parts)
    if type(parts) ~= "table" then
      return 0
    end
    local count = 0
    for _ in pairs(parts) do
      count = count + 1
    end
    return count
  end

  local function normalizeDraftParts(parts)
    if type(parts) ~= "table" then
      return {}
    end
    -- JSON arrays can have string keys; restoration needs a dense numeric array.
    local normalized = {}
    local maxIndex = 0
    for key, value in pairs(parts) do
      local index = tonumber(key)
      if index and type(value) == "table" then
        normalized[index] = value
        if index > maxIndex then
          maxIndex = index
        end
      end
    end
    if maxIndex == 0 then
      return {}
    end
    local dense = {}
    for i = 1, maxIndex do
      if normalized[i] then
        table.insert(dense, normalized[i])
      end
    end
    return dense
  end

  local function newEmptyCartDraftStore()
    return { version = CART_DRAFT_VERSION, drafts = {} }
  end

  local function writeCartDraftStore(store)
    local filePath = getCartDraftPath()
    if not filePath or not store then
      return false
    end
    if not store.drafts or not next(store.drafts) then
      if FS:fileExists(filePath) then
        FS:removeFile(filePath)
      end
      local legacyPath = getLegacyCartDraftPath()
      if legacyPath and FS:fileExists(legacyPath) then
        FS:removeFile(legacyPath)
      end
      return true
    end
    local ok = saveStore.writeNow(filePath, store, true)
    if not ok then
      log("E", "partShopping", "Failed to write cart draft file: " .. tostring(filePath))
    end
    return ok and true or false
  end

  local function pruneStaleCartDrafts(store)
    if not store or not store.drafts then
      return false
    end
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    if not vehicles then
      return false
    end
    local changed = false
    for key, _ in pairs(store.drafts) do
      local inventoryId = tonumber(key)
      if not inventoryId or not vehicles[inventoryId] then
        store.drafts[key] = nil
        memoryCartDrafts[key] = nil
        changed = true
      end
    end
    return changed
  end

  local function readCartDraftStoreFromPath(filePath)
    if not filePath or not FS:fileExists(filePath) then
      return nil
    end
    local data = jsonReadFile(filePath)
    if not data or type(data.drafts) ~= "table" then
      return nil
    end
    return { version = CART_DRAFT_VERSION, drafts = data.drafts }
  end

  local function loadAllCartDrafts()
    local store = readCartDraftStoreFromPath(getCartDraftPath())
    if not store then
      -- Migrate drafts saved under the old nested path.
      store = readCartDraftStoreFromPath(getLegacyCartDraftPath())
      if store then
        writeCartDraftStore(store)
      end
    end
    if not store then
      return newEmptyCartDraftStore()
    end
    if pruneStaleCartDrafts(store) then
      writeCartDraftStore(store)
    end
    return store
  end

  local function loadCartDraftForVehicle(inventoryId)
    if not inventoryId then
      return nil
    end
    local key = inventoryIdToDraftKey(inventoryId)
    local memoryEntry = memoryCartDrafts[key]
    if memoryEntry and draftPartsCount(memoryEntry.parts) > 0 then
      return {
        parts = normalizeDraftParts(memoryEntry.parts),
        savedAt = memoryEntry.savedAt,
      }
    end
    local entry = loadAllCartDrafts().drafts[key]
    if not entry then
      return nil
    end
    local parts = normalizeDraftParts(entry.parts)
    if draftPartsCount(parts) == 0 then
      return nil
    end
    return { parts = parts, savedAt = entry.savedAt }
  end

  local function clearCartDraftForVehicle(inventoryId)
    if not inventoryId then
      return
    end
    local key = inventoryIdToDraftKey(inventoryId)
    memoryCartDrafts[key] = nil
    local store = loadAllCartDrafts()
    if not store.drafts[key] then
      return
    end
    store.drafts[key] = nil
    writeCartDraftStore(store)
  end

  -- Restoration queue -----------------------------------------------------------------------------

  local function getSlotPathDepth(slotPath)
    if not slotPath then
      return 0
    end
    local depth = 0
    for _ in string.gmatch(slotPath, "[^/]+") do
      depth = depth + 1
    end
    return depth
  end

  local function sortRestoreEntries(entries)
    table.sort(entries, function(a, b)
      local depthA = getSlotPathDepth(a.containingSlot)
      local depthB = getSlotPathDepth(b.containingSlot)
      if depthA ~= depthB then
        return depthA < depthB
      end
      return (a.containingSlot or "") < (b.containingSlot or "")
    end)
    return entries
  end

  local function serializePartsInForDraft()
    local parts = {}
    if not inputs.getShoppingCart() or not inputs.getShoppingCart().partsIn then
      return parts
    end
    for containingSlot, part in pairs(inputs.getShoppingCart().partsIn) do
      table.insert(parts, {
        containingSlot = containingSlot,
        name = part.name,
        partId = part.partId,
        emptyPlaceholder = part.emptyPlaceholder or false,
      })
    end
    return sortRestoreEntries(parts)
  end

  local function persistCartDraftToFile()
    if not inputs.getCurrentVehicle() or not inputs.getShoppingCart() then
      return
    end
    local parts = serializePartsInForDraft()
    local key = inventoryIdToDraftKey(inputs.getCurrentVehicle())
    if #parts == 0 then
      clearCartDraftForVehicle(inputs.getCurrentVehicle())
      return
    end
    local entry = {
      parts = parts,
      savedAt = os.time(),
    }
    memoryCartDrafts[key] = entry
    local store = loadAllCartDrafts()
    store.drafts[key] = entry
    writeCartDraftStore(store)
  end

  local function isSlotAlreadySatisfied(entry)
    if not entry or not inputs.getShoppingCart() or not inputs.getShoppingCart().partsIn then
      return false
    end
    local existing = inputs.getShoppingCart().partsIn[entry.containingSlot]
    if not existing then
      return false
    end
    if entry.emptyPlaceholder then
      return existing.emptyPlaceholder == true
    end
    if entry.partId then
      return existing.name == entry.name and existing.partId == entry.partId
    end
    return existing.name == entry.name and not existing.emptyPlaceholder
  end

  local function findPartInShopForRestoreEntry(entry)
    if not entry then
      return nil
    end
    for _, part in ipairs(inputs.getPartsInShop()) do
      if part.containingSlot ~= entry.containingSlot then
        goto continue
      end
      if entry.emptyPlaceholder then
        if part.emptyPlaceholder then
          return part
        end
      else
        if part.emptyPlaceholder then
          goto continue
        end
        if part.name ~= entry.name then
          goto continue
        end
        if entry.partId then
          if part.partId == entry.partId then
            return part
          end
        elseif not part.partId then
          return part
        end
      end
      ::continue::
    end
    return nil
  end

  local function abortCartRestore()
    restoreQueue = {}
    restoreInProgress = false
    restoreTotal = 0
    restoreCurrent = 0
  end

  local function processNextRestorePart()
    if not canRestoreParts() then return end
    if not restoreInProgress then
      return
    end
    while #restoreQueue > 0 do
      local entry = table.remove(restoreQueue, 1)
      if not isSlotAlreadySatisfied(entry) then
        local matched = findPartInShopForRestoreEntry(entry)
        if matched then
          if matched.emptyPlaceholder then
            inputs.removePart(matched)
          else
            inputs.installPart(matched)
          end
          return
        end
      end
    end
    restoreInProgress = false
    restoreCurrent = restoreTotal
    inputs.sendShoppingDataToUI()
  end

  local function startCartRestore(parts)
    if not canRestoreParts() then return end
    abortCartRestore()
    local entries = sortRestoreEntries(deepcopy(parts or {}))
    restoreQueue = {}
    for _, entry in ipairs(entries) do
      if not isSlotAlreadySatisfied(entry) then
        table.insert(restoreQueue, entry)
      end
    end
    restoreTotal = #restoreQueue
    restoreCurrent = 0
    if restoreTotal == 0 then
      return
    end
    restoreInProgress = true
    inputs.sendShoppingDataToUI()
    processNextRestorePart()
  end

  local function maybeStartCartRestore()
    if not canRestoreParts() then return end
    local draft = loadCartDraftForVehicle(inputs.getCurrentVehicle())
    if not draft then
      saveForLaterEnabled = false
      -- A restore left over from a replaced session has no job to finish it.
      abortCartRestore()
      return
    end
    saveForLaterEnabled = true
    startCartRestore(draft.parts)
  end

  -- Save-for-later controls -----------------------------------------------------------------------

  local function setSaveForLater(enabled)
    saveForLaterEnabled = toBool(enabled)
    if saveForLaterEnabled then
      if inputs.isSessionActive() then
        persistCartDraftToFile()
      end
    else
      clearCartDraftForVehicle(inputs.getCurrentVehicle())
    end
    if inputs.isSessionActive() then
      inputs.sendShoppingDataToUI()
    end
    return true
  end

  local function getSaveForLater()
    return saveForLaterEnabled
  end

  -- Public API ------------------------------------------------------------------------------------

  local drafts = {}
  drafts.persistCartDraftToFile = persistCartDraftToFile
  drafts.clearCartDraftForVehicle = clearCartDraftForVehicle
  drafts.abortCartRestore = abortCartRestore
  drafts.maybeStartCartRestore = maybeStartCartRestore
  drafts.processNextRestorePart = processNextRestorePart
  drafts.setSaveForLater = setSaveForLater
  drafts.getSaveForLater = getSaveForLater
  function drafts.setSaveForLaterEnabled(enabled) saveForLaterEnabled = enabled end
  function drafts.isRestoreInProgress() return restoreInProgress end
  function drafts.getRestoreProgress() return restoreCurrent, restoreTotal end
  function drafts.incrementRestoreCurrent() restoreCurrent = restoreCurrent + 1 end
  return drafts
end

return M

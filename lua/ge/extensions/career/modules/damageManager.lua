local M = {}

local dependencies = {'career_career', 'career_modules_inventory'}

local function getSpawnedVehicles()
    local inventoryIdToVehId = career_modules_inventory.getMapInventoryIdToVehId()
    local spawnedVehicles = {}
    for inventoryId, vehId in pairs(inventoryIdToVehId) do
        spawnedVehicles[inventoryId] = true
    end
    return spawnedVehicles
end

local function getDamagedVehicles()
    local spawnedVehicles = getSpawnedVehicles()
    local damagedVehicles = {}
    for inventoryId, _ in pairs(spawnedVehicles) do
        local vehicle = career_modules_inventory.getVehicles()[inventoryId]
        if vehicle then
            local damage = career_modules_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions)
            if damage > 0 then
                damagedVehicles[inventoryId] = true
            end
        end
    end

    return damagedVehicles
end

local function GetVehicleSaveFile(inventoryId)
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    local currentSavePath = path
    if not currentSavePath then return end

    local saveFile = currentSavePath .. "/career/vehicles/damage/" .. inventoryId .. "_damageState.json"
    return saveFile
end

function M.deleteVehicleDelayed(vehId)
    core_jobsystem.create(function(job)
        job.sleep(0.5)
        local object = be:getObjectByID(vehId)
        object:delete()
    end)
end

function M.saveDamageState(inventoryId, saveFile, removeVehicle)
    if not saveFile then
        saveFile = GetVehicleSaveFile(inventoryId)
    end
    print("Checking damage state for vehicle " .. inventoryId .. " to " .. saveFile)
    local vehicle = career_modules_inventory.getVehicles()[inventoryId]
    local spawnedVehicles = career_modules_inventory.getMapInventoryIdToVehId()
    if vehicle and spawnedVehicles[inventoryId] then
        local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(career_modules_inventory.getVehicles()[inventoryId].partConditions)
        if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
            print("Saving damage state for vehicle " .. inventoryId .. " to " .. saveFile)
            local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
            local object = be:getObjectByID(vehId)
            if removeVehicle then
                --object:queueLuaCommand("beamstate.save(\"" .. saveFile .. "\"); obj:queueGameEngineLua('career_modules_damageManager.deleteVehicleDelayed(" .. vehId .. ")');")
                object:queueLuaCommand("individualRepair.saveDamageData(\"" .. saveFile .. "\"); obj:queueGameEngineLua('career_modules_damageManager.deleteVehicleDelayed(" .. vehId .. ")');")
            else
                object:queueLuaCommand("individualRepair.saveDamageData(\"" .. saveFile .. "\");")
                --object:queueLuaCommand("beamstate.save(\"" .. saveFile .. "\");")
            end
        else
            if removeVehicle then
                local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
                local object = be:getObjectByID(vehId)
                object:delete()
            end
            print("No damage state to save for vehicle " .. inventoryId)
            FS:removeFile(saveFile)
            
            -- Also clear the vehicle's internal damage tracking state since there's no damage to save
            local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
            if vehId then
                local object = be:getObjectByID(vehId)
                if object then
                    object:queueLuaCommand("if individualRepair then individualRepair.reset(); end")
                end
            end
        end
    end
end

function M.loadDamageState(inventoryId)
    print("Loading damage state for vehicle " .. inventoryId)
    local saveFile = GetVehicleSaveFile(inventoryId)
    local object = be:getObjectByID(career_modules_inventory.getVehicleIdFromInventoryId(inventoryId))
    --object:queueLuaCommand("beamstate.load(\"" .. saveFile .. "\");")
    object:queueLuaCommand("individualRepair.loadDamageData(\"" .. saveFile .. "\");")
end

function M.clearDamageState(inventoryId)
    local saveFile = GetVehicleSaveFile(inventoryId)
    FS:removeFile(saveFile)
    
    -- Also clear the vehicle's internal damage tracking state if the vehicle is currently spawned
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if vehId then
        local object = be:getObjectByID(vehId)
        if object then
            object:queueLuaCommand("if individualRepair then individualRepair.reset(); end")
        end
    end
end

function M.repairPartsAndReloadState(inventoryId, partsToRepair, partsToRemove)
    if not inventoryId then
        log('E', 'damageManager.repairParts', 'No inventoryId provided.')
        return
    end

    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not vehId then
        log('E', 'damageManager.repairParts', 'Could not find vehicleId for inventoryId: ' .. inventoryId)
        return
    end

    local object = be:getObjectByID(vehId)
    if not object then
        log('E', 'damageManager.repairParts', 'Could not find vehicle object for vehId: ' .. vehId)
        return
    end

    local saveFile = GetVehicleSaveFile(inventoryId)
    if not saveFile then
        log('E', 'damageManager.repairParts', 'Could not get save file path for inventoryId: ' .. inventoryId)
        return
    end

    local serializedPartsToRepair = serialize(partsToRepair)
    if not serializedPartsToRepair then
        log('E', 'damageManager.repairParts', 'Failed to serialize partsToRepair table.')
        return
    end

    local serializedPartsToRemove = serialize(partsToRemove)
    if not serializedPartsToRemove then
        log('E', 'damageManager.repairParts', 'Failed to serialize partsToRemove table.')
        return
    end

    log('I', 'damageManager.repairParts', 'Attempting to repair parts for vehicle ' .. inventoryId .. '. Using save file: ' .. saveFile)
    
    local command = string.format(
        "individualRepair.loadDamageData('%s', %s, %s);",
        saveFile:gsub("\\", "/"), 
        serializedPartsToRepair,
        serializedPartsToRemove
    )

    object:queueLuaCommand(command)
end

local function onSaveCurrentSaveSlot(currentSavePath)
    local _, oldSavePath = career_saveSystem.getCurrentSaveSlot()

    local oldDamageDir = oldSavePath .. "/career/vehicles/damage/"
    local newDamageDir = currentSavePath .. "/career/vehicles/damage/"

    if not FS:directoryExists(newDamageDir) then
        FS:directoryCreate(newDamageDir)
    end

    local oldFiles = {}
    local newFiles = {}
    
    if FS:directoryExists(oldDamageDir) then
        local oldDamageFiles = FS:findFiles(oldDamageDir, '*_damageState.json', 0, false, false)
        for _, oldFilePath in ipairs(oldDamageFiles) do
            local _, fileName, _ = path.split(oldFilePath)
            print("oldFilePath: " .. oldFilePath)
            oldFiles[fileName] = oldFilePath
        end
    end
    
    if FS:directoryExists(newDamageDir) then
        local newDamageFiles = FS:findFiles(newDamageDir, '*_damageState.json', 0, false, false)
        for _, newFilePath in ipairs(newDamageFiles) do
            local _, fileName, _ = path.split(newFilePath)
            print("newFilePath: " .. newFilePath)
            newFiles[fileName] = newFilePath
        end
    end
    
    for fileName, oldFilePath in pairs(oldFiles) do
        local newFilePath = newDamageDir .. fileName
        local damageData = jsonReadFile(oldFilePath)
        if damageData then
            jsonWriteFile(newFilePath, damageData, true)
        end
    end
    
    for fileName, newFilePath in pairs(newFiles) do
        if not oldFiles[fileName] then
            FS:removeFile(newFilePath)
        end
    end
end


M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.getSpawnedVehicles = getSpawnedVehicles
M.getDamagedVehicles = getDamagedVehicles
return M
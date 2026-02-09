-- CarSwap Online Marketplace
-- Direct Connection Mode (Client -> Supabase)

local M = {}

-- Load configuration
local config_path = "ge/extensions/gameplay/carswap/config"
local success, loaded_config = pcall(require, config_path)
local config = {}

if success then
    config = loaded_config
    log("I", "carswap", "Configuration loaded successfully")
else
    log("E", "carswap", "Config file not found or invalid! Error: " .. tostring(loaded_config))
    config = { SUPABASE_URL = "", SUPABASE_ANON_KEY = "" }
end

-- jsonEncode and jsonDecode are global functions in BeamNG

-- Configuration
local SUPABASE_URL = config.SUPABASE_URL
local SUPABASE_KEY = config.SUPABASE_ANON_KEY
local headers = {
    ["apikey"] = SUPABASE_KEY,
    ["Authorization"] = "Bearer " .. SUPABASE_KEY,
    ["Content-Type"] = "application/json",
    ["Prefer"] = "return=representation"
}

local pendingDespawnInventoryIds = {}

local function queueDespawnAfterSave(inventoryId)
    if not inventoryId then return end
    pendingDespawnInventoryIds[inventoryId] = true
    if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
    else
        if core_jobsystem and core_jobsystem.create then
            core_jobsystem.create(function(job)
                job.sleep(0.5)
                if career_modules_inventory and career_modules_inventory.removeVehicleObject then
                    career_modules_inventory.removeVehicleObject(inventoryId)
                end
            end)
        end
    end
end

-- Local HTTP bridge to bypass HTTPS restriction
local BRIDGE_URL = "http://127.0.0.1:8766/bridge"
local httpClient = nil
local ltn12 = nil
do
    local okHttp, http = pcall(require, "socket.http")
    local okLtn, ltn = pcall(require, "ltn12")
    if okHttp then httpClient = http end
    if okLtn then ltn12 = ltn end
    if not httpClient or not ltn12 then
        log("E", "carswap", "HTTP client not available (socket.http/ltn12)")
    end
end

local function bridgeRequest(payload, callback)
    if not httpClient or not ltn12 then
        if callback then callback(nil, "HTTP client not available") end
        return
    end

    local body = jsonEncode(payload)
    local responseBody = {}

    local _, statusCode = httpClient.request({
        url = BRIDGE_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = #body
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(responseBody)
    })

    local response = table.concat(responseBody)

    if statusCode ~= 200 then
        if callback then callback(nil, "Bridge HTTP status: " .. tostring(statusCode)) end
        return
    end

    local ok, decoded = pcall(jsonDecode, response)
    if not ok then
        if callback then callback(nil, "Bridge returned invalid JSON") end
        return
    end

    if callback then callback(decoded, nil) end
end

    local function bridgeRequestSync(payload)
        if not httpClient or not ltn12 then
            return nil, "HTTP client not available"
        end

        local body = jsonEncode(payload)
        local responseBody = {}

        local _, statusCode = httpClient.request({
            url = BRIDGE_URL,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = #body
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(responseBody)
        })

        local response = table.concat(responseBody)

        if statusCode ~= 200 then
            return nil, "Bridge HTTP status: " .. tostring(statusCode)
        end

        local ok, decoded = pcall(jsonDecode, response)
        if not ok then
            return nil, "Bridge returned invalid JSON"
        end

        return decoded, nil
    end

-- Helper to make HTTP requests via the local bridge
local function request(endpoint, method, body, callback)
    local url = SUPABASE_URL .. endpoint
    local payload = {
        url = url,
        method = method or "GET",
        headers = headers,
        body = body and jsonEncode(body) or nil
    }

    if callback then
        bridgeRequest(payload, function(response, err)
            if err then
                log("E", "carswap", "Bridge error: " .. tostring(err))
                if callback then callback(nil, err) end
                return
            end

            local statusCode = response and response.status or 0
            local responseText = response and response.text or ""

            if statusCode >= 200 and statusCode < 300 then
                local data = nil
                if responseText ~= "" then
                    local ok, decoded = pcall(jsonDecode, responseText)
                    if ok then
                        data = decoded
                    else
                        log("W", "carswap", "Failed to decode JSON response: " .. tostring(responseText))
                    end
                end
                if callback then callback(data, nil) end
            else
                log("E", "carswap", "Request failed: " .. tostring(statusCode) .. " " .. tostring(responseText))
                if callback then callback(nil, "Error: " .. tostring(statusCode)) end
            end
        end)
        return
    end

    local response, err = bridgeRequestSync(payload)
    if err then
        log("E", "carswap", "Bridge error: " .. tostring(err))
        return nil, err
    end

    local statusCode = response and response.status or 0
    local responseText = response and response.text or ""

    if statusCode >= 200 and statusCode < 300 then
        local data = nil
        if responseText ~= "" then
            local ok, decoded = pcall(jsonDecode, responseText)
            if ok then
                data = decoded
            else
                log("W", "carswap", "Failed to decode JSON response: " .. tostring(responseText))
            end
        end
        return data, nil
    end

    log("E", "carswap", "Request failed: " .. tostring(statusCode) .. " " .. tostring(responseText))
    return nil, "Error: " .. tostring(statusCode)
end

local function readProfileData()
    local dirPath = nil
    local idFile = nil

    if career_saveSystem and career_saveSystem.getCurrentSaveSlot and career_saveSystem.getSaveRootDirectory then
        local currentSlot, _ = career_saveSystem.getCurrentSaveSlot()
        if currentSlot then
            dirPath = career_saveSystem.getSaveRootDirectory() .. currentSlot .. "/career/rls_career"
            idFile = dirPath .. "/carswap_id.json"
        end
    end

    if not idFile and career_career and career_career.getAutosavePath then
        local savePath = career_career.getAutosavePath()
        if savePath then
            dirPath = savePath .. "/career/rls_career"
            idFile = dirPath .. "/carswap_id.json"
        end
    end

    if dirPath and not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    if idFile then
        local existing = jsonReadFile(idFile) or {}
        return existing, idFile
    end

    return {}, nil
end

local function writeProfileData(data, idFile)
    if not idFile then return end
    if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
        career_saveSystem.jsonWriteFileSafe(idFile, data, true)
    else
        jsonWriteFile(idFile, data, true)
    end
end

local function getVisualValueFromMileage(mileage)
    if career_modules_vehicleShopping and career_modules_vehicleShopping.getVisualValueFromMileage then
        return career_modules_vehicleShopping.getVisualValueFromMileage(mileage)
    end
    return 1
end

local function spawnPurchasedVehicle(listingId, callback)
    local query = "/rest/v1/listings?select=vehicle_model,vehicle_config,mileage,condition,vehicle_year&id=eq." .. listingId
    request(query, "GET", nil, function(data, error)
        if error then
            log("E", "carswap", "Failed to fetch listing data: " .. tostring(error))
            if callback then callback(false, error) end
            return
        end

        local listing = data and data[1]
        if not listing then
            if callback then callback(false, "Listing data not found") end
            return
        end

        local model = listing.vehicle_model
        local config = listing.vehicle_config
        local mileage = listing.mileage or 0

        if not model and type(config) == "table" then
            model = config.model
        end

        if not model then
            if callback then callback(false, "Vehicle model missing") end
            return
        end

        if not core_vehicles or not core_vehicles.spawnNewVehicle then
            if callback then callback(false, "Vehicle spawn not available") end
            return
        end

        local spawnOptions = { autoEnterVehicle = false }
        if config then
            spawnOptions.config = config
        end

        local newVeh = core_vehicles.spawnNewVehicle(model, spawnOptions)
        if not newVeh then
            if callback then callback(false, "Vehicle spawn failed") end
            return
        end

        if partCondition and newVeh.getID then
            newVeh:queueLuaCommand(string.format(
                "partCondition.initConditions(nil, %d, nil, %f)",
                mileage, getVisualValueFromMileage(mileage)))
        end

        if career_modules_inventory and career_modules_inventory.addVehicle then
            local inventoryId = career_modules_inventory.addVehicle(newVeh:getID())
            if inventoryId and career_modules_inventory.moveVehicleToGarage then
                career_modules_inventory.moveVehicleToGarage(inventoryId)
            end
            queueDespawnAfterSave(inventoryId)
        end

        if callback then callback(true, nil) end
    end)
end

local function spawnPurchasedVehicleSync(listingId)
    local query = "/rest/v1/listings?select=vehicle_model,vehicle_config,mileage,condition,vehicle_year&id=eq." .. listingId
    local data, error = request(query, "GET", nil, nil)
    if error then
        log("E", "carswap", "Failed to fetch listing data: " .. tostring(error))
        return false, error
    end

    local listing = data and data[1]
    if not listing then
        return false, "Listing data not found"
    end

    local model = listing.vehicle_model
    local config = listing.vehicle_config
    local mileage = listing.mileage or 0

    if not model and type(config) == "table" then
        model = config.model
    end

    if not model then
        return false, "Vehicle model missing"
    end

    if not core_vehicles or not core_vehicles.spawnNewVehicle then
        return false, "Vehicle spawn not available"
    end

    local spawnOptions = { autoEnterVehicle = false }
    if config then
        spawnOptions.config = config
    end

    local newVeh = core_vehicles.spawnNewVehicle(model, spawnOptions)
    if not newVeh then
        return false, "Vehicle spawn failed"
    end

    if partCondition and newVeh.getID then
        newVeh:queueLuaCommand(string.format(
            "partCondition.initConditions(nil, %d, nil, %f)",
            mileage, getVisualValueFromMileage(mileage)))
    end

    if career_modules_inventory and career_modules_inventory.addVehicle then
        local inventoryId = career_modules_inventory.addVehicle(newVeh:getID())
        if inventoryId and career_modules_inventory.moveVehicleToGarage then
            career_modules_inventory.moveVehicleToGarage(inventoryId)
        end
        queueDespawnAfterSave(inventoryId)
    end

    return true, nil
end

local function findInventoryIdByListingId(listingId)
    if not career_modules_inventory or not career_modules_inventory.getVehicles then return nil end
    local vehicles = career_modules_inventory.getVehicles()
    for invId, vehicle in pairs(vehicles) do
        local cfg = vehicle and vehicle.config
        if cfg and cfg.carswap_listing_id == listingId then
            return invId
        end
    end
    return nil
end

local function markVehicleAsCarSwapListed(inventoryId, listingId)
    if not career_modules_inventory or not career_modules_inventory.getVehicle then return end
    local vehicle = career_modules_inventory.getVehicle(inventoryId)
    if not vehicle then return end
    vehicle.config = vehicle.config or {}
    vehicle.config.carswap_listing_id = listingId
    vehicle.config.carswap_listed = true
    if career_modules_inventory.setVehicleDirty then
        career_modules_inventory.setVehicleDirty(inventoryId)
    end
end

local function clearCarSwapListingMarker(listingId)
    if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
    local vehicles = career_modules_inventory.getVehicles()
    for invId, vehicle in pairs(vehicles) do
        local cfg = vehicle and vehicle.config
        if cfg and cfg.carswap_listing_id == listingId then
            cfg.carswap_listing_id = nil
            cfg.carswap_listed = false
            if career_modules_inventory.setVehicleDirty then
                career_modules_inventory.setVehicleDirty(invId)
            end
        end
    end
end

-- ============================================================================
-- Lifecycle & Helper
-- ============================================================================

local function getPlayerId()
    local dirPath = nil
    local idFile = nil

    if career_saveSystem and career_saveSystem.getCurrentSaveSlot and career_saveSystem.getSaveRootDirectory then
        local currentSlot, _ = career_saveSystem.getCurrentSaveSlot()
        if currentSlot then
            dirPath = career_saveSystem.getSaveRootDirectory() .. currentSlot .. "/career/rls_career"
            idFile = dirPath .. "/carswap_id.json"
        end
    end

    if not idFile and career_career and career_career.getAutosavePath then
        local savePath = career_career.getAutosavePath()
        if savePath then
            dirPath = savePath .. "/career/rls_career"
            idFile = dirPath .. "/carswap_id.json"
        end
    end

    if dirPath and not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    if Steam and Steam.getSteamID then
        local steamId = tostring(Steam.getSteamID())
        if idFile then
            local data = { seller_id = steamId, source = "steam" }
            if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
                career_saveSystem.jsonWriteFileSafe(idFile, data, true)
            else
                jsonWriteFile(idFile, data, true)
            end
        end
        return steamId
    end

    -- Per-save persistent ID (stored in save folder)
    if idFile then
        local existing = jsonReadFile(idFile)
        if existing and existing.seller_id then
            return tostring(existing.seller_id)
        end
        local newId = Engine.generateUUID()
        local data = { seller_id = newId, source = "save" }
        if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
            career_saveSystem.jsonWriteFileSafe(idFile, data, true)
        else
            jsonWriteFile(idFile, data, true)
        end
        return tostring(newId)
    end

    return "player_local_dev"
end

local function getPlayerName()
    local data = readProfileData()
    if data and data.profile_name and data.profile_name ~= "" then
        return tostring(data.profile_name)
    end
    if Steam and Steam.getPersonaName then
        return Steam.getPersonaName()
    end
    return "Unknown Driver"
end

local function setProfileName(name)
    local data, idFile = readProfileData()
    if not idFile then return false end
    data.profile_name = tostring(name or "")
    writeProfileData(data, idFile)
    return true
end

local function getProfileName()
    local data = readProfileData()
    if data and data.profile_name and data.profile_name ~= "" then
        return tostring(data.profile_name)
    end
    return nil
end

local function checkHubConnection(callback)
    -- Simply ping the listings table to check connection
    if callback then
        request("/rest/v1/listings?select=count&limit=1", "HEAD", nil, function(data, error)
            if callback then
                callback(error == nil)
            end
        end)
        return true
    end

    local _, error = request("/rest/v1/listings?select=count&limit=1", "HEAD", nil, nil)
    return error == nil
end

-- Debug helper to test bridge + Supabase connectivity
local function testConnection(callback)
    local data, error = request("/rest/v1/listings?select=id&limit=1", "GET", nil, nil)
    if error then
        if callback then callback(false, error) end
        return false, error
    end
    if callback then callback(true, nil, data) end
    return true, nil, data
end

-- ============================================================================
-- API Functions
-- ============================================================================

-- Get all available listings
local function getListings(callback)
    -- Filter by status=available and order by created_at desc
    local query = "/rest/v1/listings?select=*&status=eq.available&order=created_at.desc"

    if callback then
        request(query, "GET", nil, function(data, error)
            callback(data or {}, error)
        end)
        return
    end

    local data, error = request(query, "GET", nil, nil)
    if error then return {}, error end
    return data or {}, nil
end

-- Get my listings
local function getMyListings(callback)
    local sellerId = getPlayerId()
    local query = "/rest/v1/listings?select=*&seller_id=eq." .. sellerId .. "&order=created_at.desc"

    if callback then
        request(query, "GET", nil, function(data, error)
            callback(data or {}, error)
        end)
        return
    end

    local data, error = request(query, "GET", nil, nil)
    if error then return {}, error end
    return data or {}, nil
end

-- List a vehicle for sale
-- UI may pass optional 5th arg: single base64 string, or array of base64 strings (up to 4).
-- We store each photo in its own column (thumbnail_base64, thumbnail_2_base64, ...) so no JSON-in-string encoding issues.
local function createListing(invId, price, title, desc, thumbnailBase64OrCallback, callback)
    local thumb1, thumb2, thumb3, thumb4 = nil, nil, nil, nil
    if type(thumbnailBase64OrCallback) == "function" then
        callback = thumbnailBase64OrCallback
    elseif type(thumbnailBase64OrCallback) == "string" and thumbnailBase64OrCallback ~= "" then
        local s = thumbnailBase64OrCallback:gsub("^%s+", ""):gsub("%s+$", "")
        if s:sub(1, 1) == "[" then
            local ok, arr = pcall(jsonDecode, s)
            if ok and type(arr) == "table" then
                thumb1 = arr[1] or arr["1"] or arr[0]
                thumb2 = arr[2] or arr["2"]
                thumb3 = arr[3] or arr["3"]
                thumb4 = arr[4] or arr["4"]
            else
                thumb1 = thumbnailBase64OrCallback
            end
        else
            thumb1 = thumbnailBase64OrCallback
        end
    elseif type(thumbnailBase64OrCallback) == "table" then
        local arr = {}
        for i = 0, 3 do
            local v = thumbnailBase64OrCallback[i]
            if type(v) == "string" and v ~= "" then arr[#arr + 1] = v end
        end
        if #arr == 0 then
            for i = 1, 4 do
                local v = thumbnailBase64OrCallback[i] or thumbnailBase64OrCallback[tostring(i)]
                if type(v) == "string" and v ~= "" then arr[#arr + 1] = v end
            end
        end
        thumb1 = arr[1]
        thumb2 = arr[2]
        thumb3 = arr[3]
        thumb4 = arr[4]
    end

    -- Find vehicle in inventory
    -- Note: This assumes we can get vehicle data from inventory ID
    -- UI calls createListing(invId, price, title, desc, thumbnailBase64)
    
    local vehicle = nil
    if career_modules_inventory then
         local vehs = career_modules_inventory.getVehicles()
         vehicle = vehs[invId]
    end

    if not vehicle then
        -- Mock for dev if inventory not available
        vehicle = {
            config = {},
            model = "pickup",
            year = 2020,
            mileage = 12000
        }
    end

    local endpoint = "/rest/v1/listings"

    local safePrice = tonumber(price) or 0
    local safeMileage = tonumber(vehicle.mileage) or 0
    local safeYear = tonumber(vehicle.year)

    local listing = {
        seller_id = getPlayerId(),
        seller_name = getPlayerName(),
        vehicle_config = vehicle.config or {},
        vehicle_model = vehicle.model or "unknown",
        vehicle_year = safeYear and math.floor(safeYear) or nil,
        thumbnail_base64 = thumb1,
        thumbnail_2_base64 = thumb2,
        thumbnail_3_base64 = thumb3,
        thumbnail_4_base64 = thumb4,
        price = math.floor(safePrice),
        title = title,
        description = desc,
        mileage = math.floor(safeMileage),
        condition = 100,
        status = "available"
    }
    
    request(endpoint, "POST", listing, function(data, error)
        if not error and data and data[1] and data[1].id and invId then
            markVehicleAsCarSwapListed(invId, data[1].id)
            if career_saveSystem and career_saveSystem.saveCurrent then
                career_saveSystem.saveCurrent()
            end
        end
        -- UI expects callback(success, error)
        if callback then
            callback(error == nil, error)
        end
    end)
end

-- Purchase a vehicle
local function purchaseVehicle(listingId, callback)
    local endpoint = "/rest/v1/rpc/complete_sale"
    local body = {
        p_listing_id = listingId,
        p_buyer_id = getPlayerId(),
        p_buyer_name = getPlayerName()
    }

    if callback then
        local priceQuery = "/rest/v1/listings?select=price,status&id=eq." .. listingId
        request(priceQuery, "GET", nil, function(listingData, listingError)
            if listingError then
                callback(nil, listingError)
                return
            end
            local listing = listingData and listingData[1]
            if not listing or listing.status ~= "available" then
                callback(nil, "Listing not available")
                return
            end
            local price = math.floor(tonumber(listing.price) or 0)
            if career_modules_payment and career_modules_payment.canPay then
                local canPay = career_modules_payment.canPay({money = {amount = price, canBeNegative = false}})
                if not canPay then
                    callback(nil, "Not enough money")
                    return
                end
            end

            request(endpoint, "POST", body, function(data, error)
                if data and data.success then
                    if career_modules_payment and career_modules_payment.pay then
                        career_modules_payment.pay({money = {amount = price, canBeNegative = false}}, {label = "CarSwap purchase", tags = {"carswap", "buying"}})
                    end
                    spawnPurchasedVehicle(listingId, function(ok, spawnErr)
                        if not ok then
                            log("E", "carswap", "Failed to add purchased vehicle: " .. tostring(spawnErr))
                        end
                        callback(data, nil)
                    end)
                else
                    callback(nil, error or (data and data.error) or "Transaction failed")
                end
            end)
        end)
        return
    end

    local priceQuery = "/rest/v1/listings?select=price,status&id=eq." .. listingId
    local listingData, listingError = request(priceQuery, "GET", nil, nil)
    if listingError then return nil, listingError end
    local listing = listingData and listingData[1]
    if not listing or listing.status ~= "available" then
        return nil, "Listing not available"
    end
    local price = math.floor(tonumber(listing.price) or 0)
    if career_modules_payment and career_modules_payment.canPay then
        local canPay = career_modules_payment.canPay({money = {amount = price, canBeNegative = false}})
        if not canPay then
            return nil, "Not enough money"
        end
    end

    local data, error = request(endpoint, "POST", body, nil)
    if data and data.success then
        if career_modules_payment and career_modules_payment.pay then
            career_modules_payment.pay({money = {amount = price, canBeNegative = false}}, {label = "CarSwap purchase", tags = {"carswap", "buying"}})
        end
        local ok, spawnErr = spawnPurchasedVehicleSync(listingId)
        if not ok then
            log("E", "carswap", "Failed to add purchased vehicle: " .. tostring(spawnErr))
        end
        return data
    end

    return nil, error or (data and data.error) or "Transaction failed"
end

-- Send a message to the seller of a listing (insert into messages table)
local function sendMessage(listingId, content, callback)
    if not listingId or not content or tostring(content):match("^%s*$") then
        if callback then callback(false, "Invalid listing or message") end
        return nil, "Invalid listing or message"
    end
    local query = "/rest/v1/listings?select=seller_id,seller_name&id=eq." .. listingId
    local listingData, listErr = request(query, "GET", nil, nil)
    if listErr or not listingData or not listingData[1] then
        if callback then callback(false, listErr or "Listing not found") end
        return nil, listErr or "Listing not found"
    end
    local listing = listingData[1]
    local body = {
        listing_id = listingId,
        sender_id = getPlayerId(),
        sender_name = getPlayerName(),
        recipient_id = listing.seller_id,
        content = tostring(content):sub(1, 500)
    }
    local endpoint = "/rest/v1/messages"
    if callback then
        request(endpoint, "POST", body, function(data, err)
            callback(err == nil, err)
        end)
        return
    end
    local _, err = request(endpoint, "POST", body, nil)
    if err then return nil, err end
    return true, nil
end

-- Remove/Cancel a listing
local function removeListing(listingId, callback)
    local endpoint = "/rest/v1/listings?id=eq." .. listingId
    local body = { status = "cancelled" }
    
    request(endpoint, "PATCH", body, function(data, error)
        if not error then
            clearCarSwapListingMarker(listingId)
            if career_saveSystem and career_saveSystem.saveCurrent then
                career_saveSystem.saveCurrent()
            end
        end
        if callback then
            callback(error == nil, error)
        end
    end)
end

local function claimListing(listingId, callback)
    local query = "/rest/v1/listings?select=id,price,status&id=eq." .. listingId

    if callback then
        request(query, "GET", nil, function(data, error)
            if error then
                callback(nil, error)
                return
            end
            local listing = data and data[1]
            if not listing then
                callback({success = false, reason = "listing_missing"}, nil)
                return
            end
            if listing.status ~= "sold" then
                callback({success = false, reason = "not_sold"}, nil)
                return
            end
            local invId = findInventoryIdByListingId(listingId)
            if not invId then
                callback({success = false, reason = "vehicle_missing"}, nil)
                return
            end
            local price = math.floor(tonumber(listing.price) or 0)
            if career_modules_inventory and career_modules_inventory.sellVehicle then
                local ok = career_modules_inventory.sellVehicle(invId, price)
                if not ok then
                    callback({success = false, reason = "sell_failed"}, nil)
                    return
                end
            end
            request("/rest/v1/listings?id=eq." .. listingId, "PATCH", {status = "expired"}, function(_, patchErr)
                if patchErr then
                    callback({success = false, reason = "status_update_failed"}, patchErr)
                    return
                end
                clearCarSwapListingMarker(listingId)
                callback({success = true}, nil)
            end)
        end)
        return
    end

    local data, error = request(query, "GET", nil, nil)
    if error then return nil, error end
    local listing = data and data[1]
    if not listing then return {success = false, reason = "listing_missing"}, nil end
    if listing.status ~= "sold" then return {success = false, reason = "not_sold"}, nil end

    local invId = findInventoryIdByListingId(listingId)
    if not invId then return {success = false, reason = "vehicle_missing"}, nil end

    local price = math.floor(tonumber(listing.price) or 0)
    if career_modules_inventory and career_modules_inventory.sellVehicle then
        local ok = career_modules_inventory.sellVehicle(invId, price)
        if not ok then return {success = false, reason = "sell_failed"}, nil end
    end

    local _, patchErr = request("/rest/v1/listings?id=eq." .. listingId, "PATCH", {status = "expired"}, nil)
    if patchErr then return {success = false, reason = "status_update_failed"}, patchErr end
    clearCarSwapListingMarker(listingId)
    return {success = true}, nil
end

-- Inventory Helper
local function getInventoryForListing()
    if not career_modules_inventory then return {} end
    
    local vehicles = career_modules_inventory.getVehicles()
    local result = {}
    
    for invId, vehicle in pairs(vehicles) do
        if vehicle and vehicle.config and vehicle.config.carswap_listed then
            goto continue
        end
        local vehInfo = {
            inventoryId = invId,
            name = vehicle.niceName or "Unknown Vehicle",
            model = vehicle.model,
            year = vehicle.year,
            mileage = vehicle.mileage,
            estimatedValue = vehicle.value
        }
        table.insert(result, vehInfo)
        ::continue::
    end
    
    return result
end

-- ============================================================================
-- UI Data Agreggation
-- ============================================================================

-- Normalize only legacy listings where thumbnail_base64 was stored as a JSON array string.
-- New listings use separate columns (thumbnail_base64, thumbnail_2_base64, ...) and need no change.
local function normalizeListingThumbnail(listing)
    if not listing then return end
    if listing.thumbnail_2_base64 then return end  -- new format: already separate columns
    local t = listing.thumbnail_base64
    if t == nil or t == "" then return end
    if type(t) == "table" then
        local first = t[1] or t[0]
        if type(first) == "string" and first ~= "" then
            listing.thumbnail_base64 = first
            listing.thumbnail_base64_full = t
        end
        return
    end
    if type(t) ~= "string" then return end
    local s = (t:gsub("^%s+", ""):gsub("%s+$", ""))
    if s:sub(1, 1) == "[" then
        local ok, arr = pcall(jsonDecode, s)
        if ok and type(arr) == "table" and (arr[1] or arr[0]) then
            local first = arr[1] or arr[0]
            if type(first) == "string" and first ~= "" then
                listing.thumbnail_base64_full = t
                listing.thumbnail_base64 = first
            end
        end
    end
end

local function normalizeListings(listings)
    if not listings then return end
    for i = 1, #listings do
        normalizeListingThumbnail(listings[i])
    end
end

local function getUIData(callback)
    local isConnected = checkHubConnection(nil)
    local profileName = getProfileName()
    local data = {
        isConnected = isConnected,
        playerId = getPlayerId(),
        playerName = getPlayerName(),
        nameRequired = (profileName == nil or profileName == "")
    }

    if isConnected then
        local listings = getListings(nil)
        local myListings = getMyListings(nil)
        local playerId = getPlayerId()
        local messagesQuery = "/rest/v1/messages?recipient_id=eq." .. playerId .. "&order=created_at.desc&select=*"
        local messagesList = request(messagesQuery, "GET", nil, nil)
        if messagesList and type(messagesList) == "table" then
            data.messages = messagesList
            local unread = 0
            for i = 1, #messagesList do
                if not messagesList[i].read then unread = unread + 1 end
            end
            data.unreadMessages = unread
        else
            data.messages = {}
            data.unreadMessages = 0
        end
        local sentQuery = "/rest/v1/messages?sender_id=eq." .. playerId .. "&order=created_at.desc&select=*"
        local sentList = request(sentQuery, "GET", nil, nil)
        data.sentMessages = (sentList and type(sentList) == "table") and sentList or {}

        data.listings = listings or {}
        data.myListings = myListings or {}
        normalizeListings(data.listings)
        normalizeListings(data.myListings)
    else
        data.listings = {}
        data.myListings = {}
        data.messages = {}
        data.sentMessages = {}
        data.unreadMessages = 0
    end

    if callback then
        callback(data)
    end

    return data
end

-- ============================================================================
-- Exports
-- ============================================================================

M.checkHubConnection = checkHubConnection
M.getListings = getListings
M.createListing = createListing 
M.purchaseVehicle = purchaseVehicle
M.cancelListing = removeListing 
M.removeListing = removeListing
M.getMyListings = getMyListings
M.getUIData = getUIData
M.getInventoryForListing = getInventoryForListing
M.testConnection = testConnection
M.sendMessage = sendMessage
M.claimListing = claimListing

-- Legacy exports
M.getPlayerId = getPlayerId
M.getPlayerName = getPlayerName
M.setProfileName = setProfileName
M.getProfileName = getProfileName
M.getVehicleCondition = function(vid) return 1.0 end
M.getVehicleMileage = function(vid) return 0 end

M.onExtensionLoaded = function()
    log("I", "carswap", "CarSwap Direct initialized. URL: " .. SUPABASE_URL)
end

M.onSaveFinished = function()
    if not career_modules_inventory or not career_modules_inventory.removeVehicleObject then return end
    for inventoryId, _ in pairs(pendingDespawnInventoryIds) do
        career_modules_inventory.removeVehicleObject(inventoryId)
        pendingDespawnInventoryIds[inventoryId] = nil
    end
end

return M

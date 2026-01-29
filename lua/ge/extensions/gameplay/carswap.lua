-- CarSwap Online Marketplace
-- Connects to RLS Hub companion app for online features

local M = {}

local HUB_URL = "http://127.0.0.1:8085"
local requestId = 0
local pendingRequests = {}

-- ============================================================================
-- HTTP Communication with RLS Hub
-- ============================================================================

local function sendToHub(action, data, callback)
    requestId = requestId + 1
    local currentId = requestId
    
    local requestBody = {
        action = action,
        data = data or {}
    }
    
    local json = require("jsonEncode")
    local body = json(requestBody)
    
    -- Store callback for response
    pendingRequests[currentId] = callback
    
    -- Use BeamNG's HTTP capability to localhost
    local socket = require("socket.http")
    local ltn12 = require("ltn12")
    
    local responseBody = {}
    
    local result, statusCode, headers = socket.request({
        url = HUB_URL .. "/carswap",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = #body
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(responseBody)
    })
    
    local response = table.concat(responseBody)
    
    if callback then
        if statusCode == 200 then
            local decoded = require("jsonDecode")(response)
            callback(decoded)
        else
            callback({
                success = false,
                error = "Hub not available (status: " .. tostring(statusCode) .. ")"
            })
        end
    end
end

-- Alternative method using core_online if available
local function sendToHubAsync(action, data, callback)
    local requestBody = {
        action = action,
        data = data or {}
    }
    
    -- Try using BeamNG's internal HTTP if available
    if core_online and core_online.httpRequest then
        core_online.httpRequest(HUB_URL .. "/carswap", {
            method = "POST",
            body = jsonEncode(requestBody),
            headers = {
                ["Content-Type"] = "application/json"
            },
            callback = function(response)
                if callback then
                    if response and response.success and response.data then
                        callback(jsonDecode(response.data))
                    else
                        callback({
                            success = false,
                            error = response and response.error or "Hub not available"
                        })
                    end
                end
            end
        })
    else
        -- Fallback: synchronous request
        sendToHub(action, data, callback)
    end
end

-- ============================================================================
-- API Functions
-- ============================================================================

-- Check if RLS Hub is running
local function checkHubConnection(callback)
    local socket = require("socket.http")
    local result, statusCode = socket.request(HUB_URL .. "/health")
    
    if callback then
        callback(statusCode == 200)
    end
    return statusCode == 200
end

-- Get all available listings
local function getListings(callback)
    sendToHubAsync("get_listings", nil, function(response)
        if callback then
            if response.success then
                callback(response.data or {})
            else
                callback(nil, response.error or "Failed to get listings")
            end
        end
    end)
end

-- List a vehicle for sale
local function listVehicle(vehicleData, callback)
    -- Get player's identifier (Steam ID or generate one)
    local sellerId = getPlayerId()
    local sellerName = getPlayerName()
    
    local listing = {
        seller_id = sellerId,
        seller_name = sellerName,
        vehicle_config = vehicleData.config,
        thumbnail = vehicleData.thumbnail,
        price = vehicleData.price,
        title = vehicleData.title or vehicleData.config.model,
        description = vehicleData.description,
        mileage = vehicleData.mileage,
        condition = vehicleData.condition,
        status = "available"
    }
    
    sendToHubAsync("list_vehicle", listing, function(response)
        if callback then
            callback(response.success, response.error)
        end
    end)
end

-- Purchase a vehicle
local function purchaseVehicle(listingId, callback)
    local buyerId = getPlayerId()
    
    sendToHubAsync("purchase_vehicle", {
        listing_id = listingId,
        buyer_id = buyerId
    }, function(response)
        if callback then
            if response.success then
                -- Return the vehicle data so BeamNG can spawn it
                callback(response.data, nil)
            else
                callback(nil, response.error or "Purchase failed")
            end
        end
    end)
end

-- Remove a listing
local function removeListing(listingId, callback)
    sendToHubAsync("remove_listing", {
        listing_id = listingId
    }, function(response)
        if callback then
            callback(response.success, response.error)
        end
    end)
end

-- Get player's own listings
local function getMyListings(callback)
    local sellerId = getPlayerId()
    
    sendToHubAsync("get_my_listings", {
        seller_id = sellerId
    }, function(response)
        if callback then
            if response.success then
                callback(response.data or {})
            else
                callback(nil, response.error)
            end
        end
    end)
end

-- ============================================================================
-- Helper Functions
-- ============================================================================

local function getPlayerId()
    -- Try to get Steam ID
    if Steam and Steam.getSteamID then
        return tostring(Steam.getSteamID())
    end
    
    -- Fallback: use a persistent ID from career
    local career = career_career
    if career and career.getAutosavePath then
        local path = career.getAutosavePath()
        if path then
            return "career_" .. path:gsub("[/\\]", "_")
        end
    end
    
    -- Last resort: generate based on computer name or random
    return "player_" .. os.time()
end

local function getPlayerName()
    -- Try Steam name
    if Steam and Steam.getPersonaName then
        return Steam.getPersonaName()
    end
    
    -- Fallback
    return "Player"
end

-- Get vehicle thumbnail as base64
local function getVehicleThumbnail(vehicleId, callback)
    -- This is tricky in BeamNG - we'd need to capture a screenshot
    -- For now, return nil and let the Hub handle missing thumbnails
    if callback then
        callback(nil)
    end
end

-- Get vehicle condition percentage
local function getVehicleCondition(vehicleId)
    local veh = be:getObjectByID(vehicleId)
    if not veh then return 1.0 end
    
    local vdata = core_vehicle_manager.getVehicleData(vehicleId)
    if vdata and vdata.veh and vdata.veh:getBeamDamage() then
        local damage = vdata.veh:getBeamDamage()
        -- Estimate condition based on beam damage
        local conditionPercent = math.max(0, 1 - (damage / 100))
        return conditionPercent
    end
    
    return 1.0
end

-- Get vehicle mileage
local function getVehicleMileage(vehicleId)
    local inventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(vehicleId)
    if inventoryId then
        local vehicle = career_modules_inventory.getVehicles()[inventoryId]
        if vehicle then
            return vehicle.mileage or 0
        end
    end
    return 0
end

-- ============================================================================
-- UI Data for Phone App
-- ============================================================================

local function getUIData(callback)
    local isConnected = checkHubConnection()
    
    local data = {
        isConnected = isConnected,
        hubUrl = HUB_URL,
        playerId = getPlayerId(),
        playerName = getPlayerName()
    }
    
    if isConnected then
        getListings(function(listings, error)
            data.listings = listings or {}
            data.listingsError = error
            
            getMyListings(function(myListings, myError)
                data.myListings = myListings or {}
                data.myListingsError = myError
                
                if callback then
                    callback(data)
                end
            end)
        end)
    else
        data.listings = {}
        data.myListings = {}
        data.connectionError = "RLS Hub not running. Please start the RLS Hub companion app."
        
        if callback then
            callback(data)
        end
    end
end

-- ============================================================================
-- Exported Functions
-- ============================================================================

M.checkHubConnection = checkHubConnection
M.getListings = getListings
M.listVehicle = listVehicle
M.purchaseVehicle = purchaseVehicle
M.removeListing = removeListing
M.getMyListings = getMyListings
M.getUIData = getUIData
M.getPlayerId = getPlayerId
M.getPlayerName = getPlayerName
M.getVehicleCondition = getVehicleCondition
M.getVehicleMileage = getVehicleMileage

-- Extension lifecycle
M.onExtensionLoaded = function()
    log("I", "carswap", "CarSwap extension loaded - connects to RLS Hub on " .. HUB_URL)
end

return M

local M = {}

local dependencies = {'career_career', 'career_modules_inventory'}

local assignmentData = nil
local vehiclePresent = nil
local POLICE_ASSIGNMENT_TRIGGER = "policeAssignment"
local POLICE_ASSIGNMENT_UNLOCK_LEVEL = 20
local POLICE_SKILL_ATTRIBUTE_KEY = "careerSkills-police"
local POLICE_SKILL_PATH_IDS = {"careerSkills-police", "police", "freestyle-police"}
local roleAssignments = {
    [POLICE_ASSIGNMENT_TRIGGER] = "Police"
}

local function getBranchLevelByPathIds(pathIds)
    if not career_branches or not career_branches.getBranchLevel then
        return 0
    end

    for _, skillPathId in ipairs(pathIds or {}) do
        local branchLevel = career_branches.getBranchLevel(skillPathId)
        local level = tonumber(branchLevel)
        if level then
            return math.max(0, math.floor(level))
        end
    end

    return 0
end

local function getPoliceSkillLevel()
    local level = getBranchLevelByPathIds(POLICE_SKILL_PATH_IDS)
    if level > 0 then
        return level
    end

    if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
        local value = tonumber(career_modules_playerAttributes.getAttributeValue(POLICE_SKILL_ATTRIBUTE_KEY)) or 0
        for _, skillPathId in ipairs(POLICE_SKILL_PATH_IDS) do
            local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
            level = math.max(level, tonumber(branchLevel) or 0)
        end
    end

    return math.max(0, math.floor(level))
end

local function isPoliceCertificationUnlocked()
    return getPoliceSkillLevel() >= POLICE_ASSIGNMENT_UNLOCK_LEVEL
end

local function getPoliceCertificationLockMessage()
    return string.format("Police certification requires Police Skill level %d", POLICE_ASSIGNMENT_UNLOCK_LEVEL)
end

local function canPay()
    local canPayJobIndex = career_modules_globalEconomy and career_modules_globalEconomy.getJobMarketIndex() or 1.0
    local certificationPrice = {
        money = {
            amount = math.floor(assignmentData.cost * canPayJobIndex),
            canBeNegative = false
        }
    }
    return career_modules_payment.canPay(certificationPrice)
end

local function startCertification()
    guihooks.trigger('ChangeState', {
        state = 'play',
        params = {}
    })
    if not isPoliceCertificationUnlocked() then
        ui_message(getPoliceCertificationLockMessage(), 8, "Police", "info")
        return
    end
    local inventoryId = career_modules_inventory.getCurrentVehicle()
    if inventoryId then
        if not canPay() then
            ui_message("You do not have enough funds to certify your vehicle", 10, "error", "info")
            return
        end
        local jobMarketIndex = career_modules_globalEconomy and career_modules_globalEconomy.getJobMarketIndex() or 1.0
        local certificationPrice = {
            money = {amount = math.floor(assignmentData.cost * jobMarketIndex), canBeNegative = false}
        }
        career_modules_payment.pay(certificationPrice, {
            label = "Certification fee",
            tags = {"certification", string.lower(assignmentData.type)}
        })
        career_modules_inventory.setVehicleRole(inventoryId, string.lower(assignmentData.type))
        career_modules_inventory.delayVehicleAccess(inventoryId, assignmentData.time, string.format("%s_certification", assignmentData.type))
        core_vehicleBridge.executeAction(be:getPlayerVehicle(0), 'setFreeze', true)
        vehiclePresent = be:getPlayerVehicle(0)
    end
end

local function onBeamNGTrigger(data)
    if data.subjectID ~= be:getPlayerVehicleID(0) then
        return
    end
    if gameplay_walk.isWalking() then
        return
    end

    if not data.triggerName:find(POLICE_ASSIGNMENT_TRIGGER) then
        return
    end
    assignmentData = {
        time = 14400,
        cost = 10000,
        type = "Police"
    }

    if data.event == "enter" then
        local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID)
        if inventoryId then
            if not isPoliceCertificationUnlocked() then
                ui_message(getPoliceCertificationLockMessage(), 8, "Police", "info")
                return
            end
            if career_modules_inventory.getVehicleRole(inventoryId) ~= string.lower(assignmentData.type) then
                guihooks.trigger('ChangeState', {
                    state = 'roleAssignment'
                })
            end
        end
    elseif data.event == "exit" then
        guihooks.trigger('ChangeState', {
            state = 'play',
            params = {}
        })
    end
end

local function onUpdate()
    if vehiclePresent then
        local playerVeh = be:getPlayerVehicle(0)
        if not playerVeh then return end
        local vehiclePosition = vehiclePresent:getPosition()
        local playerPosition = playerVeh:getPosition()
        if (playerPosition - vehiclePosition):length() >= 25 then
            career_modules_inventory.removeVehicleObject(career_modules_inventory.getInventoryIdFromVehicleId(
                vehiclePresent:getID()))
            vehiclePresent = nil
            career_saveSystem.saveCurrent()
        end
    end
end

local function requestAssignmentData()
    return assignmentData
end

local function formatAssignRolePoi(role, roleName)
    local switchToObj = scenetree.findObject(role)
    local pos = switchToObj and switchToObj:getPosition() or nil
    
    if not pos then return nil end

    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/roleAssignment/" .. role .. ".jpg"

    return {
        id = role,
        data = {
            type = "assignRole",
            facility = {}
        },
        markerInfo = {
            bigmapMarker = {
                pos = pos,
                icon = "poi_fasttravel_round_orange_green",
                name = roleName .. " Certification",
                description = "Certify your vehicle as a " .. roleName .. " Vehicle",
                previews = {preview},
                thumbnail = preview
            }
        }
    }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    for role, roleName in pairs(roleAssignments) do
        if role == POLICE_ASSIGNMENT_TRIGGER and not isPoliceCertificationUnlocked() then
            goto continue
        end
        local poi = formatAssignRolePoi(role, roleName)
        if poi then
            table.insert(elements, poi)
        end
        ::continue::
    end
end

M.canPay = canPay
M.startCertification = startCertification
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate
M.requestAssignmentData = requestAssignmentData

return M

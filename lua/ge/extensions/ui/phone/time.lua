local M = {}

local lastSentTime = nil

local function formatTime(t)
    local total_minutes = t * 1440
    local hours = math.floor(total_minutes / 60)
    local minutes = math.floor(total_minutes % 60)
    local period = hours < 12 and "PM" or "AM"
    local twelve_hour = hours % 12
    twelve_hour = twelve_hour == 0 and 12 or twelve_hour
    return string.format("%d:%02d %s", twelve_hour, minutes, period)
end

local function getTime()
    if scenetree and scenetree.tod and scenetree.tod.time ~= nil then
        return formatTime(scenetree.tod.time)
    end
    return nil
end

local function requestTime()
    local formatted = getTime()
    if formatted then
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function onUpdate()
    local formatted = getTime()
    if formatted and formatted ~= lastSentTime then
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function onExtensionLoaded()
    local formatted = getTime()
    if formatted then
        lastSentTime = formatted
        guihooks.trigger("phone_time_update", formatted)
    end
end

local function clearTime()
    lastSentTime = nil
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.clearTime = clearTime
M.requestTime = requestTime

return M
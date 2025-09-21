local M = {}

M.dependencies = {"core_input_actions"}

local actionsPath = "lua/ge/extensions/core/input/actions"
local activeActions = {} -- Track injected actions
local customActions = {
    openPhone = {
        cat = "gameplay",
        order = 97.6,
        ctx = "tlua",
        onDown = "if not gameplay_phone then extensions.load('gameplay_phone') end if gameplay_phone then gameplay_phone.togglePhone() end",
        title = "Toggle Phone",
        desc = "Toggle Phone"
    }
}

local function injectCustomActions()
    local actions = {}
    for actionName, actionData in pairs(customActions) do
        if not activeActions[actionName] then
            actions[actionData.cat] = actions[actionData.cat] or jsonReadFile(actionsPath .. "/" .. actionData.cat .. ".json") or {}
            actions[actionData.cat][actionName] = actionData
            activeActions[actionName] = true
            log("I", "customActions", "Injected custom action: " .. actionName)
        end
    end
    for cat, actionData in pairs(actions) do
        jsonWriteFile("overriden/" .. actionsPath .. "/" .. cat .. ".json", actionData)
    end
end

M.injectCustomActions = injectCustomActions

return M

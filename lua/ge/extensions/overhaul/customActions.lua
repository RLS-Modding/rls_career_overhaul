local M = {}

M.dependencies = {"core_input_actions"}

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
    local activeActions = core_input_actions.getActiveActions()

    for actionName, actionData in pairs(customActions) do
        dump(actionName)
        dump(actionData)
        if not activeActions[actionName] then
            activeActions[actionName] = actionData
            log("I", "customActions", "Injected custom action: " .. actionName)
        end
    end
end

local function onFileChanged(filename)
    -- Re-inject actions when action files change
    if string.find(filename, "input/actions") then
        injectCustomActions()
    end
end

M.onExtensionLoaded = injectCustomActions
M.onFirstUpdate = injectCustomActions
M.onFileChanged = onFileChanged

return M

local M = {}

local vanillaMapItems = {}

local function addMapChanges()
    local additionalFiles = FS:findFiles("/levels/", "*additional.items.level.json", -1, true, false)
    local vanillaGroups = {}
    
    for _, additionalPath in ipairs(additionalFiles) do
        local dir = additionalPath:match("(.*/)")
        local vanillaPath = dir .. "items.level.json"
        
        if not vanillaGroups[vanillaPath] then
            vanillaGroups[vanillaPath] = { additionalPaths = {}, additionalContent = {} }
        end
        table.insert(vanillaGroups[vanillaPath].additionalPaths, additionalPath)
        
        local additionalFile = io.open(additionalPath, "r")
        if additionalFile then
            local content = additionalFile:read("*all")
            additionalFile:close()
            if content and #content > 0 then
                table.insert(vanillaGroups[vanillaPath].additionalContent, content)
            end
        end
    end
    
    for vanillaPath, group in pairs(vanillaGroups) do
        local vanillaFile = io.open(vanillaPath, "r")
        if vanillaFile then
            local originalContent = vanillaFile:read("*all")
            vanillaFile:close()
            
            vanillaMapItems[vanillaPath] = {
                additionalPaths = group.additionalPaths,
                originalContent = originalContent
            }
            
            local combinedAdditional = table.concat(group.additionalContent, "\n")
            if #combinedAdditional > 0 then
                local outFile = io.open(vanillaPath, "w")
                if outFile then
                    local newContent = originalContent
                    if not originalContent:match("\n$") then
                        newContent = newContent .. "\n"
                    end
                    newContent = newContent .. combinedAdditional
                    outFile:write(newContent)
                    outFile:close()
                end
            end
        end
    end
end

local function removeMapChanges()
    for vanillaPath, data in pairs(vanillaMapItems) do
        local allMissing = true
        for _, additionalPath in ipairs(data.additionalPaths) do
            local additionalFile = io.open(additionalPath, "r")
            if additionalFile then
                additionalFile:close()
                allMissing = false
                break
            end
        end
        
        if allMissing then
            local outFile = io.open(vanillaPath, "w")
            if outFile then
                outFile:write(data.originalContent)
                outFile:close()
            end
            vanillaMapItems[vanillaPath] = nil
        end
    end
end

M.onModActivated = addMapChanges
M.onExtensionLoaded = addMapChanges
M.onModDeactivated = removeMapChanges
M.onExtensionUnloaded = removeMapChanges
return M

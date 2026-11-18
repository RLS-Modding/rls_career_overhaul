local M = {}
local bindings = {}

local function detach(device, binding)
    if device.updateGFX == binding.wrapper then device.updateGFX = binding.original end
    if binding.lastApplied and device.invBurnEfficiencyCoef == binding.lastApplied then
        device.invBurnEfficiencyCoef = device.invBurnEfficiencyCoef / 1.5
    end
    device.rlsFuelConsumptionMultiplier = nil
    bindings[device] = nil
end

local function onExtensionLoaded()
    local devices = powertrain.getDevices()
    local current = {}
    for _, device in pairs(devices) do current[device] = true end
    for device, binding in pairs(bindings) do
        if not current[device] then detach(device, binding) end
    end
    for _, device in pairs(devices) do
    -- Substring match: mod engines use types such as "combustionEngine_camshalfts_vip".
    if tostring(device.type or ''):find('combustionEngine', 1, true) and device.updateGFX and not bindings[device] then
        local originalUpdateGFX = device.updateGFX
        local binding = {original = originalUpdateGFX}
        device.updateGFX = function(self, dt)
            if binding.lastApplied and self.invBurnEfficiencyCoef == binding.lastApplied then
                self.invBurnEfficiencyCoef = self.invBurnEfficiencyCoef / 1.5
            end
            originalUpdateGFX(self, dt)
            if self.invBurnEfficiencyCoef then
                self.invBurnEfficiencyCoef = (self.invBurnEfficiencyCoef or 1) * 1.5
                binding.lastApplied = self.invBurnEfficiencyCoef
            end
        end
        binding.wrapper = device.updateGFX
        bindings[device] = binding
        device.rlsFuelConsumptionMultiplier = 1.5
    end
    end
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onExtensionLoaded
M.onExtensionUnloaded = function()
    for device, binding in pairs(bindings) do
        detach(device, binding)
    end
    bindings = {}
end

return M

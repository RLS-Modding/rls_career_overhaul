local M = {}

local function onExtensionLoaded()
    local device = powertrain.getDevice("mainEngine")
    if not device then
        return
    end

    if device.updateGFX then
        local originalUpdateGFX = device.updateGFX
        device.updateGFX = function(self, dt)
            originalUpdateGFX(self, dt)
            if self.invBurnEfficiencyCoef then
                self.invBurnEfficiencyCoef = (self.invBurnEfficiencyCoef or 1) * 0.5
            end
        end
    end
end

M.onExtensionLoaded = onExtensionLoaded

return M
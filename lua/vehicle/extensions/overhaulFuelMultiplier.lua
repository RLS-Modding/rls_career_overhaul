-- Applies the configured fuel-consumption multiplier to this vehicle.
-- Read state, consumption updates, configuration and initialization hooks.
local M = {}

local wrappedDevice = nil
local originalUpdateGFX = nil
local wrappedUpdateGFX = nil

local function onExtensionUnloaded()
    if wrappedDevice and wrappedDevice.updateGFX == wrappedUpdateGFX then
        wrappedDevice.updateGFX = originalUpdateGFX
    end
    wrappedDevice = nil
    originalUpdateGFX = nil
    wrappedUpdateGFX = nil
end

local function onExtensionLoaded()
    local device = powertrain.getDevice("mainEngine")
    if device and device == wrappedDevice and device.updateGFX == wrappedUpdateGFX then return end
    onExtensionUnloaded()
    if not device then
        return
    end

    if device.updateGFX then
        local baseUpdateGFX = device.updateGFX
        originalUpdateGFX = baseUpdateGFX
        wrappedDevice = device
        wrappedUpdateGFX = function(self, dt)
            baseUpdateGFX(self, dt)
            if self.invBurnEfficiencyCoef then
                -- The engine recomputes this coefficient in its base updateGFX.
                self.invBurnEfficiencyCoef = self.invBurnEfficiencyCoef * 1.5
            end
        end
        device.updateGFX = wrappedUpdateGFX
    end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onReset = onExtensionLoaded

return M

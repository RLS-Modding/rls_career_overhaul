-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Simple override for manualTraffic mode
local function onExtensionLoaded()
    -- Wait for AI to load, then override the exported function
    local function patchAI()
        if not ai then
            return setTimeout(patchAI, 100)
        end

        -- Store original driveUsingPathWithTraffic function
        local originalDriveUsingPathWithTraffic = ai.driveUsingPathWithTraffic

        -- Override driveUsingPathWithTraffic to customize manualTraffic setup
        ai.driveUsingPathWithTraffic = function(arg)
            if not arg then return end

            -- Set up the parameters with custom traffic-friendly defaults
            local trafficArgs = {
                wpTargetList = arg.wpTargetList,
                path = arg.path,
                script = arg.script,
                wpSpeeds = arg.wpSpeeds,
                noOfLaps = arg.noOfLaps,
                routeSpeed = arg.routeSpeed,
                routeSpeedMode = arg.routeSpeedMode,
                driveInLane = arg.driveInLane or 'on',  -- Default to staying in lanes
                aggression = arg.aggression or 0.3,     -- Default to conservative driving
                avoidCars = arg.avoidCars or 'on',      -- Default to avoiding cars
                driveStyle = arg.driveStyle,
                staticFrictionCoefMult = arg.staticFrictionCoefMult,
                lookAheadKv = arg.lookAheadKv,
                understeerThrottleControl = arg.understeerThrottleControl,
                oversteerThrottleControl = arg.oversteerThrottleControl,
                throttleTcs = arg.throttleTcs,
                abBrakeControl = arg.abBrakeControl,
                underSteerBrakeControl = arg.underSteerBrakeControl
            }

            -- Use the regular driveUsingPath function to set up the route
            ai.driveUsingPath(trafficArgs)

            -- Switch to manual traffic mode
            ai.mode = 'manualTraffic'
            ai.stateChanged()

            -- CUSTOM MANUAL TRAFFIC SETUP
            -- Add your custom parameters here
            ai.setParameters({
                trafficWaitTime = 0.005,      -- How long to wait at traffic signals
                lookAheadKv = 0.01,           -- Look-ahead distance multiplier
                awarenessForceCoef = 0.02,    -- Awareness of other vehicles
                driveStyle = "offroad"        -- Driving style
            })

            print("Custom manualTraffic mode activated")
        end

        print("ManualTraffic override loaded - driveUsingPathWithTraffic successfully patched")
    end

    setTimeout(patchAI, 100)
end

M.onExtensionLoaded = onExtensionLoaded

return M
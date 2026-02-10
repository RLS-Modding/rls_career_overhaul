# AI Integration Synthesis Document

## Model Input/Output Specification

**Based on real BeamNG.drive Lua API variables for implementable AI model interface**

### INPUTS (from game state)

#### Vehicle Telemetry
```lua
-- Core vehicle state (via obj:getState())
position = {x = float, y = float, z = float}          -- World coordinates
velocity = {x = float, y = float, z = float}          -- m/s velocity vector
angular_velocity = {x = float, y = float, z = float}  -- rad/s rotation rates
rotation = {x = float, y = float, z = float, w = float} -- Quaternion orientation

-- Vehicle dynamics (via electrics values)
steering_angle = electrics.values.steering_input     -- [-1.0, 1.0] current wheel angle
throttle = electrics.values.throttle                 -- [0.0, 1.0] current throttle
brake = electrics.values.brake                       -- [0.0, 1.0] current brake pressure
gear = electrics.values.gear                         -- integer current gear (-1=reverse, 0=neutral, 1+=forward)
rpm = electrics.values.rpm                          -- float engine RPM
speed = electrics.values.wheelspeed                 -- float km/h ground speed
fuel = electrics.values.fuel                        -- [0.0, 1.0] fuel level
```

#### Environment Context
```lua
-- Road surface (via physics raycast)
surface_condition = {
    friction = float,              -- [0.0, 1.0] current surface grip
    material = string,             -- "asphalt", "dirt", "ice", etc.
    slope_angle = float,           -- degrees, positive = uphill
    roughness = float              -- [0.0, 1.0] surface irregularity
}

-- Traffic density (via traffic system)
traffic_density = ai.getTrafficDensity()            -- [0.0, 1.0] current traffic level
road_type = map.getRoadType(position)               -- "highway", "city", "rural", "off-road"
```

#### Navigation Data
```lua
-- Route planning (via route system)
waypoint_distance = route.getDistanceToNextWaypoint() -- meters to next nav point
route_direction = route.getNextDirection()             -- "straight", "left", "right", "uturn"
lane_position = {
    offset = float,                -- [-1.0, 1.0] -1=left edge, 0=center, 1=right edge
    lane_width = float,            -- meters total lane width
    lane_count = integer           -- total lanes in current direction
}

-- GPS/Map data
current_speed_limit = map.getSpeedLimit(position)   -- km/h legal speed limit
upcoming_intersections = map.getIntersections(position, 500) -- array of intersections within 500m
upcoming_turns = route.getUpcomingTurns(5)         -- next 5 turns in route
```

#### Traffic State
```lua
-- Ego vehicle bounding box (via vehicle object)
ego_bounding_box = {
    center = {x = float, y = float, z = float},      -- world position of center
    dimensions = {length = float, width = float, height = float}, -- meters
    corners = {                    -- 8 corner positions in world coordinates
        front_left_top = {x = float, y = float, z = float},
        front_right_top = {x = float, y = float, z = float},
        front_left_bottom = {x = float, y = float, z = float},
        front_right_bottom = {x = float, y = float, z = float},
        rear_left_top = {x = float, y = float, z = float},
        rear_right_top = {x = float, y = float, z = float},
        rear_left_bottom = {x = float, y = float, z = float},
        rear_right_bottom = {x = float, y = float, z = float}
    }
}

-- All nearby vehicles with full bounding boxes (via sensor system)
nearby_vehicles = {
    {
        vehicle_id = integer,      -- unique vehicle identifier
        vehicle_type = string,     -- "car", "truck", "bus", "emergency", "motorcycle"
        distance = float,          -- meters from ego vehicle center
        relative_speed = float,    -- m/s difference (positive = approaching)
        direction_vector = {x = float, y = float, z = float}, -- unit vector of travel direction
        position_relative = {x = float, y = float, z = float}, -- position relative to ego vehicle
        bounding_box = {
            center = {x = float, y = float, z = float},
            dimensions = {length = float, width = float, height = float},
            corners = {
                front_left_top = {x = float, y = float, z = float},
                front_right_top = {x = float, y = float, z = float},
                front_left_bottom = {x = float, y = float, z = float},
                front_right_bottom = {x = float, y = float, z = float},
                rear_left_top = {x = float, y = float, z = float},
                rear_right_top = {x = float, y = float, z = float},
                rear_left_bottom = {x = float, y = float, z = float},
                rear_right_bottom = {x = float, y = float, z = float}
            }
        },
        lane_offset = float,       -- [-1.0, 1.0] lateral position relative to ego
        is_emergency = boolean,    -- true if emergency vehicle (police, fire, ambulance)
        emergency_lights = boolean -- true if emergency lights are active
    }
}

-- Collision risk assessment
collision_risk = {
    time_to_collision = float,     -- seconds until potential impact
    risk_level = float,            -- [0.0, 1.0] computed risk score
    primary_threat = string        -- "front", "rear", "left", "right", "none"
}

-- Emergency vehicle tracking
emergency_vehicles = {
    {
        vehicle_id = integer,      -- reference to vehicle in nearby_vehicles
        emergency_type = string,   -- "police", "fire", "ambulance", "medical"
        lights_active = boolean,   -- emergency lights on/off
        siren_active = boolean,    -- siren on/off (if audio detection available)
        direction_vector = {x = float, y = float, z = float}, -- travel direction unit vector
        position_relative = {x = float, y = float, z = float}, -- position relative to ego
        approach_angle = float,    -- radians, angle of approach relative to ego heading
        priority_level = float     -- [0.0, 1.0] urgency level for right-of-way
    }
}

-- Traffic control (via AI traffic system)
traffic_signals = {
    current_light = string,        -- "red", "yellow", "green", "none"
    time_to_change = float,        -- seconds until light changes
    stop_line_distance = float     -- meters to stop line
}
```

#### Vision Data
```lua
-- Camera feeds (via render system)
front_camera = {
    image_data = table,           -- RGB pixel array [width][height][3]
    depth_map = table,            -- Distance values [width][height]
    resolution = {width = integer, height = integer},
    fov = float,                  -- degrees field of view
    range = float                 -- meters maximum depth detection
}

rear_camera = {
    image_data = table,
    depth_map = table,
    resolution = {width = integer, height = integer},
    fov = float,
    range = float
}

-- Object detection results
detected_objects = {
    {
        type = string,            -- "vehicle", "pedestrian", "sign", "obstacle"
        position = {x = float, y = float}, -- screen coordinates
        distance = float,         -- meters from ego vehicle
        confidence = float        -- [0.0, 1.0] detection confidence
    }
}
```

### OUTPUTS (to vehicle controls)

#### Primary Control Commands
```lua
-- Direct vehicle input (sent via input.event)
steering_input = float           -- [-1.0, 1.0] -1=full left, 1=full right
throttle_input = float           -- [0.0, 1.0] acceleration pedal position
brake_input = float              -- [0.0, 1.0] brake pedal force
clutch_input = float             -- [0.0, 1.0] clutch engagement (manual transmission)

-- Transmission control
gear_request = integer           -- requested gear (-1=reverse, 0=neutral, 1+=forward)
transmission_mode = string       -- "manual", "automatic", "sport"
```

#### Advanced Control Outputs
```lua
-- Electronic systems
abs_enabled = boolean            -- Anti-lock braking system toggle
traction_control = boolean       -- Stability/traction control toggle
cruise_control = {
    enabled = boolean,           -- Cruise control on/off
    target_speed = float         -- km/h desired cruise speed
}

-- Driving behavior modes (similar to ai.lua speed modes)
traffic_compliance = boolean     -- Following the laws or not
speed_mode = string             -- "set", "limit", "legal", "fleeing", "chasing", "following", "off"
driving_mode = string           -- "traffic", "chase", "follow", "flee", "manual", "disabled"

-- Behavioral flags
aggressive_mode = boolean        -- Allow risky maneuvers for speed
comfort_mode = boolean           -- Prioritize smooth acceleration/braking
eco_mode = boolean              -- Optimize for fuel efficiency
fleeing_mode = boolean          -- High-speed evasive driving patterns
chasing_mode = boolean          -- Aggressive pursuit driving patterns
following_mode = boolean        -- Maintain distance behind target vehicle
```

#### Navigation Commands
```lua
-- Route modification
route_recalculate = boolean      -- Trigger route replanning
avoid_highways = boolean         -- Prefer surface roads
avoid_tolls = boolean            -- Avoid toll roads
fastest_route = boolean          -- Optimize for time vs distance
```

#### Communication/UI Outputs
```lua
-- Driver assistance feedback
warning_level = string           -- "none", "caution", "warning", "critical"
suggested_speed = float          -- km/h recommended speed
lane_change_signal = string      -- "left", "right", "none"
hazard_alert = {
    type = string,               -- "collision", "weather", "mechanical"
    severity = float,            -- [0.0, 1.0]
    message = string             -- Human-readable description
}
```

### Implementation Interface

#### Lua Integration Points
```lua
-- Main AI control hook (called every frame)
function ai_driver.onUpdate(dt)
    -- Gather input data
    local inputs = ai_driver.collectInputs()
    
    -- Process through AI model
    local outputs = ai_model.process(inputs)
    
    -- Apply outputs to vehicle
    ai_driver.applyControls(outputs)
end

-- Input collection function
function ai_driver.collectInputs()
    return {
        vehicle = ai_driver.getVehicleTelemetry(),
        environment = ai_driver.getEnvironmentData(),
        navigation = ai_driver.getNavigationData(),
        traffic = ai_driver.getTrafficState(),
        vision = ai_driver.getVisionData()
    }
end

-- Control application function
function ai_driver.applyControls(outputs)
    input.event("steering", outputs.steering_input, 1)
    input.event("throttle", outputs.throttle_input, 1)
    input.event("brake", outputs.brake_input, 1)
    -- Additional control applications...
end
```

#### Data Types Reference
```lua
-- All numeric values are Lua numbers (double precision float)
-- Positions are in BeamNG world coordinates (meters)
-- Angles are in radians unless specified otherwise
-- Time values are in seconds
-- Boolean flags use Lua true/false
-- Arrays are 1-indexed following Lua convention
```

This specification provides the exact variable names, data types, and API calls needed to build an AI model interface with BeamNG.drive. All variables are based on actual game systems and can be directly implemented using the existing Lua API.
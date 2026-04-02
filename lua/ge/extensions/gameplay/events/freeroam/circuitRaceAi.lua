local M = {}

M.dependencies = { 'gameplay_events_freeroam_session', 'gameplay_events_freeroam_processRoad' }

local mAiLapState = {}
local mRaceWaypoints = nil
local mRaceCkptsMain = nil
local mRaceCkptsAlt = nil
local mRaceProgressCtx = nil
local mRaceProgressCtxKey = nil
local mAiWaypointState = {}
local mAiWaypointUpdateAccum = 0
local mSanctionedEntrantIds = nil
local mGapSpmByEndCp = {}
local mGapSecSmooth = {}
local mLastLeaderPacing = { key = nil, lap = -1, cp = -1 }
local mLastSegIdx = {}

local SPM_EMA = 0.18
local GAP_SEC_DISPLAY_EMA = 0.22

local function sess()
    return gameplay_events_freeroam_session
end

local function getSessionElapsed()
    return (sess().mTotalRaceTime or 0) + sess().in_race_time
end

local LOOP_CLOSE_THRESHOLD = 50
local GAP_SPEED_FLOOR_MPS = 5
local PROJECT_S_WINDOW = 5
local PROJECT_S_WINDOW_MAX_DIST = 45

local function xyzFromVecLike(v)
    if not v then return 0, 0, 0 end
    local x, y, z = v.x, v.y, v.z
    if x == nil and type(v) == "table" then
        x, y, z = v[1], v[2], v[3]
    end
    return tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
end

local function getPlayerSpeedMps()
    local b = be
    if not b or not b.getPlayerVehicle then return nil end
    local veh = b:getPlayerVehicle(0)
    if not veh then return nil end
    local vel = veh.getVelocity and veh:getVelocity()
    if not vel then return nil end
    local vx, vy, vz = xyzFromVecLike(vel)
    return math.sqrt(vx * vx + vy * vy + vz * vz)
end

local function dist2(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return dx * dx + dy * dy
end

local function dist3(a, b)
    if not a or not b then return 0 end
    return math.sqrt(dist2(a.x, a.y, b.x, b.y) + (b.z - a.z) * (b.z - a.z))
end

local function nodesFormLoop(nodes)
    if not nodes or #nodes < 3 then return false end
    local a, b = nodes[1], nodes[#nodes]
    return dist2(a.x, a.y, b.x, b.y) < (LOOP_CLOSE_THRESHOLD * LOOP_CLOSE_THRESHOLD)
end

local function nearestNodeIndex(nodes, p)
    if not nodes or not p or #nodes < 1 then return 1 end
    local best, bestD = 1, math.huge
    for i = 1, #nodes do
        local n = nodes[i]
        local d = dist2(n.x, n.y, p.x, p.y)
        if d < bestD then bestD, best = d, i end
    end
    return best
end

local function segDistAndT(px, py, ax, ay, bx, by)
    local abx, aby = bx - ax, by - ay
    local apx, apy = px - ax, py - ay
    local ab2 = abx * abx + aby * aby
    if ab2 < 1e-8 then return math.sqrt(apx * apx + apy * apy), 0 end
    local t = (apx * abx + apy * aby) / ab2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = ax + abx * t, ay + aby * t
    return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy)), t
end

local function buildPolylineFromCheckpoints(cps)
    local R = {}
    for i = 1, #(cps or {}) do
        local n = cps[i] and cps[i].node
        if n and n.x and n.y and n.z then
            table.insert(R, { x = n.x, y = n.y, z = n.z })
        end
    end
    return R
end

local function buildRotatedPolyline(rawNodes, cps, isLoopRoad)
    local n = #rawNodes
    if n < 2 then return nil end
    local cp1, cp2 = cps[1], cps[2]
    if not cp1 or not cp1.node then return nil end
    local idx1 = tonumber(cp1.index)
    if not idx1 or idx1 < 1 or idx1 > n then
        idx1 = nearestNodeIndex(rawNodes, cp1.node)
    end
    local R = {}
    if isLoopRoad then
        local nxt = idx1 < n and idx1 + 1 or 1
        local dirx, diry = rawNodes[nxt].x - rawNodes[idx1].x, rawNodes[nxt].y - rawNodes[idx1].y
        local backward = false
        if cp2 and cp2.node then
            local rx, ry = cp2.node.x - cp1.node.x, cp2.node.y - cp1.node.y
            backward = (dirx * rx + diry * ry < 0)
        end
        for k = 0, n - 1 do
            local j = backward and (((idx1 - 1 - k) % n + n) % n + 1) or (((idx1 - 1 + k) % n) + 1)
            table.insert(R, rawNodes[j])
        end
    else
        local nxt = math.min(idx1 + 1, n)
        local prv = math.max(idx1 - 1, 1)
        local dirx, diry = rawNodes[nxt].x - rawNodes[idx1].x, rawNodes[nxt].y - rawNodes[idx1].y
        local rx, ry = 0, 0
        if cp2 and cp2.node then
            rx, ry = cp2.node.x - cp1.node.x, cp2.node.y - cp1.node.y
        else
            rx, ry = rawNodes[idx1].x - rawNodes[prv].x, rawNodes[idx1].y - rawNodes[prv].y
        end
        local forward = (dirx * rx + diry * ry >= 0)
        if forward then
            for j = idx1, n do table.insert(R, rawNodes[j]) end
        else
            for j = idx1, 1, -1 do table.insert(R, rawNodes[j]) end
        end
        if #R < 2 then
            R = {}
            for j = 1, n do table.insert(R, rawNodes[j]) end
        end
    end
    return #R >= 2 and R or nil
end

local function prefixLengths(R, isLoopRoad)
    local n = #R
    local segLen = {}
    local pre = { 0 }
    local total = 0
    local numSeg = isLoopRoad and n or (n - 1)
    for i = 1, numSeg do
        local a, b = R[i], R[i < n and i + 1 or 1]
        local L = dist3(a, b)
        segLen[i] = L
        total = total + L
        pre[i + 1] = total
    end
    return pre, segLen, total
end

local function projectToS(R, isLoopRoad, pre, px, py, hintIdx)
    local n = #R
    local numSeg = isLoopRoad and n or (n - 1)
    if numSeg < 1 then
        return 0, math.huge, 1
    end
    local bestS, bestD, bestSeg = 0, math.huge, 1
    local function consider(i)
        local a, b = R[i], R[i < n and i + 1 or 1]
        local d, t = segDistAndT(px, py, a.x, a.y, b.x, b.y)
        if d < bestD then
            bestD = d
            local segL = dist3(a, b)
            bestS = pre[i] + t * segL
            bestSeg = i
        end
    end
    if hintIdx and type(hintIdx) == "number" and hintIdx >= 1 and hintIdx <= numSeg then
        for w = -PROJECT_S_WINDOW, PROJECT_S_WINDOW do
            local i
            if isLoopRoad then
                i = ((hintIdx - 1 + w) % numSeg + numSeg) % numSeg + 1
            else
                i = hintIdx + w
            end
            if not isLoopRoad and (i < 1 or i > numSeg) then
                -- skip
            else
                consider(i)
            end
        end
        if bestD <= PROJECT_S_WINDOW_MAX_DIST then
            return bestS, bestD, bestSeg
        end
        bestS, bestD, bestSeg = 0, math.huge, 1
    end
    for i = 1, numSeg do
        consider(i)
    end
    return bestS, bestD, bestSeg
end

local function forwardArcAlongLoop(L, isLoop, sFrom, sTo)
    if not L or L < 1e-6 then return 0 end
    if isLoop then
        if sTo >= sFrom then return sTo - sFrom end
        return L - sFrom + sTo
    end
    return math.abs(sTo - sFrom)
end

local function buildSectorLenByEndCp(ctx, cps)
    local n = #(cps or {})
    if n < 2 or not ctx or not ctx.R then return nil end
    local cpS = {}
    for i = 1, n do
        local node = cps[i] and cps[i].node
        if not node or not node.x or not node.y then return nil end
        cpS[i] = select(1, projectToS(ctx.R, ctx.isLoop, ctx.pre, node.x, node.y, nil))
        cpS[i] = math.min(math.max(cpS[i], 0), ctx.loopLen)
    end
    local L = ctx.loopLen
    local lens = {}
    if ctx.isLoop then
        lens[1] = math.max(forwardArcAlongLoop(L, true, cpS[n], cpS[1]), 5)
        for k = 2, n do
            lens[k] = math.max(forwardArcAlongLoop(L, true, cpS[k - 1], cpS[k]), 5)
        end
    else
        lens[1] = math.max(cpS[1], 5)
        for k = 2, n do
            lens[k] = math.max(cpS[k] - cpS[k - 1], 5)
        end
    end
    ctx.cpArcAtCheckpoint = cpS
    return lens
end

local function resetGapPacingState()
    mGapSpmByEndCp = {}
    mGapSecSmooth = {}
    mLastLeaderPacing = { key = nil, lap = -1, cp = -1 }
end

local function getLeaderSectorDuration(leader, endCp)
    if not leader or not endCp or endCp < 1 then return nil end
    if leader.isPlayer then
        if sess().mActiveRace and sess().races then
            local rz = sess().races[sess().mActiveRace]
            if rz then
                local erz = (sess().mAltRoute and rz.altRoute) and rz.altRoute or rz
                if erz and erz.driftGoal then return nil end
            end
        end
        local st = sess().mSplitTimes
        if not st or not st[endCp] then return nil end
        if endCp <= 1 then return st[1] end
        if not st[endCp - 1] then return nil end
        return st[endCp] - st[endCp - 1]
    end
    local state = mAiLapState[leader.vehId]
    if not state or not state.splitTimes or not state.splitTimes[endCp] then return nil end
    local st = state.splitTimes
    if endCp <= 1 then
        local t0 = state.lapStartTime
        if not t0 then return nil end
        return st[1] - t0
    end
    if not st[endCp - 1] then return nil end
    return st[endCp] - st[endCp - 1]
end

local function updateLeaderSectorPacing(leader, ctx)
    if not leader or leader.finished or not ctx or not ctx.sectorLenByEndCp then return end
    local key = leader.isPlayer and "player" or tostring(leader.vehId)
    local lap = leader.lapCount or 0
    local cp = leader.checkpointsHit or 0
    local last = mLastLeaderPacing
    if last.key ~= key or last.lap ~= lap then
        last.key = key
        last.lap = lap
        last.cp = cp
        return
    end
    if cp > last.cp then
        local lens = ctx.sectorLenByEndCp
        for seg = last.cp + 1, cp do
            local dur = getLeaderSectorDuration(leader, seg)
            local len = lens[seg]
            if dur and dur > 0.15 and len and len > 1 then
                local sample = dur / len
                if sample > 0.02 and sample < 2.5 then
                    local old = mGapSpmByEndCp[seg]
                    mGapSpmByEndCp[seg] = SPM_EMA * sample + (1 - SPM_EMA) * (old or sample)
                end
            end
        end
    end
    last.cp = cp
end

local function avgSpmFromSamples(totalCp)
    local sum, n = 0, 0
    for i = 1, totalCp or 0 do
        local v = mGapSpmByEndCp[i]
        if type(v) == "number" and v > 0 then
            sum = sum + v
            n = n + 1
        end
    end
    if n > 0 then return sum / n end
    return nil
end

local function spmForGapEstimate(playerComb, ctx, totalCp, vFallbackMps)
    local total = totalCp or 0
    if total < 1 then return 1 / math.max(vFallbackMps, GAP_SPEED_FLOOR_MPS) end
    local endCp = math.max(1, math.min(total, (playerComb.checkpointsHit or 0) + 1))
    local spm = mGapSpmByEndCp[endCp]
    if type(spm) ~= "number" or spm <= 0 then
        spm = avgSpmFromSamples(total)
    end
    if type(spm) ~= "number" or spm <= 0 then
        spm = 1 / math.max(vFallbackMps, GAP_SPEED_FLOOR_MPS)
    end
    return spm
end

local function getRaceProgressContext()
    if not sess().mActiveRace or not sess().races then return nil end
    local races = sess().races
    local race = races[sess().mActiveRace]
    if not race then return nil end
    local effectiveRace = (sess().mAltRoute and race.altRoute) and race.altRoute or race
    if not effectiveRace or not effectiveRace.checkpointRoad then return nil end
    local cps = sess().mAltRoute and mRaceCkptsAlt or mRaceCkptsMain
    if not cps or #cps < 2 then return nil end
    local key = tostring(sess().mActiveRace) .. "\0" .. (sess().mAltRoute and "1" or "0")
    if mRaceProgressCtx and mRaceProgressCtxKey == key then
        return mRaceProgressCtx
    end
    local pr = gameplay_events_freeroam_processRoad
    if not pr or not pr.getRoadNodesFromRace then return nil end
    local rawNodes = pr.getRoadNodesFromRace(effectiveRace)
    local isLoopRoad = rawNodes and nodesFormLoop(rawNodes) or false
    local R = rawNodes and buildRotatedPolyline(rawNodes, cps, isLoopRoad) or nil
    if not R then
        R = buildPolylineFromCheckpoints(cps)
        isLoopRoad = R and nodesFormLoop(R) or false
    end
    if not R or #R < 2 then
        mRaceProgressCtx, mRaceProgressCtxKey = nil, nil
        return nil
    end
    mRaceProgressCtxKey = key
    local pre, segLen, loopLen = prefixLengths(R, isLoopRoad)
    mRaceProgressCtx = {
        R = R,
        isLoop = isLoopRoad,
        pre = pre,
        segLen = segLen,
        loopLen = loopLen,
    }
    mRaceProgressCtx.sectorLenByEndCp = buildSectorLenByEndCp(mRaceProgressCtx, cps)
    return mRaceProgressCtx
end

local function rankScoreForEntrant(ctx, px, py, pz, lap, cpHit, totalCp, finished, segHint, segKey)
    if not ctx or not ctx.loopLen or ctx.loopLen < 1e-6 then return nil end
    lap = lap or 0
    local L = ctx.loopLen
    if finished then
        return lap * L
    end
    local s, _, segUsed = projectToS(ctx.R, ctx.isLoop, ctx.pre, px, py, segHint)
    if segKey then
        mLastSegIdx[segKey] = segUsed
    end
    s = math.min(math.max(s, 0), L)
    local cpN = cpHit or 0
    if lap > 0 and cpN == 0 and ctx.isLoop and s >= L * 0.82 then
        s = s - L
    end
    local cpArc = ctx.cpArcAtCheckpoint
    if totalCp and totalCp >= 2 and cpArc and cpArc[1] and cpArc[2] and (cpN == 1 or (cpN == 0 and lap == 0)) then
        local s1 = cpArc[1]
        local s2 = cpArc[2]
        if cpN == 0 then
            if ctx.isLoop then
                local seg0 = forwardArcAlongLoop(L, true, 0, s1)
                if seg0 > 1e-4 then
                    local d = forwardArcAlongLoop(L, true, 0, s)
                    d = math.min(math.max(d, 0), seg0)
                    return lap * L + d
                end
            else
                if s1 > 1e-4 then
                    return lap * L + math.min(math.max(s, 0), s1)
                end
            end
        elseif ctx.isLoop then
            local before = forwardArcAlongLoop(L, true, 0, s1)
            local seg = forwardArcAlongLoop(L, true, s1, s2)
            if seg > 1e-4 then
                local d = forwardArcAlongLoop(L, true, s1, s)
                d = math.min(math.max(d, 0), seg)
                return lap * L + before + d
            end
        else
            local seg = s2 - s1
            if seg > 1e-4 then
                local d = math.min(math.max(s - s1, 0), seg)
                return lap * L + s1 + d
            end
        end
    end
    if totalCp and totalCp > 0 and cpN >= 2 then
        local hint = (cpN / totalCp) * L
        if math.abs(s - hint) > L * 0.35 then
            s = hint * 0.12 + s * 0.88
        end
    end
    return lap * L + s
end

function M.compareRaceStanding(a, b)
    if a.finished ~= b.finished then
        return a.finished
    end
    if a.finished and b.finished then
        local at = a.totalTime
        local bt = b.totalTime
        if type(at) ~= "number" then at = 999999 end
        if type(bt) ~= "number" then bt = 999999 end
        if math.abs(at - bt) > 1e-4 then return at < bt end
    end
    local lac, lbc = a.lapCount or 0, b.lapCount or 0
    if lac ~= lbc then return lac > lbc end
    local ach, bch = a.checkpointsHit or 0, b.checkpointsHit or 0
    if ach ~= bch then return ach > bch end
    local ars, brs = a.rankScore, b.rankScore
    if type(ars) == "number" and type(brs) == "number" then
        if math.abs(ars - brs) > 1e-6 then return ars > brs end
    elseif type(ars) == "number" then return true
    elseif type(brs) == "number" then return false
    end
    local at = a.totalTime
    local bt = b.totalTime
    if type(at) ~= "number" then at = 999999 end
    if type(bt) ~= "number" then bt = 999999 end
    return at < bt
end

local function onExtensionLoaded()
end

function M.getRaceSessionElapsed()
    return getSessionElapsed()
end

function M.isSanctionedTriggerOnlyLapRace()
    if sess().mActiveRace ~= gameplay_events_freeroam_competitiveTrackFlow.TRACK_RACE_ID then return false end
    local sr = gameplay_events_freContracts_sanctionedRacing
    if not sr or not sr.shouldSuppressFrePayouts then return false end
    return sr.shouldSuppressFrePayouts() == true
end

function M.setWaypointsFromCheckpoints(checkpoints, altCheckpoints)
    mRaceCkptsMain = checkpoints
    mRaceCkptsAlt = altCheckpoints
    mRaceProgressCtx = nil
    mRaceProgressCtxKey = nil
    mRaceWaypoints = { checkpoints = {} }
    for _, cp in ipairs(checkpoints or {}) do
        local n = cp and cp.node
        if n and n.x and n.y and n.z then
            table.insert(mRaceWaypoints.checkpoints, {
                x = n.x, y = n.y, z = n.z,
                r = (type(n.width) == "number" and n.width > 0) and n.width or 30
            })
        end
    end
    if not mRaceWaypoints.checkpoints or #mRaceWaypoints.checkpoints == 0 then
        mRaceWaypoints = nil
    end
end

function M.resetForRaceBegin()
    mSanctionedEntrantIds = nil
    mLastSegIdx = {}
    resetGapPacingState()
end

function M.setupAfterAiSpawn(raceName, subjectID, totalCheckpoints, mainRace, raceForAi)
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.getSpawnedVehicleIds or not aiRacers.releaseAndDrive then return end
    local ids = aiRacers.getSpawnedVehicleIds() or {}
    if #ids == 0 then return end
    local aiLaps = gameplay_events_freeroam_competitiveTrackFlow.getDisplayTotalLapsForRace(raceForAi)
    if aiLaps < 1 then aiLaps = (raceForAi.lapCount and raceForAi.lapCount > 0) and raceForAi.lapCount or 3 end
    aiRacers.releaseAndDrive(raceForAi, aiLaps)
    local aiTotalCheckpoints = totalCheckpoints
    if raceForAi == mainRace.altRoute then
        if gameplay_events_freeroam_checkpointManager.getAiAltCheckpointCount and gameplay_events_freeroam_checkpointManager.getAiAltCheckpointCount() > 0 then
            aiTotalCheckpoints = gameplay_events_freeroam_checkpointManager.getAiAltCheckpointCount()
        elseif gameplay_events_freeroam_checkpointManager.getAltCheckpointCount then
            local altCount = gameplay_events_freeroam_checkpointManager.getAltCheckpointCount()
            if altCount and altCount > 0 then aiTotalCheckpoints = altCount end
        end
    end
    mAiLapState = {}
    mAiWaypointState = {}
    local t0 = getSessionElapsed()
    for _, vehId in ipairs(ids) do
        mAiLapState[vehId] = {
            lapCount = 0,
            lapStartTime = t0,
            totalLaps = aiLaps,
            totalCheckpoints = aiTotalCheckpoints,
            checkpointsHit = 0,
            currentExpectedCheckpoint = 1,
            lapTimes = {},
            splitTimes = {},
            finished = false,
            finishTime = nil,
        }
        mAiWaypointState[vehId] = { in1 = false, inExp = false, expIdx = 0 }
    end
    if raceName == gameplay_events_freeroam_competitiveTrackFlow.TRACK_RACE_ID then
        local sr = gameplay_events_freContracts_sanctionedRacing
        if sr and sr.shouldSuppressFrePayouts and sr.shouldSuppressFrePayouts() then
            mSanctionedEntrantIds = {}
            if subjectID then mSanctionedEntrantIds[subjectID] = true end
            for _, vid in ipairs(aiRacers.getSpawnedVehicleIds() or {}) do
                mSanctionedEntrantIds[vid] = true
            end
        end
    end
end

function M.clearAll()
    mAiLapState = {}
    mRaceWaypoints = nil
    mRaceCkptsMain = nil
    mRaceCkptsAlt = nil
    mRaceProgressCtx = nil
    mRaceProgressCtxKey = nil
    mAiWaypointState = {}
    mSanctionedEntrantIds = nil
    mAiWaypointUpdateAccum = 0
    mLastSegIdx = {}
    resetGapPacingState()
end

function M.getAiLapStateTable()
    return mAiLapState
end

function M.hasAiLapState()
    return next(mAiLapState) ~= nil
end

local function applyWaypointHit_AI(vehId, eventType, checkpointIndex, raceTime)
    if not sess().mActiveRace or not mAiLapState[vehId] then return end
    local state = mAiLapState[vehId]
    if state.finished then return end
    if eventType == "start" then
        if state.totalCheckpoints == 0 or state.checkpointsHit >= state.totalCheckpoints then
            local lapTime = raceTime - state.lapStartTime
            table.insert(state.lapTimes, lapTime)
            state.lapCount = state.lapCount + 1
            if state.lapCount >= state.totalLaps then
                state.finished = true
                state.finishTime = raceTime
            else
                state.lapStartTime = raceTime
                state.checkpointsHit = 0
                state.splitTimes = {}
                state.currentExpectedCheckpoint = 1
            end
        elseif checkpointIndex == 1 and state.currentExpectedCheckpoint == 1 then
            if state.lapCount ~= 0 or state.checkpointsHit ~= 0 then
                state.checkpointsHit = state.checkpointsHit + 1
                state.splitTimes[state.checkpointsHit] = raceTime
                state.currentExpectedCheckpoint = state.currentExpectedCheckpoint + 1
            end
        end
        return
    end
    if eventType == "checkpoint" and checkpointIndex and checkpointIndex == state.currentExpectedCheckpoint then
        state.checkpointsHit = state.checkpointsHit + 1
        state.splitTimes[state.checkpointsHit] = raceTime
        state.currentExpectedCheckpoint = state.currentExpectedCheckpoint + 1
        return
    end
    if eventType == "finish" then
        state.finished = true
        state.finishTime = raceTime
    end
end

local function pointInCheckpointRadius(px, py, pz, wp)
    local dx = (wp.x or 0) - px
    local dy = (wp.y or 0) - py
    local dz = (wp.z or 0) - pz
    local r = (wp.r and wp.r > 0) and wp.r or 30
    return (dx * dx + dy * dy + dz * dz) <= (r * r)
end

local function updateAiWaypointsFromNavgraph()
    if M.isSanctionedTriggerOnlyLapRace() then return end
    if not sess().mActiveRace or not mRaceWaypoints or not mRaceWaypoints.checkpoints or #mRaceWaypoints.checkpoints == 0 then return end
    if not next(mAiLapState) then return end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.getSpawnedVehicleIds then return end
    local ids = aiRacers.getSpawnedVehicleIds()
    if not ids or #ids == 0 then return end
    local be = be
    if not be or not be.getObjectByID then return end
    local cps = mRaceWaypoints.checkpoints
    local nc = #cps
    for _, vehId in ipairs(ids) do
        local state = mAiLapState[vehId]
        if not state or state.finished then goto continue end
        local obj = be:getObjectByID(vehId)
        if not obj or not obj.getPosition then goto continue end
        local pos = obj:getPosition()
        local px, py, pz = xyzFromVecLike(pos)
        local last = mAiWaypointState[vehId]
        if not last then last = { in1 = false, inExp = false, expIdx = 0 } end
        local wp1 = cps[1]
        local nowIn1 = wp1 and pointInCheckpointRadius(px, py, pz, wp1) or false
        local exp = state.currentExpectedCheckpoint or 1
        local lastInExp = last.inExp
        if exp ~= (last.expIdx or 0) then
            lastInExp = false
        end
        local nowInExp = false
        if exp > 1 and exp <= nc then
            local wpe = cps[exp]
            nowInExp = wpe and pointInCheckpointRadius(px, py, pz, wpe) or false
        end
        local tSes = getSessionElapsed()
        if nowIn1 and not last.in1 then
            applyWaypointHit_AI(vehId, "start", 1, tSes)
        end
        if exp > 1 and exp <= nc and nowInExp and not lastInExp then
            applyWaypointHit_AI(vehId, "checkpoint", exp, tSes)
        end
        mAiWaypointState[vehId] = { in1 = nowIn1, inExp = nowInExp, expIdx = exp }
        ::continue::
    end
end

function M.onWaypointPollAccum(dtSim)
    mAiWaypointUpdateAccum = mAiWaypointUpdateAccum + (dtSim or 0)
    if mAiWaypointUpdateAccum >= 0.1 then
        updateAiWaypointsFromNavgraph()
        mAiWaypointUpdateAccum = 0
    end
end

function M.getAiLapStateForDisplay()
    if not sess().mActiveRace or not next(mAiLapState) then return nil end
    local races = sess().races
    local race = races[sess().mActiveRace]
    local effectiveRace = (sess().mAltRoute and race and race.altRoute) and race.altRoute or race
    local totalLaps = gameplay_events_freeroam_competitiveTrackFlow.getDisplayTotalLapsForRace(effectiveRace)
    if totalLaps < 1 then totalLaps = 3 end
    local progCtx = getRaceProgressContext()
    local beInst = be
    local totalCpAll = sess().totalCheckpoints or 0
    local combined = {}
    local playerTotalTime = (sess().mTotalRaceTime or 0) + sess().in_race_time
    local prs, ppy, ppz = 0, 0, 0
    if beInst and beInst.getPlayerVehicle then
        local pv = beInst:getPlayerVehicle(0)
        if pv and pv.getPosition then
            prs, ppy, ppz = xyzFromVecLike(pv:getPosition())
        end
    end
    local playerRank = rankScoreForEntrant(progCtx, prs, ppy, ppz, sess().lapCount, sess().checkpointsHit or 0, totalCpAll, false,
        mLastSegIdx["player"], "player")
    local playerVehId = (beInst and beInst.getPlayerVehicleID) and beInst:getPlayerVehicleID(0) or nil
    table.insert(combined, {
        isPlayer = true,
        index = 0,
        vehId = playerVehId,
        lapCount = sess().lapCount,
        checkpointsHit = sess().checkpointsHit or 0,
        currentLapTime = sess().in_race_time,
        finished = false,
        finishTime = nil,
        totalTime = playerTotalTime,
        rankScore = playerRank,
    })
    local aiRacers = gameplay_events_freeroam_aiRacers
    local aiIds = aiRacers and aiRacers.getSpawnedVehicleIds() or {}
    for i, vehId in ipairs(aiIds) do
        local s = mAiLapState[vehId]
        if s then
            local tSes = getSessionElapsed()
            local currentLapTime = (not s.finished) and (tSes - s.lapStartTime) or nil
            local aiTotal = s.finishTime
            if not aiTotal then
                if s.lapTimes and #s.lapTimes > 0 then
                    aiTotal = 0
                    for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + t end
                    aiTotal = aiTotal + (tSes - s.lapStartTime)
                else
                    aiTotal = tSes - s.lapStartTime
                end
            end
            local ax, ay, az = 0, 0, 0
            if beInst and beInst.getObjectByID then
                local obj = beInst:getObjectByID(vehId)
                if obj and obj.getPosition then
                    ax, ay, az = xyzFromVecLike(obj:getPosition())
                end
            end
            local aiRank = rankScoreForEntrant(progCtx, ax, ay, az, s.lapCount, s.checkpointsHit, s.totalCheckpoints or totalCpAll, s.finished,
                mLastSegIdx[vehId], vehId)
            table.insert(combined, {
                isPlayer = false,
                index = i,
                vehId = vehId,
                lapCount = s.lapCount,
                checkpointsHit = s.checkpointsHit or 0,
                currentLapTime = currentLapTime or 0,
                finished = s.finished,
                finishTime = s.finishTime,
                totalTime = aiTotal or 0,
                totalLaps = s.totalLaps,
                lapTimes = s.lapTimes,
                rankScore = aiRank,
            })
        end
    end
    table.sort(combined, M.compareRaceStanding)
    for place = 1, #combined do combined[place].place = place end
    if #combined > 0 then
        updateLeaderSectorPacing(combined[1], progCtx)
    end
    local leaderTime = (#combined > 0 and combined[1].totalTime) and combined[1].totalTime or 0
    local playerComb = nil
    for _, e in ipairs(combined) do
        if e.isPlayer then playerComb = e break end
    end
    local vPlayer = getPlayerSpeedMps()
    local vEff = (type(vPlayer) == "number" and vPlayer > GAP_SPEED_FLOOR_MPS) and vPlayer or GAP_SPEED_FLOOR_MPS
    local vDisp = vEff
    local spmAvg = avgSpmFromSamples(totalCpAll)
    if type(spmAvg) == "number" and spmAvg > 0 then
        vDisp = math.max(1 / spmAvg, GAP_SPEED_FLOOR_MPS)
    end
    local function displaySmoothGap(indexKey, raw)
        local prevS = mGapSecSmooth[indexKey]
        local smoothed = prevS and (GAP_SEC_DISPLAY_EMA * raw + (1 - GAP_SEC_DISPLAY_EMA) * prevS) or raw
        mGapSecSmooth[indexKey] = smoothed
        return smoothed
    end
    local vehicles = {}
    for _, e in ipairs(combined) do
        local diffFromLeader = (e.totalTime or 0) - leaderTime
        local gapM, gapSecPlayer = nil, nil
        if not e.isPlayer and playerComb then
            local ksmooth = e.index
            if e.finished or playerComb.finished then
                gapSecPlayer = displaySmoothGap(ksmooth, (playerComb.totalTime or 0) - (e.totalTime or 0))
                gapM = gapSecPlayer * vDisp
            else
                local prk, erk = playerComb.rankScore, e.rankScore
                if type(prk) == "number" and type(erk) == "number" then
                    local deltaR = erk - prk
                    gapM = deltaR
                    local spm = spmForGapEstimate(playerComb, progCtx, totalCpAll, vEff)
                    gapSecPlayer = displaySmoothGap(ksmooth, deltaR * spm)
                else
                    gapSecPlayer = displaySmoothGap(ksmooth, (playerComb.totalTime or 0) - (e.totalTime or 0))
                    gapM = gapSecPlayer * vDisp
                end
            end
        end
        local row = {
            place = e.place,
            isPlayer = e.isPlayer,
            index = e.index,
            lapCount = e.lapCount,
            totalLaps = e.totalLaps or totalLaps,
            totalTime = e.totalTime,
            diffFromLeader = diffFromLeader,
            gapM = gapM,
            gapSecPlayer = gapSecPlayer,
            finished = e.finished,
            finishTime = e.finishTime,
            currentLapTime = e.currentLapTime,
            checkpointsHit = e.checkpointsHit or 0,
        }
        if not e.isPlayer and e.lapTimes and #e.lapTimes > 0 then
            row.lastLapTime = e.lapTimes[#e.lapTimes]
        end
        table.insert(vehicles, row)
    end
    if #vehicles == 0 then return nil end
    return {
        inRaceTime = sess().in_race_time,
        leaderTime = leaderTime,
        vehicles = vehicles,
        totalCheckpoints = sess().totalCheckpoints,
    }
end

function M.buildSanctionedHudStandingsPayload()
    if sess().mActiveRace ~= gameplay_events_freeroam_competitiveTrackFlow.TRACK_RACE_ID then return nil end
    local sr = gameplay_events_freContracts_sanctionedRacing
    if not sr or not sr.shouldSuppressFrePayouts or not sr.shouldSuppressFrePayouts() then return nil end
    local lapState = M.getAiLapStateForDisplay()
    if not lapState or not lapState.vehicles or #lapState.vehicles < 2 then return nil end
    local out = {}
    local maxR = math.min(6, #lapState.vehicles)
    for i = 1, maxR do
        local v = lapState.vehicles[i]
        local total = tonumber(v.totalLaps) or 0
        local completed = tonumber(v.lapCount) or 0
        local disp = (total > 0) and math.min(completed + 1, total) or (completed + 1)
        table.insert(out, {
            place = v.place,
            isPlayer = v.isPlayer and true or false,
            label = v.isPlayer and "You" or ("Rival " .. tostring(v.index)),
            lapsText = string.format("%d / %d", disp, total),
            gapSec = (v.gapSecPlayer ~= nil) and v.gapSecPlayer or nil,
            gapM = (v.gapM ~= nil) and v.gapM or nil,
        })
    end
    return out
end

function M.tryHandleAiTrigger(data, event, triggerType, raceName, checkpointIndex, isAiAlt, isAlt, isPlayer)
    local sanctionedEntrantOk = (not M.isSanctionedTriggerOnlyLapRace()) or (mSanctionedEntrantIds and mSanctionedEntrantIds[data.subjectID])
    if not isPlayer and sess().mActiveRace == raceName and mAiLapState[data.subjectID] and event == "enter" and sanctionedEntrantOk then
        local tSes = getSessionElapsed()
        if triggerType == "start" then
            applyWaypointHit_AI(data.subjectID, "start", 1, tSes)
            return true
        end
        if triggerType == "checkpoint" and checkpointIndex then
            local useForAi = isAiAlt or not isAlt or not (gameplay_events_freeroam_checkpointManager.getAiAltCheckpointCount and gameplay_events_freeroam_checkpointManager.getAiAltCheckpointCount() > 0)
            if useForAi then
                applyWaypointHit_AI(data.subjectID, "checkpoint", checkpointIndex, tSes)
            end
            return true
        end
        if triggerType == "finish" then
            applyWaypointHit_AI(data.subjectID, "finish", nil, tSes)
            return true
        end
    end
    return false
end

M.onExtensionLoaded = onExtensionLoaded

return M

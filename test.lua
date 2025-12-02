
local Kp = 10
local Kd = 30
local alpha = 0.15
local maxStep = 0.02
local deadband = 0.01
local historySize = 5

rollHistory = rollHistory or {}
rollHistoryCount = rollHistoryCount or 0

cmdHistory = cmdHistory or {}
cmdHistoryCount = cmdHistoryCount or 0

filtRate = filtRate or 0

function onTick()
    local roll = input.getNumber(1)
    
    table.insert(rollHistory, roll)
    if #rollHistory > historySize then
        table.remove(rollHistory, 1)
    end
    rollHistoryCount = #rollHistory
    
    local rollRate = 0
    if rollHistoryCount >= 2 then
        local sumRate = 0
        for i = 1, rollHistoryCount - 1 do
            sumRate = sumRate + (rollHistory[i + 1] - rollHistory[i]) * 60
        end
        rollRate = sumRate / (rollHistoryCount - 1)
    end
    
    filtRate = filtRate * (1 - alpha) + rollRate * alpha
    
    local error = roll
    if math.abs(error) < deadband then error = 0 end
    
    local cmd = -Kp * error - Kd * filtRate
    
    cmd = math.max(-1, math.min(1, cmd))
    
    local lastCmd = 0
    if cmdHistoryCount > 0 then
        lastCmd = cmdHistory[cmdHistoryCount] or 0
    end
    
    local delta = math.max(-maxStep, math.min(maxStep, cmd - lastCmd))
    cmd = lastCmd + delta
    
    table.insert(cmdHistory, cmd)
    if #cmdHistory > historySize then
        table.remove(cmdHistory, 1)
    end
    cmdHistoryCount = #cmdHistory
    
    output.setNumber(1, cmd)
end
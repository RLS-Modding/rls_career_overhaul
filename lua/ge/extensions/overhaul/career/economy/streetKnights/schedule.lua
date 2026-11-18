-- Owns the shared overnight meet window and title-challenge count. The offer
-- journal can persist slots 1 through 3; reject tuning that would exceed it.
local M={}
local defaults={meetOpenHour=22,meetCloseHour=4,titleChallengesMinPerMeet=2,titleChallengesMaxPerMeet=3}
local function integer(v) return type(v)=='number' and v==v and math.abs(v)<math.huge and v%1==0 end
function M.fromConfig(data)
  if type(data)~='table' or not integer(data.meetOpenHour) or not integer(data.meetCloseHour)
    or data.meetCloseHour<0 or data.meetOpenHour>=24 or data.meetOpenHour<=data.meetCloseHour
    or not integer(data.titleChallengesMinPerMeet) or not integer(data.titleChallengesMaxPerMeet)
    or data.titleChallengesMinPerMeet<1 or data.titleChallengesMaxPerMeet>3
    or data.titleChallengesMinPerMeet>data.titleChallengesMaxPerMeet then data=defaults end
  return {meetOpenHour=data.meetOpenHour,meetCloseHour=data.meetCloseHour,
    titleChallengesMinPerMeet=data.titleChallengesMinPerMeet,titleChallengesMaxPerMeet=data.titleChallengesMaxPerMeet}
end
local ok,data=false,nil
if type(jsonReadFile)=='function' then ok,data=pcall(jsonReadFile,'/gameplay/overhaul/streetKnights/schedule.json') end
M.config=M.fromConfig(ok and data or nil)
return M

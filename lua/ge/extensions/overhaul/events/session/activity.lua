-- Foreground activity definition for the shared event session.
-- The activity host reads current staging/race state through delegates bound to this load.
return function(M)
  return {
    id = "eventSession",
    label = "Event session",
    role = "foreground",
    modes = { "career", "freeroam" },
    extension = "overhaul_events_session",
    blocks = { "travelJournal" },
    blockingOrder = -1,
    probe = function()
      return not not (M.timerActive or M.mActiveRace or M.staged or M.dragPracticeActive or M.freeroamPracticeStaging)
    end,
  }
end

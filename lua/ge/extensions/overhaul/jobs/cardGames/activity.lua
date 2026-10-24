-- Card table activity contract and host actions.
-- The table owner keeps bets, rounds and wallet settlement.
return function(M)
  local function delegate(name)
    return function(...) return M[name](...) end
  end

  return {
    id = "cardGames",
    label = "Card games",
    role = "foreground",
    modes = {"career", "freeroam"},
    extension = "overhaul_jobs_cardGames_cardGames",
    lifecycle = "cardGames",
    actions = {
      open = delegate("open"),
      close = delegate("close"),
      setBet = delegate("setBet"),
      confirmBet = delegate("confirmBet"),
      action = delegate("action"),
      newRound = delegate("newRound"),
      leaveTable = delegate("leaveTable"),
      requestSync = delegate("requestSync"),
      clearGamblingPromptPlayerLock = delegate("clearGamblingPromptPlayerLock"),
      startGambleCameraAnim = delegate("startGambleCameraAnim"),
    },
    transitions = {
      unload = delegate("onClientEndMission"),
    },
    resources = {"camera", "input"},
    settlement = "owner",
  }
end

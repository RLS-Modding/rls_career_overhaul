-- Car meets as an activity definition: the activity host adopts it for the current carmeets load (lib/activity/access.lua).
-- Every callable field delegates to that load's export table at call time, so a reloaded module is never reached through an old one.

return function(M)

  local function delegate(name)
    return function(...) return M[name](...) end
  end

  local actions = {}
  for _, name in ipairs({"rsvpToMeet", "cancelRSVP", "decline", "checkAvailableMeets", "joinClub", "leaveClub",
    "setRoute", "requestRSVPData", "openMeetSaleOffers", "requestMeetSaleOfferData", "setMeetSaleAskingPrice",
    "acceptBazaarOffer", "declineBazaarOffer", "negotiateBazaarOffer"}) do
    actions[name] = delegate(name)
  end

  return {
    id = "carMeets",
    label = "Car meets",
    role = "foreground",
    modes = {"career"},
    extension = "overhaul_career_carmeets_carmeets",
    lifecycle = "carMeets",
    actions = actions,
    save = delegate("onOverhaulSaveCurrentProfile"),
    transitions = {
      save = delegate("onOverhaulSaveCurrentProfile"),
      stop = delegate("onOverhaulActive"),
    },
    resources = {"route", "vehicle", "traffic"},
    settlement = "owner",
    economyKeys = {},
  }
end

local M = {}
M.dependencies = {'overhaul_events_motorsportEvents'}

function M.getState() return overhaul_events_motorsportEvents.getState() end
function M.acceptOffer(offerId) return overhaul_events_motorsportEvents.acceptOffer(offerId) end
function M.advanceOffer(offerId) return overhaul_events_motorsportEvents.advanceOffer(offerId) end
function M.declineOffer(offerId) return overhaul_events_motorsportEvents.declineOffer(offerId) end
function M.withdrawEvent(eventId) return overhaul_events_motorsportEvents.withdrawEvent(eventId) end
function M.registerVehicles(selectedRows) return overhaul_events_motorsportEvents.registerVehicles(selectedRows) end
function M.startRegisteredEvent(eventId) return overhaul_events_motorsportEvents.startRegisteredEvent(eventId) end
function M.checkIn() return overhaul_events_motorsportEvents.checkIn() end
function M.advanceDay() return overhaul_events_motorsportEvents.advanceDay() end
function M.skipToMyGroup(eventId, key) return overhaul_events_motorsportEvents.skipToMyGroup(eventId, key) end
function M.finishSpectatorWeekend() return overhaul_events_motorsportEvents.finishSpectatorWeekend() end
function M.routeRegistration() return overhaul_events_motorsportEvents.routeRegistration() end
function M.runNext() return overhaul_events_motorsportEvents.runNext() end
function M.buildBracket() return overhaul_events_motorsportEvents.buildBracket() end
function M.cancelPass() return overhaul_events_motorsportEvents.cancelPass() end
function M.watchPass() return overhaul_events_motorsportEvents.watchPass() end
function M.stopWatching() return overhaul_events_motorsportEvents.stopWatching() end
function M.returnToCar() return overhaul_events_motorsportEvents.returnToCar() end
function M.cycleSpectatorCamera() return overhaul_events_motorsportEvents.cycleSpectatorCamera() end
function M.getSpectatorState() return overhaul_events_motorsportEvents.getSpectatorState() end
function M.devStartEvent(definitionId) return overhaul_events_motorsportEvents.devStartEvent(definitionId) end
function M.listEventDefinitions() return overhaul_events_motorsportEvents.listEventDefinitions() end
function M.devCancelEvent() return overhaul_events_motorsportEvents.devCancelEvent() end
function M.devSimulateQualifying() return overhaul_events_motorsportEvents.devSimulateQualifying() end
function M.devSimulateRaces() return overhaul_events_motorsportEvents.devSimulateRaces() end

return M

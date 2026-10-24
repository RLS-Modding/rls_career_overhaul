// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private race-action diagnostics retain each action's reason strings and fallback wording.
// Keep separate policies for scheduling, grid entry and cancellation.
export const isOutOfSpecErr = (err) => {
  const e = String(err || "")
  return e === "fleet_hp_over_class_max" || e === "fleet_hp_under_class_min" || e === "fleet_hp_bracket_mismatch"
}

export const armScheduledErrMessage = (err) => {
  const m = {
    no_pending_race_offer: "That driver has no scheduled race.",
    race_not_scheduled_yet: "Race time not reached yet.",
    invalid_driver: "Invalid overhaulDriver.",
    no_valid_fleet_vehicle: "Driver needs a valid fleet vehicle.",
    missing_business_or_driver: "Missing business or overhaulDriver.",
    no_business: "No business selected.",
    fleet_hp_over_class_max: "Fleet car is too powerful for this race class.",
    fleet_hp_under_class_min: "Fleet car is below the minimum HP for this race class.",
    fleet_hp_bracket_mismatch: "Fleet car does not match the race HP class.",
    lua_error: "Something went wrong. Check the log.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Could not start spectate (no error detail from the game).",
  }
  return m[err] || (err ? String(err) : "Could not start the race.")
}

export const proxyRaceErrMessage = (err) => {
  const m = {
    no_proxy_request: "No armed team race. Accept an offer and arm the proxy driver first.",
    sanctioned_phone_active: "Finish or cancel the sanctioned race from your phone first.",
    race_or_staging_active: "A race or staging is already in progress.",
    in_pursuit: "Cannot start while in a pursuit.",
    no_staging_spot: "No track staging spot (player_stage_track) on this map.",
    no_inventory: "Business inventory is not available.",
    teleport_failed: "Could not place the team car at staging.",
    enter_vehicle_failed: "Could not switch you into the team car.",
    no_business: "No business selected.",
    no_track_flow: "Track flow is not available.",
    no_proxy_flow: "Race flow extension is not ready. Restart the game or verify the mod install.",
    lua_error: "Something went wrong. Check the log.",
    begin_failed: "Staging did not complete. Check the log.",
    unknown_error: "Could not go to grid (no error detail from the game).",
  }
  return m[err] || (err ? String(err) : "Could not start the race.")
}

export const dropScheduledErrMessage = (err) => {
  const m = {
    no_pending_race_offer: "That driver has no scheduled race to drop.",
    missing_business_or_driver: "Missing business or overhaulDriver.",
    no_business: "No business selected.",
    no_racing_team: "Racing team module is not available.",
    lua_error: "Something went wrong. Check the log.",
  }
  return m[err] || (err ? String(err) : "Could not drop out of the scheduled race.")
}

-- Used-car auction tuning. Durations are simulated seconds (_S), distances
-- metres (_M), speeds metres per second (_MPS), money whole dollars (_DOLLARS).
local constants = {

  LOT_DURATION_S = 30,
  FADE_DURATION_S = 0.35,
  ENTRY_RETRIGGER_COOLDOWN_S = 4.0,
  LIVE_STATUS_INTERVAL_S = 1.0,
  HUD_UPDATE_INTERVAL_S = 0.25,
  -- Accept the AI's natural stop; teleport only after transit is detected stuck.
  LOT_ARRIVE_DISTANCE_M = 2.0,
  LOT_ARRIVE_SPEED_MPS = 0.35,
  LOT_ARRIVE_HEADING_DOT = 0.94, -- within twenty degrees of the authored facing
  LOT_OFFSTAGE_DISTANCE_M = 10,
  LOT_EXACT_PATH_RADIUS_M = 0.1,
  LOT_EXACT_TERMINAL_DISTANCE_M = 15.0,
  LOT_EXIT_DESPAWN_DISTANCE_M = 5.0,
  AI_MAX_SPEED_MPS = 4.4352, -- 5 mph
  LOAD_EJECT_DISTANCE_M = 180,
  LOT_STUCK_TIMEOUT_S = 12.0,
  LOT_PROGRESS_DISTANCE_M = 0.35,
  LOT_PROGRESS_WAYPOINT_DISTANCE_M = 5.0,
  -- A misrouted car can keep inching closer without ever reaching its mark.
  LOT_TRANSIT_TIMEOUT_S = 120.0,
  ANTI_SNIPE_WINDOW_S = 10.0,
  ANTI_SNIPE_EXTEND_S = 8.0,
  VEHICLE_SWITCH_REJECT_WARN_COOLDOWN_S = 2.5,
  VEHICLE_SWITCH_REVERT_DELAY_S = 0.05,
  PURCHASE_CALLBACK_TIMEOUT_S = 5,
  METERS_PER_MILE = 1609.344,
  MIN_LOT_COUNT = 5,
  DEFAULT_LOT_COUNT = 10,
  MAX_LOT_COUNT = 25,
  -- Zero allows unlimited queued listings; a batch still uses its selected lot count.
  MAX_CONSIGNMENT_LISTINGS = 5,
  DEFAULT_BID_STEP_DOLLARS = 250,
  LOT_WIN_EMITTER_DURATION_S = 2.0,
  AUCTION_ENTRY_PAYMENT_SFX_EVENT = 'event:>UI>Career>Buy_01',
  AUCTION_ENTRY_FEE_DOLLARS = 1000,
  AUCTION_SETTINGS_SAVE_FILE = 'usedCarAuctionSettings.json',
  AUCTION_LOT_REGISTRATION_PAYMENT_LABEL = 'Used Auction Lot Registration',
  BID_ACCEPTED_SFX_EVENT = 'event:>UI>Career>Buy_02',
  LOT_WIN_CELEBRATION_SFX_EVENT = 'event:>UI>Missions>End_Gold',
  -- Dealership-style entrance pin (not the green fast-travel >>> sprite).
  AUCTION_POI_ICON = 'poi_entrance_round',
  AUCTION_EXIT_MARKER_SHAPE = 'art/shapes/interface/checkpoint_marker.dae',
  AUCTION_EXIT_MARKER_SCALE = 2.2,
  AUCTION_EXIT_MARKER_COLOR = '1.00 0.10 0.10 0.95',
  AUCTION_COUNTER_MARKER_SCALE = 1.8,
  AUCTION_COUNTER_MARKER_COLOR = '1.00 0.55 0.10 0.95',
  AUCTION_EXIT_MARKER_Z_OFFSET_M = -0.8,
  AUCTION_ENTRY_LOADING_TAG = 'auctionEntryLoading',
}

-- Counter offers, grouped in tiers; a tier's full fee is the registration price of a full batch.
constants.COUNTER_OFFER_TIERS = {
  {
    tier = 1,
    fullFee = 1000,
    offers = {
      { id = 'anything_goes', label = 'Anything Goes', subtitle = 'No filter' },
      { id = 'budget', label = 'Budget', subtitle = 'Cheap, high-mileage cars' },
      { id = 'salvage_special', label = 'Salvage Special', subtitle = "One man's another mans treasure" },
      { id = 'modern_daily', label = 'Modern Daily', subtitle = 'Recent factory commuters' }
    }
  },
  {
    tier = 2,
    fullFee = 2000,
    offers = {
      { id = 'vintage', label = 'Vintage', subtitle = 'Pre-1980 vehicles' },
      { id = 'truck_night', label = 'Truck Night', subtitle = 'SUVs, vans, and pickups' },
      { id = 'sports_weekend', label = 'Sports Weekend', subtitle = 'Fun coupes and roadsters' },
      { id = 'touge_nights', label = 'Touge Nights', subtitle = 'Japanese-market street cars' },
      { id = 'autobahn_after_dark', label = 'Autobahn After Dark', subtitle = 'European imports' },
      { id = 'american_allstars', label = 'American Allstars', subtitle = 'US cars and trucks' },
      { id = 'work_fleet', label = 'Work Fleet', subtitle = 'Factory and service trucks' }
    }
  },
  {
    tier = 3,
    fullFee = 5000,
    offers = {
      { id = 'rare_finds', label = 'Rare Finds', subtitle = 'Low-population vehicles' },
      { id = 'high_rollers', label = 'High Rollers', subtitle = 'High-end exotics' }
    }
  }
}

return constants

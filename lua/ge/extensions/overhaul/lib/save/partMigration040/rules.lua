-- Part, slot, seat, cage and cargo rules for importing pre-0.40 vehicle saves.
-- Map: part and slot renames, colored seats, seat/cage moves, cargo moves and conditional renames.
local M = {}

-- Part renames --------------------------------------------------------------------------------------

M.partRenames = {
  pickup_modern_lightbar = "pickup_lightbar_police",
  us_semi_tire_F = "us_semi_tire_F_295/75R22_5",
  us_semi_tire_R_1 = "us_semi_tire_R_1_295/75R22_5",
  miramar_dashboard = "miramar_interior",
  miramar_dashboard_lhd = "miramar_interior_lhd",
  vintage_seat_FL_headrest = "seat_vintage_headrest",
  vintage_seat_FR_headrest = "seat_vintage_headrest",
  pigeon_driver_weight = "",
  pigeon_passenger_weight = "",
  schoolbus_seats_R_b_occupants = "",
  schoolbus_seats_L_b_occupants = "",
  schoolbus_seats_R_c_occupants = "",
  schoolbus_seats_L_c_occupants = "",
}

-- Slot renames --------------------------------------------------------------------------------------

M.slotRenames = {
  {
    model = "*", oldSlot = "bastion_v6_exhmanifold", newSlot = "bastion_v6_exhmanifold",
    newParentSlot = "bastion_v6_intake",
  },
  {
    model = "miramar", oldSlot = "miramar_dashboard", newSlot = "miramar_interior",
    valueMapWhenParentIsUte = {
      miramar_dashboard = "miramar_interior_ute", miramar_dashboard_lhd = "miramar_interior_ute_lhd",
    },
    uteBodies = {"miramar_body_ute", "miramar_junk_body_ute", "miramar_beater_body_ute"},
  },
  {model = "*", oldSlot = "vintage_seat_FL_headrest", newSlot = "vintage_seat_headrest"},
  {model = "*", oldSlot = "vintage_seat_FR_headrest", newSlot = "vintage_seat_headrest"},
  {
    model = "pickup|roamer|van", oldSlot = "pickup_receiver_attachment", newSlot = "towhitch_receiver_attachment",
    onlyWhenParentPart = {"pickup_towhitch"}, valueMap = {pickup_receiver_ball = "tow_hitch_straight"},
  },
  {
    model = "vivace", oldSlotPattern = "^vivace_engine_ecu_.+_speedlimit$", newSlot = "vivace_speedlimit",
    newParentSlot = "vivace_DSE", valuePattern = {"^vivace_engine_ecu_.+_speedlimit_(%w+)$", "vivace_speedlimit_%s"},
  },
  {model = "etk800", oldSlot = "etk800_ABS", newSlot = "etk_DSE_ABS", newParentSlot = "etk_DSE"},
}

-- Color seats ---------------------------------------------------------------------------------------

M.colorSeats = {
  {
    oldPart = "vintage_seat_FL", slot = "vintage_seat_FL", skinSlot = "skin_vintageseat_FL",
    skinPattern = "^skin_vintageseat_FL_(%w+)$", newPattern = "seat_vintage_%s", colors = {"black", "red", "tan"},
    fallback = "seat_vintage_black",
  },
  {
    oldPart = "vintage_seat_FR", slot = "vintage_seat_FR", skinSlot = "skin_vintageseat_FR",
    skinPattern = "^skin_vintageseat_FR_(%w+)$", newPattern = "seat_vintage_%s", colors = {"black", "red", "tan"},
    fallback = "seat_vintage_black",
  },
  {
    oldPart = "race_seat_FL", slot = "race_seat_FL", skinSlot = "skin_race_seat_FL", newPattern = "seat_race_%s",
    colors = {"gray", "red", "blue", "green"}, fallback = "seat_race_gray",
  },
  {
    oldPart = "race_seat_FR", slot = "race_seat_FR", skinSlot = "skin_race_seat_FR", newPattern = "seat_race_%s",
    colors = {"gray", "red", "blue", "green"}, fallback = "seat_race_gray",
  },
}

-- Seat moves ----------------------------------------------------------------------------------------

M.seatMoves = {
  autobello = {
    autobello_seat_FL = {"autobello_interior"}, autobello_seat_FR = {"autobello_interior"},
    autobello_seats_R = {"autobello_interior"}, autobuggy_seat_FL = {"autobuggy_dash"},
    autobuggy_seat_FR = {"autobuggy_dash"}, offroad_seat_FL = {"autobuggy_seat_FL"},
    offroad_seat_FR = {"autobuggy_seat_FR"},
  },
  barstow = {
    barstow_seat_FL = {"barstow_interior"}, barstow_seat_FR = {"barstow_interior"},
    barstow_seats_R = {"barstow_interior"},
  },
  bastion = {
    bastion_seat_FL = {"bastion_dash"}, bastion_seat_FR = {"bastion_dash"}, bastion_seats_R = {"bastion_dash"},
  },
  bluebuck = {
    bluebuck_seat_FL = {"bluebuck_seats_F"}, bluebuck_seat_FR = {"bluebuck_seats_F"},
    bluebuck_seats_F = {"bluebuck_interior"}, bluebuck_seats_R = {"bluebuck_interior"},
  },
  bolide = {bolide_seat_FL = {"bolide_dash"}, bolide_seat_FR = {"bolide_dash"}},
  burnside = {
    burnside_seat_FL = {"burnside_seats_F"}, burnside_seat_FR = {"burnside_seats_F"},
    burnside_seats_F = {"burnside_interior", "burnside_interior_chopped"},
    burnside_seats_R = {"burnside_interior", "burnside_interior_chopped"},
  },
  bx = {bx_seat_FL = {"bx_dashboard"}, bx_seat_FR = {"bx_dashboard"}, bx_seats_R = {"bx_dashboard"}},
  citybus = {citybus_driverseat = {"citybus_interior"}, citybus_seats = {"citybus_interior"}},
  covet = {
    covet_seat_FL = {"covet_interior", "covet_interior_3wheel", "covet_interior_midengine"},
    covet_seat_FR = {"covet_interior", "covet_interior_3wheel", "covet_interior_midengine"},
    covet_seats_R = {"covet_interior"},
  },
  dumptruck = {dumptruck_seat_L = {"dumptruck_interior"}, dumptruck_seat_R = {"dumptruck_interior"}},
  etk800 = {
    etk800_seat_FL = {"etk800_dash", "etk800_dash_wagon"}, etk800_seat_FR = {"etk800_dash", "etk800_dash_wagon"},
    etk800_seats_R = {"etk800_dash", "etk800_dash_wagon"},
  },
  etkc = {etkc_seat_FL = {"etkc_dash"}, etkc_seat_FR = {"etkc_dash"}},
  etki = {etki_seat_FL = {"etki_interior"}, etki_seat_FR = {"etki_interior"}, etki_seats_R = {"etki_interior"}},
  fullsize = {fullsize_seat_FL = {"fullsize_dash"}, fullsize_seat_FR = {"fullsize_dash"}},
  hopper = {hopper_seat_FL = {"hopper_dash"}, hopper_seat_FR = {"hopper_dash"}},
  lansdale = {
    lansdale_seat_FL = {"lansdale_interior"}, lansdale_seat_FR = {"lansdale_interior"},
    lansdale_seat_RL = {"lansdale_seats_R"}, lansdale_seat_RR = {"lansdale_seats_R"},
    lansdale_seats_R = {"lansdale_interior"}, lansdale_seats_RR = {"lansdale_interior"},
  },
  legran = {
    legran_seat_FL = {"legran_dashboard"}, legran_seat_FR = {"legran_dashboard"}, legran_seats_R = {"legran_dashboard"},
  },
  md_series = {
    armored_seat_F = {"armored_interior"}, armored_seat_R = {"armored_interior"},
    armored_seat_cage_R = {"armored_interior"}, md_series_seat_F = {"md_series_cab"},
    md_series_seat_FL = {"md_series_seat_F"}, md_series_seat_FR = {"md_series_seat_F"},
    md_series_seat_R = {"md_series_cab"}, schoolbus_seat_FL = {"schoolbus_interior_b", "schoolbus_interior_c"},
    schoolbus_seat_FR_prisonbus = {"schoolbus_interior_b", "schoolbus_interior_c"},
    schoolbus_seat_RR_prisonbus = {"schoolbus_interior_c"}, schoolbus_seats_L_b = {"schoolbus_interior_b"},
    schoolbus_seats_L_b_prisonbus = {"schoolbus_interior_b"}, schoolbus_seats_L_c = {"schoolbus_interior_c"},
    schoolbus_seats_L_c_prisonbus = {"schoolbus_interior_c"}, schoolbus_seats_R_b = {"schoolbus_interior_b"},
    schoolbus_seats_R_b_prisonbus = {"schoolbus_interior_b"}, schoolbus_seats_R_c = {"schoolbus_interior_c"},
    schoolbus_seats_R_c_prisonbus = {"schoolbus_interior_c"},
  },
  midsize = {
    midsize_seat_FL = {"midsize_interior"}, midsize_seat_FR = {"midsize_interior"},
    midsize_seat_R = {"midsize_interior"},
  },
  midtruck = {
    midtruck_shelter_seat_R = {"midtruck_upfit_6w"}, offroad_seat_FL = {"midtruck_seat_FL"},
    offroad_seat_FR = {"midtruck_seat_FR"},
  },
  miramar = {
    miramar_seat_FL = {"miramar_seats_F"}, miramar_seat_FR = {"miramar_seats_F"},
    miramar_seats_F = {"miramar_interior"},
  },
  moonhawk = {
    moonhawk_seat_FL = {"moonhawk_interior"}, moonhawk_seat_FR = {"moonhawk_interior"},
    moonhawk_seats_R = {"moonhawk_interior"},
  },
  nine = {
    nine_jumpseats_R_coupe = {"nine_trunk"}, nine_seat_FL = {"nine_seats_F_coupe", "nine_seats_F_panelvan"},
    nine_seat_FR = {"nine_seats_F_coupe", "nine_seats_F_panelvan"}, nine_seat_F_handrail = {"nine_seats_F_coupe"},
    nine_seat_F_pocket = {"nine_seats_F_coupe"},
  },
  percheron = {
    percheron_seat_L = {"percheron_interior_L", "percheron_interior_S", "percheron_interior_XL"},
    percheron_seat_R = {"percheron_interior_L", "percheron_interior_S", "percheron_interior_XL"},
  },
  pessima = {
    pessima_seat_FL = {"pessima_interior"}, pessima_seat_FR = {"pessima_interior"},
    pessima_seats_R = {"pessima_interior"},
  },
  pickup = {
    pickup_seat_F = {"pickup_interior"}, pickup_seat_FL = {"pickup_seat_F"}, pickup_seat_FR = {"pickup_seat_F"},
  },
  pigeon = {pigeon_seat_FL = {"pigeon_dashboard"}, pigeon_seat_FR = {"pigeon_dashboard"}},
  racetruck = {
    racetruck_racing_seat_L = {"racetruck_seat_L"}, racetruck_racing_seat_R = {"racetruck_seat_R"},
    racetruck_seat_L = {"racetruck_interior"}, racetruck_seat_R = {"racetruck_interior"},
  },
  rockbouncer = {
    offroad_seat_FL = {"rockbouncer_seat_FL"}, offroad_seat_FR = {"rockbouncer_seat_FR"},
    rockbouncer_seat_FL = {"rockbouncer_interior"}, rockbouncer_seat_FR = {"rockbouncer_interior"},
  },
  sbr = {sbr_seat_FL = {"sbr_interior"}, sbr_seat_FR = {"sbr_interior"}, sbr_seats_R = {"sbr_interior"}},
  scintilla = {scintilla_seat_FL = {"scintilla_dash"}, scintilla_seat_FR = {"scintilla_dash"}},
  sunburst2 = {
    sunburst2_seat_FL = {"sunburst2_interior_sedan", "sunburst2_interior_wagon"},
    sunburst2_seat_FR = {"sunburst2_interior_sedan", "sunburst2_interior_wagon"},
    sunburst2_seats_R = {"sunburst2_interior_sedan", "sunburst2_interior_wagon"},
  },
  us_semi = {
    us_semi_cabover_seat_L = {"us_semi_cabover_dashboard"}, us_semi_cabover_seat_R = {"us_semi_cabover_dashboard"},
    us_semi_conventional_seat_L = {"us_semi_conventional_interior_daycab", "us_semi_conventional_interior_sleepercab"},
    us_semi_conventional_seat_R = {"us_semi_conventional_interior_daycab", "us_semi_conventional_interior_sleepercab"},
  },
  utv = {utv_seat_FL = {"utv_dash"}, utv_seat_FR = {"utv_dash"}},
  van = {van_seat_FL = {"van_interior"}, van_seat_FR = {"van_interior"}},
  vivace = {
    ardente_seat_FL = {"ardente_dash"}, ardente_seat_FR = {"ardente_dash"}, ardente_seats_R = {"ardente_dash"},
    vivace_seat_FL = {"vivace_dash", "vivace_dash_panoramic"},
    vivace_seat_FR = {"vivace_dash", "vivace_dash_panoramic"},
    vivace_seats_R = {"vivace_dash", "vivace_dash_panoramic"},
  },
  wendover = {
    wendover_seat_FL = {"wendover_dashboard"}, wendover_seat_FR = {"wendover_dashboard"},
    wendover_seats_R = {"wendover_dashboard"},
  },
  wigeon = {wigeon_seat_FL = {"wigeon_dashboard"}, wigeon_seat_FR = {"wigeon_dashboard"}},
  wl40 = {wl40_seat = {"wl40_interior"}},
}

-- Cage moves ----------------------------------------------------------------------------------------

M.cageMoves = {
  autobello = {autobello_rollcage = {slot = "autobello_seats_R", hosts = {"autobello_interior"}}},
  vivace = {
    vivace_rollcage = {slot = "vivace_seats_R", hosts = {"vivace_dash", "vivace_dash_panoramic"}},
    ardente_rollcage = {slot = "ardente_seats_R", hosts = {"ardente_dash"}},
  },
}

-- Cargo moves ---------------------------------------------------------------------------------------

M.cargoMoves = {
  ardente_seats_R_space = {
    cargoPart = "ardente_seats_R_cargo", hostSlotType = {"ardente_seats_R"},
    occupantsPart = "ardente_seats_R_occupants",
  },
  armored_seat_R_space = {
    cargoPart = "armored_seat_R_cargo", hostSlotType = {"armored_seat_R"}, occupantsPart = "armored_seat_R_occupants",
  },
  autobello_seats_R_space = {
    cargoPart = "autobello_seats_R_cargo", hostSlotType = {"autobello_seats_R"},
    occupantsPart = "autobello_seats_R_occupants",
  },
  barstow_seats_R_space = {
    cargoPart = "barstow_seats_R_cargo", hostSlotType = {"barstow_seats_R"},
    occupantsPart = "barstow_seats_R_occupants",
  },
  bastion_seats_R_space = {
    cargoPart = "bastion_seats_R_cargo", hostSlotType = {"bastion_seats_R"},
    occupantsPart = "bastion_seats_R_occupants",
  },
  bluebuck_seats_R_space = {
    cargoPart = "bluebuck_seats_R_cargo", hostSlotType = {"bluebuck_seats_R"},
    occupantsPart = "bluebuck_seats_R_occupants",
  },
  burnside_seats_R_space = {
    cargoPart = "burnside_seats_R_cargo", hostSlotType = {"burnside_seats_R"},
    occupantsPart = "burnside_seats_R_occupants",
  },
  covet_seats_R_space = {
    cargoPart = "covet_seats_R_cargo", hostSlotType = {"covet_seats_R"}, occupantsPart = "covet_seats_R_occupants",
  },
  etk800_seats_R_space = {
    cargoPart = "etk800_seats_R_cargo", hostSlotType = {"etk800_seats_R"}, occupantsPart = "etk800_seats_R_occupants",
  },
  etki_seats_R_space = {
    cargoPart = "etki_seats_R_cargo", hostSlotType = {"etki_seats_R"}, occupantsPart = "etki_seats_R_occupants",
  },
  fullsize_seats_R_space = {
    cargoPart = "fullsize_seats_R_cargo", hostSlotType = {"fullsize_seats_R"},
    occupantsPart = "fullsize_seats_R_occupants",
  },
  lansdale_seats_R_space = {
    cargoPart = "lansdale_seats_R_cargo", hostSlotType = {"lansdale_seats_R"},
    occupantsPart = "lansdale_seats_R_occupants",
  },
  legran_seats_R_space = {
    cargoPart = "legran_seats_R_cargo", hostSlotType = {"legran_seats_R"}, occupantsPart = "legran_seats_R_occupants",
  },
  midsize_seat_R_space = {
    cargoPart = "midsize_seat_R_cargo", hostSlotType = {"midsize_seat_R"}, occupantsPart = "midsize_seat_R_occupants",
  },
  miramar_seats_R_space = {
    cargoPart = "miramar_seats_R_cargo", hostSlotType = {"miramar_seats_R"},
    occupantsPart = "miramar_seats_R_occupants",
  },
  moonhawk_seats_R_space = {
    cargoPart = "moonhawk_seats_R_cargo", hostSlotType = {"moonhawk_seats_R"},
    occupantsPart = "moonhawk_seats_R_occupants",
  },
  nine_seats_R_space = {
    cargoPart = "nine_seats_R_sedan_cargo", hostSlotType = {"nine_seats_R_sedan"},
    occupantsPart = "nine_seats_R_sedan_occupants",
  },
  pessima_seats_R_space = {
    cargoPart = "pessima_seats_R_cargo", hostSlotType = {"pessima_seats_R"},
    occupantsPart = "pessima_seats_R_occupants",
  },
  roamer_seats_R_space = {
    cargoPart = "roamer_seats_R_cargo", hostSlotType = {"roamer_seats_R"}, occupantsPart = "roamer_seats_R_occupants",
  },
  sunburst2_seats_R_space = {
    cargoPart = "sunburst2_seats_R_cargo", hostSlotType = {"sunburst2_seats_R"},
    occupantsPart = "sunburst2_seats_R_occupants",
  },
  van_seat_1R_space = {
    cargoPart = "van_seat_1R_cargo", hostSlotType = {"van_seat_1R"}, occupantsPart = "van_seat_1R_occupants",
  },
  van_seat_2R_ext_space = {
    cargoPart = "van_seat_2R_ext_cargo", hostSlotType = {"van_seat_2R_ext"},
    occupantsPart = "van_seat_2R_ext_occupants",
  },
  van_seat_2R_space = {
    cargoPart = "van_seat_2R_cargo", hostSlotType = {"van_seat_2R"}, occupantsPart = "van_seat_2R_occupants",
  },
  van_seat_3R_ext_space = {
    cargoPart = "van_seat_3R_ext_alt_cargo", hostSlotType = {"van_seat_3R_ext"},
    occupantsPart = "van_seat_3R_ext_alt_occupants",
  },
  van_seat_3R_space = {
    cargoPart = "van_seat_3R_cargo", hostSlotType = {"van_seat_3R"}, occupantsPart = "van_seat_3R_occupants",
  },
  van_seat_4R_ext_space = {
    cargoPart = "van_seat_4R_ext_cargo", hostSlotType = {"van_seat_4R_ext"},
    occupantsPart = "van_seat_4R_ext_occupants",
  },
  vivace_seats_R_space = {
    cargoPart = "vivace_seats_R_cargo", hostSlotType = {"vivace_seats_R"}, occupantsPart = "vivace_seats_R_occupants",
  },
  wendover_seats_R_space = {
    cargoPart = "wendover_seats_R_cargo", hostSlotType = {"wendover_seats_R"},
    occupantsPart = "wendover_seats_R_occupants",
  },
}

-- Conditional renames -------------------------------------------------------------------------------

M.conditionalRenames = {
  {
    model = "bluebuck", slot = "bluebuck_intake_v8_big", parentPart = "bluebuck_junk_engine_v8_423",
    old = "bluebuck_intake_v8_big_4bbl", new = "bluebuck_junk_intake_v8_big_4bbl",
  },
}

return M

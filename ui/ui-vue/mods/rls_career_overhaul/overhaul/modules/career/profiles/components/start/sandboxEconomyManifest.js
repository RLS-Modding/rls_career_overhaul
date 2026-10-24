/**
 * UI mirror of economyAdjusterPolicy.lua ECONOMY_SECTIONS.
 * Keep in sync when adding umbrellas (Lua is runtime source of truth).
 */
export const SANDBOX_ECONOMY_MIN = 0.25
export const SANDBOX_ECONOMY_MAX = 3
export const SANDBOX_ECONOMY_STEP = 0.25
export const SANDBOX_ECONOMY_DEFAULT = 1

export const SANDBOX_ECONOMY_SECTIONS = [
  {
    id: "civilService",
    label: "Civil Service",
    children: [
      { id: "police", label: "Police", skillKey: "careerSkills-police" },
      { id: "paramedic", label: "Paramedic", skillKey: "careerSkills-paramedic" },
      { id: "bus", label: "Bus", skillKey: "careerSkills-bus" },
    ],
  },
  {
    id: "logistics",
    label: "Logistics",
    children: [
      {
        id: "logistics",
        label: "Logistics",
        skillKey: "logistics-delivery",
        expandable: [
          { id: "delivery_parcel", label: "Parcels" },
          { id: "delivery_vehicle", label: "Vehicles" },
          { id: "delivery_trailer", label: "Trailers" },
          { id: "delivery_fluid", label: "Fluids" },
          { id: "delivery_dryBulk", label: "Dry Bulk" },
          { id: "delivery_cement", label: "Cement" },
          { id: "delivery_cash", label: "Cash Runs" },
          { id: "beamEats", label: "BeamEats" },
          { id: "facilityWork", label: "Facility Work" },
        ],
      },
    ],
  },
  {
    id: "jobs",
    label: "Jobs",
    children: [
      { id: "taxi", label: "Taxi", skillKey: "careerSkills-passenger" },
      { id: "repo", label: "Repo", skillKey: "careerSkills-recovery" },
      { id: "offroadRecovery", label: "Off-Road Recovery", skillKey: "careerSkills-recovery" },
    ],
  },
  {
    id: "racing",
    label: "Racing & Events",
    children: [
      { id: "rally", label: "Rally", skillKey: "careerSkills-offroad" },
      { id: "drift", label: "Drift", skillKey: "careerSkills-mayhem" },
      { id: "offroad", label: "Off-Road", skillKey: "careerSkills-offroad" },
      { id: "drag", label: "Drag", skillKey: "careerSkills-speed" },
      { id: "oval", label: "Oval", skillKey: "careerSkills-circuitRacing" },
      { id: "crawling", label: "Crawling", skillKey: "careerSkills-offroad" },
      { id: "mudding", label: "Mudding", skillKey: "careerSkills-offroad" },
      { id: "landspeed", label: "Land Speed", skillKey: "careerSkills-speed" },
      { id: "roadracing", label: "Road Racing", skillKey: "careerSkills-circuitRacing" },
      { id: "trail", label: "Trail", skillKey: "careerSkills-offroad" },
      { id: "demo", label: "Demolition Derby", skillKey: "careerSkills-mayhem" },
      { id: "burnout", label: "Burnout", skillKey: "careerSkills-mayhem" },
    ],
  },
]

export function isDefaultRelative(value) {
  return Math.abs(Number(value) - SANDBOX_ECONOMY_DEFAULT) < 0.001
}

export function clampRelative(value) {
  const num = Number(value)
  if (!Number.isFinite(num)) return SANDBOX_ECONOMY_DEFAULT
  return Math.min(SANDBOX_ECONOMY_MAX, Math.max(SANDBOX_ECONOMY_MIN, num))
}

/** Strip defaults so untouched Advanced matches flat global economy behavior. */
export function sanitizeSandboxEconomyProfile(profile) {
  const src = profile && typeof profile === "object" ? profile : {}
  const umbrellas = {}
  const expanded = {}

  if (src.umbrellas && typeof src.umbrellas === "object") {
    for (const [key, value] of Object.entries(src.umbrellas)) {
      const clamped = clampRelative(value)
      if (!isDefaultRelative(clamped)) {
        umbrellas[key] = clamped
      }
    }
  }

  if (src.expanded && typeof src.expanded === "object") {
    for (const [key, value] of Object.entries(src.expanded)) {
      const clamped = clampRelative(value)
      if (!isDefaultRelative(clamped)) {
        expanded[key] = clamped
      }
    }
  }

  const hasUmbrellas = Object.keys(umbrellas).length > 0
  const hasExpanded = Object.keys(expanded).length > 0
  if (!hasUmbrellas && !hasExpanded) {
    return null
  }

  return {
    umbrellas: hasUmbrellas ? umbrellas : undefined,
    expanded: hasExpanded ? expanded : undefined,
  }
}

export function hasSandboxEconomyOverrides(profile) {
  return sanitizeSandboxEconomyProfile(profile) !== null
}

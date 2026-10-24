// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// English fallback for mod keys absent from the shipping game locale cache.
// Kept equal to the delivery locale by the reward-screen tests.
export const deliveryEnglish = {
  "ui.career.cargoDropOff.basePay": "Base pay",
  "ui.career.cargoDropOff.includedDemand": "High demand: included in base pay (+{{percent}}%)",
  "ui.career.cargoDropOff.appliedRewards": "Applied rewards",
  "ui.career.cargoDropOff.route": "Route: {{pickup}} to {{dropOff}}",
  "ui.career.cargoDropOff.pickupOnly": "Pickup: {{pickup}}",
  "ui.career.cargoDropOff.dropOffOnly": "Drop-off: {{dropOff}}",
  "ui.career.cargoDropOff.reputationLevel": "{{label}} (level {{level}})",
  "ui.career.delivery.breakdown.onTime": "On time",
  "ui.career.delivery.breakdown.delayed": "Delayed delivery",
  "ui.career.delivery.breakdown.late": "Late delivery",
  "ui.career.delivery.breakdown.excessiveDamage": "Excessive damage",
  "ui.career.delivery.breakdown.slightDamage": "Slight damage",
  "ui.career.delivery.breakdown.noDamage": "No damage",
  "ui.career.delivery.breakdown.noDetours": "No detours",
  "ui.career.delivery.breakdown.noDelays": "No delays",
  "ui.career.delivery.breakdown.loanerOrganization": "Loaner organization cut ({{cut}}%)",
  "ui.career.delivery.breakdown.levelMultiplier": "Logistics level {{level}} multiplier",
  "ui.career.delivery.breakdown.precisionParking": "Precision parking: {{precisionLevel}}",
  "ui.career.delivery.precisionLevel.none": "Not rated",
  "ui.career.delivery.precisionLevel.horrible": "Very poor",
  "ui.career.delivery.precisionLevel.bad": "Poor",
  "ui.career.delivery.precisionLevel.good": "Good",
  "ui.career.delivery.precisionLevel.great": "Great",
  "ui.career.delivery.precisionLevel.perfect": "Perfect",
  "ui.career.delivery.progress.level": "Level {{level}}",
  "ui.career.delivery.progress.unlockPopupHeader": "{{branchName}} {{branchType}}: level {{level}} unlocked",
  "ui.career.delivery.progress.skill": "skill",
  "ui.career.delivery.progress.branch": "branch",
  "ui.career.delivery.progress.branchName": "{{name}}",
  "ui.career.delivery.progress.skillName": "{{name}}",
  "ui.career.delivery.progress.money": "Money",
  "ui.career.delivery.progress.beamXP": "BeamXP",
  "ui.career.organizations.reputationAnimationName": "{{organizationName}} reputation",
  "ui.career.justXP": "{{cur}} XP"
}

export function createDeliveryTranslator(service) {
  const instant = (key, params = {}) => {
    if (typeof key !== "string") return key
    const value = service.instant?.(key, params)
    const text = typeof value === "string" && value && value !== key ? value : deliveryEnglish[key] || key
    return text.replace(/\{\{(\w+)\}\}/g, (match, name) => params[name] == null ? match : String(params[name]))
  }
  return { instant, contextTranslate: ({ txt, context }) => instant(txt, context) }
}

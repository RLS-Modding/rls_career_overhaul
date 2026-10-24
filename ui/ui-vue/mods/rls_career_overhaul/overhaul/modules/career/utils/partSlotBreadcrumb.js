// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// The slot itself is printed below the breadcrumb; keep its nearest parent.
export const compactSlotPath = path => {
  const segments = (path || "").split(" > ").filter(Boolean)
  const parents = segments.length > 1 ? segments.slice(0, -1) : segments
  return `${parents.length > 1 ? "… > " : ""}${parents.at(-1) || ""}`
}

// Stock tooltips render HTML, so catalog names must be escaped as plain text.
export const slotPathTooltip = path => path ? {
  text: path.replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]),
} : null

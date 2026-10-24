// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

export function nextTab(tabs, selected, direction) {
  if (!tabs.length) return null
  const start = tabs.findIndex(tab => tab.id === selected)
  for (let offset = 1; offset <= tabs.length; offset++) {
    const index = ((start < 0 ? (direction > 0 ? -1 : 0) : start) + offset * direction + tabs.length * 2) % tabs.length
    if (!tabs[index].disabled) return tabs[index]
  }
  return null
}

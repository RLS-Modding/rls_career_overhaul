// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { getNavigableElements, isAvailable } from "@/services/crossfire"
import { setFocus } from "@/services/uiNavFocus"

// Called only when stock container navigation reaches a vertical boundary.
// Crossfire excludes clipped controls, so reveal the next row before focusing it.
export function revealNextControl(root, direction, active = document.activeElement) {
  if (!root?.contains(active) || !["top", "bottom"].includes(direction)) return false
  const from = active.getBoundingClientRect()
  const sign = direction === "bottom" ? 1 : -1
  const centerY = rect => rect.top + rect.height / 2
  const centerX = rect => rect.left + rect.width / 2
  const candidates = getNavigableElements(root)
    .filter(el => el !== active && !el.disabled && isAvailable(el, true))
    .map(el => ({ el, rect: el.getBoundingClientRect() }))
    .filter(({ rect }) => sign * (centerY(rect) - centerY(from)) > 1)
    .sort((a, b) => sign * (centerY(a.rect) - centerY(b.rect))
      || Math.abs(centerX(a.rect) - centerX(from)) - Math.abs(centerX(b.rect) - centerX(from)))
  const target = candidates[0]?.el
  if (!target) return false
  target.scrollIntoView({ block: "nearest", inline: "nearest" })
  return setFocus(target)
}

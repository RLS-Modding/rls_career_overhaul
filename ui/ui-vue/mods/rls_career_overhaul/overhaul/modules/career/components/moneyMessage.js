// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { h, markRaw } from "vue"
import MoneyAmount from "./MoneyAmount.vue"

// HouseConfirm accepts a component message. Keep surrounding copy as text nodes,
// including player-authored names, rather than interpolating it into HTML.
export function moneyMessage(before, amount, after = "") {
  return {
    component: markRaw({
      render: () => [before, h(MoneyAmount, null, { default: () => amount }), after],
    }),
  }
}

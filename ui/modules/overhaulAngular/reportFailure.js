// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { safeLua } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/safeLua.js'

// Optional storage and bridge failures use the same once-per-context diagnostics as Lua calls.
export function reportFailure(error, why) {
  safeLua(() => { throw error }, why)
}

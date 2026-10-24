import { safeLua } from '../../ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/safeLua.js'

// Optional storage and bridge failures use the same once-per-context diagnostics as Lua calls.
export function reportFailure(error, why) {
  safeLua(() => { throw error }, why)
}

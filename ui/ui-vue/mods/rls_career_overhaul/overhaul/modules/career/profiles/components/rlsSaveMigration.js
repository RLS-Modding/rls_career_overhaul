// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// RLS saves on the Overhaul profile screen, the way RLS showed legacy saves: as normal
// profile cards, and loading one opens the legacy migration step (LegacyMigrationModal).
// "Create migrated copy" runs the save importer (overhaul_shell_saveImport), which copies
// the save into the Overhaul save root; the original under settings/cloud/saves/ is only read.

import { safeLua } from "../../utils/safeLua.js"

/** Lua serialises an empty table as `{}` and arrays as objects keyed 1..n. */
export function luaList(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []
  return Object.keys(value).filter(key => /^\d+$/.test(key)).sort((a, b) => a - b).map(key => value[key])
}

export function isImportSource(profile) {
  return !!profile && profile.importSource === true
}

/** Overhaul profiles followed by the RLS saves not imported yet; null when there are none. */
export function mergeProfileCards(profiles, sources) {
  const merged = [...luaList(profiles), ...luaList(sources).filter(isImportSource)]
  return merged.length ? merged : null
}

/** What LegacyMigrationModal shows once the copy exists (main's prepareLegacySaveMigration shape). */
export function toMigrationResult(result, sourceReport) {
  const report = result?.report || {}
  const legacy = report.legacyMigration || {}
  const slots = luaList(report.slots)
  const primary = slots.find(slot => slot?.slot === legacy.primarySlot) || slots[0] || {}
  const summary = { ...(legacy.summary || primary.migration || {}) }
  summary.warnings = [...luaList(summary.warnings), ...luaList(primary.warnings)
    .filter(warning => !luaList(summary.warnings).includes(warning))]
  return {
    ok: true,
    imported: true,
    targetProfile: result.targetProfile,
    targetSaveFolder: null,
    alreadyImported: !!result.alreadyImported,
    summary,
    cashOut: legacy.cashOut || null,
    report: { issues: luaList(sourceReport?.issues) },
  }
}

/**
 * The migration step for an RLS save card.
 * api: preflight(id), queue(profile, target, options), status(); timers: {setInterval, clearInterval}.
 */
export function createRlsSaveMigration({ api, timers = globalThis, pollMs = 1000 }) {
  let pending = null

  function settle(status) {
    if (!pending || !status || status.status !== "complete") return false
    if (pending.jobId != null && status.jobId != null && status.jobId !== pending.jobId) return false
    const done = pending
    pending = null
    timers.clearInterval(done.poll)
    done.resolve(status.result || { ok: false, error: "The import finished without a result." })
    return true
  }

  /** OverhaulSaveImportProgress events and the poll both end up here. */
  function handleStatus(status) {
    return settle(status)
  }

  async function preflight(id) {
    return api.preflight(id)
  }

  /**
   * Starts the copy and resolves when the importer completes, with the modal's result
   * shape or {ok:false,error}. The copy keeps the importer's default name unless the
   * player typed another one; vehicle choices only exist for 0.39 saves (policyChoice).
   */
  async function migrate(report, options = {}) {
    if (pending) return { ok: false, error: "An import is already running" }
    const name = String(options.targetProfile || "").trim()
    const target = !name || name === report.defaultTargetProfile ? null : name
    const choices = report.policyChoice
      ? { vehiclePolicy: options.vehiclePolicy, cashOutVehicleIds: options.cashOutVehicleIds || [],
          cashOutGarageIds: options.cashOutGarageIds || [], sellParts: !!options.sellParts }
      : {}
    const queued = await api.queue(report.sourceProfile, target, choices)
    if (!queued?.ok) return { ok: false, error: queued?.error || "The import could not be started." }
    const result = await new Promise(resolve => {
      pending = { jobId: queued.jobId, resolve, poll: null }
      const current = pending
      current.poll = timers.setInterval(async () => {
        if (pending !== current) return
        // A failed poll is retried on the next tick; the job stays pending and the failure is logged once per session.
        try { settle(await api.status()) } catch (error) { safeLua(() => { throw error }, "rlsSaveMigration failed to poll the import status") }
      }, pollMs)
    })
    if (!result?.ok) return { ok: false, error: result?.error || "Migration could not be prepared." }
    return toMigrationResult(result, report)
  }

  function dispose() {
    if (!pending) return
    timers.clearInterval(pending.poll)
    pending = null
  }

  return { preflight, migrate, handleStatus, dispose, isBusy: () => !!pending }
}

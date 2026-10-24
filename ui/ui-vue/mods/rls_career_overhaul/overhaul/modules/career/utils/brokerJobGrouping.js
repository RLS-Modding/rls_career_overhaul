// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Reserved work is stricter than market display grouping. Missing identities
// stay separate; matching display names cannot prove an interchangeable route.
function locationKey(location) {
  if (!location?.facId && !location?.psPath) return null
  return [location.type || '', location.facId || '', location.psPath || '']
}

export function groupBrokerJobs(jobs, pickedUp) {
  const groups = [], index = new Map()
  for (const job of jobs) {
    const origin = locationKey(job.origin), destination = locationKey(job.destination)
    // Vehicles and trailers have individual condition/configuration obligations.
    // Parcels must carry the cargo template/modifier identity, including on saves.
    const eligible = ['parcel', 'material'].includes(job.kind) && job.cargoIdentity != null && origin && destination
    const key = eligible ? JSON.stringify([job.map, origin, destination, job.market,
      job.kind, job.cargoIdentity, job.title, job.unit, job.quantity, job.weight,
      job.requirement, job.arrangement, job.subtype, job.trailerType,
      job.pay, job.estimatedPay, job.status, pickedUp(job),
      job.remaining, job.inTransit, job.delivered, job.standardLoad]) : null
    let group = key == null ? null : index.get(key)
    if (!group) {
      group = { ...job, groupKey: key == null ? job.id : 'stack:' + encodeURIComponent(key),
        groupCount: 1, groupJobs: [job],
        totalQuantity: Number(job.quantity) || 0,
        totalPay: Number(job.estimatedPay ?? job.pay) || 0 }
      groups.push(group)
      if (key != null) index.set(key, group)
    } else {
      group.groupCount++
      group.groupJobs.push(job)
      group.totalQuantity += Number(job.quantity) || 0
      group.totalPay += Number(job.estimatedPay ?? job.pay) || 0
    }
  }
  return groups
}

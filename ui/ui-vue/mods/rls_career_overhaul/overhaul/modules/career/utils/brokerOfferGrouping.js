// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

function rowGroupKey(row, includeStatus) {
  const parts = [
    row.market,
    row.kind,
    row.title,
    row.from,
    row.to,
    String(row.pay ?? ''),
    String(row.quantity ?? ''),
    row.unit ?? '',
    row.trailerType ?? '',
    row.arrangement ?? '',
    row.subtype ?? '',
    row.requirement ?? '',
  ]
  if (includeStatus) parts.push(row.status ?? '', String(row.unlocked !== false))
  return parts.join('\u001f')
}

export function groupBrokerRows(rows, { byStatus = false } = {}) {
  const grouped = []
  const index = new Map()
  for (const row of rows) {
    const key = rowGroupKey(row, byStatus)
    let at = index.get(key)
    if (at == null) {
      at = grouped.length
      index.set(key, at)
      grouped.push({ ...row, groupCount: 1, groupOfferIds: [row.id] })
    } else {
      const entry = grouped[at]
      entry.groupCount += 1
      entry.groupOfferIds.push(row.id)
    }
  }
  return grouped
}

export function groupedOfferCount(rows, options) {
  return groupBrokerRows(rows, options).length
}

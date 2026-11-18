// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { resolveNotificationAppId } from './phoneNotificationRoutes'
import { findPhoneApp } from './phoneAppRegistry'
import { ensurePhoneApps, isPhoneAppCatalogLoaded } from './phoneAppCatalog'

// Starts app discovery once, from a surface's mount, so lookups while rendering stay free of side effects.
export function loadNotificationApps() {
  if (!isPhoneAppCatalogLoaded()) ensurePhoneApps().catch(() => {})
}

// The app a notification belongs to: its manifest (by app id, channel or source, then by app name), so
// the card can show the app's own icon. Senders with no matching app keep their source name and group
// under it. key is what notifications group by.
export function notificationApp(item) {
  const source = String(item?.source || '').trim()
  const app = findPhoneApp({ id: resolveNotificationAppId(item), name: source })
  if (app) return { key: `app:${app.id}`, name: app.name || source, app }
  return { key: `source:${source.toLowerCase()}`, name: source, app: null }
}

export const notificationAppKey = item => notificationApp(item).key

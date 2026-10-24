// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { NOTIFICATION_CHANNEL_APP_IDS } from './phoneNotificationRegistry'
import { getNotificationSourceAppIds, onPhoneAppsChanged } from './phoneAppCatalog'
import { acquireScope } from './luaScopes'

// App id -> route, and payload.source (lower case) -> app id (manifest notificationSources), both
// from the discovered app manifests.
const APP_ROUTES_BY_ID = {}
const SOURCE_APP_IDS = getNotificationSourceAppIds()

onPhoneAppsChanged(apps => {
  for (const key of Object.keys(APP_ROUTES_BY_ID)) delete APP_ROUTES_BY_ID[key]
  for (const manifest of apps) {
    if (manifest?.id && manifest?.route) {
      APP_ROUTES_BY_ID[manifest.id] = manifest.route
    }
  }
})

export function resolveNotificationAppId(payload) {
  if (!payload || typeof payload !== 'object') return null
  if (typeof payload.appId === 'string' && payload.appId) return payload.appId
  if (typeof payload.channelKey === 'string' && NOTIFICATION_CHANNEL_APP_IDS[payload.channelKey]) {
    return NOTIFICATION_CHANNEL_APP_IDS[payload.channelKey]
  }
  const source = String(payload.source || '').trim().toLowerCase()
  return SOURCE_APP_IDS[source] || null
}

export function resolveNotificationRoute(payload) {
  if (!payload || typeof payload !== 'object') return null
  if (typeof payload.route === 'string' && payload.route) return payload.route
  const appId = resolveNotificationAppId(payload)
  if (!appId) return null
  return APP_ROUTES_BY_ID[appId] || null
}

export function getNotificationInstallAppId(payload) {
  if (!payload || typeof payload !== 'object') return ''
  return typeof payload.installAppId === 'string' ? payload.installAppId.trim() : ''
}

export async function installAppFromNotification(lua, payload) {
  const appId = getNotificationInstallAppId(payload)
  if (!appId || !lua) return false
  try {
    await acquireScope(lua, 'phone.layout')
    if (lua.overhaul_phone_apps_layout?.isAppInstalled) {
      const installed = await lua.overhaul_phone_apps_layout.isAppInstalled(appId)
      if (installed) return true
    }
    const ok = await lua.overhaul_phone_apps_layout?.installApp?.(appId)
    return ok !== false
  } catch (error) {
    console.warn('[phone] failed to install app from notification', error)
    return false
  }
}

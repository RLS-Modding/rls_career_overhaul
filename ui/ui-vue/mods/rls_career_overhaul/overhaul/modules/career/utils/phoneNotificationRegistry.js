// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { ref } from 'vue'
import { PREINSTALLED_APP_IDS } from './phoneLayoutUtils'
import { ensurePhoneApps, getPhoneApps, isPhoneAppCatalogLoaded, onPhoneAppsChanged } from './phoneAppCatalog'
import { acquireScope } from './luaScopes'

// Phone notification framework (works like a real phone OS):
// An app declares its own notification channels in its manifest (a discovered JSON file, see
// phoneAppCatalog.js), e.g. car-meet.json:
//
//   {
//     "id": "car-meet",
//     "name": "Car Meet",
//     "notifications": [
//       { "key": "carMeet.invite", "label": "Invites", "default": true, "description": "..." }
//     ]
//   }
//
// Channels appear in Settings -> Notifications when the app is installed on the phone.
// Lua gates fireNotification: installed app -> per-channel toggle -> master mute.
//
// Convention: namespace keys as `appCamelCase.channel` (e.g. 'racingTeam.raceReady').
function isValidChannel(decl) {
  return !!(decl && typeof decl.key === 'string' && decl.key && typeof decl.label === 'string' && decl.label)
}

function loadNotificationChannels() {
  const channels = []
  const seenKeys = new Set()

  for (const manifest of getPhoneApps()) {
    if (!manifest || !manifest.id || !Array.isArray(manifest.notifications)) continue

    for (const decl of manifest.notifications) {
      if (!isValidChannel(decl)) continue
      if (seenKeys.has(decl.key)) {
        console.warn(`[phoneNotificationRegistry] duplicate channel key '${decl.key}' (ignored)`)
        continue
      }
      seenKeys.add(decl.key)
      channels.push({
        key: decl.key,
        label: decl.label,
        description: typeof decl.description === 'string' ? decl.description : '',
        default: decl.default !== false, // default ON unless explicitly false
        order: Number.isFinite(decl.order) ? decl.order : 0,
        appId: manifest.id,
        appName: manifest.name || manifest.id,
        appColor: manifest.color || '#6b7280',
        appCategory: manifest.category || '',
        unlockCondition: typeof manifest.unlockCondition === 'function' ? manifest.unlockCondition : null,
      })
    }
  }
  return channels
}

// Filled in place from the discovered app manifests (and refilled if they reload).
export const NOTIFICATION_CHANNELS = []

// Channel key -> app id (manifest channels + dev/test channels without manifest entries).
export const NOTIFICATION_CHANNEL_APP_IDS = {}

function resolveChannelAppId(channel) {
  if (channel?.appId && !channel.discovered) {
    return channel.appId
  }
  return NOTIFICATION_CHANNEL_APP_IDS[channel?.key] || null
}

function isChannelAppInstalled(channel, installedSet) {
  const appId = resolveChannelAppId(channel)
  if (!appId) {
    return false
  }
  if (PREINSTALLED_APP_IDS.includes(appId)) {
    return true
  }
  return installedSet.has(appId)
}

// Map of key -> default, used to seed the settings store so the Lua gate is authoritative
// (its fail-open default is "on", so default:false channels must be seeded explicitly).
export const NOTIFICATION_DEFAULTS = {}

function clearObject(target) {
  for (const key of Object.keys(target)) delete target[key]
}

onPhoneAppsChanged(() => {
  NOTIFICATION_CHANNELS.length = 0
  NOTIFICATION_CHANNELS.push(...loadNotificationChannels())
  clearObject(NOTIFICATION_CHANNEL_APP_IDS)
  clearObject(NOTIFICATION_DEFAULTS)
  for (const ch of NOTIFICATION_CHANNELS) {
    NOTIFICATION_CHANNEL_APP_IDS[ch.key] = ch.appId
    NOTIFICATION_DEFAULTS[ch.key] = ch.default
  }
})

// Turn a Lua-discovered channel (auto-recorded on first fire, no manifest) into a
// synthetic channel. These have no unlock info, so they always show once discovered.
function discoveredToChannel(entry) {
  const source = typeof entry.source === 'string' && entry.source ? entry.source : 'Other'
  return {
    key: entry.key,
    label: typeof entry.label === 'string' && entry.label ? entry.label : entry.key,
    description: '',
    default: true,
    order: 9999,
    appId: `discovered:${source}`,
    appName: source,
    appColor: '#6b7280',
    appCategory: '',
    unlockCondition: null,
    discovered: true,
  }
}

function isDiscoveredChannelEntry(value) {
  return !!(value && typeof value === 'object' && typeof value.key === 'string' && value.key)
}

// The Lua->JS bridge can hand back a list in several shapes depending on how it
// marshals a Lua table: a real array, a single entry (1-element arrays often unwrap),
// an index-keyed object ({1:{...},2:{...}}), or a JSON string.
function coerceToArray(raw) {
  if (raw == null) return []
  if (Array.isArray(raw)) return raw.filter(isDiscoveredChannelEntry)
  if (typeof raw === 'string') {
    try {
      return coerceToArray(JSON.parse(raw))
    } catch (_) {
      return []
    }
  }
  if (typeof raw === 'object') {
    if (isDiscoveredChannelEntry(raw)) return [raw]
    return Object.values(raw).filter(isDiscoveredChannelEntry)
  }
  return []
}

function coerceToStringList(raw) {
  if (raw == null) return []
  if (Array.isArray(raw)) {
    return raw.filter(id => typeof id === 'string' && id.length > 0)
  }
  if (typeof raw === 'string') {
    try {
      return coerceToStringList(JSON.parse(raw))
    } catch (_) {
      return raw.length > 0 ? [raw] : []
    }
  }
  if (typeof raw === 'object') {
    const numericKeys = Object.keys(raw)
      .filter(k => /^\d+$/.test(k))
      .sort((a, b) => Number(a) - Number(b))
    if (numericKeys.length > 0) {
      return numericKeys
        .map(k => raw[k])
        .filter(id => typeof id === 'string' && id.length > 0)
    }
    return Object.values(raw).filter(id => typeof id === 'string' && id.length > 0)
  }
  return []
}

let cachedInstalledAppIds = []

function rememberInstalledAppIds(ids) {
  const list = coerceToStringList(ids)
  if (list.length > 0) {
    cachedInstalledAppIds = list
  }
  return list
}

async function resolveInstalledAppIds(luaBridge, options = {}) {
  const fromOptions = rememberInstalledAppIds(options.installedAppIds)
  if (fromOptions.length > 0) return fromOptions
  if (cachedInstalledAppIds.length > 0) return cachedInstalledAppIds
  return fetchInstalledAppIds(luaBridge)
}

async function fetchInstalledAppIds(luaBridge) {
  try {
    // The phone layout extension, loaded through its scope like every phone screen does. (Never
    // return or await the bridge namespace itself: it is a Proxy whose every property, `then`
    // included, is a Lua call.)
    await acquireScope(luaBridge, 'phone.layout')
    const raw = await luaBridge?.overhaul_phone_apps_layout?.getInstalledAppIds?.()
    const list = rememberInstalledAppIds(raw)
    if (list.length > 0) return list
  } catch (err) {
    console.warn('[phoneNotificationRegistry] getInstalledAppIds failed', err)
  }
  return cachedInstalledAppIds.length > 0 ? cachedInstalledAppIds : [...PREINSTALLED_APP_IDS]
}

async function fetchDiscoveredChannels(luaBridge) {
  try {
    await acquireScope(luaBridge, 'phone.layout')
    const raw = await luaBridge?.overhaul_phone_apps_layout?.getKnownNotificationChannels?.()
    return coerceToArray(raw)
  } catch (err) {
    console.warn('[phoneNotificationRegistry] getKnownNotificationChannels failed', err)
    return []
  }
}

export function usePhoneNotifications() {
  const notificationGroups = ref([])

  // Build the grouped channel list (one group per app). Requires install on the phone.
  async function refreshNotifications(luaBridge, options = {}) {
    // The channels come from the discovered app manifests: wait for them (routes open before
    // discovery finishes). If discovery failed, keep showing what this screen had.
    if (!isPhoneAppCatalogLoaded()) {
      await ensurePhoneApps()
      if (!isPhoneAppCatalogLoaded()) {
        console.warn('[phoneNotificationRegistry] phone apps are not discovered yet; notification settings unchanged')
        return
      }
    }
    const installedIds = await resolveInstalledAppIds(luaBridge, options)
    const installedSet = new Set(installedIds)

    const manifestKeys = new Set(NOTIFICATION_CHANNELS.map(ch => ch.key))
    const discovered = await fetchDiscoveredChannels(luaBridge)
    const orphanChannels = discovered
      .filter(e => !manifestKeys.has(e.key))
      .map(discoveredToChannel)

    const allChannels = [...NOTIFICATION_CHANNELS, ...orphanChannels]

    const groups = new Map()

    for (const ch of allChannels) {
      if (!isChannelAppInstalled(ch, installedSet)) {
        continue
      }

      if (!groups.has(ch.appId)) {
        groups.set(ch.appId, {
          appId: ch.appId,
          appName: ch.appName,
          appColor: ch.appColor,
          appCategory: ch.appCategory,
          channels: [],
        })
      }
      groups.get(ch.appId).channels.push(ch)
    }

    const result = [...groups.values()]
    for (const g of result) {
      g.channels.sort((a, b) => (a.order - b.order) || String(a.label).localeCompare(String(b.label)))
    }
    result.sort((a, b) => String(a.appName).localeCompare(String(b.appName)))
    notificationGroups.value = result
  }

  return { notificationGroups, refreshNotifications, NOTIFICATION_CHANNELS, NOTIFICATION_DEFAULTS }
}

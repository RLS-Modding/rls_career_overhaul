// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import {
  clampNotificationDisplaySeconds,
  isLockScreenContentHidden,
} from '../composables/usePhoneSettings'

const DEFAULT_TTL_SECONDS = 8

function sanitizeText(value, fallback = '') {
  const text = value == null ? fallback : value
  return String(text).trim()
}

/** @param {unknown} raw */
export function normalizePhoneNotificationPayload(raw) {
  if (Array.isArray(raw)) {
    raw = raw.find(entry => entry && typeof entry === 'object') || raw[0]
  }
  if (!raw || typeof raw !== 'object') return null

  const message = sanitizeText(raw.message || raw.msg)
  if (!message) return null

  const kind = ['success', 'warning', 'error', 'invite', 'rep', 'racing', 'dakar', 'info'].includes(raw.kind)
    ? raw.kind
    : 'info'
  const ttl = Number(raw.ttl)

  const title = sanitizeText(raw.title, kind === 'racing' ? 'Race Ready' : 'Notification')
  const meta = sanitizeText(raw.meta)
  const channelKey = sanitizeText(raw.channelKey)
  const appId = sanitizeText(raw.appId)
  const route = sanitizeText(raw.route)
  const replaceKey = sanitizeText(raw.replaceKey)
  const installAppId = sanitizeText(raw.installAppId)

  const base = {
    title,
    message,
    source: sanitizeText(raw.source, 'Phone'),
    meta,
    kind,
    ttl: ttl > 0 ? ttl : DEFAULT_TTL_SECONDS,
    sound: raw.sound,
    soundClass: sanitizeText(raw.soundClass),
    soundType: sanitizeText(raw.soundType || raw.soundEvent || raw.type),
    forcePeek: raw.forcePeek === true,
    forceTtl: raw.forceTtl === true,
    ...(channelKey ? { channelKey } : {}),
    ...(appId ? { appId } : {}),
    ...(route ? { route } : {}),
    ...(replaceKey ? { replaceKey } : {}),
    ...(installAppId ? { installAppId } : {}),
  }

  if (kind === 'racing') {
    const parts = []
    if (meta) parts.push(meta)
    if (message && message !== title) parts.push(message)
    base.subline = parts.length ? parts.join(', ') : ''
  }

  return base
}

/** Apply lock-screen presentation prefs (duration, hide content). */
export function applyLockScreenNotificationPrefs(payload, settings) {
  if (!payload || typeof payload !== 'object') return payload
  const seconds = payload.forceTtl
    ? clampNotificationDisplaySeconds(payload.ttl)
    : clampNotificationDisplaySeconds(settings?.lockScreenDisplaySeconds)
  const out = { ...payload, ttl: seconds }
  if (isLockScreenContentHidden(settings)) {
    out.presentationSimple = true
  }
  return out
}

/** Apply banner presentation prefs (duration only — full content on banners). */
export function applyBannerNotificationPrefs(payload, settings) {
  if (!payload || typeof payload !== 'object') return payload
  const seconds = payload.forceTtl
    ? clampNotificationDisplaySeconds(payload.ttl)
    : clampNotificationDisplaySeconds(settings?.bannerDisplaySeconds)
  return { ...payload, ttl: seconds }
}

/** @deprecated */
export function applyNotificationDisplayPrefs(payload, settings) {
  return applyLockScreenNotificationPrefs(payload, settings)
}

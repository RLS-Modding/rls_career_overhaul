// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { lua } from "@/bridge"
import { callModLua, installLuaBridgeFallbacks } from "./installLuaBridgeFallbacks"
import { acquireScope } from './luaScopes'

installLuaBridgeFallbacks()

function resolveLuaTarget(router, target) {
  if (!router || !target) return null

  try {
    const routeTarget = typeof target === "string" && router.hasRoute(target)
      ? { name: target }
      : target
    const resolved = router.resolve(routeTarget)
    if (typeof resolved?.name !== "string" || !resolved.name) return null
    return {
      name: resolved.name,
      params: resolved.params || {},
    }
  } catch (error) {
    console.error("[phoneNavigation] Unable to resolve phone route", target, error)
    return null
  }
}

export async function navigatePhoneRoute(router, target) {
  const resolved = resolveLuaTarget(router, target)
  if (!resolved) {
    console.warn("[phoneNavigation] Ignoring unresolved phone route", target)
    return { success: false, reason: "route_not_found" }
  }
  try {
    return await lua.extensions.ui_router.navigate(resolved.name, resolved.params)
  } catch (error) {
    console.error("[phoneNavigation] Phone navigation failed", resolved.name, error)
    return { success: false, reason: "navigation_failed" }
  }
}

export async function openPhoneRoute(router, target) {
  const resolved = resolveLuaTarget(router, target)
  if (!resolved) {
    console.warn("[phoneNavigation] Ignoring unresolved phone route", target)
    return { success: false, reason: "route_not_found" }
  }
  try {
    await acquireScope(lua, 'phone.phone')
    return await callModLua("overhaul_phone_phone.openRoute", resolved.name, resolved.params)
  } catch (error) {
    console.error("[phoneNavigation] Phone open failed", resolved.name, error)
    return { success: false, reason: "navigation_failed" }
  }
}

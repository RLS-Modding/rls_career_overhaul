// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, onMounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { asLuaArray } from "./luaTableUtils.js"
import { moneyText } from "../../../utils/units.js"
import { acquireScope } from '../../../utils/luaScopes'

/**
 * @param {import('vue').Ref<string|null|undefined>} startingMapRef
 * @param {{ allowSpecific?: boolean }} [options]
 *   allowSpecific — Custom career: list every garage on the selected map.
 *   Career path keeps only Random / No garage.
 */
export function useStartGarages(startingMapRef, options = {}) {
  const allowSpecific = options.allowSpecific === true
  const allGarages = ref([])
  const startingGarage = ref("default_garage")

  const { units } = useBridge()

  const garageOptions = computed(() => {
    // Native option labels render text only, so use the localized amount.
    const opts = [
      { value: "default_garage", label: `Random Garage (≤${moneyText(units, 50000, { decimals: 0 })})` },
      { value: "no_garage", label: "No starting garage" },
    ]

    if (!allowSpecific) return opts

    const mapId = startingMapRef.value
    const seen = new Set(opts.map(o => o.value))
    for (const garage of allGarages.value) {
      if (!garage?.id || seen.has(garage.id)) continue
      if (mapId && garage.mapId && garage.mapId !== mapId) continue
      const name = garage.name || garage.id
      const label = garage.mapName && garage.mapName !== name ? `${name} (${garage.mapName})` : name
      opts.push({ value: garage.id, label })
      seen.add(garage.id)
    }

    return opts
  })

  watch(startingMapRef, () => {
    if (!garageOptions.value.some(o => o.value === startingGarage.value)) {
      startingGarage.value = "default_garage"
    }
  })

  async function loadGarages() {
    if (!allowSpecific) return
    try {
      await acquireScope(lua, 'profiles.challengeModes')
      const list = await lua.overhaul_career_challengeModes.getAvailableGarages()
      allGarages.value = asLuaArray(list)
    } catch (_) {
      allGarages.value = []
    }
  }

  onMounted(loadGarages)

  return { garageOptions, startingGarage, loadGarages }
}

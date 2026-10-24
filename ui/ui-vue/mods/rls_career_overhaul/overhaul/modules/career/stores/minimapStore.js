// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { ref, shallowRef, onScopeDispose, watch } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import { acquireScope, releaseScope } from '../utils/luaScopes'
import { reportUiFailure } from '../utils/safeLua'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
import { createMinimapRenderer } from '../utils/minimapRenderer.js'

export const useMinimapStore = defineStore("overhaulMinimap", () => {
    const events = useEvents(onScopeDispose)
    const nodes = shallowRef({})
    const zoomFactor = ref(3)
    const viewBox = ref('0 0 1000 1000')
    const camRotation = ref(0)
    const isFreeCam = ref(false)
    const playerPos = shallowRef({ x: 0, y: 0 })
    const playerId = ref(0)
    const viewControlledBy = ref(null)
    const showTerrainImage = ref(true)
    const darkMode = ref(false)
    const terrainTiles = shallowRef([])
    const roadsVersion = ref(0)
    const playerRotation = ref(0)
    let users = 0, generation = 0
    let level = null, revision = null
    const renderer = createMinimapRenderer({
        nodes, terrainTiles, roadsVersion, darkMode, showTerrainImage, isFreeCam, camRotation, playerId,
        playerPos, playerRotation, zoomFactor, viewBox, viewControlledBy,
    })
    watch([darkMode, showTerrainImage], renderer.refreshRoadNetwork, { flush: 'sync' })
    function onMapData(data) {
        renderer.processMapData(data)
        level = data.level
        revision = data.revision
    }
    const markerStream = useStreams(['phoneMinimap'], streams => {
        if (streams.phoneMinimap) renderer.processMapUpdate(streams.phoneMinimap)
    }, onScopeDispose)
    markerStream.off()

    function acquire() {
        if (++users !== 1) return
        if (!viewControlledBy.value) renderer.setMapViewBox(viewBox.value)
        const opening = ++generation
        events.on('PhoneMinimapData', onMapData)
        markerStream.on()
        Promise.resolve(acquireScope(lua, 'phone.minimap')).then(() => {
            if (users && opening === generation) return callModLua('overhaul_phone_apps_minimap.requestPhoneMap', level, revision)
        }).catch(error => reportUiFailure(error, 'Failed to load phone minimap'))
    }
    function release() {
        if (!users || --users) return
        generation++
        markerStream.off()
        events.off('PhoneMinimapData', onMapData)
        releaseScope(lua, 'phone.minimap')
        // Keep the processed graph and road canvas for the next scope acquisition.
    }
    onScopeDispose(() => { if (users) { users = 1; release() } })

    return {
        terrainTiles, roadsVersion, playerRotation, playerPos,
        acquire, release, viewBox, viewControlledBy, zoomFactor, showTerrainImage, darkMode,
        ...renderer, processMapData: onMapData,
    }
})

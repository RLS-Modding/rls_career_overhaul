<!-- Business Supplies Pickup, house style (same data, events and Lua calls as before).
     Order: where you are -> what's waiting and what it costs -> how much to take this trip ->
     which parked vehicles it goes into -> Back / Load. Orange only on Load. -->
<template>
  <div class="supply-shell" v-bng-blur bng-ui-scope="passiveBusinessSupplyPickup" v-bng-on-ui-nav:back,menu="close">
    <div class="rls-shell pickup-shell">
      <BngCard class="rls-card">
        <BngCardHeading type="ribbon">
          <span class="hd-name">Business Supplies Pickup</span>
          <span v-if="ready" class="hd-status" :class="data.available ? (data.maximumLoad > 0 ? 'ready' : 'warn') : 'warn'">{{ !data.available ? 'Unavailable' : data.maximumLoad > 0 ? 'Ready to load' : 'Waiting' }}</span>
        </BngCardHeading>
        <div class="card-content" v-bng-ui-nav-scroll>
          <!-- after the data arrives; no picture of its own: name and line only, no empty banner -->
          <div v-if="ready" class="hero" :class="{ 'text-only': !heroPicture }">
            <img v-if="heroPicture" :src="heroPicture" alt="" @error="onHeroPictureError" />
            <div class="hero-copy">
              <strong>{{ data.facilityName || 'Business supplier' }}</strong>
              <span>Paid supply pallets for your owned businesses</span>
            </div>
          </div>

          <section v-if="!ready" class="block"><HouseLoader :label="$translate.instant('ui.career.vehicleShopping.pleaseWait')" /></section>
          <section v-else-if="!data.available" class="block">
            <p class="notice-bad">{{ data.reason || 'Procurement is unavailable right now.' }}</p>
          </section>
          <template v-else>
            <!-- what's waiting -->
            <div class="summary">
              <div class="tile">
                <span class="tile-key">Ready for pickup</span>
                <span class="tile-value">{{ data.paidAtSupplier }}</span>
                <span class="tile-note">paid pallet{{ data.paidAtSupplier === 1 ? '' : 's' }}</span>
              </div>
              <div class="tile">
                <span class="tile-key">Nearby capacity</span>
                <span class="tile-value">{{ data.vehicleCapacity }}</span>
                <span class="tile-note">pallets, 128 slots each</span>
              </div>
              <div class="tile">
                <span class="tile-key">Chain inventory</span>
                <span class="tile-value">{{ data.chainStored }}<small> / {{ data.chainCapacity }}</small></span>
                <span class="stock-bar" v-if="data.chainCapacity > 0">
                  <span class="stored" :style="{ transform: `scaleX(${stockFraction(data.chainStored)})` }" />
                  <span class="reserved" :style="{ left: `${stockFraction(data.chainStored) * 100}%`, transform: `scaleX(${stockFraction(data.chainReserved)})` }" />
                </span>
                <span class="tile-note">{{ data.chainStored }} stored, {{ data.chainReserved }} on the way</span>
              </div>
              <div class="tile">
                <span class="tile-key">Pickup charge</span>
                <span class="tile-value money-text"><BngIcon class="cur" :type="icons.beamCurrency" />{{ money(data.unitCost) }}</span>
                <span class="tile-note">paid at each business</span>
              </div>
            </div>

            <div class="columns">
              <!-- this trip -->
              <section class="block">
                <div class="block-head">
                  <div class="kicker">This pickup</div>
                  <span v-if="data.maximumLoad > 0" class="hint">Up to {{ data.maximumLoad }}</span>
                </div>
                <div class="panel trip">
                  <template v-if="data.maximumLoad > 0">
                    <span class="big">{{ selected }} <small>pallet{{ selected === 1 ? '' : 's' }}</small></span>
                    <HouseSlider :min="1" :max="data.maximumLoad" :step="1" v-model="selected" />
                    <div class="chips">
                      <button type="button" bng-nav-item :class="{ active: selected === data.maximumLoad }" @click="selected = data.maximumLoad">
                        Take all {{ data.maximumLoad }}
                      </button>
                    </div>
                  </template>
                  <div v-else class="no-capacity">
                    <strong>{{ data.paidAtSupplier > 0 ? 'No free space nearby' : 'Nothing to pick up' }}</strong>
                    <span class="hint">{{ data.paidAtSupplier > 0 ? 'Bring a vehicle with at least 128 free parcel slots.' : 'No paid order is waiting. Order stock from an owned business first.' }}</span>
                  </div>
                </div>
                <p class="hint charge-note">Charged now <strong class="money-text"><BngIcon class="cur" :type="icons.beamCurrency" />0</strong>. Delivery pays through each business's margin.</p>
                <p v-if="message" :class="resultError ? 'status-error' : 'status-ok'">{{ message }}</p>
              </section>

              <!-- parked vehicles -->
              <section class="block">
                <div class="block-head">
                  <div class="kicker">Nearby vehicles</div>
                  <span class="hint">Freight containers in range</span>
                </div>
                <!-- read-only list: the right stick scrolls it without moving focus -->
                <ul v-if="vehicles.length" class="fleet scroll-list" v-bng-ui-nav-scroll.force>
                  <li v-for="v in vehicles" :key="v.key" class="vehicle" :class="{ off: !v.eligible }">
                    <div class="vehicle-top">
                      <div class="vehicle-img">
                        <img v-if="v.thumbnail" :src="v.thumbnail" :alt="v.vehicleName" />
                      </div>
                      <div class="vehicle-copy">
                        <strong>{{ v.vehicleName }}</strong>
                        <span v-if="v.eligible" class="fits">{{ v.pallets }} pallet{{ v.pallets === 1 ? '' : 's' }} fit</span>
                        <span v-else class="pill bad">Not usable</span>
                      </div>
                    </div>
                    <ul class="containers">
                      <li v-for="c in v.containers" :key="c.containerId" :class="{ off: !c.eligible }">
                        <span class="container-name">{{ c.containerName }}</span>
                        <span class="container-free">{{ c.free }} slots free</span>
                        <span v-if="c.eligible" class="pill">{{ c.pallets }} pallet{{ c.pallets === 1 ? '' : 's' }}</span>
                        <span v-else-if="c.reason" class="pill bad">{{ c.reason }}</span>
                      </li>
                    </ul>
                  </li>
                </ul>
                <p v-else class="muted">No cargo containers detected.</p>
              </section>
            </div>
          </template>

          <div class="actions">
            <HouseButton class="btn-back" variant="quiet" binding="back" @click="close">Back</HouseButton>
            <HouseButton
              class="btn-load"
              binding="ok"
              v-if="ready && data.available"
              variant="primary"
              :disabled="loading || selected <= 0 || data.maximumLoad <= 0"
              @click="load">
              {{ loading ? 'Loading…' : `Load ${selected} pallet${selected === 1 ? '' : 's'}` }}
            </HouseButton>
          </div>
        </div>
      </BngCard>
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { lua, useBridge } from '@/bridge'
import { BngCard, BngCardHeading, BngIcon, icons } from '@/common/components/base'
import { HouseLoader, HouseButton, HouseSlider } from '../components/house/index.js'
import { vBngBlur, vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { useUINavScope } from '@/services/uiNav'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { useFacilityPicture } from '../composables/useFacilityPicture'

useUINavScope('passiveBusinessSupplyPickup')
const { events } = useBridge()
const ready = ref(false), loading = ref(false), selected = ref(0), message = ref(''), resultError = ref(false)
const data = reactive({ available: false, equipment: [], maximumLoad: 0, paidAtSupplier: 0, unitCost: 0, facilityName: '', facilityPreview: '' })
const { picture: heroPicture, onPictureError: onHeroPictureError } = useFacilityPicture(() => data.facilityPreview)

// One card per vehicle; its cargo containers are listed inside the card.
const vehicles = computed(() => {
    const map = new Map()
    for (const item of data.equipment) {
        const key = item.vehId ?? item.vehicleName
        if (!map.has(key)) map.set(key, { key, vehId: item.vehId, vehicleName: item.vehicleName, thumbnail: item.thumbnail, containers: [], pallets: 0, eligible: false })
        const v = map.get(key)
        v.containers.push(item); v.pallets += Number(item.pallets) || 0; v.eligible = v.eligible || !!item.eligible
        if (!v.thumbnail && item.thumbnail) v.thumbnail = item.thumbnail
    }
    return [...map.values()]
})
const stockFraction = value => (data.chainCapacity > 0 ? Math.min(1, Math.max(0, (Number(value) || 0) / data.chainCapacity)) : 0)
// number only: the template puts the game currency glyph in front
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()
function applyData(payload) {
  Object.assign(data, payload || {})
  data.equipment = Array.isArray(data.equipment) ? data.equipment : Object.values(data.equipment || {})
  ready.value = true
  loading.value = Boolean(payload?.loading)
  if (selected.value <= 0 || selected.value > data.maximumLoad) selected.value = data.maximumLoad
}
function applyResult(payload) { loading.value = false; message.value = payload?.message || ''; resultError.value = payload?.success === false }
function load() { if (loading.value || selected.value <= 0) return; loading.value = true; message.value = ''; lua.overhaul_career_logistics_cargoScreen.loadPassiveBusinessSupply(Math.round(selected.value)) }
function close() { lua.overhaul_career_logistics_cargoScreen.closePassiveBusinessSupplyPickupScreen() }
watch(() => data.maximumLoad, max => { if (selected.value > max) selected.value = max })

// Controller: no scoped-nav scope here, so focus Load once the pickup data arrived (Back when nothing can
// be loaded), and again whenever loading / a data refresh disabled or swapped the focused button.
const pickMainAction = () => {
  const root = document.querySelector('.supply-shell')
  return root?.querySelector('.actions .btn-load:not(:disabled)') || root?.querySelector('.actions .btn-back')
}
watch([ready, loading, () => data.available, () => data.maximumLoad], () => refocusIfLost(pickMainAction), { flush: 'post' })
onMounted(() => { events.on('passiveBusinessSupplyPickupData', applyData); events.on('passiveBusinessSupplyPickupResult', applyResult); lua.overhaul_career_logistics_cargoScreen.requestPassiveBusinessSupplyPickupData() })
onUnmounted(() => {
  events.off('passiveBusinessSupplyPickupData', applyData)
  events.off('passiveBusinessSupplyPickupResult', applyResult)
  lua.overhaul_career_logistics_cargoScreen.onPassiveBusinessSupplyPickupRouteLeave()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsCard.scss" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsSupplyPickup.scss" as *;


/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

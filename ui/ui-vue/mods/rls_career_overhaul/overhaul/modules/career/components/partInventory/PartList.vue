<template>
  <BngCard
    class="part-inventory-card rls-house"
    v-bng-blur
    v-bng-scoped-nav="{ scopeId: 'part-inventory-list' }"
    tabindex="-1"
    v-bng-disabled="!partInventoryStore">
    <BngInput class="searchField" :label="$translate.instant('ui.common.search')" floating-label :leading-icon="icons.search" v-model.trim="partInventoryStore.searchString" />
    <HouseLoader v-if="!isInventoryLoaded" :label="$translate.instant('ui.career.vehicleShopping.pleaseWait')" />

    <div v-else class="part-list-scroll scroll" v-bng-ui-nav-scroll.force>
      <p v-if="isSearching && !shownGroups.length" class="list-message" role="status">{{ $translate.instant('ui.career.partInventory.noSearchMatches') }}</p>
      <Accordion v-else class="part-groups" singular>
        <AccordionItem
          v-for="group in shownGroups"
          :key="group.id"
          :data-groupid="group.id"
          :ref="item => { if (item) accordionItems[group.id] = item; else delete accordionItems[group.id] }"
          navigable
          @expanded="state => setGroupExpanded(group.id, state)"
          @selected="accordionItems[group.id]?.captionClick()">
          <HouseButton
            v-if="group.id == 0 && group.parts.length"
            class="sell-all-button"
            compact
            @click="openSellPopup()">
            {{ $translate.instant("ui.career.partInventory.sellParts") }}
          </HouseButton>
          <p v-if="!group.parts.length" class="group-empty">
            {{ $translate.instant(group.id == 0 ? 'ui.career.partInventory.noLooseParts' : 'ui.career.partInventory.noRemovableParts') }}
          </p>

          <template #caption>
            <div class="veh-part-caption">
              <BngIcon v-if="group.icon" class="veh-icon" :type="group.icon" />
              <div v-if="group.thumbnail" class="veh-preview" :style="{ backgroundImage: `url('${group.thumbnail}')` }" ></div>
              <span class="veh-name">
                {{ group.id == 0 ? $translate.instant("ui.career.partShopping.inventory") : group.name }}
                <span class="veh-name-count">({{ group.parts.length }})</span>
              </span>
            </div>
          </template>

          <div v-for="(part, index) in group.parts" class="part-item"
            bng-ui-scope="veh-part-inv"
            v-bng-on-ui-nav:back="() => setGroupExpanded(group.id, false, true)">
            <div class="part-info-col" v-if="(readyGroups[group.id] || index < immediateLimit)">
              <div>
                <span class="part-name">{{ part.name }}</span>
              </div>
              <div class="part-info-row">
                <span class="right meta-value"><BngPropVal :iconType="icons.beamCurrency" :valueLabel="part.valueFormatted" /></span>
                <span class="right meta-mileage">{{ part.mileage }}</span>
                <span v-if="groupBy !== 'location'" class="center">{{ part.location }}</span>
                <span v-else-if="groupBy !== 'model'" class="center">{{ part.model }}</span>
                <span class="center meta-flag"><span v-if="part.data.repairCount">{{ $translate.instant("ui.career.partInventory.repairs", { count: part.data.repairCount }) }} </span></span>
                <span class="center meta-flag"> <span v-if="part.data.primered">{{ $translate.instant("ui.career.partInventory.notPainted") }}</span></span>
              </div>
            </div>
            <HouseButton
              v-if="(readyGroups[group.id] || index < immediateLimit) && part.functions.sell"
              class="part-button"
              compact
              @click="confirmSellPart(part.data)">
              {{ $translate.instant("ui.career.partInventory.sell") }}
            </HouseButton>
          </div>
        </AccordionItem>
      </Accordion>
    </div>
  </BngCard>
</template>

<script setup>
import Accordion from "../PartsAccordion.vue"
import { computed, ref, watch, watchEffect } from "vue"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"
import { lua, useBridge } from "@/bridge"
import { BngCard, BngPropVal, BngIcon, ACCENTS, icons, BngInput } from "@/common/components/base"
import { HouseLoader, HouseButton, openHouseConfirmation, openHouseMessage } from "../house/index.js"
import { vBngOnUiNav, vBngDisabled, vBngBlur, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { AccordionItem } from "@/common/components/utility"
import { addPopup } from "@/services/popup"
import { $translate } from "@/services/translation"

import { usePartInventoryStore } from "../../stores/partInventoryStore"
import PartSellingPopup from "./PartSellingPopup.vue"

const { units } = useBridge()

const emit = defineEmits(["partSold"])
const partInventoryStore = usePartInventoryStore()

// Leading space keeps this group sorted to the top; do not use for display.
const INVENTORY_GROUP_SORT_NAME = " Inventory"

// number of parts to show right away
const immediateLimit = 15

const groupBy = ref("location")

const groups = ref([])
const accordionItems = ref({})
const disableInstallButtons = ref(false)

const expandedGroups = ref({})
const readyGroups = ref({})

// Lua sends the list once the route has mounted; until then show a wait line, not an empty card.
const isInventoryLoaded = computed(() => partInventoryStore.partInventoryData?.partList != null)
const isSearching = computed(() => partInventoryStore.searchString !== "")
// While searching, groups with no match are noise (every vehicle showed "(0)"); hide them.
const shownGroups = computed(() => isSearching.value ? groups.value.filter(group => group.parts.length) : groups.value)

const setGroupExpanded = (groupId, state, focusOnCollapse = false) => {
  expandedGroups.value[groupId] = state
  if (!state) {
    delete readyGroups.value[groupId]
    if (focusOnCollapse) {
      const elm = document.querySelector(`[data-groupid="${groupId}"] > .bng-accitem-caption`)
      elm && elm.focus()
    }
    return
  }
  if (!(groupId in readyGroups.value)) {
    readyGroups.value[groupId] = false
    setTimeout(() => {
      // only flip to ready if the group is still expanded
      if (expandedGroups.value[groupId]) {
        readyGroups.value[groupId] = true
      }
    }, 100)
  }
}

const openSellPopup = async () => {
  const res = await addPopup(PartSellingPopup, { parts: groups.value[0].parts }).promise
  if (res) {
    emit("partSold")
  }
}

watchEffect(() => {
  disableInstallButtons.value = false
  // an empty list still rebuilds (Inventory + one empty group per vehicle); returning early on an empty
  // list left the last groups on screen after the final part was sold, or a blank card on first open.
  // (Lua sends an empty table as {}, so anything that is not an array counts as no parts.)
  if (!partInventoryStore || partInventoryStore.partInventoryData?.partList == null) {
    return [] // not loaded yet
  }
  const res = []

  if (groupBy.value == "location") {
    let group = {
      id: 0,
      name: INVENTORY_GROUP_SORT_NAME,
      parts: [],
      icon: icons.BNGFolder
    }
    res.push(group)

    for (const [vehId, vehicle] of Object.entries(partInventoryStore.partInventoryData.vehicles || {})) {
      let group = {
        id: vehId,
        name: vehicle.niceName,
        parts: [],
        thumbnail: partInventoryStore.partInventoryData.vehicles[vehId].thumbnail
      }
      res.push(group)
    }
  }

  const filteredParts = partInventoryStore.partInventoryData.filteredPartList
  for (const part of Array.isArray(filteredParts) ? filteredParts : []) {
    const item = {
      name: part.missingFile ? $translate.instant("ui.career.partInventory.missingFile") : part.description.description,
      model: part.vehicleModelDisplayName || part.vehicleModel,
      mileage: units.buildString("length", part.partCondition.odometer, 0),
      // value: part.finalValue,
      valueFormatted: units.beamBucks(part.finalValue),
      location: part.location,
      // please leave the whitespace in inventory name - it helps it sort to the top without any visual change
      locationName: part.location === 0 ? INVENTORY_GROUP_SORT_NAME : partInventoryStore.partInventoryData.vehicles[part.location].niceName,
      functions: {
        sell: false,
      },
      data: part,
    }
    if (!part.missingFile && part.accessible) {
      item.functions.sell =
        part.location === 0
    }
    const groupId = item[groupBy.value]
    let group = res.find(g => g.id == groupId)
    if (!group) {
      group = {
        id: groupId,
        name: item[`${groupBy.value}Name`] || item[groupBy.value],
        parts: [],
      }
      if (part.location > 0) {
        group.thumbnail = partInventoryStore.partInventoryData.vehicles[part.location].thumbnail
      } else {
        // folder BNGFolder
        group.icon = icons.BNGFolder
      }
      res.push(group)
    }
    group.parts.push(item)
  }
  if (res.length > 0) {
    const sorter = (a, b) => a.name.localeCompare(b.name)
    res.sort(sorter)
    for (const group of res) {
      group.parts.sort(sorter)
    }
  }
  // show the result; expansion/ready state lives in expandedGroups/readyGroups
  // (keyed by group id) and persists across rebuilds without retriggering here
  groups.value = res
})

const confirmSellPart = async partToSell => {
  const res = await openHouseConfirmation(partToSell.description.description, $translate.instant("ui.career.partInventory.confirmSell", { price: units.beamBucks(partToSell.finalValue) }), [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.text } },
  ])
  if (res) sellPart(partToSell)
}

const showPartInstallPopup = (data) => {
  if (data) {
    if (data.success) {
      partInventoryStore.openNewPartsPopup(data.newPartIds)
    } else {
      openHouseMessage(data.title, data.message)
    }
  }
}

// Controller: selling removes the row (and its focused Sell button) once the list rebuilds; keep a pad
// on the Sell button that moved into its place (or the one above), else on the group's caption
let soldAt = null
const sellPart = part => {
  const group = groups.value.find(g => g.parts.some(p => p.data === part))
  if (group) soldAt = { groupId: group.id, index: group.parts.findIndex(p => p.data === part) }
  lua.overhaul_career_parts_partInventory.sellParts([part.id])
  emit("partSold")
}
// Controller entry: the first group, not the search box above it (the scope's first navigable item).
// The scope (preferAutoFocus) takes this mark on route entry; it is dropped again afterwards so later
// scope resumes return to the last focused row.
let entryMarked = false
watch(groups, list => {
  if (entryMarked || !list.length) return
  entryMarked = true
  setTimeout(() => {
    const first = document.querySelector(".part-inventory-card .part-groups .bng-accitem-caption")
    if (!first) return
    first.setAttribute("bng-scoped-nav-autofocus", "")
    const active = document.activeElement
    if (!active || active === document.body || active.closest?.(".searchField")) refocusIfLost(() => first, { force: true })
    // drop the mark once the player has moved on from it (the route's scope activation can come
    // before or after this), or after a while at the latest
    const drop = () => first.removeAttribute("bng-scoped-nav-autofocus")
    first.addEventListener("focusout", drop, { once: true })
    setTimeout(drop, 10000)
  }, 50)
}, { flush: "post" })

watch(groups, () => {
  if (!soldAt) return
  const { groupId, index } = soldAt
  soldAt = null
  refocusIfLost(() => {
    const item = document.querySelector(`.part-inventory-card [data-groupid="${groupId}"]`)
    const buttons = [...(item?.querySelectorAll(".part-item .part-button:not([disabled])") || [])]
    return buttons[Math.min(index, buttons.length - 1)] || item?.querySelector(".bng-accitem-caption")
  }, { force: true })
}, { flush: "post" })
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house style: near-black card, white primary copy, muted metadata, gold money.
   Everything is em off the card, whose font-size follows the viewport height. */

.part-inventory-card.bng-card {
  --bng-card-height: auto;
  --bg-opacity: 0.9; /* the default 0.6 reads grey over bright garages */
  --bng-icon-color: currentColor;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  min-height: 0;
  height: 100%;
  padding: 0;
  color: #fff;
  border-radius: 0.6em;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  :deep(.card-cnt) {
    display: flex;
    flex-direction: column;
    flex: 1 1 0;
    min-height: 0;
    padding: 0.85em 0.35em 0.6em 0.85em;
    border-radius: 0.6em;
    background-color: rgba(var(--bng-off-black-rgb), var(--bg-opacity));
  }
}

.part-list-scroll {
  flex: 1 1 0;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  padding-right: 0.35em;
}

.part-groups {
  min-height: 0;
}

/* ---- search: house .search look on the vanilla BngInput (focus frame kept) */
.part-inventory-card .searchField.bng-input {
  flex: 0 0 auto;
  height: 2.5em;
  margin: 0 0.85em 0.65em 0;
  font-size: 1em;
  border-radius: var(--radius-panel);
  background-color: rgba(0, 0, 0, 0.3);
  box-shadow: inset 0 0 0 1px var(--line);
  overflow: hidden;
}
.part-inventory-card .searchField.bng-input:focus-within { box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.28); }
.part-inventory-card .searchField.bng-input :deep(.leading-icon) {
  padding: 0 0.2em 0 0.7em;
  font-size: 1.05em;
  color: var(--faint);
  --bng-icon-color: var(--faint);
}
.part-inventory-card .searchField.bng-input :deep(.input-container) {
  padding: 0.2em 0.75em 0 0.35em; /* Overpass sits high */
  border-radius: 0;
  background: transparent;
}
.part-inventory-card .searchField.bng-input :deep(.input-container::before) { display: none; }
.part-inventory-card .searchField.bng-input :deep(input) {
  font-family: inherit;
  font-size: 1em;
  font-weight: 400;
  color: #fff;
}
.part-inventory-card .searchField.bng-input :deep(.floating-label) {
  top: 50%;
  left: 0.35em;
  transform: translateY(-38%);
  font-size: 1em;
  font-weight: 400;
  color: var(--faint);
}
.part-inventory-card .searchField.bng-input.has-value :deep(.floating-label) { display: none; }

/* ---- group rows (inventory folder / one per vehicle) */
.part-groups.bng-accordion-container {
  padding: 0;
  gap: 0.35em;
}
.part-groups :deep(.bng-accitem) { margin: 0; }
.part-groups :deep(.bng-accitem.bng-accitem-expandable > .bng-accitem-caption) {
  margin: 0;
  padding: 0.4em 0.75em 0.4em 0.4em;
  gap: 0.35em;
  border-radius: var(--radius-panel);
  background-color: var(--panel);
  transition: background-color 0.12s ease-out;
}
.part-groups :deep(.bng-accitem.bng-accitem-expandable > .bng-accitem-caption:hover) { background-color: var(--panel-2); }
.part-groups :deep(.bng-accitem.bng-accitem-expanded > .bng-accitem-caption) { background-color: var(--panel-2); }
.part-groups :deep(.bng-accitem > .bng-accitem-caption > .bng-accitem-caption-expander) {
  font-size: 1.2em;
  color: var(--faint);
  transition: transform 0.18s ease-out;
}
.part-groups :deep(.bng-accitem > .bng-accitem-caption > .bng-accitem-caption-content) { font-weight: 700; }
.part-groups :deep(.bng-accitem > .bng-accitem-content) {
  padding: 0.35em 0 0.5em 0.6em;
}

.veh-part-caption {
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  align-items: center;
  gap: 0.75em;
  overflow: hidden;
  width: 100%;
  min-height: 3.1em;
  $thumb-w: 5.4em;
  $thumb-h: 3.04em; // 16:9
  .veh-icon {
    flex: 0 0 auto;
    display: grid;
    place-items: center;
    width: calc($thumb-w / 1.5);
    height: calc($thumb-h / 1.5);
    font-size: 1.5em;
    line-height: 1;
    border-radius: calc(var(--radius-thumb) / 1.5);
    background-color: var(--panel-2);
    color: rgba(255, 255, 255, 0.85);
  }
  .veh-preview {
    flex: 0 0 auto;
    width: $thumb-w;
    height: $thumb-h;
    border-radius: var(--radius-thumb);
    background-color: var(--photo);
    background-size: cover;
    background-position: 50% 50%;
    background-repeat: no-repeat;
  }
  .veh-name {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    padding-top: 0.15em; /* Overpass sits high */
    font-size: 1.05em;
    font-weight: 700;
    color: #fff;
    .veh-name-count {
      margin-left: 0.2em;
      font-size: 0.85em;
      font-weight: 600;
      color: var(--faint);
      font-variant-numeric: tabular-nums;
    }
  }
}

/* ---- part rows: hairline list, white name, muted metadata, gold value */
.part-item {
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  align-items: center;
  gap: 0.8em;
  overflow: hidden;
  width: 100%;
  min-height: 3.4em;
  padding: 0.5em 0.6em 0.4em 0.5em;
  color: #fff;
  border-radius: var(--radius-thumb);
  transition: background-color 0.12s ease-out;
  > * {
    flex: 1 1 auto;
  }
  &:hover { background-color: rgba(255, 255, 255, 0.04); }
  &:not(:last-child) {
    border-bottom: 1px solid var(--line);
    border-bottom-left-radius: 0;
    border-bottom-right-radius: 0;
  }
}

.part-info-col {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
  min-width: 0;
}
.part-info-row {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.2em 1.1em;
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  > * {
    flex: 0 0 auto;
  }
  > :empty { display: none; }
}

.meta-value {
  color: var(--money);
  font-weight: 700;
  --units-icon-color: var(--money);
  :deep(.info-item) {
    --paddings: 0;
    --icon-size: 1.15em;
    --font-weight-value: 700;
    gap: 0.25em;
    line-height: 1.2;
    font-family: inherit;
  }
}
.meta-flag { color: var(--warn); }

.part-name {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 1em;
  font-weight: 700;
  line-height: 1.2;
}

.center,
.right {
  text-align: left;
}

/* ---- empty and waiting states: one muted line, never a blank card */
.list-message,
.group-empty {
  margin: 0;
  color: var(--muted);
  font-weight: 600;
  line-height: 1.35;
}
.list-message {
  padding: 0.6em 0.85em 0.6em 0.1em;
  font-size: 1em;
}
.group-empty {
  padding: 0.5em 0.6em 0.4em 0.5em;
  font-size: 0.9em;
}

/* ---- buttons: neutral compact house buttons */
.part-button {
  flex: 0 0 auto;
  margin: 0;
}
.sell-all-button {
  margin: 0.15em 0 0.45em 0.5em;
}
</style>

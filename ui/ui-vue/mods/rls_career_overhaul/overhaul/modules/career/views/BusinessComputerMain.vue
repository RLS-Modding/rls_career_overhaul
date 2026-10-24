<template>
  <div class="business-computer-wrapper" :class="{ workshop: sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning', 'engine-shop-fullscreen': sessionStore.hasCapability('fullscreenComputer') }">
    <!-- the workshop views show the balance under the career status chip instead (no overlap) -->
    <BusinessAccountBalance v-if="businessComputerReady && sessionStore.businessId && sessionStore.businessType && !sessionStore.hasCapability('fullscreenComputer') && sessionStore.businessData.showBusinessAccount !== false && !(sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning')" />
    <BusinessWorkshopParts
      v-if="businessComputerReady && sessionStore.vehicleView === 'parts' && sessionStore.pulledOutVehicle"
      :key="`parts-${sessionStore.pulledOutVehicle.vehicleId}`"
    />
    <BusinessWorkshopTuning
      v-else-if="businessComputerReady && sessionStore.vehicleView === 'tuning' && sessionStore.pulledOutVehicle"
      :key="`tuning-${sessionStore.pulledOutVehicle.vehicleId}`"
    />
    <template v-else>
    <Teleport to="body">
      <transition name="rt-promo-fade">
        <div
          v-if="showLeague2InviteComputerPopup"
          class="rt-promo-overlay"
          v-bng-scoped-nav="league2InviteScope" v-bc-modal-focus
          v-bng-on-ui-nav:back,menu="onLeague2InviteLater"
          @click.self.stop.prevent
        >
          <RacingTeamPromoPanel
            :title="league2InviteUi.popupTitle"
            :body="league2InviteUi.popupBody"
            :image-url="league2InviteUi.popupImageUrl"
            :fee="league2InviteUi.fee"
            @click.stop
          >
            <HouseButton variant="quiet" bng-scoped-nav-autofocus @click="onLeague2InviteLater">
              {{ league2InviteUi.laterLabel }}
            </HouseButton>
            <HouseButton variant="primary" @click="onLeague2InviteAccept">
              {{ league2InviteUi.acceptLabel }}
            </HouseButton>
          </RacingTeamPromoPanel>
        </div>
      </transition>
    </Teleport>

    <BusinessMaintenanceModal
      v-model:open="showMaintenanceModal"
      :vehicle="vehicleToMaintain"
      @close="onMaintenanceModalClosed"
    />

    <!-- Controller: the sidebar and the tab content are two container scopes side by side (entry focus on the
         active sidebar tab). Up/down stay inside each pane, left/right cross between them, LB/RB switch tabs
         from anywhere, B steps from the content back to the sidebar and from the sidebar closes the computer.
         Inner modals run their own scopes. -->
    <BngCard v-if="businessComputerReady" class="rls-house business-computer-container" :class="{ 'vehicle-view': sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning', 'collapsed': isVehicleViewCollapsed && (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning'), 'vehicle-sidebar-expanded': !isVehicleSidebarCollapsed && (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning'), 'engine-shop-fullscreen': sessionStore.hasCapability('fullscreenComputer') }" v-bng-blur ref="containerRef" v-bng-on-ui-nav:tab_l,tab_r="onTabNav" @focusin="onCardFocusIn">
      <div class="main-header" :class="{ 'collapsed': isVehicleViewCollapsed && (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning') }">
        <h1 class="bc-title">{{ sessionStore.vehicleView === 'parts' ? 'Parts Customization' : sessionStore.vehicleView === 'tuning' ? 'Tuning' : sessionStore.businessName }}</h1>
        <div class="header-actions">
          <button
            v-if="sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning'"
            class="collapse-toggle-vehicle"
            @click="isVehicleViewCollapsed = !isVehicleViewCollapsed"
          >
            <svg v-if="isVehicleViewCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="18 15 12 9 6 15"/>
            </svg>
            <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </button>
          <HouseButton
            class="close-button"
            bng-no-nav="true"
            variant="quiet"
            :icon="icons.xmark"
            title="Close"
            aria-label="Close"
            @click="close" />
        </div>
      </div>

      <div class="content-layout" :class="{ 'vehicle-view': sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning' }">
        <aside v-if="sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning'" :class="['vehicle-sidebar', { collapsed: isVehicleSidebarCollapsed }]">
          <div class="sidebar-header">
            <button class="collapse-toggle" bng-no-nav="true" @click="isVehicleSidebarCollapsed = !isVehicleSidebarCollapsed">
              <svg v-if="isVehicleSidebarCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M9 18l6-6-6-6"/>
              </svg>
              <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
          </div>

          <nav class="sidebar-nav">
            <template v-if="sessionStore.hasCapability('fleetVehicles') && vehicleList.length">
              <div
                v-for="vehicle in vehicleList"
                :key="`rt-workshop-vehicle-${vehicle.vehicleId}`"
                class="nav-section rt-workshop-section"
              >
                <div
                  class="nav-section-title rt-workshop-vehicle-title"
                  :title="rtVehicleDisplayName(vehicle)"
                >
                  {{ isVehicleSidebarCollapsed ? rtWorkshopCollapsedTitle(vehicle) : rtVehicleDisplayName(vehicle) }}
                </div>
                <ul v-if="!isVehicleSidebarCollapsed" class="nav-list">
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'parts'), disabled: isRtPartsTuningDisabled(vehicle) }]"
                      :disabled="isRtPartsTuningDisabled(vehicle)"
                      :bng-no-nav="isRtPartsTuningDisabled(vehicle) ? 'true' : null"
                      @click.stop="openRtWorkshop(vehicle, 'parts')"
                      @mousedown.stop
                    >
                      <span>Parts</span>
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'tuning'), disabled: isRtPartsTuningDisabled(vehicle) }]"
                      :disabled="isRtPartsTuningDisabled(vehicle)"
                      :bng-no-nav="isRtPartsTuningDisabled(vehicle) ? 'true' : null"
                      @click.stop="openRtWorkshop(vehicle, 'tuning')"
                      @mousedown.stop
                    >
                      <span>Tuning</span>
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      class="nav-item nav-item--workshop-link"
                      @click.stop="openRtWorkshop(vehicle, 'paint')"
                      @mousedown.stop
                    >
                      <span>Paint</span>
                    </button>
                  </li>
                  <li v-if="sessionStore.isMaintenanceEnabled">
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'maintain') }]"
                      @click.stop="openRtWorkshop(vehicle, 'maintain')"
                      @mousedown.stop
                    >
                      <span>Maintain</span>
                    </button>
                  </li>
                </ul>
              </div>
            </template>
            <template v-else-if="sessionStore.hasCapability('partsCustomization') && vehicleList.length">
              <div
                v-for="vehicle in vehicleList"
                :key="`ts-workshop-vehicle-${vehicle.vehicleId}`"
                class="nav-section rt-workshop-section"
              >
                <div
                  class="nav-section-title rt-workshop-vehicle-title"
                  :title="vehicle.vehicleName || 'Vehicle'"
                >
                  {{ isVehicleSidebarCollapsed ? 'V' : (vehicle.vehicleName || 'Vehicle') }}
                </div>
                <ul v-if="!isVehicleSidebarCollapsed" class="nav-list">
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isTsWorkshopLinkActive(vehicle, 'parts'), disabled: sessionStore.isDamageLocked }]"
                      :disabled="sessionStore.isDamageLocked"
                      :bng-no-nav="sessionStore.isDamageLocked ? 'true' : null"
                      @click.stop="openTsWorkshop(vehicle, 'parts')"
                      @mousedown.stop
                    >
                      <span>Parts</span>
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isTsWorkshopLinkActive(vehicle, 'tuning'), disabled: sessionStore.isDamageLocked }]"
                      :disabled="sessionStore.isDamageLocked"
                      :bng-no-nav="sessionStore.isDamageLocked ? 'true' : null"
                      @click.stop="openTsWorkshop(vehicle, 'tuning')"
                      @mousedown.stop
                    >
                      <span>Tuning</span>
                    </button>
                  </li>
                </ul>
              </div>
            </template>
            <div v-else class="nav-section">
              <div class="nav-section-title">{{ isVehicleSidebarCollapsed ? 'V' : 'VEHICLE' }}</div>
              <ul class="nav-list"></ul>
            </div>
          </nav>
        </aside>

        <aside v-if="sessionStore.vehicleView !== 'parts' && sessionStore.vehicleView !== 'tuning'" :class="['sidebar', { collapsed: isCollapsed }]" v-bng-scoped-nav="sidebarScope">
          <div class="sidebar-header">
            <BngBinding v-if="tabCount > 1" class="tab-bind" ui-event="tab_l" controller track-ignore />
            <!-- mouse-only: as a d-pad stop it sat "right" of every sidebar row and caught focus_r before the content -->
            <button class="collapse-toggle" bng-no-nav="true" @click="isCollapsed = !isCollapsed">
              <svg v-if="isCollapsed" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M9 18l6-6-6-6"/>
              </svg>
              <svg v-else width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M15 18l-6-6 6-6"/>
              </svg>
            </button>
            <BngBinding v-if="tabCount > 1" class="tab-bind" ui-event="tab_r" controller track-ignore />
          </div>

          <nav class="sidebar-nav" v-bng-ui-nav-scroll>
            <div v-for="(tabs, section) in sessionStore.tabsBySection" :key="section" class="nav-section">
              <div class="nav-section-title">{{ isCollapsed ? section.charAt(0) : section }}</div>
              <ul class="nav-list">
                <li v-for="tab in tabs" :key="tab.id">
                  <button
                    :class="['nav-item', 'tab-item', { active: !tab.action && sessionStore.activeView === tab.id }]"
                    :bng-scoped-nav-autofocus="!tab.action && sessionStore.activeView === tab.id ? true : null"
                    @click.stop="onSidebarTabClick(tab)"
                    @mousedown.stop
                  >
                    <svg v-if="tabIcons.get(tab)?.svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" v-html="tabIcons.get(tab).svg"></svg>
                    <BngIcon v-else class="nav-glyph" :type="tabIcons.get(tab)?.glyph || FALLBACK_TAB_ICON" />
                    <span v-if="!isCollapsed">{{ tab.label }}</span>
                  </button>
                </li>
              </ul>
            </div>

            <template v-if="sessionStore.hasCapability('fleetVehicles') && vehicleList.length">
              <div
                v-for="vehicle in vehicleList"
                :key="`rt-workshop-${vehicle.vehicleId}`"
                class="nav-section rt-workshop-section"
              >
                <div
                  class="nav-section-title rt-workshop-vehicle-title"
                  :title="rtVehicleDisplayName(vehicle)"
                >
                  {{ isCollapsed ? rtWorkshopCollapsedTitle(vehicle) : rtVehicleDisplayName(vehicle) }}
                </div>
                <ul v-if="!isCollapsed" class="nav-list">
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'parts'), disabled: isRtPartsTuningDisabled(vehicle) }]"
                      :disabled="isRtPartsTuningDisabled(vehicle)"
                      :bng-no-nav="isRtPartsTuningDisabled(vehicle) ? 'true' : null"
                      @click.stop="openRtWorkshop(vehicle, 'parts')"
                      @mousedown.stop
                    >
                      <span>Parts</span>
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'tuning'), disabled: isRtPartsTuningDisabled(vehicle) }]"
                      :disabled="isRtPartsTuningDisabled(vehicle)"
                      :bng-no-nav="isRtPartsTuningDisabled(vehicle) ? 'true' : null"
                      @click.stop="openRtWorkshop(vehicle, 'tuning')"
                      @mousedown.stop
                    >
                      <span>Tuning</span>
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      class="nav-item nav-item--workshop-link"
                      @click.stop="openRtWorkshop(vehicle, 'paint')"
                      @mousedown.stop
                    >
                      <span>Paint</span>
                    </button>
                  </li>
                  <li v-if="sessionStore.isMaintenanceEnabled">
                    <button
                      type="button"
                      :class="['nav-item', 'nav-item--workshop-link', { active: isRtWorkshopLinkActive(vehicle, 'maintain') }]"
                      @click.stop="openRtWorkshop(vehicle, 'maintain')"
                      @mousedown.stop
                    >
                      <span>Maintain</span>
                    </button>
                  </li>
                </ul>
              </div>
            </template>
            <div
              v-else-if="vehicleList.length"
              :class="['garage-selector', { collapsed: isCollapsed }]"
            >
              <div class="nav-section-title selector-title" v-if="!isCollapsed">Garage vehicles</div>
              <div class="selector-pills">
                <button
                  v-for="vehicle in vehicleList"
                  :key="vehicle.vehicleId"
                  type="button"
                  class="selector-pill"
                  :class="{ active: isActiveVehicle(vehicle.vehicleId), locked: vehicle.damageLocked }"
                  :title="vehicle.vehicleName"
                  @mousedown.stop
                  @click.stop="selectVehicle(vehicle.vehicleId)"
                >
                  <span class="pill-name">{{ vehicle.vehicleName }}</span>
                  <span v-if="vehicle.damageLocked" class="pill bad pill-status">Damaged</span>
                </button>
              </div>
            </div>
            <div
              v-if="sessionStore.hasCapability('partsCustomization') && sessionStore.pulledOutVehicle"
              class="nav-section"
            >
              <div class="nav-section-title">{{ isCollapsed ? 'W' : 'WORKSHOP' }}</div>
              <ul class="nav-list">
                <li>
                  <button
                    type="button"
                    aria-label="Parts"
                    title="Parts"
                    :class="['nav-item', { active: sessionStore.vehicleView === 'parts', disabled: sessionStore.isDamageLocked }]"
                    :disabled="sessionStore.isDamageLocked"
                    :bng-no-nav="sessionStore.isDamageLocked ? 'true' : null"
                    @click.stop="computerStore.switchVehicleView('parts')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
                    </svg>
                    <span v-if="!isCollapsed">Parts</span>
                  </button>
                </li>
                <li>
                  <button
                    type="button"
                    aria-label="Tuning"
                    title="Tuning"
                    :class="['nav-item', { active: sessionStore.vehicleView === 'tuning', disabled: sessionStore.isDamageLocked }]"
                    :disabled="sessionStore.isDamageLocked"
                    :bng-no-nav="sessionStore.isDamageLocked ? 'true' : null"
                    @click.stop="computerStore.switchVehicleView('tuning')"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <circle cx="12" cy="12" r="3"/>
                      <path d="M12 1v6m0 6v6M5.64 5.64l4.24 4.24m4.24 4.24l4.24 4.24M1 12h6m6 0h6M5.64 18.36l4.24-4.24m4.24-4.24l4.24-4.24"/>
                    </svg>
                    <span v-if="!isCollapsed">Tuning</span>
                  </button>
                </li>
              </ul>
            </div>
            <div v-if="sessionStore.pulledOutVehicle" class="nav-section">
              <ul class="nav-list">
                <li v-if="sessionStore.hasCapability('fleetVehicles') && skillsStore.hasPitFuelSkill">
                  <button
                    class="nav-item"
                    :title="'Refuel this vehicle from the shop stockpile'"
                    @click.stop="handleRefuelActiveVehicle"
                    @mousedown.stop
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M3 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18"/>
                      <path d="M3 14h12"/>
                      <path d="M3 22h14"/>
                      <path d="M18 7h1a2 2 0 0 1 2 2v7a2 2 0 0 1-4 0v-4h-2"/>
                      <path d="M18 5v2"/>
                    </svg>
                    <span v-if="!isCollapsed">Refuel</span>
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </aside>

        <main v-if="!sessionStore.vehicleView" class="main-content" v-bng-scoped-nav="contentScope">
          <div :class="['content-body', { 'skill-tree-content-body': activeTab?.component === 'BusinessSkillTreeTab' }]" v-bng-ui-nav-scroll>
            <component
              :is="activeTabComponent"
              v-if="activeTabComponent"
              :data="activeTabData"
            />
          </div>
        </main>
      </div>
    </BngCard>

    <div v-else class="loading">
      Loading...
    </div>
    </template>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { ref, onMounted, onUnmounted, watch, nextTick, Teleport, computed } from "vue"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import { useBusinessRacingTeamStore } from "../stores/businessComputer/businessRacingTeamStore.js"
import { useBusinessSessionStore } from "../stores/businessComputer/businessSessionStore.js"
import { useBusinessSkillsStore } from "../stores/businessComputer/businessSkillsStore.js"
import { useBusinessVehiclesStore } from "../stores/businessComputer/businessVehiclesStore.js"
import BusinessHomeView from "../components/businessComputer/BusinessHomeView.vue"
import BusinessInventoryTab from "../components/businessComputer/BusinessInventoryTab.vue"
import BusinessAccountBalance from "../components/businessComputer/BusinessAccountBalance.vue"
import BusinessMaintenanceModal from "../components/businessComputer/BusinessMaintenanceModal.vue"
import RacingTeamPromoPanel from "../components/RacingTeamPromoPanel.vue"
import BusinessWorkshopParts from "./BusinessWorkshopParts.vue"
import BusinessWorkshopTuning from "./BusinessWorkshopTuning.vue"
import { getBusinessTabComponent } from "../utils/businessTypeCatalog"
import { businessTypesReady, retryBusinessTypesWhileMounted } from "../utils/businessTypeCatalog.js"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"
import { BngCard, BngBinding, BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseActionHint } from "../components/house/index.js"
import { revealNextControl } from "../components/businessComputer/bcEdgeScroll.js"
import { vBngBlur, vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { useScopedNav } from "@/services/scopedNav/api"
import { bcModalScope, vBcModalFocus } from "../components/businessComputer/bcModalNav"
import { normalizeId } from "../utils/businessUtils"

const props = defineProps({
  businessType: String,
  businessId: String
})

const computerStore = useBusinessComputerStore()
const racingTeamStore = useBusinessRacingTeamStore()
const sessionStore = useBusinessSessionStore()
const skillsStore = useBusinessSkillsStore()
const vehiclesStore = useBusinessVehiclesStore()
const businessComputerReady = computed(() => !sessionStore.loading && businessTypesReady.value)
const league2InviteUi = computed(() => sessionStore.businessData?.league2Invite || {})
const showLeague2InviteComputerPopup = computed(
  () => sessionStore.hasCapability('goals') && league2InviteUi.value?.computerPopup === true
)
const onLeague2InviteLater = async () => {
  const bid = sessionStore.businessId
  if (!bid) return
  try {
    await racingTeamStore.racingTeamLeague2InviteLater()
  } catch (e) { reportUiFailure(e, "on league2 invite later (BusinessComputerMain)") }
  computerStore.switchView("jobs")
}

const onLeague2InviteAccept = async () => {
  await racingTeamStore.acceptLeague2Invite()
}

const isCollapsed = ref(false)
const isVehicleViewCollapsed = ref(false)
const isVehicleSidebarCollapsed = ref(true)
const containerRef = ref(null)

// A tab's icon comes from its registered data: a stock bngIcons name ("engine") or inline 24-grid SVG markup
// (the older form some tabs still use). A missing or unknown name gets a neutral glyph so every row keeps its icon.
const FALLBACK_TAB_ICON = "tiles"
const sidebarIcon = (tab) => {
  const icon = typeof tab?.icon === "string" ? tab.icon.trim() : ""
  if (icon.startsWith("<")) return { svg: icon }
  return { glyph: Object.hasOwn(icons, icon) ? icon : FALLBACK_TAB_ICON }
}
// resolved once per tab list change, not on every row render; keyed by the tab itself (the rows are the same objects)
const tabIcons = computed(() => new Map((sessionStore.registeredTabs || []).map(tab => [tab, sidebarIcon(tab)])))

// ---- controller navigation (the game's crossfire + scoped nav; no custom focus layer) ----
const league2InviteScope = bcModalScope("league2-invite")

const cardEl = () => containerRef.value?.$el || containerRef.value || null
const navTabs = computed(() => (sessionStore.registeredTabs || []).filter(tab => !tab?.action))
const tabCount = computed(() => navTabs.value.length)

// the sidebar row of the open tab (or the first row): where focus goes on entry, after LB/RB and on B
const focusActiveTab = () => {
  const el = cardEl()
  const target = el?.querySelector(".sidebar .tab-item.active") || el?.querySelector(".sidebar .tab-item")
  return target ? setFocus(target) : false
}

const navigateToPreviousTab = () => {
  if (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning') {
    return
  }
  const tabs = navTabs.value
  if (tabs.length === 0) return
  const currentIdx = tabs.findIndex(t => t.id === sessionStore.activeView)
  const prevIdx = currentIdx <= 0 ? tabs.length - 1 : currentIdx - 1
  computerStore.switchView(tabs[prevIdx].id)
  // the old tab's content unmounts; park focus on the new tab's sidebar row instead of losing it
  nextTick(focusActiveTab)
}

const onSidebarTabClick = async (tab) => {
  if (!tab) return
  if (tab.action && sessionStore.hasCapability('fullscreenComputer') && sessionStore.businessId) {
    try {
      await lua.overhaul_career_business_computer.performEngineShopAction(tab.action, sessionStore.businessId)
    } catch (error) { reportUiFailure(error, "on sidebar tab click (BusinessComputerMain)") }
    return
  }
  computerStore.switchView(tab.id)
}

const navigateToNextTab = () => {
  if (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning') {
    return
  }
  const tabs = navTabs.value
  if (tabs.length === 0) return
  const currentIdx = tabs.findIndex(t => t.id === sessionStore.activeView)
  const nextIdx = currentIdx >= tabs.length - 1 ? 0 : currentIdx + 1
  computerStore.switchView(tabs[nextIdx].id)
  nextTick(focusActiveTab)
}

const onTabNav = (event) => {
  // a dialog rendered inside a tab (not teleported) must not lose its tab under it
  if (document.activeElement?.closest?.(".modal")) return false
  const name = event?.detail?.name
  if (name === "tab_l") navigateToPreviousTab()
  else if (name === "tab_r") navigateToNextTab()
  return false
}

// B: from the tab content (or with focus lost) step back to the sidebar first; from the sidebar/header close.
// Inner owners (modals, expanded rows) consume B before it reaches here.
// B in the tab content: back to the sidebar row of the open tab (inner owners such as modals and expanded
// rows consume B before it gets here); without a pad there is no focus to move, so close as before.
const onContentBack = () => {
  if (!focusActiveTab()) close()
  return false
}
// B in the sidebar closes the computer
const onSidebarBack = () => {
  close()
  return false
}

// The business modals are teleported to <body>, so opening one makes the scope coordinator deactivate the
// pane it came from (the pane is not their parent) and closing it leaves no active scope and focus on
// <body>: the d-pad goes dead and B falls through to the router (seen in the UI Atlas). When a bc-modal
// scope closes, put focus back on the control that opened it (focusing it re-activates its pane scope),
// else on the active sidebar tab; without a pad just re-activate the sidebar scope.
let lastCardFocus = null
const onCardFocusIn = (event) => {
  const el = event.target
  if (el && !el.closest?.(".modal")) lastCardFocus = el
}
const bridgeEvents = useEvents()
let refocusTimer = null
let modalOpener = null
const onNavScopeChanged = ({ scopeId, previousScope } = {}) => {
  const opening = String(scopeId || "").startsWith("bc-modal-")
  if (opening && !String(previousScope || "").startsWith("bc-modal-")) modalOpener = lastCardFocus
  if (!String(previousScope || "").startsWith("bc-modal-") || opening) return
  if (scopeId && scopeId !== SIDEBAR_SCOPE_ID && scopeId !== CONTENT_SCOPE_ID) return
  clearTimeout(refocusTimer)
  refocusTimer = setTimeout(() => {
    const el = cardEl()
    if (!el) return
    // (focus may still sit in the closing modal: it stays in the DOM for its leave transition)
    const active = document.activeElement
    // the coordinator may resume the sidebar scope (its last active row) instead: prefer the opener
    const opener = modalOpener && el.contains(modalOpener) && !modalOpener.disabled ? modalOpener : null
    modalOpener = null
    if (opener && (active === opener || setFocus(opener))) return
    if (active && active !== document.body && el.contains(active) && !active.closest(".modal")) return
    if (focusActiveTab()) return
    const nav = useScopedNav()
    if (nav.getScopeById(SIDEBAR_SCOPE_ID) && !nav.isActiveScope(SIDEBAR_SCOPE_ID)) nav.activateScope(SIDEBAR_SCOPE_ID)
  }, 30)
}

const SIDEBAR_SCOPE_ID = "business-computer-sidebar"
const CONTENT_SCOPE_ID = "business-computer-content"
// Two side-by-side container scopes. Without preventNavigationEscape top/bottom, crossfire happily jumped
// from a content button down/up to whichever sidebar row was nearest (Jobs: Race recognition -> Kits), and
// right from the content landed on the header Close button (Race offer detail: A then closed the computer).
// So only sidebar -> right and content -> left cross; Close stays a mouse control (B closes on a pad).
// LB/RB must bubble out of either pane to the card's handler.
const PANE_BUBBLE_EVENTS = ["tab_l", "tab_r"]
const sidebarScope = {
  scopeId: SIDEBAR_SCOPE_ID,
  type: "container",
  activateOnMount: true, // entry focus: the active tab row (bng-scoped-nav-autofocus)
  preventNavigationEscape: ["top", "bottom", "left"],
  bubbleWhitelistEvents: PANE_BUBBLE_EVENTS,
  canDeactivate: onSidebarBack,
}
const contentScope = {
  scopeId: CONTENT_SCOPE_ID,
  type: "container",
  preventNavigationEscape: ["top", "bottom", "right"],
  bubbleWhitelistEvents: PANE_BUBBLE_EVENTS,
  canDeactivate: onContentBack,
  onPreventedNavigationEscape: ({ direction, element }) => revealNextControl(element, direction),
}

const vehicleList = computed(() => Array.isArray(sessionStore.pulledOutVehicles) ? sessionStore.pulledOutVehicles : [])
const isActiveVehicle = (vehicleId) => {
  return normalizeId(vehicleId) === normalizeId(sessionStore.activeVehicleId)
}
const selectVehicle = async (vehicleId) => {
  await computerStore.setActiveVehicleSelection(vehicleId)
}

const showMaintenanceModal = ref(false)
const vehicleToMaintain = ref(null)

const rtVehicleDisplayName = (vehicle) => {
  if (!vehicle) return "Vehicle"
  return vehicle.vehicleName || vehicle.name || `Vehicle #${vehicle.vehicleId ?? ""}`
}

const rtWorkshopCollapsedTitle = (vehicle) => {
  const name = rtVehicleDisplayName(vehicle)
  const trimmed = name.trim()
  if (!trimmed) return "V"
  const firstWord = trimmed.split(/\s+/)[0]
  return firstWord.length > 8 ? `${firstWord.slice(0, 8)}…` : firstWord
}

const isRtPartsTuningDisabled = (vehicle) => {
  if (vehicle?.damageLocked) return true
  if (isActiveVehicle(vehicle?.vehicleId) && sessionStore.isDamageLocked) return true
  return false
}

const isRtWorkshopLinkActive = (vehicle, action) => {
  if (!isActiveVehicle(vehicle?.vehicleId)) return false
  if (action === "parts") return sessionStore.vehicleView === "parts"
  if (action === "tuning") return sessionStore.vehicleView === "tuning"
  if (action === "maintain") {
    return (
      showMaintenanceModal.value
      && normalizeId(vehicleToMaintain.value?.vehicleId) === normalizeId(vehicle?.vehicleId)
    )
  }
  return false
}

const isTsWorkshopLinkActive = (vehicle, view) => {
  if (!vehicle || sessionStore.vehicleView !== view) return false
  return normalizeId(vehicle.vehicleId) === normalizeId(sessionStore.activeVehicleId)
}

const openTsWorkshop = async (vehicle, action) => {
  if (!vehicle) return
  const vid = vehicle.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  await computerStore.setActiveVehicleSelection(vid)
  if (action === "parts" || action === "tuning") {
    await computerStore.switchVehicleView(action)
  }
}

const openRtWorkshop = async (vehicle, action) => {
  if (!vehicle) return
  const vid = vehicle.vehicleId
  if (vid === undefined || vid === null || vid === "") return
  await computerStore.setActiveVehicleSelection(vid)
  if (action === "parts") {
    await computerStore.switchVehicleView("parts")
    return
  }
  if (action === "tuning") {
    await computerStore.switchVehicleView("tuning")
    return
  }
  if (action === "paint") {
    await vehiclesStore.startVehiclePainting(vid)
    return
  }
  if (action === "maintain") {
    vehicleToMaintain.value = vehicle
    showMaintenanceModal.value = true
  }
}

const onMaintenanceModalClosed = () => {
  vehicleToMaintain.value = null
}

const handleRefuelActiveVehicle = async () => {
  const vid = sessionStore.activeVehicleId
    ?? sessionStore.pulledOutVehicle?.vehicleId
    ?? sessionStore.pulledOutVehicle?.id
  if (vid === undefined || vid === null || vid === "") return
  await vehiclesStore.startVehicleRefueling(vid)
}

const activeTab = computed(() => {
  return sessionStore.registeredTabs.find(tab => tab.id === sessionStore.activeView) || null
})

const activeTabComponent = computed(() => {
  if (!activeTab.value) {
    return null
  }
  const component = getBusinessTabComponent(activeTab.value.component)
  return component
})

const activeTabData = computed(() => {
  if (!activeTab.value) return null
  return {
    ...activeTab.value.data,
    businessId: sessionStore.businessId,
    businessType: sessionStore.businessType
  }
})

watch(() => sessionStore.registeredTabs, (tabs) => {
  if (tabs.length > 0 && sessionStore.activeView === 'home' && !tabs.find(t => t.id === 'home')) {
    computerStore.switchView(tabs[0].id)
  }
}, { immediate: true })

watch(() => sessionStore.vehicleView, (newView) => {
  if (!newView || (newView !== 'parts' && newView !== 'tuning')) {
    isVehicleViewCollapsed.value = false
    isVehicleSidebarCollapsed.value = true
  }
})

watch(() => isVehicleViewCollapsed.value, async (collapsed) => {
  if (!containerRef.value || !sessionStore.vehicleView) return

  const container = containerRef.value.$el || containerRef.value
  const header = container.querySelector('.main-header')
  if (!header) return

  const headerHeight = header.offsetHeight
  const fullHeight = window.innerHeight * 0.85

  if (collapsed) {
    container.style.height = fullHeight + 'px'
    container.style.transition = 'height 0.4s ease'
    await nextTick()
    requestAnimationFrame(() => {
      container.style.height = headerHeight + 'px'
    })
  } else {
    container.style.height = headerHeight + 'px'
    container.style.transition = 'height 0.6s ease'
    await nextTick()
    requestAnimationFrame(() => {
      container.style.height = fullHeight + 'px'
      setTimeout(() => {
        container.style.height = ''
        container.style.transition = ''
      }, 600)
    })
  }
})

const close = async () => {
  isVehicleViewCollapsed.value = false

  if (containerRef.value) {
    const container = containerRef.value.$el || containerRef.value
    container.style.height = ''
    container.style.transition = ''
  }

  computerStore.onMenuClosed()
  lua.overhaul_career_career.closeAllMenus()
}

const start = async () => {
  if (props.businessType && props.businessId) {
    await sessionStore.loadBusinessData(props.businessType, props.businessId)
  }
}

const kill = () => {
  if (sessionStore.vehicleView === 'parts' || sessionStore.vehicleView === 'tuning') {
    try {
      const p = computerStore.closeVehicleView()
      if (p && typeof p.catch === 'function') {
        p.catch(error => reportUiFailure(error, "kill (BusinessComputerMain)"))
      }
    } catch (error) { reportUiFailure(error, "kill (BusinessComputerMain)") }
  }
  computerStore.onMenuClosed()
}

let stopCatalogRetries = () => {}
onMounted(() => {
  bridgeEvents.on("uiNav_scopeChanged", onNavScopeChanged)
  start()
  stopCatalogRetries = retryBusinessTypesWhileMounted()
})
onUnmounted(() => {
  stopCatalogRetries()
  bridgeEvents.off("uiNav_scopeChanged", onNavScopeChanged)
  clearTimeout(refocusTimer)
  kill()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Business computer shell, house style: near-black card carrying .rls-house (tokens + em scale for
   every tab inside), bold title + quiet close, sidebar of quiet rows under Style Guide captions. */

.business-computer-wrapper {
  position: fixed;
  bottom: 2em;
  left: 2em;
  width: auto;
  height: auto;
  max-width: calc(100vw - 4em);
  max-height: calc(85vh - 2em);
  display: flex;
  flex-direction: column;
  background: transparent;
  padding: 0;
  overflow: hidden;
  z-index: 1000;

  &.workshop {
    inset: 0;
    width: 100vw;
    height: 100vh;
    max-width: none;
    max-height: none;
    overflow: visible;
  }

  &.engine-shop-fullscreen:not(.workshop) {
    inset: 1em;
    width: calc(100vw - 2em);
    height: calc(100vh - 2em);
    max-width: none;
    max-height: none;
  }
}

.business-computer-container {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  width: 60em;
  height: 85vh;
  background: rgba(21, 21, 23, 0.94);
  border: none;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 1em 3em rgba(0, 0, 0, 0.45);
  color: #fff;
  overflow: hidden;
  // the workshop collapse/expand script drives width/height inline; this only eases the vehicle-view width swap
  transition: width 0.4s ease, transform 0.4s ease;

  &.engine-shop-fullscreen:not(.vehicle-view) {
    width: 100%;
    height: 100%;
    max-width: none;
    max-height: none;
  }

  &.vehicle-view {
    width: 32em;

    &.collapsed {
      position: fixed;
      bottom: 0;
      left: 2em;
      height: auto;
      width: 32em;
      transform: translateY(0);
    }

    &.vehicle-sidebar-expanded {
      width: 42em;
    }
  }
}

/* ---------- header ---------- */
.main-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  padding: 0.8em 0.85em 0.75em 1.25em;
  border-bottom: 1px solid var(--line);
  background: transparent;
  flex-shrink: 0;

  &.collapsed {
    border-bottom: none;
    border-top: 1px solid var(--line);
    border-radius: var(--radius-control) var(--radius-control) 0 0;
  }

  .bc-title {
    margin: 0;
    min-width: 0;
    color: #fff;
    font-size: 1.3em;
    font-weight: 800;
    letter-spacing: -0.01em;
    line-height: 1.15;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    flex: 0 0 auto;
  }

  .collapse-toggle-vehicle {
    @include house-focus;
    appearance: none;
    display: grid;
    place-items: center;
    width: 2.2em;
    height: 2.2em;
    margin: 0;
    padding: 0;
    background: transparent;
    border: none;
    border-radius: var(--radius-control);
    color: var(--muted);
    cursor: pointer;
    transition: background-color 0.12s, color 0.12s;

    &:hover {
      color: #fff;
      background: var(--panel);
    }

    svg {
      width: 1.25em;
      height: 1.25em;
    }
  }
}

.close-button {
  color: var(--muted);

  &:hover:not(:disabled) {
    color: #fff;
  }
}

/* ---------- layout ---------- */
.content-layout {
  display: flex;
  flex: 1;
  gap: 0;
  padding: 0;
  overflow: hidden;
  min-height: 0;

  &.vehicle-view {
    .main-content,
    .parts-panel,
    .tuning-panel {
      width: 100%;
    }
  }
}

.sidebar,
.vehicle-sidebar {
  width: 14em;
  background: transparent;
  border: none;
  border-right: 1px solid var(--line);
  border-radius: 0;
  display: flex;
  flex-direction: column;
  flex-shrink: 0;

  &.collapsed {
    width: 4em;
  }
}

.sidebar-header {
  display: flex;
  align-items: center;
  border-bottom: 1px solid var(--line);
  padding: 0;
}

/* LB / RB glyphs either side of the collapse toggle (BngBinding renders nothing without a pad) */
.tab-bind {
  flex: 0 0 auto;
  font-size: 0.9em;
  margin: 0 0.45em;
}
.sidebar.collapsed .tab-bind {
  display: none;
}

.collapse-toggle {
  @include house-focus(var(--focus-inset));
  appearance: none;
  flex: 1 1 auto;
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 0;
  padding: 0.65em;
  background: transparent;
  border: none;
  color: var(--faint);
  cursor: pointer;
  transition: color 0.12s, background-color 0.12s;

  &:hover {
    color: #fff;
    background: var(--panel);
  }

  svg {
    flex-shrink: 0;
    width: 1.25em;
    height: 1.25em;
  }
}

.sidebar-nav {
  flex: 1;
  overflow-y: auto;
  padding: 0.5em 0;

  &::-webkit-scrollbar { width: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
}

.nav-section {
  margin-bottom: 0.85em;
}

/* Style Guide caption */
.nav-section-title {
  padding: 0.55em 1.3em 0.4em;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--faint);
  text-align: left;
}

.sidebar.collapsed .nav-section-title,
.vehicle-sidebar.collapsed .nav-section-title {
  text-align: center;
  padding-left: 0;
  padding-right: 0;
}

.nav-list {
  list-style: none;
  padding: 0;
  margin: 0;
}

/* quiet rows with a plain glyph; active = a touch brighter panel + accent-soft text */
.nav-item {
  @include house-focus(var(--focus-inset));
  appearance: none;
  width: calc(100% - 1em);
  margin: 0.1em 0.5em;
  display: flex;
  align-items: center;
  gap: 0.7em;
  padding: 0.62em 0.6em 0.5em;
  background: transparent;
  border: none;
  border-radius: var(--radius-panel);
  color: var(--muted);
  font: inherit;
  font-size: 0.95em;
  font-weight: 600;
  line-height: 1.2;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s, color 0.12s;

  svg {
    flex-shrink: 0;
    width: 1.2em;
    height: 1.2em;
    transform: translateY(-0.05em);
  }

  /* stock glyphs: coloured by the row (muted, hover white, active accent) */
  .nav-glyph {
    --bng-icon-size: 1.2em; /* of the row's font, like the SVG's 1.2em box */
    --bng-icon-color: currentColor;
    flex-shrink: 0;
    width: 1em; /* the glyph's own font-size, so the same 1.2em of the row */
    text-align: center;
    transform: translateY(-0.05em);
  }

  &:hover {
    background: var(--panel);
    color: #fff;
  }

  &.active {
    background: var(--panel-2);
    color: var(--accent-soft);
  }

  &.disabled,
  &:disabled {
    opacity: 0.4;
    cursor: default;
    pointer-events: none;
  }
}

.sidebar.collapsed .nav-item,
.vehicle-sidebar.collapsed .nav-item {
  justify-content: center;
  gap: 0;
}

/* racing team / tuning shop per-vehicle workshop groups */
.rt-workshop-section {
  margin: 0 0.5em 0.5em;
  background: var(--panel);
  border-radius: var(--radius-panel);
  overflow: hidden;
}

.rt-workshop-vehicle-title {
  padding: 0.6em 0.75em 0.45em;
  text-transform: none;
  letter-spacing: normal;
  font-size: 0.88em;
  font-weight: 700;
  color: #fff;
  line-height: 1.25;
  overflow-wrap: anywhere;
  /* long vehicle names: two lines, then ellipsis */
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.rt-workshop-section .nav-list {
  margin: 0;
  padding: 0 0 0.35em;
}

.nav-item--workshop-link {
  width: calc(100% - 0.7em);
  margin: 0.05em 0.35em;
  padding-left: 0.65em;
  font-size: 0.9em;
}

/* garage vehicle chips: neutral panel rows, the active one in accent-soft text */
.garage-selector {
  padding: 0.75em 0.5em 0.5em;
  border-top: 1px solid var(--line);
  display: flex;
  flex-direction: column;
  gap: 0.15em;

  .selector-title {
    padding-left: 0.8em;
    padding-right: 0.8em;
  }

  .selector-pills {
    display: flex;
    flex-direction: column;
    gap: 0.3em;
  }

  .selector-pill {
    @include house-focus(var(--focus-inset));
    appearance: none;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5em;
    width: 100%;
    margin: 0;
    padding: 0.6em 0.65em 0.48em;
    border: none;
    border-radius: var(--radius-panel);
    background: var(--panel);
    color: var(--muted);
    font: inherit;
    font-size: 0.9em;
    font-weight: 600;
    line-height: 1.25;
    text-align: left;
    cursor: pointer;
    transition: background-color 0.12s, color 0.12s;

    &:hover {
      background: var(--panel-2);
      color: #fff;
    }

    &.active {
      background: var(--panel-2);
      color: var(--accent-soft);
    }

    .pill-name {
      flex: 1 1 auto;
      min-width: 0;
      overflow-wrap: anywhere;
      /* long vehicle names: two lines, then ellipsis */
      display: -webkit-box;
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 2;
      line-clamp: 2;
      overflow: hidden;
    }

    .pill-status {
      flex: 0 0 auto;
    }
  }

  &.collapsed {
    padding: 0.6em 0.35em;

    .selector-pill {
      justify-content: center;
      padding: 0.5em 0.3em 0.4em;
      font-size: 0.7em;
    }

    .pill-name {
      display: block;
      overflow: hidden;
      white-space: nowrap;
      text-align: center;
    }

    .pill-status {
      display: none;
    }
  }
}

/* ---------- content ---------- */
.main-content,
.vehicle-panel,
.parts-panel,
.tuning-panel {
  flex: 1;
  background: transparent;
  border: none;
  border-radius: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 0;
}

.vehicle-panel {
  max-width: 28em;
  flex-shrink: 0;
}

.parts-panel,
.tuning-panel {
  width: 100%;
  flex-shrink: 0;
}

.content-body {
  flex: 1;
  overflow-y: auto;
  padding: 1.25em;
  background: transparent;

  &::-webkit-scrollbar { width: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
  &::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
}

.content-body.skill-tree-content-body {
  padding: 0;
}

.loading {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  font-weight: 600;
}

.panel-collapse-enter-active,
.panel-collapse-leave-active {
  transition: opacity 0.2s ease;
}

.panel-collapse-enter-from,
.panel-collapse-leave-to {
  opacity: 0;
}

</style>

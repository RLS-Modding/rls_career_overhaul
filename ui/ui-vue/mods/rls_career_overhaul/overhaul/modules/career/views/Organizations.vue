<template>
  <LayoutMenu
    class="organizations-layout"
    nav-scope="root"
    :nav-active="false"
    :nav-auto-focus="true"
    :breadcrumbs="breadcrumbItems"
    :hide-breadcrumb-last-item="false"
    @breadcrumb-click="breadcrumbClick"
    @breadcrumb-back="onBreadcrumbBack"
  >
    <template #heading>
      <BngScreenHeadingV2 type="2">{{ $translate.instant("ui.career.organizations.title") }}</BngScreenHeadingV2>
    </template>

    <template #topbar-right>
      <BngCard class="status-container" v-bng-blur="true">
        <CareerStatus class="career-page-status" ref="careerStatusRef" />
      </BngCard>
    </template>

    <div class="organizations-card" v-bng-blur>
      <div class="organizations-container">
        <div class="general-info">
          <div class="text">
            <div>
              {{ $translate.instant("ui.career.organizations.introReputation") }}
            </div>
            <div>
              {{ $translate.instant("ui.career.organizations.introLoaners") }}
            </div>
          </div>
          <template v-if="!selectedOrganization">
            <div class="card-wrapper selectedOrg">
              <div class="header">
                <div class="name">
                  {{ $translate.instant("ui.career.organizations.clickToViewDetails") }}
                </div>
                <BngIcon class="glyph" :type="icons.peopleOutline" />
              </div>
            </div>
          </template>
          <OrganizationCard v-else
            :organization="selectedOrganization"
            :detail="true"
            @click="openOrganizationPage()"
            />
        </div>

        <div class="scrollable-container" v-bng-ui-nav-scroll.force>
          <template v-for="level in reputationLevels">
            <template v-if="level.value >=-1 || (filteredOrganizationsByLevel[level.value] && filteredOrganizationsByLevel[level.value].length > 0)" >
              <div class="level-header" :class="'level-' + level.levelClass">
                <div class="label" v-if="level.value >= -1">
                  {{ $translate.instant("ui.career.organizations.levelLabel", { label: level.label, level: level.value }) }}
                </div>
                <div class="label"  v-else>
                  {{ $translate.instant("ui.career.organizations.undiscovered") }}
                </div>
                <div class="info" v-if="level.bonus">
                  <BngPropVal :iconType="icons.beamCurrency" :valueLabel="level.bonus" :keyLabel="$translate.instant('ui.career.organizations.deliveryRewards')" />
                </div>
              </div>

              <div class="cards-container" v-if="(filteredOrganizationsByLevel[level.value] && filteredOrganizationsByLevel[level.value].length > 0)">
                <OrganizationCard
                  tabindex="1"
                  bng-nav-item
                  v-for="organization in filteredOrganizationsByLevel[level.value]"
                  :key="organization.id"
                  :organization="organization"
                  v-bng-sound-class="organization.visible ? 'bng_hover_generic': ''"
                  v-bng-on-ui-nav:ok.asMouse
                  @click="openOrganizationPage(organization.id)" />

              </div>
              <div v-else> </div>
            </template>
          </template>
        </div>
      </div>
    </div>
  </LayoutMenu>
</template>

<script setup>
import { useUINavTracker } from "@/services/uiNavTracker"
import { SCROLL_EVENT_H, SCROLL_EVENT_V } from "@/services/crossfire"
import { LayoutMenu } from "@/common/layouts"
import { BngScreenHeadingV2, BngIcon, icons, BngCard, BngPropVal } from "@/common/components/base"
import { vBngBlur, vBngOnUiNav, vBngSoundClass, vBngUiNavScroll } from "@/common/directives"
import OrganizationCard from "@/modules/career/components/organizations/OrganizationCard.vue"
import CareerStatus from "../components/careerStatus.vue"
import { lua } from "@/bridge"
import { ref, onMounted, onUnmounted, computed } from "vue"

import { useRouteDataStore } from "@/services/routeData"
import { $translate } from "@/services/translation"

const props = defineProps({
  orgId: String,
})
const routeDataStore = useRouteDataStore()
const breadcrumbItems = computed(() => routeDataStore.breadcrumbs || [])

const careerStatusRef = ref()
const organizations = ref([])
const selectedOrgId = ref("")
const reputationLevels = computed(() => [
  { value: 3, levelClass: "Partner", label: $translate.instant("ui.career.organizations.reputation.partner"), color: '#00f', bonus:"+40%" },
  { value: 2, levelClass: "Preferred", label: $translate.instant("ui.career.organizations.reputation.preferred"), color: '#0f0',bonus:"+20%" },
  { value: 1, levelClass: "Reliable", label: $translate.instant("ui.career.organizations.reputation.reliable"), color: '#ff0', bonus:"+10%" },
  { value: 0, levelClass: "Neutral", label: $translate.instant("ui.career.organizations.reputation.neutral"), color: '#f00', bonus:"+0%" },
  { value: -1, levelClass: "Questionable", label: $translate.instant("ui.career.organizations.reputation.questionable"), color: '#999', bonus:"-10%" },
  { value: -2, levelClass: "Undiscovered", label: $translate.instant("ui.career.organizations.reputation.undiscovered"), color: '#999' },
]);// Filter organizations by level
// Create a computed property to filter organizations by each level
const filteredOrganizationsByLevel = computed(() => {
  // Create an object to hold arrays of organizations for each level
  const levelMap = {};
  // Initialize arrays for each level
  reputationLevels.value.forEach(level => {
    levelMap[level.value] = [];
  });

  // Populate the arrays with organizations filtered by level
  organizations.value.forEach(org => {
    if (!org.visible) {
      // Assign to "Facilities" level if not visible
      levelMap[-2].push(org);
    } else if (levelMap[org.reputation.level] !== undefined) {
      // Assign to other levels based on reputation
      levelMap[org.reputation.level].push(org);
    }
  });

  return levelMap;
});




const selectedOrganization = computed(() => {
  if (!selectedOrgId.value) {
    return undefined
  }

  for (let organization of organizations.value) {
    if (organization.id == selectedOrgId.value) {
      return organization
    }
  }

  return undefined
})

function setup(data) {
  organizations.value = data
  organizations.value.sort((a,b) => {
    if (a.visible === b.visible)
      return a.name < b.name
    else
      return a.visible ? -1 : 1
  })
}

lua.overhaul_world_organizations.getUIData().then(setup)

const openOrganizationPage = organizationId => {
  if(organizationId == selectedOrgId.value) {
    selectedOrgId.value = null
  } else {
    selectedOrgId.value = organizationId
  }
}

async function breadcrumbClick(item) {
  if (!item) return
  if (item.closeAllMenus) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  if (item.routeName && !item.abstract) {
    await lua.extensions.ui_router.navigate(item.routeName, item.params)
  }
}

const onBreadcrumbBack = () => {
  lua.extensions.ui_router.back()
}

// Keep the existing action bar while enabling right-stick scrolling.
const scrollHints = useUINavTracker()
const scrollHintOwner = "overhaul-organizations-scroll"
onMounted(() => {
  for (const event of [SCROLL_EVENT_H, SCROLL_EVENT_V]) scrollHints.addIgnore(event, scrollHintOwner)
})
onUnmounted(() => {
  for (const event of [SCROLL_EVENT_H, SCROLL_EVENT_V]) scrollHints.removeIgnore(event, scrollHintOwner)
})

const start = () => {
  if (props.orgId) {
    selectedOrgId.value = props.orgId
  }
}

onMounted(start)
</script>

<style lang="scss" scoped>
$textcolor: #fff;
$fontsize: 1rem;

hr {
  margin: 0.5em;
  border: none;
  border-top: 1px solid var(--bng-cool-gray-600);
}

.organizations-layout {
  color: $textcolor;
  font-size: $fontsize;
}

.status-container {
  border-radius: var(--bng-corners-2);
  color: white;
  align-self: flex-start;
  flex: 0 0 auto;
}

.career-page-status {
  padding: 0.5rem 0.75rem 0.5rem 0.5rem;
  font-weight: 800;
  display: flex;
  justify-content: center;
  align-items: center;
}

.organizations-card {
  display: flex;
  flex: 1 1 auto;
  height: 100%;
  max-width: 80em;
  overflow: hidden;
}

.organizations-container {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  color: $textcolor;

  background: rgba(0, 0, 0, 0.8);
  border-radius: var(--bng-corners-3);
  overflow: hidden;
  width: 100%;
}

.scrollable-container {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: scroll;
  padding: 0.5rem 0;
}

.description {
  color: white;
}

.orgRewards {
  color: white;
  float: left;
  padding: 0.5em;
}

.selectedOrg {
  padding-left: 1em;
  width: fit-content;
}

.level-Partner {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-add-green-400-rgb),1) 0%,
    rgba(var(--bng-add-green-600-rgb),1) 0.25rem,
    rgba(var(--bng-add-green-600-rgb),0.5) 0.251rem,
    rgba(var(--bng-add-green-700-rgb),0.15) 100%,
  );
}
.level-Preferred {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-add-green-400-rgb),1) 0%,
    rgba(var(--bng-add-green-600-rgb),1) 0.25rem,
    rgba(var(--bng-add-green-600-rgb),0.5) 0.251rem,
    rgba(var(--bng-add-green-700-rgb),0.15) 100%,
  );
}
.level-Reliable {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-ter-yellow-400-rgb),1) 0%,
    rgba(var(--bng-ter-yellow-600-rgb),1) 0.25rem,
    rgba(var(--bng-ter-yellow-600-rgb),0.5) 0.251rem,
    rgba(var(--bng-ter-yellow-700-rgb),0.15) 100%,
  );
}
.level-Neutral {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-ter-yellow-400-rgb),1) 0%,
    rgba(var(--bng-ter-yellow-600-rgb),1) 0.25rem,
    rgba(var(--bng-ter-yellow-600-rgb),0.5) 0.251rem,
    rgba(var(--bng-ter-yellow-700-rgb),0.15) 100%,
  );
}
.level-Questionable {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-add-red-500-rgb),1) 0%,
    rgba(var(--bng-add-red-600-rgb),1) 0.25rem,
    rgba(var(--bng-add-red-700-rgb),0.5) 0.251rem,
    rgba(var(--bng-add-red-700-rgb),0.15) 100%,
  );
}
.level-Undiscovered {
   background-image: linear-gradient(180deg,
    rgba(var(--bng-cool-gray-700-rgb),1) 0%,
    rgba(var(--bng-cool-gray-700-rgb),1) 0.25rem,
    rgba(var(--bng-cool-gray-700-rgb),0.5) 0.251rem,
    rgba(var(--bng-cool-gray-700-rgb),0.15) 100%,
  );
}

.level-header {

   padding: 0.5rem 1rem;
   margin-bottom: 0.5rem;
   display: flex;
   .label {
    flex: 1 1 auto;
    font-size: 1.5rem;
    font-weight: 800;
   }
   .info {
    flex: 0 0 auto;
    font-size: 1.25rem;
   }
}

.cards-container {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(auto-fill, minmax(20em, 1fr));
  padding: 1rem;

  .no-organizations {
    opacity: 0.5;
  }
}

.general-info {
  flex: 0 0 auto;
  padding: 1rem;
  display: flex;
  flex-direction: row;
  gap: 2rem;
  > .text {
    font-size: 1.25rem;
    text-align: justify;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  > * {
    width: 50%;
  }

}

.card-wrapper {
  background-color: rgba(var(--bng-cool-gray-800-rgb), 0.9);
  border-radius: var(--bng-corners-2);
  flex: 1 1 auto;
  padding: 0.5rem;
  height: 100%;
  color: white;
  display: flex;
  flex-direction: column;


  > .header {
    padding-left: 0em;
    flex: 1 1 auto;
    align-items: auto;
    display: flex;
    flex-direction: row;
    > .name {
      font-weight: 800;
      font-size: 1.25rem;
      flex: 1 1 auto;
      padding-bottom: 0.75rem;
    }
    .glyph {
      font-size: 2rem;
      align-self: start;
    }

    .empty {
      opacity: 0.25;
      justify-content: center;
      align-items: center;
      font-weight: 50;
      color: rgba(var(--bng-cool-gray-300-rgb), 1);
    }
  }
  > .progress{
    align-items:flex-end;
    :deep(.progress-bar) {
      overflow: hidden;
      border-radius: var(--bng-corners-1);
    }
  }


  .center{
    flex: 1 1 auto;
    align-items:center;
    justify-content: center;
  }

}
</style>

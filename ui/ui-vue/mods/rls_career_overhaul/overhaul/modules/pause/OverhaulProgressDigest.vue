<template>
  <BngGroupPanel class="progress-digest" title="Skills">
    <div
      v-for="(domain, index) in domains"
      :key="domain.id"
      class="domain-btn-wrapper"
      @focusin="showDomainInfo(domain.id)"
      @focusout="hideDomainInfo(domain.id)"
      @mouseenter="showDomainInfo(domain.id)"
      @mouseleave="hideDomainInfo(domain.id)"
    >
      <Button
        class="domain-btn"
        :data-domain-id="domain.id"
        :style="getDomainStyle(domain)"
        :bng-scoped-nav-autofocus="isAutofocusDomain(domain.id, index) ? 'true' : null"
        @click="openDomain(domain.id)"
      >
        <div class="domain-btn-content">
          <div class="branch-icon-assembly" :class="{ 'is-locked': !domain.unlocked }">
            <div class="branch-background"></div>
            <BngIcon :type="icons[domain.unlocked ? domain.icon : 'lockClosed']" class="assembly-icon" />
          </div>
          <div class="domain-progress-content">
            <div class="domain-header">
              <span class="domain-name">{{ $ctx_t(domain.name) }}</span>
              <span class="domain-level">{{ getDomainLevel(domain) }}</span>
            </div>
            <BngProgressBar
              class="domain-progress"
              :value="getProgressValue(domain)"
              :min="0"
              :max="getProgressMax(domain)"
              :showValueLabel="false"
              valueColor="white"
            />
          </div>
        </div>
      </Button>
    </div>
  </BngGroupPanel>
</template>

<script setup>
import { computed, onMounted, ref } from "vue"
import { BngGroupPanel, BngIcon, BngProgressBar, icons } from "@/common/components/base"
import { Button } from "@/common/components/utility"
import { lua } from "@/bridge"
import "../career/utils/installLuaBridgeFallbacks.js"
import { $translate } from "@/services/translation"
import { focusedDomainId } from "./progressFocus.js"

defineOptions({ name: "OverhaulProgressDigest" })

// Skills cards use the canonical careerSkills root to exclude stock domain cards.
const SKILLS_ROOT_ID = "careerSkills"
const domains = ref([])

const fallbackDomainLevel = computed(() => $translate.contextTranslate({ txt: "ui.career.lvlLabel", context: { lvl: 0 } }))

function getProgressValue(domain) {
  if (domain.max === -1) return 1
  return Math.max(0, Number(domain.value || 0) - Number(domain.min || 0))
}

function getProgressMax(domain) {
  if (domain.max === -1) return 1
  return Math.max(1, Number(domain.max || 0) - Number(domain.min || 0))
}

function getDomainLevel(domain) {
  if (domain.isInDevelopment) return $translate.contextTranslate("ui.career.inDevelopment")
  if (!domain.unlocked) return $translate.contextTranslate("ui.career.locked")
  if (domain.levelLabel) return $translate.contextTranslate(domain.levelLabel)
  return fallbackDomainLevel.value
}

function getDomainStyle(domain) {
  const accentColor = normalizeCssColor(domain.accentColor || domain.color || "var(--bng-cool-gray-500-rgb)")
  return {
    "--domain-accent-color": accentColor,
  }
}

function normalizeCssColor(color) {
  if (!color) return "var(--bng-cool-gray-500)"
  if (color.startsWith("var(") && color.includes("-rgb)")) return `rgb(${color})`
  return color
}

function openDomain(domainId) {
  lua.extensions.ui_router.navigate("overhaul.branchPage", { pathId: domainId })
}

function isAutofocusDomain(domainId, index) {
  return index === 0
}

// the domain card keeps the last domain shown, as the career side panel does while a domain is focused
function showDomainInfo(domainId) {
  focusedDomainId.value = domainId
}

function hideDomainInfo() {}

onMounted(async () => {
  const page = await lua.overhaul_career_progression_skillsPage.getLandingPageData(SKILLS_ROOT_ID)
  const listed = Array.isArray(page?.branches) ? page.branches : Object.values(page?.branches || {})
  const skillIds = listed.map(entry => entry?.id).filter(Boolean)
  const loadedDomains = await Promise.all(
    skillIds.map(async id => {
      const data = await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(id)
      return data ? { ...data, id: data.id || id } : null
    })
  )
  domains.value = loadedDomains.filter(Boolean)
  if (domains.value.length > 0 && !domains.value.some(domain => domain.id === focusedDomainId.value)) {
    focusedDomainId.value = domains.value[0].id
  }
})
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.progress-digest {
  display: flex;
  flex-direction: column;
  color: var(--bng-off-white);
  margin: 0.5rem 0.5rem 0 0.5rem  ;
}

.domain-btn-wrapper {
  display: flex;
  width: 100%;
  padding: 0.25rem;
}

.domain-btn {
  @include modify-focus(var(--bng-corners-1), 0.0rem);
  --domain-icon-bg: var(--bng-cool-gray-600);
  --bng-content-flow: row;
  --bng-content-align: center;
  --bng-content-justify: flex-start;

  --bng-button-min-width: auto;
  --bng-button-max-width: 100%;
  --bng-button-padding: 0.5rem;
  --bng-button-padding-top: 0.5rem;
  --bng-button-padding-bottom: 0.5rem;

  --bng-bg-border-radius: var(--bng-corners-1);
  --bng-bg-border-width: 0.0625em;

  --bng-bg-enabled: var(--bng-cool-gray-750);
  --bng-bg-hover: var(--bng-cool-gray-700);
  --bng-bg-active: var(--bng-cool-gray-700);
  --bng-bg-disabled: var(--bng-cool-gray-700);
  --bng-bg-focus: var(--bng-cool-gray-700);

  --bng-bg-enabled-opacity: 0.60;
  --bng-bg-hover-opacity: 0.75;
  --bng-bg-active-opacity: 0.9;
  --bng-bg-disabled-opacity: 0.55;
  --bng-bg-focus-opacity: 0.85;

  --bng-bg-border-enabled: var(--bng-cool-gray-500);
  --bng-bg-border-hover: var(--bng-cool-gray-500);
  --bng-bg-border-active: var(--bng-cool-gray-500);
  --bng-bg-border-disabled: var(--bng-cool-gray-500);
  --bng-bg-border-focus: var(--bng-cool-gray-300);

  width: 100%;
  margin: 0;

  &:hover,
  &:focus,
  &.focus-visible {
    --domain-icon-bg: var(--domain-accent-color);

    .branch-background {
      background-color: var(--domain-accent-color);
    }
  }
}

.domain-btn-content {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
  width: 100%;
}

.branch-icon-assembly {
  position: relative;
  flex: 0 0 auto;
  height: 2.2em;
  width: 2.2em;
  display: flex;
  align-items: center;
  justify-content: center;

  &.is-locked {
    opacity: 0.6;
  }
}

.branch-background {
  position: absolute;
  top: -0.18rem;
  bottom: -0.18rem;
  left: -0.18rem;
  right: -0.18rem;
  mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
  -webkit-mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
  mask-repeat: no-repeat;
  -webkit-mask-repeat: no-repeat;
  mask-size: contain;
  -webkit-mask-size: contain;
  mask-position: 50% 50%;
  -webkit-mask-position: 50% 50%;
  background-color: var(--domain-icon-bg);
  transition: background-color 120ms ease;
  z-index: 1;
}

.assembly-icon {
  position: relative;
  font-size: 2.2em;
  font-style: normal;
  z-index: 2;
}

.domain-progress-content {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 0.35rem;
  min-width: 0;
}

.domain-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  min-width: 0;
  font-family: "Overpass", var(--fnt-defs);
  font-size: 1em;
  font-style: italic;
  line-height: 1.1;
}

.domain-name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  font-weight: 800;
  text-align: left;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.domain-level {
  flex: 0 0 auto;
  font-weight: 700;
  white-space: nowrap;
}

.domain-progress {
  width: 100%;
  padding-bottom: 0.1rem;

  :deep(.progress-bar) {
    height: 0.75rem;
    border-radius: var(--bng-corners-2);
  }
}
</style>

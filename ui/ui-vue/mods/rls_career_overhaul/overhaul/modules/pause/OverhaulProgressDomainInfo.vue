<template>
  <section v-if="domainInfo" class="progress-domain-info">
    <BngCardHeading type="ribbon" class="domain-heading">
      <div class="domain-heading-content">
        <span class="domain-heading-title">{{ $ctx_t(domainInfo.name) }}</span>
      </div>
    </BngCardHeading>
    <AspectRatio v-if="domainImageUrl" class="domain-image" :external-image="domainImageUrl" />
    <div v-if="domainDescription" class="domain-description">
      {{ $ctx_t(domainDescription) }}
    </div>
    <div class="domain-tree">
      <template v-for="entry in treeEntries" :key="entry.key">
        <div class="tree-row" :style="getTreeRowStyle(entry.level)">
          <div class="tree-icon-assembly" :class="{ 'is-locked': !entry.item.unlocked }">
            <div v-if="!entry.item.isSkill" class="tree-icon-background" :style="getIconBackgroundStyle(entry.item.accentColor || entry.item.color)"></div>
            <BngIcon class="tree-icon" :type="getSkillIcon(entry.item)" />
          </div>
          <div class="tree-label">{{ $ctx_t(entry.item.name) }}</div>
          <div class="tree-status">{{ getStatusLabel(entry.item) }}</div>
        </div>
      </template>
    </div>
  </section>
  <template v-else>
    <div class="progress-domain-info-empty">
      {{ $ctx_t("ui.career.computer.loading") }}
    </div>
  </template>
</template>

<script setup>
import { computed, onMounted, ref, watch } from "vue"
import { BngCardHeading, BngIcon, icons } from "@/common/components/base"
import { AspectRatio } from "@/common/components/utility"
import { lua } from "@/bridge"
import "../career/utils/installLuaBridgeFallbacks.js"
import { $translate } from "@/services/translation"
import { getURL } from "@/utils"
import { getIconBackgroundStyle } from "@/utils/colorUtils"

import { focusedDomainId } from "./progressFocus.js"

defineOptions({ name: "OverhaulProgressDomainInfo" })

const domainInfo = ref(null)
const treeEntries = ref([])
const domainDescription = computed(() => domainInfo.value?.description || domainInfo.value?.shortDescription || "")
const domainImageUrl = computed(() => domainInfo.value?.cover ? getURL(domainInfo.value.cover) : "")
const domainIcon = computed(() => icons[domainInfo.value?.icon] || icons.info)

async function buildTreeEntries(parentId, level = 0, keyPrefix = "") {
  const entries = []
  const data = await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(parentId)
  const children = Array.isArray(data?.skills) ? data.skills : []
  for (const item of children) {
    const key = keyPrefix ? `${keyPrefix}.${item.id}` : item.id
    entries.push({ key, item, level })
    if (item.isBranch && !item.isInDevelopment) {
      entries.push(...await buildTreeEntries(item.id, level + 1, key))
    }
  }
  return entries
}

function getStatusLabel(item) {
  if (item.isInDevelopment) return $translate.contextTranslate("ui.career.inDevelopment")
  if (!item.unlocked) return $translate.contextTranslate("ui.career.locked")
  if (item.levelLabel) return $translate.contextTranslate(item.levelLabel)
  return $translate.contextTranslate({ txt: "ui.career.lvlLabel", context: { lvl: item.level || 0 } })
}

function getSkillIcon(item) {
  if (item.isInDevelopment) return icons.roadblockL
  return icons[item.unlocked ? item.icon : "lockClosed"] || item.icon || icons.info
}

function getTreeRowStyle(level) {
  return {
    "--tree-level": Math.max(0, Number(level) || 0),
  }
}

let loadVersion = 0
async function loadDomainInfo() {
  const domainId = focusedDomainId.value
  const version = ++loadVersion
  if (!domainId) return
  const data = await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(domainId)
  const entries = data ? await buildTreeEntries(domainId) : []
  if (version !== loadVersion) return
  domainInfo.value = data ? { ...data, id: data.id || domainId } : null
  treeEntries.value = entries
}

onMounted(loadDomainInfo)
watch(focusedDomainId, loadDomainInfo)
</script>

<style scoped lang="scss">
.progress-domain-info {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  color: var(--bng-off-white);
  padding: 0.5rem;
}

.domain-heading {
  margin: 0;
  margin-left: -0.5rem;
}

.domain-heading-content {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
}


.domain-heading-title {
  min-width: 0;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.domain-description {
  padding: 0.35rem 0.45rem 0.5rem;
  border-bottom: 0.0625rem solid rgba(var(--bng-off-white-rgb), 0.18);
  color: rgba(var(--bng-off-white-rgb), 0.86);
  font-size: 0.9rem;
  line-height: 1.35;
}

.domain-image {
  flex: 0 0 auto;
  border-radius: var(--bng-corners-2);
  overflow: hidden;
}

.domain-tree {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.tree-row {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.45rem;
  min-width: 0;
  padding: 0.25rem 0.35rem;
  border-radius: var(--bng-corners-1);
  background: linear-gradient(to right, rgba(var(--bng-off-white-rgb), 0.08), rgba(var(--bng-off-white-rgb), 0.04));
  font-size: 0.85rem;
  font-weight: 600;
  margin-left: calc(var(--tree-level, 0) * 0.5rem);
}

.tree-icon-assembly {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 1.55em;
  height: 1.55em;

  &.is-locked {
    opacity: 0.6;
  }
}

.tree-icon-background {
  position: absolute;
  inset: -0.18rem;
  mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
  -webkit-mask-image: url(/ui/assets/SVG/24/branchXP-bg.svg);
  mask-repeat: no-repeat;
  -webkit-mask-repeat: no-repeat;
  mask-size: contain;
  -webkit-mask-size: contain;
  mask-position: 50% 50%;
  -webkit-mask-position: 50% 50%;
  z-index: 1;
}

.tree-icon {
  position: relative;
  z-index: 2;
  font-size: 1.5em;
}

.tree-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tree-status {
  color: rgba(var(--bng-off-white-rgb), 0.78);
  font-style: italic;
  white-space: nowrap;
}

.progress-domain-info-empty {
  color: rgba(var(--bng-off-white-rgb), 0.78);
  font-style: italic;
  padding: 0.5rem;
}
</style>

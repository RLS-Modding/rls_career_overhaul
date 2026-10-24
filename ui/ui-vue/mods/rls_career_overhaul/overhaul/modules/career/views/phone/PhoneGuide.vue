<template>
  <div class="guide-container">
    <div v-if="!selectedTopicId" class="guide-list-view">
      <div class="guide-list-header">
        <h2 class="guide-list-title">Career wiki</h2>
        <p class="guide-list-subtitle">Learn how to play the overhaul — open a category and pick a topic.</p>
      </div>
      <div class="guide-topic-list">
        <section
          v-for="group in topicGroups"
          :key="group.id"
          class="topic-section"
        >
          <button
            type="button"
            class="category-row"
            :class="{ expanded: isCategoryExpanded(group.id) }"
            :aria-expanded="isCategoryExpanded(group.id)"
            @click="toggleCategory(group.id)"
          >
            <span class="category-label">{{ group.label }}</span>
            <span class="category-count">{{ group.topics.length }}</span>
            <span class="category-chevron" aria-hidden="true">›</span>
          </button>
          <div v-show="isCategoryExpanded(group.id)" class="category-topics">
            <button
              v-for="topic in group.topics"
              :key="topic.id"
              type="button"
              class="topic-row"
              @click="openTopic(topic.id)"
            >
              <span class="topic-icon" v-html="getIcon(topic.iconKey)"></span>
              <div class="topic-copy">
                <span class="topic-name">{{ topic.title }}</span>
                <span class="topic-desc">{{ topic.description }}</span>
              </div>
              <span class="topic-open" aria-hidden="true">
                <span class="topic-open-icon">›</span>
              </span>
            </button>
          </div>
        </section>
      </div>
    </div>

    <div v-else-if="activeTopic" class="guide-detail-view">
      <div class="detail-top">
        <div class="detail-head">
          <span class="detail-icon" v-html="getIcon(activeTopic.iconKey)"></span>
          <div class="detail-heading">
            <div class="detail-title">{{ activeTopic.title }}</div>
            <div class="detail-subtitle">{{ activeTopic.description }}</div>
          </div>
        </div>
        <div v-if="activeTopic.sections.length > 1" class="section-jumps" @wheel.prevent="onJumpWheel">
          <button
            v-for="sec in activeTopic.sections"
            :key="sec.id"
            type="button"
            class="jump-chip"
            :class="{ active: activeSectionId === sec.id }"
            @click="jumpToSection(sec.id)"
          >
            {{ sec.title }}
          </button>
        </div>
      </div>
      <div ref="guideScrollRef" class="guide-scroll" v-bng-ui-nav-scroll.force @scroll="onGuideScroll">
        <section
          v-for="sec in activeTopic.sections"
          :key="sec.id"
          :id="`guide-section-${sec.id}`"
          class="wiki-section"
        >
          <h3 class="wiki-section-title">{{ sec.title }}</h3>
          <ol v-if="sec.steps?.length" class="wiki-steps">
            <li v-for="(step, i) in sec.steps" :key="i">{{ step }}</li>
          </ol>
          <p v-for="(paragraph, i) in sec.body || []" :key="`p-${i}`" class="wiki-paragraph">
            {{ paragraph }}
          </p>
        </section>
        <button
          v-if="activeTopic.relatedRoute"
          type="button"
          class="related-app-btn"
          @click="openRelatedApp(activeTopic.relatedRoute)"
        >
          Open on phone
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>

import { usePhoneAppFocus } from './controllerLayers.js'
import { vBngUiNavScroll } from '@/common/directives'
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { usePhoneTutorial } from '../../composables/usePhoneTutorial'
import { GUIDE_CATEGORIES, mergeGuideTopics } from '../../data/guideWikiTopics'
import { usePhoneApps } from '../../utils/phoneAppRegistry'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'

usePhoneAppFocus()


const { tryAdvanceOnGuideRoute } = usePhoneTutorial()
const { APP_DEFINITIONS } = usePhoneApps()

const router = useRouter()
const route = useRoute()
const selectedTopicId = ref(null)
const guideScrollRef = ref(null)
const activeSectionId = ref(null)
const expandedCategories = ref(new Set())
const localTopics = ref([])
let scrollSpyPaused = false

function isCategoryExpanded(categoryId) {
  return expandedCategories.value.has(categoryId)
}

function toggleCategory(categoryId) {
  const next = new Set(expandedCategories.value)
  if (next.has(categoryId)) {
    next.delete(categoryId)
  } else {
    next.add(categoryId)
  }
  expandedCategories.value = next
}

const iconMap = {
  flag: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6h-5.6z"/></svg>',
  bank: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.8 10.9c-2.27-.59-3-1.2-3-2.15 0-1.09 1.01-1.85 2.7-1.85 1.78 0 2.44.85 2.5 2.1h2.21c-.07-1.72-1.12-3.3-3.21-3.81V3h-3v2.16c-1.94.42-3.5 1.68-3.5 3.61 0 2.31 1.91 3.46 4.7 4.13 2.5.6 3 1.48 3 2.41 0 .69-.49 1.79-2.7 1.79-2.06 0-2.87-.92-2.98-2.1h-2.2c.12 2.19 1.76 3.42 3.68 3.83V21h3v-2.15c1.95-.37 3.5-1.5 3.5-3.55 0-2.84-2.43-3.81-4.7-4.4z"/></svg>',
  economy: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M16 6l2.29 2.29-4.88 4.88-4-4L2 16.59 3.41 18l6-6 4 4 6.3-6.29L22 12V6h-6z"/></svg>',
  car: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z"/></svg>',
  box: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 6h-2.18c.11-.31.18-.65.18-1a2.996 2.996 0 0 0-5.5-1.65l-.5.67-.5-.68C10.96 2.54 10 2 9 2 7.34 2 6 3.34 6 5c0 .35.07.69.18 1H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-5-2c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zM9 4c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm11 15H4v-2h16v2zm0-5H4V8h5.08L7 10.83 8.62 12 11 8.76l1-1.36 1 1.36L15.38 12 17 10.83 14.92 8H20v6z"/></svg>',
  building: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 7V3H2v18h20V7H12zM6 19H4v-2h2v2zm0-4H4v-2h2v2zm0-4H4V9h2v2zm0-4H4V5h2v2zm4 12H8v-2h2v2zm0-4H8v-2h2v2zm0-4H8V9h2v2zm0-4H8V5h2v2zm10 12h-8v-2h2v-2h-2v-2h2v-2h-2V9h8v10zm-2-8h-2v2h2v-2zm0 4h-2v2h2v-2z"/></svg>',
  work: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z"/></svg>',
  racing: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6h-5.6z"/></svg>',
  tools: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M22.7 19l-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.4 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.5-.4.5-1.1.1-1.4z"/></svg>',
  settings: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94L14.4 2.81c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.07.62-.07.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
}

function getIcon(key) {
  return iconMap[key] || iconMap.flag
}

const appRouteById = computed(() => new Map(APP_DEFINITIONS.map(app => [app.id, app.route])))

const topics = computed(() =>
  mergeGuideTopics(localTopics.value).map(topic => ({
    ...topic,
    relatedRoute: topic.relatedAppId ? appRouteById.value.get(topic.relatedAppId) || null : null,
  }))
)

const topicGroups = computed(() =>
  GUIDE_CATEGORIES.map(category => ({
    ...category,
    topics: topics.value.filter(topic => topic.category === category.id),
  })).filter(group => group.topics.length > 0)
)

const activeTopic = computed(() => topics.value.find(topic => topic.id === selectedTopicId.value) || null)

function resolveTopicFromRoute() {
  const raw = route.query.topic
  const topicId = typeof raw === 'string' ? raw : Array.isArray(raw) ? raw[0] : null
  if (!topicId) return false
  if (topics.value.some(topic => topic.id === topicId)) {
    expandCategoryForTopic(topicId)
    selectedTopicId.value = topicId
    return true
  }
  const byApp = topics.value.find(topic => topic.relatedAppId === topicId)
  if (byApp) {
    expandCategoryForTopic(byApp.id)
    selectedTopicId.value = byApp.id
    return true
  }
  return false
}

function expandCategoryForTopic(topicId) {
  const topic = topics.value.find(t => t.id === topicId)
  if (!topic?.category) return
  const next = new Set(expandedCategories.value)
  next.add(topic.category)
  expandedCategories.value = next
}

function openTopic(id) {
  expandCategoryForTopic(id)
  selectedTopicId.value = id
  activeSectionId.value = null
  const nextQuery = { ...route.query, topic: id }
  delete nextQuery.section
  router.replace({ query: nextQuery })
}

function onPhoneBack() {
  if (selectedTopicId.value) {
    selectedTopicId.value = null
    activeSectionId.value = null
    const nextQuery = { ...route.query }
    delete nextQuery.topic
    delete nextQuery.section
    router.replace({ query: nextQuery })
    return true
  }
  return false
}

function openRelatedApp(appRoute) {
  if (!appRoute) return
  navigatePhoneRoute(router, appRoute)
}

function jumpToSection(sectionId) {
  activeSectionId.value = sectionId
  scrollSpyPaused = true
  const el = document.getElementById(`guide-section-${sectionId}`)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
  router.replace({ query: { ...route.query, topic: selectedTopicId.value, section: sectionId } })
  window.setTimeout(() => { scrollSpyPaused = false }, 400)
}

function onJumpWheel(e) {
  e.currentTarget.scrollLeft += e.deltaY
}

function onGuideScroll() {
  if (scrollSpyPaused || !activeTopic.value || !guideScrollRef.value) return
  const containerTop = guideScrollRef.value.getBoundingClientRect().top
  let current = activeTopic.value.sections[0]?.id || null
  for (const sec of activeTopic.value.sections) {
    const el = document.getElementById(`guide-section-${sec.id}`)
    if (!el) continue
    if (el.getBoundingClientRect().top - containerTop <= 28) current = sec.id
  }
  if (current) activeSectionId.value = current
}

async function applySectionFromRoute() {
  await nextTick()
  const raw = route.query.section
  const sectionId = typeof raw === 'string' ? raw : Array.isArray(raw) ? raw[0] : null
  if (!sectionId || !activeTopic.value?.sections.some(s => s.id === sectionId)) return
  activeSectionId.value = sectionId
  scrollSpyPaused = true
  const el = document.getElementById(`guide-section-${sectionId}`)
  if (el) el.scrollIntoView({ block: 'start' })
  window.setTimeout(() => { scrollSpyPaused = false }, 100)
}

watch(() => route.query.topic, async () => {
  if (resolveTopicFromRoute()) await applySectionFromRoute()
})

watch(() => route.query.section, async () => {
  if (selectedTopicId.value) await applySectionFromRoute()
})

watch(selectedTopicId, async (id) => {
  if (!id) return
  const topic = topics.value.find(t => t.id === id)
  activeSectionId.value = topic?.sections[0]?.id || null
  await applySectionFromRoute()
})

onMounted(async () => {
  try {
    const localGuide = await lua.overhaul_career_guide_guide.getLocalGuideOverrides()
    localTopics.value = Array.isArray(localGuide?.topics) ? localGuide.topics : []
  } catch {
    localTopics.value = []
  }
  resolveTopicFromRoute()
  await applySectionFromRoute()
  tryAdvanceOnGuideRoute()
})
usePhoneScreen({ onBack: onPhoneBack })
</script>

<style scoped>
.guide-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  background: #1a1a1a;
  color: #e5e5e5;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}

.guide-list-view,
.guide-detail-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
}

.guide-list-header {
  flex-shrink: 0;
  padding: 48px 16px 10px;
}

.guide-list-title {
  margin: 0;
  font-size: 18px;
  font-weight: 700;
  color: #fff;
}

.guide-list-subtitle {
  margin: 4px 0 0;
  font-size: 11px;
  line-height: 1.35;
  color: rgba(153, 153, 153, 0.95);
}

.guide-topic-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 12px 16px;
  scroll-behavior: smooth;
}

.topic-section + .topic-section {
  margin-top: 8px;
}

.category-row {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 11px 12px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: #222;
  color: inherit;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.14s ease, background 0.14s ease;
}

.category-row:hover {
  border-color: rgba(249, 115, 22, 0.35);
  background: #262626;
}

.category-row.expanded {
  border-color: rgba(249, 115, 22, 0.4);
  background: #262626;
}

.category-label {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 12px;
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
}

.category-count {
  flex-shrink: 0;
  min-width: 20px;
  padding: 2px 7px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.06);
  font-size: 10px;
  font-weight: 700;
  color: rgba(249, 115, 22, 0.9);
  text-align: center;
}

.category-chevron {
  flex-shrink: 0;
  font-size: 18px;
  line-height: 1;
  color: rgba(249, 115, 22, 0.9);
  transform: rotate(0deg);
  transition: transform 0.16s ease;
}

.category-row.expanded .category-chevron {
  transform: rotate(90deg);
}

.category-topics {
  padding: 8px 0 2px 8px;
}

.topic-row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 10px 10px 10px 12px;
  margin-bottom: 8px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: #222;
  color: inherit;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.14s ease, background 0.14s ease, transform 0.12s ease;
}

.topic-row:hover {
  border-color: rgba(249, 115, 22, 0.35);
  background: #262626;
}

.topic-row:active {
  transform: scale(0.995);
}

.topic-icon {
  flex-shrink: 0;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #f97316;
}

.topic-icon :deep(svg) {
  width: 18px;
  height: 18px;
}

.topic-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.topic-name {
  font-size: 13px;
  font-weight: 700;
  color: #fff;
  line-height: 1.2;
}

.topic-desc {
  font-size: 11px;
  line-height: 1.35;
  color: #999;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.topic-open {
  flex-shrink: 0;
  margin-left: auto;
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.05);
}

.topic-open-icon {
  font-size: 18px;
  line-height: 1;
  color: rgba(249, 115, 22, 0.9);
}

.detail-top {
  flex-shrink: 0;
  padding-top: 48px;
  background: #1a1a1a;
}

.detail-head {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 0 16px 8px;
}

.detail-icon {
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #f97316;
}

.detail-icon :deep(svg) {
  width: 20px;
  height: 20px;
}

.detail-heading {
  min-width: 0;
}

.detail-title {
  font-size: 18px;
  font-weight: 700;
  color: #fff;
}

.detail-subtitle {
  margin-top: 3px;
  font-size: 11px;
  line-height: 1.35;
  color: #999;
}

.section-jumps {
  display: flex;
  flex-wrap: nowrap;
  gap: 6px;
  padding: 0 12px 10px;
  overflow-x: auto;
  scroll-behavior: smooth;
  -webkit-overflow-scrolling: touch;
}

.jump-chip {
  flex-shrink: 0;
  padding: 5px 10px;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.04);
  color: rgba(203, 203, 203, 0.9);
  font-size: 10px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;
  transition: border-color 0.12s ease, background 0.12s ease, color 0.12s ease;
}

.jump-chip:hover {
  border-color: rgba(249, 115, 22, 0.35);
  color: #f0f0f0;
}

.jump-chip.active {
  border-color: rgba(249, 115, 22, 0.55);
  background: rgba(249, 115, 22, 0.14);
  color: #f97316;
}

.guide-scroll {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px 20px;
  scroll-behavior: smooth;
}

.wiki-section {
  scroll-margin-top: 8px;
  margin-bottom: 18px;
}

.wiki-section-title {
  margin: 0 0 8px;
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.03em;
  color: #f97316;
}

.wiki-steps {
  margin: 0 0 10px;
  padding-left: 18px;
  font-size: 12px;
  line-height: 1.55;
  color: rgba(226, 226, 226, 0.92);
}

.wiki-steps li + li {
  margin-top: 6px;
}

.wiki-paragraph {
  margin: 0 0 10px;
  font-size: 12px;
  line-height: 1.55;
  color: rgba(226, 226, 226, 0.92);
}

.related-app-btn {
  display: block;
  width: 100%;
  margin-top: 4px;
  padding: 10px 16px;
  border: 1px solid rgba(249, 115, 22, 0.35);
  border-radius: 999px;
  background: rgba(249, 115, 22, 0.1);
  color: #f97316;
  font-size: 12px;
  font-weight: 700;
  font-family: inherit;
  cursor: pointer;
  transition: transform 0.12s ease, background 0.12s ease;
}

.related-app-btn:hover {
  background: rgba(249, 115, 22, 0.18);
}

.related-app-btn:active {
  transform: scale(0.98);
}
</style>

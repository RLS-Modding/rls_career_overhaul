// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Skills data map: shared cache and display metadata; skill/unlock normalization;
// page discovery and detail hydration; load, lookup, reset and composable access.
import { ref } from 'vue'
import { lua } from '@/bridge'

const skills = ref([])
const rootSkills = ref([])
const civilServiceSkills = ref([])
const civilServiceParentSkill = ref(null)
const loading = ref(false)
const loaded = ref(false)
const error = ref('')

export const CIVIL_SERVICE_GROUP_ID = 'careerSkills-civilService'
export const PHONE_SKILLS_CIVIL_SERVICE_QUERY = 'civilService'
const CIVIL_SERVICE_SKILL_PREFIX = 'careerSkills-civilService-'
const VISIBLE_CAREER_SKILL_IDS = new Set([
  'careerSkills-offroad',
  'careerSkills-speed',
  'careerSkills-mayhem',
  'careerSkills-circuitRacing',
  'careerSkills-emergency',
  'careerSkills-passenger',
  'careerSkills-operator',
  'careerSkills-recovery',
  'careerSkills-logistics',
  'careerSkills-gambling',
  'careerSkills-stamina',
])
const PHONE_SKILL_PRESENTATION = {
  'careerSkills-offroad': { order: 10, icon: 'beamsNodesOutline', description: 'Master harsh terrain and off-road routes.' },
  'careerSkills-speed': { order: 20, icon: 'gaugeFull', description: 'Build raw speed and control.' },
  'careerSkills-mayhem': { order: 30, icon: 'carCrash', description: 'High risk, high reward.' },
  'careerSkills-circuitRacing': { order: 40, icon: 'flag', description: 'Compete on paved tracks and ovals.' },
  'careerSkills-emergency': { order: 50, icon: 'shieldCheckmark', description: 'Serve and protect when it matters.' },
  'careerSkills-passenger': { order: 60, icon: 'person', description: 'Transport passengers safely and efficiently.' },
  'careerSkills-operator': { order: 70, icon: 'cogs', description: 'Operate heavy equipment on the job.' },
  'careerSkills-recovery': { order: 80, icon: 'tow', description: 'Recover, tow, and get the job done.' },
  'careerSkills-logistics': { order: 90, icon: 'boxTruck', description: 'Deliver cargo and essentials.' },
  'careerSkills-gambling': { order: 100, icon: 'diceD6', description: 'Take chances and win big.' },
  'careerSkills-stamina': { order: 110, icon: 'pedestrianRunning', description: 'Increase endurance and resilience.' },
}

const LEGACY_PARENT_SKILL_IDS = {
  'careerSkills-drag': 'careerSkills-speed',
  'careerSkills-drift': 'careerSkills-mayhem',
  'careerSkills-roadracing': 'careerSkills-circuitRacing',
  'careerSkills-taxi': 'careerSkills-passenger',
  'careerSkills-repo': 'careerSkills-recovery',
}

function canonicalPhoneSkillId(skillId) {
  const id = String(skillId || '')
  return LEGACY_PARENT_SKILL_IDS[id] || id
}

export function isCivilServiceChildSkill(skillId) {
  const id = String(skillId || '')
  return id.startsWith(CIVIL_SERVICE_SKILL_PREFIX)
}

function isCivilServiceSkill(skill) {
  const id = String(skill?.id || '')
  return id.startsWith(CIVIL_SERVICE_SKILL_PREFIX)
}

function syncPhoneSkillPartitions(parentSkill) {
  const partitioned = partitionPhoneSkills(skills.value)
  rootSkills.value = partitioned.topLevel
  civilServiceSkills.value = []
  if (parentSkill !== undefined) {
    civilServiceParentSkill.value = parentSkill
  }
}

function partitionPhoneSkills(allSkills) {
  const civilService = []
  const topLevel = []
  for (const skill of asArray(allSkills)) {
    if (!skill || !skill.id) continue
    if (!VISIBLE_CAREER_SKILL_IDS.has(String(skill.id))) continue
    if (String(skill.id) === 'careerSkills-gambling' && toNumber(skill.value, 0) <= 0) continue
    if (skill.id === CIVIL_SERVICE_GROUP_ID) continue
    if (isCivilServiceSkill(skill)) {
      civilService.push(skill)
      continue
    }
    topLevel.push(skill)
  }
  civilService.sort((a, b) => toNumber(a.order, 9999) - toNumber(b.order, 9999))
  topLevel.sort((a, b) => toNumber(a.order, 9999) - toNumber(b.order, 9999))
  return { topLevel, civilService }
}

let pendingLoad = null
let requestEpoch = 0

function asArray(value) {
  return Array.isArray(value) ? value : []
}

function asObject(value) {
  return value && typeof value === 'object' ? value : {}
}

function toNumber(value, fallback = 0) {
  const n = Number(value)
  return Number.isFinite(n) ? n : fallback
}

function normalizeTask(task) {
  const src = asObject(task)
  return {
    label: typeof src.label === 'string' && src.label.trim() ? src.label : 'Task',
    description: typeof src.description === 'string' ? src.description : '',
    done: src.done === true,
  }
}

function fallbackUnlockCard(entry = {}) {
  return {
    type: 'unlockCard',
    icon: typeof entry.icon === 'string' && entry.icon.trim() ? entry.icon : 'info',
    heading: typeof entry.heading === 'string' && entry.heading.trim()
      ? entry.heading
      : (typeof entry.label === 'string' && entry.label.trim() ? entry.label : 'Unlock'),
    description: typeof entry.description === 'string' ? entry.description : '',
  }
}

function normalizeUnlockEntry(entry) {
  const src = asObject(entry)
  if (src.type === 'tasklist') {
    const taskData = asObject(src.tasklistData)
    const tasks = asArray(taskData.tasks).map(normalizeTask)
    if (tasks.length > 0) {
      return {
        ...src,
        type: 'tasklist',
        heading: typeof src.heading === 'string' && src.heading.trim() ? src.heading : 'Requirements',
        tasklistData: {
          ...taskData,
          tasks,
        },
      }
    }
    return fallbackUnlockCard(src)
  }
  return fallbackUnlockCard(src)
}

function normalizeTierDescription(description) {
  if (typeof description === 'string') {
    return { heading: '', description }
  }
  const src = asObject(description)
  return {
    heading: typeof src.heading === 'string' ? src.heading : '',
    description: typeof src.description === 'string' ? src.description : '',
  }
}

function normalizeUnlockTier(tier, fallbackIndex) {
  const src = asObject(tier)
  return {
    ...src,
    index: toNumber(src.index, fallbackIndex + 1),
    currentValue: toNumber(src.currentValue, 0),
    requiredValue: toNumber(src.requiredValue, 0),
    xpCurrent: toNumber(src.xpCurrent, 0),
    xpRequired: toNumber(src.xpRequired, -1),
    isInDevelopment: src.isInDevelopment === true,
    isMaxLevel: src.isMaxLevel === true,
    isBase: src.isBase === true,
    description: normalizeTierDescription(src.description),
    list: asArray(src.list).map(normalizeUnlockEntry),
  }
}

function normalizeSkill(skillId, skillInfo, discoveryOrder) {
  const src = asObject(skillInfo)
  const presentation = PHONE_SKILL_PRESENTATION[String(skillId)] || {}
  const min = toNumber(src.min, 0)
  const value = toNumber(src.value, 0)
  const max = toNumber(src.max, 0)
  const level = Math.max(0, toNumber(src.level, 0))

  const xpCurrent = Math.max(0, Math.round(value - min))
  const xpNeeded = Math.max(0, Math.round(max - min))
  const isMaxLevel = src.isMaxLevel === true || max === -1 || xpNeeded <= 0

  const unlockInfo = asArray(src.unlockInfo).map((tier, idx) => normalizeUnlockTier(tier, idx))
  const hasUnlocks = typeof src.hasUnlocks === 'boolean'
    ? src.hasUnlocks
    : unlockInfo.some(tier => tier.list.length > 0 || tier.description.heading || tier.description.description)

  const normalizedOrder = Number(presentation.order ?? src.order)
  return {
    id: String(skillId),
    order: Number.isFinite(normalizedOrder) ? normalizedOrder : discoveryOrder,
    name: typeof src.name === 'string' && src.name.trim() ? src.name : String(skillId),
    description: typeof src.description === 'string' && src.description.trim()
      ? src.description
      : (presentation.description || ''),
    icon: presentation.icon || (typeof src.icon === 'string' ? src.icon : 'star'),
    level,
    levelCap: unlockInfo.length > 0 ? unlockInfo.length : null,
    unlocked: src.unlocked !== false,
    hasLevels: src.hasLevels !== false,
    min,
    value,
    max,
    isMaxLevel,
    xpCurrent,
    xpNeeded,
    progressLabel: isMaxLevel ? `${xpCurrent} / MAX` : `${xpCurrent} / ${xpNeeded}`,
    progressHint: isMaxLevel ? 'Max level reached' : `${xpCurrent} / ${xpNeeded} XP to next level`,
    color: src.color,
    accentColor: src.accentColor || src.color,
    unlockInfo,
    hasUnlocks,
  }
}

function mergeSkillsById(baseSkills, incomingSkills) {
  const byId = new Map()
  for (const skill of asArray(baseSkills)) {
    if (skill && skill.id) {
      byId.set(String(skill.id), skill)
    }
  }
  for (const skill of asArray(incomingSkills)) {
    if (!skill || !skill.id) continue
    const id = String(skill.id)
    byId.set(id, {
      ...(byId.get(id) || {}),
      ...skill,
    })
  }
  const merged = Array.from(byId.values())
  merged.sort((a, b) => {
    const byOrder = toNumber(a.order, 9999) - toNumber(b.order, 9999)
    if (byOrder !== 0) return byOrder
    return String(a.name).localeCompare(String(b.name))
  })
  return merged
}

async function getLandingPageData(pathId) {
  // Lua bridge signature expects one argument; use empty string for root page.
  const normalizedPath = pathId == null ? '' : String(pathId)
  return lua.overhaul_career_progression_skillsPage.getLandingPageData(normalizedPath)
}

function scoreSkillsPage(pageData) {
  const pageSkills = asArray(pageData?.skills).filter(entry => entry && entry.id)
  const skillBranches = asArray(pageData?.branches).filter(entry => entry && entry.id && entry.isSkill === true)
  const heading = String(pageData?.heading || '').toLowerCase()
  const hasSkillText = heading.includes('skill') ? 1 : 0
  const score = pageSkills.length * 3 + skillBranches.length * 2 + hasSkillText
  return { score, pageSkills, skillBranches }
}

async function findSkillsRootPage() {
  const candidateIds = [
    'careerSkills',
    'skills',
    'career-skills',
    'career-skills-main',
    'careerSkills-skills',
  ]

  let best = null

  for (const id of candidateIds) {
    try {
      const pageData = await getLandingPageData(id)
      const scored = scoreSkillsPage(pageData)
      if (!best || scored.score > best.score) {
        best = { id, pageData, ...scored }
      }
    } catch (_) {
      // Ignore unknown path ids.
    }
  }

  if (best && best.score > 0) {
    return best
  }

  // Fallback: inspect root branches and try skill-like ids.
  const rootPage = await getLandingPageData('')
  const dynamicIds = asArray(rootPage?.branches)
    .map(entry => (entry && entry.id ? String(entry.id) : ''))
    .filter(id => id)
    .filter(id => id.toLowerCase().includes('skill'))

  for (const id of dynamicIds) {
    try {
      const pageData = await getLandingPageData(id)
      const scored = scoreSkillsPage(pageData)
      if (!best || scored.score > best.score) {
        best = { id, pageData, ...scored }
      }
    } catch (_) {
      // Ignore unknown path ids.
    }
  }

  return best
}

async function collectAllSkillsFromTreeFallback() {
  const queue = [{ id: null, isSkill: false }]
  const visitedPages = new Set()
  const skillsById = new Map()
  let discoveryOrder = 0

  while (queue.length > 0) {
    const node = queue.shift()
    const pageKey = node.id == null ? '__root__' : String(node.id)
    if (visitedPages.has(pageKey)) continue
    visitedPages.add(pageKey)

    let pageData
    try {
      pageData = await getLandingPageData(node.id)
    } catch (_) {
      continue
    }

    if (node.isSkill === true && node.id != null && pageData && pageData.skillInfo) {
      const skill = normalizeSkill(node.id, pageData.skillInfo, discoveryOrder++)
      if (!skillsById.has(skill.id)) {
        skillsById.set(skill.id, skill)
      }
    }

    for (const branch of asArray(pageData?.branches)) {
      if (!branch || !branch.id) continue
      queue.push({
        id: String(branch.id),
        isSkill: branch.isSkill === true,
      })
    }
  }

  return Array.from(skillsById.values())
}

async function collectSkillsFromNestedBranches(skillsById, pageData, discoveryOrderStart) {
  let discoveryOrder = discoveryOrderStart

  for (const branch of asArray(pageData?.branches)) {
    if (!branch || !branch.id || branch.isSkill === true) continue

    let nestedPage = null
    try {
      nestedPage = await getLandingPageData(String(branch.id))
    } catch (_) {
      continue
    }

    for (const entry of asArray(nestedPage?.skills)) {
      if (!entry || !entry.id) continue
      const id = String(entry.id)
      if (skillsById.has(id)) continue
      const skill = normalizeSkill(id, entry, discoveryOrder++)
      skillsById.set(skill.id, skill)
    }
  }

  return discoveryOrder
}

async function loadCivilServiceParentSkill() {
  try {
    const cardData = await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(CIVIL_SERVICE_GROUP_ID)
    return normalizeSkill(CIVIL_SERVICE_GROUP_ID, cardData, 0)
  } catch (_) {
    return null
  }
}

async function collectAllSkills() {
  const skillsById = new Map()
  let discoveryOrder = 0

  const bestRoot = await findSkillsRootPage()

  if (bestRoot && bestRoot.score > 0) {
    for (const entry of bestRoot.pageSkills) {
      if (!entry || !entry.id) continue
      const skill = normalizeSkill(entry.id, entry, discoveryOrder++)
      if (!skillsById.has(skill.id)) {
        skillsById.set(skill.id, skill)
      }
    }

    // If page.skills is unavailable/incomplete, pull leaf skill cards directly.
    for (const branch of bestRoot.skillBranches) {
      const id = String(branch.id)
      if (skillsById.has(id)) continue
      try {
        const cardData = await lua.overhaul_career_progression_skillsPage.getBranchSkillCardData(id)
        const skill = normalizeSkill(id, cardData, discoveryOrder++)
        skillsById.set(skill.id, skill)
      } catch (_) {
        // Ignore malformed entries.
      }
    }

    discoveryOrder = await collectSkillsFromNestedBranches(
      skillsById,
      bestRoot.pageData,
      discoveryOrder,
    )
  }

  if (skillsById.size === 0) {
    const fallback = await collectAllSkillsFromTreeFallback()
    for (const skill of fallback) {
      if (!skillsById.has(skill.id)) {
        skillsById.set(skill.id, skill)
      }
    }
  }

  const result = Array.from(skillsById.values()).filter(skill => VISIBLE_CAREER_SKILL_IDS.has(String(skill.id)))
  result.sort((a, b) => {
    const byOrder = toNumber(a.order, 9999) - toNumber(b.order, 9999)
    if (byOrder !== 0) return byOrder
    return String(a.name).localeCompare(String(b.name))
  })
  return result
}

export async function hydratePhoneSkillDetails(skillId) {
  const id = canonicalPhoneSkillId(skillId)
  if (!id) return null

  let pageData = null
  try {
    pageData = await getLandingPageData(id)
  } catch (_) {
    return getPhoneSkillById(id)
  }

  const skillInfo = pageData?.skillInfo
  if (!skillInfo) {
    return getPhoneSkillById(id)
  }

  const existing = getPhoneSkillById(id)
  const nextOrder = existing ? existing.order : skills.value.length
  const hydrated = normalizeSkill(id, skillInfo, nextOrder)
  const merged = {
    ...(existing || {}),
    ...hydrated,
    order: nextOrder,
  }

  if (existing) {
    const idx = skills.value.findIndex(skill => skill.id === id)
    if (idx >= 0) {
      const next = [...skills.value]
      next[idx] = merged
      skills.value = next
      syncPhoneSkillPartitions()
      return merged
    }
  }

  skills.value = [...skills.value, merged]
  syncPhoneSkillPartitions()
  return merged
}

export async function loadPhoneSkills(force = false) {
  if (loaded.value && !force) {
    return skills.value
  }
  if (pendingLoad) {
    return pendingLoad
  }

  loading.value = true
  error.value = ''
  const epoch = ++requestEpoch

  pendingLoad = collectAllSkills()
    .then(async data => {
      if (epoch !== requestEpoch) return skills.value
      skills.value = mergeSkillsById(skills.value, data)
      const parentSkill = null
      if (epoch !== requestEpoch) return skills.value
      syncPhoneSkillPartitions(parentSkill)
      loaded.value = true
      return data
    })
    .catch(err => {
      error.value = err?.message || 'Failed to load skills.'
      throw err
    })
    .finally(() => {
      if (epoch === requestEpoch) {
        loading.value = false
        pendingLoad = null
      }
    })

  return pendingLoad
}

export function getPhoneSkillById(skillId) {
  const id = canonicalPhoneSkillId(skillId)
  return skills.value.find(skill => skill.id === id) || null
}

export function resetPhoneSkillsCache() {
  requestEpoch += 1
  skills.value = []
  rootSkills.value = []
  civilServiceSkills.value = []
  civilServiceParentSkill.value = null
  loading.value = false
  loaded.value = false
  error.value = ''
  pendingLoad = null
}

export function usePhoneSkillsData() {
  return {
    skills,
    rootSkills,
    civilServiceSkills,
    civilServiceParentSkill,
    loading,
    loaded,
    error,
    loadPhoneSkills,
    hydratePhoneSkillDetails,
    getPhoneSkillById,
    resetPhoneSkillsCache,
  }
}

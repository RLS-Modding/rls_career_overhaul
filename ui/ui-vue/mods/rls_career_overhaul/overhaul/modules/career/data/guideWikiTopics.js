// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { financeTopics } from './guideTopics/finance.js'
import { propertyTopics } from './guideTopics/property.js'
import { vehiclesTopics } from './guideTopics/vehicles.js'
import { jobsTopics } from './guideTopics/jobs.js'
import { racingTopics } from './guideTopics/racing.js'
import { businessTopics } from './guideTopics/business.js'
import { phoneTopics } from './guideTopics/phone.js'

/** Career guide topics: player-hook description on list cards, sectioned walkthroughs on detail. relatedAppId links to a phone app when one exists. */
export const GUIDE_CATEGORIES = [
  { id: 'finance', label: 'Finance & economy' },
  { id: 'property', label: 'Property & garages' },
  { id: 'vehicles', label: 'Vehicles & trading' },
  { id: 'jobs', label: 'Jobs & hauling' },
  { id: 'racing', label: 'Racing & events' },
  { id: 'business', label: 'Business & progression' },
  { id: 'phone', label: 'Phone & tools' },
]

export const GUIDE_TOPICS = [
  ...financeTopics,
  ...propertyTopics,
  ...vehiclesTopics,
  ...jobsTopics,
  ...racingTopics,
  ...businessTopics,
  ...phoneTopics,
]

/** Merge records by stable ID; arrays of prose replace a field, while other sections stay in order. */
export function mergeGuideTopics(overrides = [], baseTopics = GUIDE_TOPICS) {
  const mergeRecords = (base, patches, isSection = false) => {
    const records = [...base]
    for (const patch of patches) {
      const index = records.findIndex(record => record.id === patch.id)
      if (index < 0 && (!patch.title || (!isSection && (!patch.category || !patch.description)))) continue
      const original = index >= 0 ? records[index] : {}
      const merged = { ...original, ...patch }
      if ('sections' in patch) merged.sections = mergeRecords(original.sections || [], patch.sections, true)
      else if (!isSection && !merged.sections) merged.sections = []
      if (index >= 0) records[index] = merged
      else records.push(merged)
    }
    return records
  }
  return mergeRecords(baseTopics, overrides)
}

export function getGuideTopicById(id, topics = GUIDE_TOPICS) {
  return topics.find(topic => topic.id === id) || null
}

export function getGuideTopicByRelatedAppId(appId, topics = GUIDE_TOPICS) {
  return topics.find(topic => topic.relatedAppId === appId) || null
}

/** @deprecated use GUIDE_TOPICS */
export const GUIDE_WIKI_TOPICS = GUIDE_TOPICS

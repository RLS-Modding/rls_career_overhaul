// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

const welcome = {
  kind: 'welcome',
  image: '/ui/images/rls_career_overhaul/welcome.jpg',
  title: 'Welcome to RLS Career Overhaul',
  summary: 'This mod transforms career mode with new work systems, freeroam events, police interactions, and an overhauled economy. Earn money your way with multiple job types including deliveries, taxi service, bus operations, and more.',
  toc: false,
}
const phone = { kind: 'phone', title: 'Your career, one tap away',
  image: '/ui/images/rls_career_overhaul/phone-setup.jpg', imagePosition: 'center', toc: false }

export function introPages(plan) {
  if (!plan) return []
  const pages = plan.welcome ? [welcome] : []
  pages.push(...(plan.whatsNew?.slides || []))
  if (pages.length || plan.preview) pages.push(phone)
  return pages
}

export function continueIntro(pages, index, editing) {
  if (editing) return { index, finish: false }
  const phoneIndex = pages.findIndex(page => page.kind === 'phone')
  return phoneIndex > index ? { index: phoneIndex, finish: false } : { index, finish: true }
}

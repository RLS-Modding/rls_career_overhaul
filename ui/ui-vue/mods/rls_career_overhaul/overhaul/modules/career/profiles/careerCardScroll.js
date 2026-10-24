// Read only on scroll/resize; no animation loop or smooth motion, including on controller focus.
export function scrollEdges(grid) {
  return { above: grid.scrollTop > 1, below: grid.scrollHeight - grid.clientHeight - grid.scrollTop > 1 }
}

// The skills use the height the pause column already has, without scrolling the pause page.
// Only when that is not enough does the list stop after its last whole row and scroll.
// Returns the viewport height in px, or null when every skill fits.
export function fitSkillRows(grid) {
  const area = grid.closest('.menu-content-main')
  const card = grid.closest('.overhaul-career-card')
  if (!area || !card) return null
  const box = grid.getBoundingClientRect()
  const belowGrid = card.getBoundingClientRect().bottom - box.bottom
  const room = area.getBoundingClientRect().bottom - belowGrid - box.top
  if (!grid.children.length || grid.scrollHeight <= room) return null
  const padding = parseFloat(getComputedStyle(grid).paddingBottom) || 0
  let height = 0, firstRow = Infinity
  for (const skill of grid.children) {
    const bottom = skill.getBoundingClientRect().bottom - box.top + grid.scrollTop + padding
    if (bottom < firstRow) firstRow = bottom
    if (bottom <= room && bottom > height) height = bottom
  }
  // With no room for even one row, still show the first so the list never collapses.
  return Math.ceil(height || firstRow)
}

export function revealSkill(event) {
  const grid = event.currentTarget
  const skill = event.target.closest('.skill')
  if (!skill) return
  const viewport = grid.getBoundingClientRect()
  const row = skill.getBoundingClientRect()
  // Keep focused content clear of both fades without scrolling the pause page itself.
  const inset = Math.min(row.height / 2, grid.clientHeight / 4)
  if (row.top < viewport.top + inset) grid.scrollTop -= viewport.top + inset - row.top
  else if (row.bottom > viewport.top + grid.clientHeight - inset) grid.scrollTop += row.bottom - viewport.top - grid.clientHeight + inset
}

const columnCount = grid => getComputedStyle(grid).gridTemplateColumns.split(' ').length

const steps = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -2, ArrowDown: 2 }

function skillTarget(current, key, count, columns = 2) {
  if (current < 0 || (key === 'ArrowLeft' && current % columns === 0) ||
    (key === 'ArrowRight' && current % columns === columns - 1)) return -1
  const next = key === 'Home' ? 0 : key === 'End' ? count - 1 : current + (key === 'ArrowUp' ? -columns : key === 'ArrowDown' ? columns : steps[key])
  return next >= 0 && next < count ? next : -1
}

export function navigateSkills(event) {
  if (!(event.key in steps) && event.key !== 'Home' && event.key !== 'End') return
  const skills = [...event.currentTarget.querySelectorAll('.skill')]
  const current = skills.indexOf(event.target)
  const next = skillTarget(current, event.key, skills.length, columnCount(event.currentTarget))
  if (next < 0) return
  event.preventDefault()
  event.stopPropagation()
  skills[next].focus()
}

export function navigateSkillController(event) {
  const keys = { focus_l: 'ArrowLeft', focus_r: 'ArrowRight', focus_u: 'ArrowUp', focus_d: 'ArrowDown' }
  const key = keys[event.detail?.name]
  const grid = event.target.closest('.skills')
  if (!key || !grid) return
  const skills = [...grid.querySelectorAll('.skill')]
  const current = skills.indexOf(event.target)
  const next = skillTarget(current, key, skills.length, columnCount(grid))
  // Let navigation leave the grid at its boundary. Inside it, focus hidden rows directly
  // so stock spatial navigation cannot skip a skill clipped by the scroll viewport.
  if (next < 0) return
  event.preventDefault()
  event.stopPropagation()
  if (event.detail.value) navigateSkills({ key, currentTarget: grid, target: event.target,
    preventDefault() {}, stopPropagation() {} })
}

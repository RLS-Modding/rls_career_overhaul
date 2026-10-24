// Action metadata comes from the stock controls catalog, including add-on actions.
export const OVERHAUL_CATEGORY = 'rlsCareerOverhaul'

export function overhaulActions(categories) {
  return (categories.find(category => category.key === OVERHAUL_CATEGORY)?.actions || [])
    .filter(action => !action.hidden)
    .slice().sort((a, b) => (a.order || 0) - (b.order || 0) || a.key.localeCompare(b.key))
}

export function actionGroups(actions) {
  const groups = new Map()
  for (const action of actions) {
    const name = action.overhaulGroup || 'Other'
    if (!groups.has(name)) groups.set(name, [])
    groups.get(name).push(action)
  }
  return Array.from(groups, ([name, actions]) => ({ name, actions }))
}

// Preserve unrelated settings and bindings. Conflict removal is a separate,
// explicit choice; resetting Overhaul must never reset an entire device.
export function planReset(bindings, defaults, actionNames, replaceConflicts = false) {
  const names = new Set(actionNames)
  const conflicts = []
  const devices = bindings.map(device => {
    const restored = defaults.find(entry => entry.devname === device.devname)?.contents.bindings
      .filter(binding => names.has(binding.action)) || []
    let kept = device.contents.bindings.filter(binding => !names.has(binding.action))
    const collisions = kept.filter(binding => restored.some(entry => entry.control === binding.control))
    conflicts.push(...collisions.map(binding => ({ ...binding, devname: device.devname })))
    if (replaceConflicts) kept = kept.filter(binding => !collisions.includes(binding))
    return { ...device, contents: { ...device.contents, bindings: [...kept, ...restored.map(binding => ({ ...binding }))] } }
  })
  return { devices, conflicts }
}

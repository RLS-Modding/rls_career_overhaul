// A pad move is committed only after choosing a destination. Work on copies so
// Cancel and invalid destinations cannot change the saved layout.
export function placeHomeApp({ pages, dock, appId, target, pageSize }) {
  const newPage = target.type === 'grid' && target.page === pages.length
  const targetSlots = target.type === 'dock' ? dock : newPage ? Array(pageSize).fill(null) : pages[target.page]
  if (!appId || !targetSlots || !Number.isInteger(target.slot) || target.slot < 0 || target.slot >= targetSlots.length) return null
  const nextPages = pages.map(page => [...page])
  if (newPage) nextPages.push([...targetSlots])
  const nextDock = [...dock]
  let source = null
  for (const [type, groups] of [['dock', [nextDock]], ['grid', nextPages]]) {
    groups.forEach((slots, page) => slots.forEach((id, slot) => {
      if (id !== appId) return
      source ??= { type, page, slot }
      slots[slot] = null
    }))
  }
  const displaced = targetSlots[target.slot]
  const destination = target.type === 'dock' ? nextDock : nextPages[target.page]
  destination[target.slot] = appId
  if (displaced && displaced !== appId) {
    if (source) (source.type === 'dock' ? nextDock : nextPages[source.page])[source.slot] = displaced
    else {
      let page = nextPages.find(slots => slots.includes(null))
      if (!page) { page = Array(pageSize).fill(null); nextPages.push(page) }
      page[page.indexOf(null)] = displaced
    }
  }
  return { pages: nextPages, dock: nextDock }
}

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Filter and sort state for the real estate list view. The caller owns the garage
// list and the player balance, and passes them in; this composable only derives the
// filtered, sorted list from them.
import { ref, reactive, computed } from 'vue'

export function usePhoneRealEstateFilters({ garages, playerBalance }) {
  const filterForm = reactive({
    affordable: false,
    notOwned: false,
    priceMin: null,
    priceMax: null,
    slotsMin: null,
    slotsMax: null,
    distMin: null,
    distMax: null,
  })
  const sortBy = ref('distance')
  const sortAsc = ref(true)
  const sortFields = [
    { key: 'price', label: 'Price' },
    { key: 'capacity', label: 'Slots' },
    { key: 'distance', label: 'Distance' },
  ]

  const listFilteredGarages = computed(() => {
    let list = garages.value
    const balance = playerBalance.value
    const f = filterForm

    if (f.affordable) {
      list = list.filter(g => g.owned || g.price <= balance)
    }
    if (f.notOwned) {
      list = list.filter(g => !g.owned)
    }
    if (f.priceMin != null && f.priceMin !== '') {
      const v = Number(f.priceMin)
      if (!isNaN(v)) list = list.filter(g => g.owned || g.price >= v)
    }
    if (f.priceMax != null && f.priceMax !== '') {
      const v = Number(f.priceMax)
      if (!isNaN(v)) list = list.filter(g => g.owned || g.price <= v)
    }
    if (f.slotsMin != null && f.slotsMin !== '') {
      const v = Number(f.slotsMin)
      if (!isNaN(v)) list = list.filter(g => g.capacity >= v)
    }
    if (f.slotsMax != null && f.slotsMax !== '') {
      const v = Number(f.slotsMax)
      if (!isNaN(v)) list = list.filter(g => g.capacity <= v)
    }
    if (f.distMin != null && f.distMin !== '') {
      const v = Number(f.distMin)
      if (!isNaN(v)) list = list.filter(g => g.distance < 0 || g.distance >= v)
    }
    if (f.distMax != null && f.distMax !== '') {
      const v = Number(f.distMax)
      if (!isNaN(v)) list = list.filter(g => g.distance < 0 || g.distance <= v)
    }

    const arr = [...list]
    const key = sortBy.value
    const asc = sortAsc.value
    arr.sort((a, b) => {
      let va = key === 'price' ? (a.owned ? 0 : a.price) : key === 'capacity' ? a.capacity : (a.distance < 0 ? 1e9 : a.distance)
      let vb = key === 'price' ? (b.owned ? 0 : b.price) : key === 'capacity' ? b.capacity : (b.distance < 0 ? 1e9 : b.distance)
      if (va < vb) return asc ? -1 : 1
      if (va > vb) return asc ? 1 : -1
      return 0
    })
    return arr
  })

  function clearFilters() {
    filterForm.affordable = false
    filterForm.notOwned = false
    filterForm.priceMin = null
    filterForm.priceMax = null
    filterForm.slotsMin = null
    filterForm.slotsMax = null
    filterForm.distMin = null
    filterForm.distMax = null
  }

  return { filterForm, sortBy, sortAsc, sortFields, listFilteredGarages, clearFilters }
}

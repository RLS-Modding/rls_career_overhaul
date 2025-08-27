import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"

export const useVehicleShoppingStore = defineStore("vehicleShopping", () => {
  // States
  const vehicleShoppingData = ref({})
  const searchQuery = ref('')
  const filters = ref({}) // { field: { min, max } }
  const sortField = ref('Value')
  const sortDirection = ref('asc') // 'asc' | 'desc'
  const soldRemovalTimers = new Map()
  
  const filteredVehicles = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []

    let filteredList = Object.keys(d.vehiclesInShop).reduce(function (result, key) {
      if (d.currentSeller) {
        if (d.vehiclesInShop[key].sellerId === d.currentSeller) result.push(d.vehiclesInShop[key])
      } else {
        result.push(d.vehiclesInShop[key])
      }

      return result
    }, [])

    filteredList = applyFiltersAndSearch(filteredList)
    if (filteredList.length) filteredList.sort(sortComparator)

    // Apply search filtering if searchQuery exists
    if (searchQuery.value) {
      const query = searchQuery.value.toLowerCase().trim()
      filteredList = filteredList.filter(vehicle => {
        const searchFields = [
          vehicle.Name,
          vehicle.Brand,
          vehicle.niceName,
          vehicle.model_key,
          vehicle.config_name,
        ]
        
        // Check each field that might contain what user is searching for
        return searchFields.some(field => {
          return field && field.toString().toLowerCase().includes(query)
        })
      })
    }

    return filteredList
  })

  // Add a new computed property to group vehicles by dealer
  const vehiclesByDealer = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []

    // Group vehicles by sellerId
    const grouped = Object.values(d.vehiclesInShop).reduce((acc, vehicle) => {
      if (!acc[vehicle.sellerId]) {
        acc[vehicle.sellerId] = {
          id: vehicle.sellerId,
          name: vehicle.sellerName || 'Unknown Dealer',
          vehicles: [],
          expanded: false
        }
      }
      acc[vehicle.sellerId].vehicles.push(vehicle)
      return acc
    }, {})

    // Sort vehicles by price within each dealer
    Object.values(grouped).forEach(dealer => {
      dealer.vehicles = applyFiltersAndSearch(dealer.vehicles)
      dealer.vehicles.sort(sortComparator)
    })

    // Only return dealers with vehicles (after filtering)
    return Object.values(grouped).filter(dealer => dealer.vehicles.length > 0)
  })

  // Helpers
  const getNumericFields = (vehicles) => {
    const excluded = new Set(['shopId','id','pos','offerTTL','generationTime','soldViewCounter','requiredInsurance','tax','fees','mapId','sellerId','distanceVec','config','thumbnail'])
    const fields = {}
    vehicles.forEach(v => {
      Object.keys(v || {}).forEach(k => {
        const val = v[k]
        if (typeof val === 'number' && !excluded.has(k)) fields[k] = true
      })
    })
    return Object.keys(fields).sort()
  }

  const numericFields = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []
    return getNumericFields(Object.values(d.vehiclesInShop))
  })

  const getCategoricalStats = (vehicles) => {
    const stats = {}
    vehicles.forEach(v => {
      Object.keys(v || {}).forEach(k => {
        const val = v[k]
        if (val === undefined || val === null) return
        if (typeof val === 'number') return
        if (typeof val === 'object') return
        if (!stats[k]) stats[k] = new Set()
        stats[k].add(String(val))
      })
    })
    return stats
  }

  const categoricalFields = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []
    const vehicles = Object.values(d.vehiclesInShop)
    const stats = getCategoricalStats(vehicles)
    const maxValues = 60
    const excluded = new Set(['niceName','Name','config_name','thumbnail','pos'])
    return Object.keys(stats)
      .filter(k => !excluded.has(k) && stats[k].size > 1 && stats[k].size <= maxValues)
      .sort()
  })

  const fieldValues = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return {}
    const stats = getCategoricalStats(Object.values(d.vehiclesInShop))
    const map = {}
    Object.keys(stats).forEach(k => {
      map[k] = Array.from(stats[k]).sort((a,b) => String(a).localeCompare(String(b)))
    })
    return map
  })

  const getFieldValue = (veh, field) => {
    const v = veh && veh[field]
    if (typeof v === 'number') return v
    return Number.NaN
  }

  const sortComparator = (a, b) => {
    const field = sortField.value || 'Value'
    const av = getFieldValue(a, field)
    const bv = getFieldValue(b, field)
    const dir = sortDirection.value === 'desc' ? -1 : 1
    const aNum = isNaN(av) ? (dir === 1 ? Number.POSITIVE_INFINITY : Number.NEGATIVE_INFINITY) : av
    const bNum = isNaN(bv) ? (dir === 1 ? Number.POSITIVE_INFINITY : Number.NEGATIVE_INFINITY) : bv
    if (aNum === bNum) return 0
    return aNum < bNum ? -1 * dir : 1 * dir
  }

  const applyFiltersAndSearch = (list) => {
    let res = Array.isArray(list) ? list.slice() : []
    const activeFilters = filters.value
    res = res.filter(v => {
      // Handle hideSold filter - check for boolean value or values array
      if (activeFilters.hideSold) {
        const shouldHide = activeFilters.hideSold.value === true || 
                          (activeFilters.hideSold.values && (activeFilters.hideSold.values[0] === true || activeFilters.hideSold.values[0] === 'true'))
        if (shouldHide && (v.__sold || v.markedSold || (v.soldViewCounter && v.soldViewCounter > 0))) {
          return false
        }
      }
      
      for (const key in activeFilters) {
        if (key === 'hideSold') continue // Already handled above
        const range = activeFilters[key]
        if (!range) continue
        if (Array.isArray(range.values) && range.values.length) {
          const rv = v && v[key]
          const str = rv === undefined || rv === null ? '' : String(rv)
          if (!range.values.map(x => String(x)).includes(str)) return false
        }
        if (range.min !== undefined || range.max !== undefined) {
          const val = getFieldValue(v, key)
          if (!isNaN(range.min) && val < range.min) return false
          if (!isNaN(range.max) && val > range.max) return false
        }
      }
      return true
    })

    if (searchQuery.value) {
      const query = searchQuery.value.toLowerCase().trim()
      res = res.filter(vehicle => {
        const fields = [vehicle.Name, vehicle.Brand, vehicle.niceName, vehicle.model_key, vehicle.config_name]
        return fields.some(f => f && f.toString().toLowerCase().includes(query))
      })
    }
    return res
  }

  // Actions
  const requestVehicleShoppingData = async () => {
    vehicleShoppingData.value = await lua.career_modules_vehicleShopping.getShoppingData()
  }

  // Lightweight live updates via events
  function applyShopDelta(delta) {
    if (!delta || typeof delta !== 'object') return
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) d.vehiclesInShop = {}
    // additions
    if (Array.isArray(delta.added)) {
      delta.added.forEach(v => {
        if (!v || !v.shopId) return
        d.vehiclesInShop[v.shopId] = v
      })
    }
    // handle sold: keep visible for 2 minutes, then remove (accept either uid or full vehicle)
    if (Array.isArray(delta.sold)) {
      delta.sold.forEach(s => {
        const uid = typeof s === 'string' ? s : s?.uid
        if (!uid) return
        let foundKey = null
        Object.keys(d.vehiclesInShop || {}).some(k => {
          const v = d.vehiclesInShop[k]
          if (v && v.uid === uid) { foundKey = k; return true }
          return false
        })
        if (foundKey != null) {
          const v = d.vehiclesInShop[foundKey]
          // enrich with incoming sold snapshot if present (preserve shopId)
          if (s && typeof s === 'object') {
            const keepShopId = v.shopId
            d.vehiclesInShop[foundKey] = { ...v, ...s, shopId: keepShopId }
          }
          d.vehiclesInShop[foundKey].__soldAt = Date.now()
          d.vehiclesInShop[foundKey].__sold = true
          if (soldRemovalTimers.has(uid)) { clearTimeout(soldRemovalTimers.get(uid)) }
          soldRemovalTimers.set(uid, setTimeout(() => {
            try {
              Object.keys(d.vehiclesInShop || {}).forEach(k => {
                const vv = d.vehiclesInShop[k]
                if (vv && vv.uid === uid) delete d.vehiclesInShop[k]
              })
            } finally {
              soldRemovalTimers.delete(uid)
            }
          }, 120000))
        }
      })
    }

    // handle removed (non-sold): remove immediately
    if (Array.isArray(delta.removed)) {
      delta.removed.forEach(uid => {
        Object.keys(d.vehiclesInShop || {}).forEach(k => {
          const v = d.vehiclesInShop[k]
          if (v && v.uid === uid) delete d.vehiclesInShop[k]
        })
      })
    }

    // handle updated: if soldViewCounter increased, mark as sold for display
    if (Array.isArray(delta.updated)) {
      delta.updated.forEach(vu => {
        const uid = vu && vu.uid
        if (!uid) return
        Object.keys(d.vehiclesInShop || {}).forEach(k => {
          const v = d.vehiclesInShop[k]
          if (v && v.uid === uid) {
            // Merge updated data but preserve shopId
            const keepShopId = v.shopId
            Object.assign(v, vu)
            v.shopId = keepShopId
            v.__sold = vu.__sold || true
            v.__soldAt = Date.now()
            if (soldRemovalTimers.has(uid)) { clearTimeout(soldRemovalTimers.get(uid)) }
            soldRemovalTimers.set(uid, setTimeout(() => {
              try {
                Object.keys(d.vehiclesInShop || {}).forEach(kk => {
                  const vv = d.vehiclesInShop[kk]
                  if (vv && vv.uid === uid) delete d.vehiclesInShop[kk]
                })
              } finally {
                soldRemovalTimers.delete(uid)
              }
            }, 120000))
          }
        })
      })
    }
  }
  
  // Add a method to set the search query
  const setSearchQuery = (query) => {
    searchQuery.value = query
  }

  const setFilterRange = (field, min, max) => {
    const hasMin = typeof min === 'number' && !isNaN(min)
    const hasMax = typeof max === 'number' && !isNaN(max)
    if (!hasMin && !hasMax) {
      delete filters.value[field]
      return
    }
    const prev = filters.value[field] || {}
    filters.value[field] = { ...prev, min: hasMin ? min : undefined, max: hasMax ? max : undefined }
  }

  const clearAllFilters = () => {
    filters.value = {}
  }

  const setSort = (field, direction) => {
    sortField.value = field || 'Value'
    sortDirection.value = direction === 'desc' ? 'desc' : 'asc'
  }

  const processVehicleList = (list) => {
    const res = applyFiltersAndSearch(list)
    return res.sort(sortComparator)
  }

  const setValueFilter = (field, values) => {
    const arr = Array.isArray(values) ? values.slice() : []
    if (!arr.length) { delete filters.value[field]; return }
    const prev = filters.value[field] || {}
    filters.value[field] = { ...prev, values: arr }
  }

  const toggleFilterValue = (field, value) => {
    const prev = filters.value[field] || {}
    const set = new Set(prev.values || [])
    const key = value
    if (set.has(key)) set.delete(key)
    else set.add(key)
    if (set.size === 0 && prev.min === undefined && prev.max === undefined) {
      delete filters.value[field]
    } else {
      filters.value[field] = { ...prev, values: Array.from(set) }
    }
  }

  return {
    vehicleShoppingData,
    filteredVehicles,
    vehiclesByDealer,
    requestVehicleShoppingData,
    searchQuery,
    setSearchQuery,
    // filters & sorting
    filters,
    numericFields,
    categoricalFields,
    fieldValues,
    sortField,
    sortDirection,
    setFilterRange,
    clearAllFilters,
    setSort,
    processVehicleList,
    setValueFilter,
    toggleFilterValue,
    applyShopDelta,
  }
})

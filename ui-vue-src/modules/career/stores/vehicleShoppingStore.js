import { computed, ref, watch } from "vue"
import { defineStore } from "pinia"
import { lua } from "@/bridge"

export const useVehicleShoppingStore = defineStore("vehicleShopping", () => {
  // States
  const vehicleShoppingData = ref({})
  const searchQuery = ref('')
  const selectedSellerId = ref(null)
  const filters = ref({}) // { field: { min, max } }
  const sortField = ref('Value')
  const sortDirection = ref('asc') // 'asc' | 'desc'
  const soldRemovalTimers = new Map()
  
  // Helper function to check if a dealer is hidden
  const isDealerHidden = (dealerId) => {
    const d = vehicleShoppingData.value
    if (!d.dealerships) return false

    const dealerMeta = d.dealerships.find(dealer => String(dealer.id) === String(dealerId))
    if (!dealerMeta) return false

    // Check dealer's hiddenFromDealerList
    let hidden = !!dealerMeta.hiddenFromDealerList

    // Check organization's hiddenFromDealerList based on current reputation level
    if (dealerMeta.associatedOrganization && d.organizations) {
      const orgData = d.organizations[dealerMeta.associatedOrganization]
      if (orgData && orgData.reputationLevels && orgData.reputation && orgData.reputation.level !== undefined && orgData.reputation.level !== null) {
        const currentLevel = orgData.reputation.level || 0

        // Calculate array index: level -1 = index 0, level 0 = index 1, level 1 = index 2, etc.
        // But handle level 0 specially since the original calculation gives -2
        let currentIndex = currentLevel + 1  // This gives: level 0 = 1, level 1 = 2, etc.

        // Get level data if index is valid
        let levelData = null
        if (currentIndex >= 0 && currentIndex < orgData.reputationLevels.length) {
          levelData = orgData.reputationLevels[currentIndex]
        }

        if (levelData && levelData.hiddenFromDealerList) {
          hidden = true
        }
      }
    }

    return hidden
  }

  // Computed property for filtered UNSOLD vehicles
  const filteredVehicles = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []

    // Convert object to array if needed (backend might return object with string keys)
    const vehicleList = Array.isArray(d.vehiclesInShop) 
      ? d.vehiclesInShop 
      : Object.values(d.vehiclesInShop || {})

    let filteredList = vehicleList.reduce(function (result, vehicle) {
      if (d.currentSeller) {
        // When at a specific dealer, only show vehicles from that dealer
        if (vehicle.sellerId === d.currentSeller) result.push(vehicle)
      } else {
        // When viewing all dealers, filter out vehicles from hidden dealers
        if (!isDealerHidden(vehicle.sellerId)) {
          result.push(vehicle)
        }
      }
      return result
    }, [])

    filteredList = applyFiltersAndSearch(filteredList)
    if (filteredList.length) filteredList.sort(sortComparator)

    return filteredList
  })

  // New computed property for filtered SOLD vehicles
  const filteredSoldVehicles = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.soldVehicles) return []

    // Convert object to array if needed
    const vehicleList = Array.isArray(d.soldVehicles) 
      ? d.soldVehicles 
      : Object.values(d.soldVehicles || {})

    // Filter sold vehicles (usually we show all sold vehicles relevant to the player)
    // We might want to apply search to sold vehicles too, but maybe not all filters
    // For now, applying search and basic filtering
    let filteredList = vehicleList

    // Apply search query if present
    if (searchQuery.value) {
        const query = searchQuery.value.toLowerCase().trim()
        filteredList = filteredList.filter(vehicle => {
          const fields = [vehicle.Name, vehicle.Brand, vehicle.niceName, vehicle.model_key, vehicle.config_name]
          return fields.some(f => f && f.toString().toLowerCase().includes(query))
        })
    }

    // Apply sorting
    if (filteredList.length) filteredList.sort((a, b) => {
        // Sort sold vehicles by sold time if available, or default sort
        return b.soldViewCounter - a.soldViewCounter || sortComparator(a, b)
    })

    return filteredList
  })

  // Add a new computed property to group vehicles by dealer
  const vehiclesByDealer = computed(() => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return []

    const vehicleList = Array.isArray(d.vehiclesInShop) 
      ? d.vehiclesInShop 
      : Object.values(d.vehiclesInShop || {})

    // Group vehicles by sellerId (include all dealers, hidden ones will be marked)
    const grouped = vehicleList.reduce((acc, vehicle) => {
      if (!acc[vehicle.sellerId]) {
        acc[vehicle.sellerId] = {
          id: vehicle.sellerId,
          name: vehicle.sellerName || 'Unknown Dealer',
          vehicles: [],
          expanded: false,
          hidden: isDealerHidden(vehicle.sellerId) // Mark if dealer is hidden
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

    // Return all dealers (including hidden ones) so they can be displayed in UI
    return Object.values(grouped)
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
    const vehicleList = Array.isArray(d.vehiclesInShop) ? d.vehiclesInShop : Object.values(d.vehiclesInShop)
    return getNumericFields(vehicleList)
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
    const vehicles = Array.isArray(d.vehiclesInShop) ? d.vehiclesInShop : Object.values(d.vehiclesInShop)
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
    const vehicles = Array.isArray(d.vehiclesInShop) ? d.vehiclesInShop : Object.values(d.vehiclesInShop)
    const stats = getCategoricalStats(vehicles)
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
      
      for (const key in activeFilters) {
        if (key === 'hideSold') continue // Already handled by separation of lists
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

    // Check and update filters when opening shopping interface
    updateFiltersOnOpen()
  }

  // Update filters when opening shopping interface
  const updateFiltersOnOpen = () => {
    const d = vehicleShoppingData.value
    if (!d.vehiclesInShop) return

    // Get current player money
    const playerMoney = d.playerAttributes?.money?.value || 0

    // Check if we have a price filter with "can afford" logic
    const priceFilter = filters.value.Value
    if (priceFilter && priceFilter.max !== undefined) {
      // If the current price filter max is higher than player money, update it
      if (priceFilter.max > playerMoney) {
        // Only update if it's a "can afford" scenario (price max equals player money)
        const effectiveMax = Math.max(priceFilter.min || 0, Math.min(playerMoney, priceFilter.max))
        if (effectiveMax !== priceFilter.max) {
          setFilterRange('Value', priceFilter.min, effectiveMax)
        }
      }
    }
  }

  // Watch for player money changes and update "can afford" filter automatically
  watch(
    () => vehicleShoppingData.value?.playerAttributes?.money?.value,
    (newMoney, oldMoney) => {
      if (newMoney === oldMoney || !newMoney) return

      const priceFilter = filters.value.Value
      if (priceFilter && priceFilter.max !== undefined) {
        // If money decreased and we have a filter that's now too high, adjust it
        if (newMoney < oldMoney && priceFilter.max > newMoney) {
          const effectiveMax = Math.max(priceFilter.min || 0, Math.min(newMoney, priceFilter.max))
          if (effectiveMax !== priceFilter.max) {
            setFilterRange('Value', priceFilter.min, effectiveMax)
          }
        }
      }
    },
    { immediate: false }
  )

  // Lightweight live updates via events
  function applyShopDelta(delta) {
    if (!delta || typeof delta !== 'object') return
    const d = vehicleShoppingData.value
    // Ensure arrays exist if not initialized
    if (!d.vehiclesInShop) d.vehiclesInShop = []
    if (!d.soldVehicles) d.soldVehicles = []

    // Convert object to array if backend sends object (just in case)
    let vehiclesArray = Array.isArray(d.vehiclesInShop) ? d.vehiclesInShop : Object.values(d.vehiclesInShop)
    let soldVehiclesArray = Array.isArray(d.soldVehicles) ? d.soldVehicles : Object.values(d.soldVehicles)

    // handle added
    if (Array.isArray(delta.added)) {
      delta.added.forEach(v => {
        if (!v || !v.shopId) return
        // Check if exists
        const existingIdx = vehiclesArray.findIndex(ex => ex.shopId === v.shopId)
        if (existingIdx !== -1) {
            vehiclesArray[existingIdx] = v
        } else {
            vehiclesArray.push(v)
        }
      })
    }

    // handle sold
    if (Array.isArray(delta.sold)) {
        delta.sold.forEach(s => {
            // 's' can be a shopId (primitive) or a vehicle object with shopId (if backend sends full obj)
            // The backend plan says it sends a vehicle object with __sold=true
            const shopId = typeof s === 'object' ? s.shopId : s
            
            // Find in vehiclesInShop and move to soldVehicles
            const idx = vehiclesArray.findIndex(v => v.shopId === shopId)
            if (idx !== -1) {
                const vehicle = vehiclesArray[idx]
                // Update properties if 's' is an object with more data
                if (typeof s === 'object') {
                    Object.assign(vehicle, s)
                }
                vehicle.__sold = true
                vehicle.__soldAt = Date.now()
                
                // Remove from unsold
                vehiclesArray.splice(idx, 1)
                
                // Add to sold if not present
                const soldIdx = soldVehiclesArray.findIndex(v => v.shopId === shopId)
                if (soldIdx !== -1) {
                    soldVehiclesArray[soldIdx] = vehicle
                } else {
                    soldVehiclesArray.push(vehicle)
                }
            }
        })
    }

    // handle removed (completely removed from shop)
    if (Array.isArray(delta.removed)) {
      delta.removed.forEach(shopId => {
        // Remove from unsold
        const idx = vehiclesArray.findIndex(v => v.shopId === shopId)
        if (idx !== -1) vehiclesArray.splice(idx, 1)
        
        // Remove from sold
        const soldIdx = soldVehiclesArray.findIndex(v => v.shopId === shopId)
        if (soldIdx !== -1) soldVehiclesArray.splice(soldIdx, 1)
      })
    }

    // handle updated
    if (Array.isArray(delta.updated)) {
        delta.updated.forEach(u => {
            // Update in unsold
            const idx = vehiclesArray.findIndex(v => v.shopId === u.shopId)
            if (idx !== -1) {
                Object.assign(vehiclesArray[idx], u)
            }
            
            // Update in sold
            const soldIdx = soldVehiclesArray.findIndex(v => v.shopId === u.shopId)
            if (soldIdx !== -1) {
                Object.assign(soldVehiclesArray[soldIdx], u)
            }
        })
    }

    // Update state refs
    d.vehiclesInShop = vehiclesArray
    d.soldVehicles = soldVehiclesArray
  }
  
  // Add a method to set the search query
  const setSearchQuery = (query) => {
    searchQuery.value = query
  }

  const setSelectedSellerId = (sellerId) => {
    selectedSellerId.value = sellerId
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
    filteredSoldVehicles,
    vehiclesByDealer,
    requestVehicleShoppingData,
    updateFiltersOnOpen,
    searchQuery,
    setSearchQuery,
    selectedSellerId,
    setSelectedSellerId,
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

import { computed, ref } from "vue"
import { defineStore } from "pinia"
import { lua, useBridge } from "@/bridge"

const LIST_TTL_MS = 15000
const DETAIL_TTL_MS = 30000

function normalizeCollection(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []

  const numericKeys = Object.keys(value)
    .filter(key => String(Number(key)) === key)
    .sort((left, right) => Number(left) - Number(right))

  if (numericKeys.length > 0) {
    return numericKeys.map(key => value[key])
  }

  return []
}

function normalizeRowArray(rows) {
  return normalizeCollection(rows)
}

function normalizeDestinationArray(destinations) {
  return normalizeCollection(destinations)
}

function normalizeSectionArray(sections) {
  return normalizeCollection(sections).map(section => ({
    ...section,
    rows: normalizeRowArray(section?.rows),
    destinations: normalizeDestinationArray(section?.destinations),
  }))
}

function normalizeFacilityList(facilities) {
  return normalizeCollection(facilities).map(facility => ({
    ...facility,
    badges: normalizeCollection(facility?.badges),
  }))
}

function normalizeFacilityDetail(data) {
  return {
    ...data,
    parcelDestinations: normalizeSectionArray(data?.parcelDestinations),
    materialSources: normalizeSectionArray(data?.materialSources),
    vehicleOfferDestinations: normalizeSectionArray(data?.vehicleOfferDestinations),
    trailerOfferDestinations: normalizeSectionArray(data?.trailerOfferDestinations),
  }
}

export const usePhoneLogisticsStore = defineStore("phoneLogistics", () => {
  const { events } = useBridge()

  const initialized = ref(false)
  const loaded = ref(false)
  const loadingList = ref(false)
  const loadingDetail = ref(false)
  const loadingDetailFor = ref("")
  const careerActive = ref(true)
  const levelId = ref("")
  const listFetchedAt = ref(0)
  const facilities = ref([])
  const selectedFacilityId = ref("")
  const detailByFacility = ref({})
  const detailErrors = ref({})
  const error = ref(null)

  const onFacilityList = data => {
    loaded.value = true
    loadingList.value = false
    error.value = null

    const nextLevelId = data?.levelId || ""
    if (levelId.value && nextLevelId !== levelId.value) {
      detailByFacility.value = {}
      detailErrors.value = {}
      selectedFacilityId.value = ""
    }

    levelId.value = nextLevelId
    careerActive.value = data?.careerActive !== false
    facilities.value = normalizeFacilityList(data?.facilities)
    listFetchedAt.value = Date.now()

    if (selectedFacilityId.value) {
      const selectedStillExists = facilities.value.some(facility => facility.id === selectedFacilityId.value)
      if (!selectedStillExists) {
        selectedFacilityId.value = ""
        loadingDetail.value = false
        loadingDetailFor.value = ""
      }
    }
  }

  const onFacilityDetail = data => {
    const facilityId = data?.facilityId
    if (!facilityId) return

    detailByFacility.value = {
      ...detailByFacility.value,
      [facilityId]: {
        data: normalizeFacilityDetail(data),
        fetchedAt: Date.now(),
      },
    }

    if (detailErrors.value[facilityId]) {
      const nextErrors = { ...detailErrors.value }
      delete nextErrors[facilityId]
      detailErrors.value = nextErrors
    }

    if (loadingDetailFor.value === facilityId) {
      loadingDetail.value = false
      loadingDetailFor.value = ""
    }
  }

  const onLogisticsError = data => {
    const payload = data || { code: "unknown_error" }
    if (payload.facilityId) {
      detailErrors.value = {
        ...detailErrors.value,
        [payload.facilityId]: payload,
      }
      if (loadingDetailFor.value === payload.facilityId) {
        loadingDetail.value = false
        loadingDetailFor.value = ""
      }
      return
    }

    loadingList.value = false
    loaded.value = true
    error.value = payload
  }

  const selectedFacility = computed(() => (
    facilities.value.find(facility => facility.id === selectedFacilityId.value) || null
  ))

  const selectedDetail = computed(() => (
    selectedFacilityId.value && detailByFacility.value[selectedFacilityId.value]
      ? detailByFacility.value[selectedFacilityId.value].data
      : null
  ))

  const selectedDetailError = computed(() => (
    selectedFacilityId.value ? detailErrors.value[selectedFacilityId.value] || null : null
  ))

  function registerEvents() {
    events.on("phoneLogisticsFacilityList", onFacilityList)
    events.on("phoneLogisticsFacilityDetail", onFacilityDetail)
    events.on("phoneLogisticsError", onLogisticsError)
  }

  function unregisterEvents() {
    events.off("phoneLogisticsFacilityList", onFacilityList)
    events.off("phoneLogisticsFacilityDetail", onFacilityDetail)
    events.off("phoneLogisticsError", onLogisticsError)
  }

  function resetState() {
    loaded.value = false
    loadingList.value = false
    loadingDetail.value = false
    loadingDetailFor.value = ""
    careerActive.value = true
    levelId.value = ""
    listFetchedAt.value = 0
    facilities.value = []
    selectedFacilityId.value = ""
    detailByFacility.value = {}
    detailErrors.value = {}
    error.value = null
  }

  async function init() {
    if (initialized.value) return
    resetState()
    registerEvents()
    initialized.value = true
    await lua.extensions.load("ui_phone_logistics")
    await refreshList(true)
  }

  async function cleanup() {
    if (!initialized.value) return
    unregisterEvents()
    initialized.value = false
    await lua.extensions.unload("ui_phone_logistics")
    resetState()
  }

  async function refreshList(force = false) {
    const isFresh = Date.now() - listFetchedAt.value < LIST_TTL_MS
    if (!force && loaded.value && isFresh) return
    loadingList.value = true
    error.value = null
    await lua.ui_phone_logistics.requestFacilityList()
  }

  async function selectFacility(facilityId, force = false) {
    selectedFacilityId.value = facilityId || ""
    if (!facilityId) {
      loadingDetail.value = false
      loadingDetailFor.value = ""
      return
    }

    const cached = detailByFacility.value[facilityId]
    const isFresh = cached && (Date.now() - cached.fetchedAt < DETAIL_TTL_MS)
    if (!force && isFresh) return

    if (force && cached) {
      const nextDetails = { ...detailByFacility.value }
      delete nextDetails[facilityId]
      detailByFacility.value = nextDetails
    }

    loadingDetail.value = true
    loadingDetailFor.value = facilityId
    detailErrors.value = {
      ...detailErrors.value,
      [facilityId]: null,
    }
    await lua.ui_phone_logistics.requestFacilityDetail(facilityId)
  }

  function backToList() {
    selectedFacilityId.value = ""
    loadingDetail.value = false
    loadingDetailFor.value = ""
  }

  async function navigateToFacility(facilityId, parkingSpotPath = "") {
    if (!facilityId) return
    await lua.ui_phone_logistics.navigateToFacility(facilityId, parkingSpotPath)
  }

  return {
    loaded,
    loadingList,
    loadingDetail,
    loadingDetailFor,
    careerActive,
    levelId,
    listFetchedAt,
    facilities,
    selectedFacilityId,
    detailByFacility,
    detailErrors,
    error,
    selectedFacility,
    selectedDetail,
    selectedDetailError,
    init,
    cleanup,
    refreshList,
    selectFacility,
    backToList,
    navigateToFacility,
  }
})

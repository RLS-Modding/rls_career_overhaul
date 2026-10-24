// Bridge map: generated namespaces; explicit argument declarations; guarded Lua transport;
// namespace fallback ownership and discovery cleanup. Stock functions keep their own signatures.
import { lua as luaImport } from "@/bridge"
import { onLuaNamespacesChanged } from './luaScopeRuntime.js'

const MOD_NAMESPACES = [
  // <generated:namespaces> from gameplay/overhaul/ui/owners (tests/support/checks/ui/generate_lua_scopes.lua)
  "overhaul_phone_phone",
  "overhaul_phone_apps_layout",
  "overhaul_phone_apps_time",
  "overhaul_phone_apps_logistics",
  "overhaul_phone_apps_realEstate",
  "overhaul_phone_apps_freContracts",
  "overhaul_phone_apps_freeroamEvents",
  "overhaul_world_weather",
  "overhaul_jobs_beamEats",
  "overhaul_jobs_facilityWork",
  "overhaul_career_work_employment",
  "overhaul_career_economy_globalEconomy",
  "overhaul_career_logistics_vehicleTransfer",
  "overhaul_career_business_manager",
  "overhaul_career_business_skillTree",
  "overhaul_career_challengeModes",
  "overhaul_shell_saveImport",
  "overhaul_career_police_certification",
  "overhaul_career_economy_bank",
  "overhaul_career_business_computer",
  "overhaul_career_business_fleet",
  "overhaul_career_business_partCustomization",
  "overhaul_career_business_vehicleTuning",
  "overhaul_career_business_racingTeam_racingTeam",
  "overhaul_career_business_tuningShop_tuningShop",
  "overhaul_career_business_tuningShop_kits",
  "overhaul_career_carmeets_carmeets",
  "overhaul_career_carmeets_reputation",
  "overhaul_career_economy_credit",
  "overhaul_career_parts_dyno_dynoSession",
  "overhaul_career_economy_economyAdjusterPolicy",
  "overhaul_career_parts_engines_enginePackages",
  "overhaul_career_parts_engines_engineCertification",
  "overhaul_career_parts_engines_engineRetail",
  "overhaul_career_garage_garageManager",
  "overhaul_career_guide_guide",
  "overhaul_career_economy_loans",
  "overhaul_career_maintenance_maintenanceComputer",
  "overhaul_career_maintenance_maintenanceMode",
  "overhaul_career_economy_payment",
  "overhaul_career_economy_playerAttributes",
  "overhaul_career_garage_property_propertyMortgage",
  "overhaul_career_garage_property_propertyRentals",
  "overhaul_career_garage_property_realEstateNegotiation",
  "overhaul_career_repair_roadsideService",
  "overhaul_career_work_equipmentRental",
  "overhaul_world_sleep",
  "overhaul_career_garage_switchMap",
  "overhaul_career_market_auction_auction",
  "overhaul_career_economy_xpAdjusterPolicy",
  "overhaul_career_guide_betaWelcome",
  "overhaul_career_progression_skillsPage",
  "overhaul_career_garage_computer",
  "overhaul_career_garage_zoneVehicles",
  "overhaul_career_logistics_cargoScreen",
  "overhaul_career_logistics_general",
  "overhaul_career_logistics_progress",
  "overhaul_career_maintenance_fuel",
  "overhaul_career_market_inspectVehicle",
  "overhaul_career_repair_insurance",
  "overhaul_career_repair_repairScreen",
  "overhaul_career_garage_inventory",
  "overhaul_career_logistics_loanerVehicles",
  "overhaul_career_progression_logbook",
  "overhaul_career_market_marketplace",
  "overhaul_career_progression_milestones_milestones",
  "overhaul_career_parts_painting",
  "overhaul_career_parts_partInventory",
  "overhaul_career_parts_partShopping",
  "overhaul_career_parts_tuning",
  "overhaul_career_guide_tutorialPopups",
  "overhaul_career_ui_uiUtils",
  "overhaul_career_market_valueCalculator",
  "overhaul_career_parts_vehiclePerformance",
  "overhaul_career_market_vehicleShopping",
  "overhaul_jobs_cardGames_cardGames",
  "overhaul_jobs_quarry_quarry",
  "overhaul_jobs_recovery",
  "overhaul_vehicles_obdScanner",
  "overhaul_phone_camera",
  "overhaul_jobs_repo",
  "overhaul_jobs_taxi_taxi",
  "guihooks",
  "overhaul_world_maps",
  "overhaul_world_organizations",
  "overhaul_dev_testerMenu",
  "overhaul_career_career",
  "overhaul_career_saveSystem",
  "overhaul_integration_services_garageMode",
  // </generated:namespaces>
]

const MOD_FUNCTIONS = ["ui_message"]

// Coercion belongs to the current Overhaul endpoint, independent of stock namespace spellings.
const OVERHAUL_ARGUMENT_TYPES = {
  "overhaul_career_economy_playerAttributes.getFinancialHistoryView": ["Object"],
  "overhaul_career_career.createOrLoadCareerAndStart": ["String", "Any", "Object"],
  "overhaul_career_career.getSaveFoldersForProfile": ["String"],
  "overhaul_career_garage_computer.computerButtonCallback": ["String", "Any"],
  "overhaul_career_garage_computer.openComputerMenuById": ["String"],
  "overhaul_career_garage_inventory.chooseVehicleFromMenu": ["Number", "Number", "Boolean"],
  "overhaul_career_garage_inventory.enterVehicle": ["Number"],
  "overhaul_career_garage_inventory.expediteRepairFromInventory": ["Number", "Number"],
  "overhaul_career_garage_inventory.getVehicle": ["Number"],
  "overhaul_career_garage_inventory.getVehicleUiData": ["Number"],
  "overhaul_career_garage_inventory.getVehicleDetailsUiData": ["Number"],
  "overhaul_career_garage_inventory.sendVehicleUpdatesToUi": [],
  "overhaul_career_garage_inventory.isLicensePlateValid": ["String"],
  "overhaul_career_garage_inventory.isVehicleNameValid": ["String"],
  "overhaul_career_garage_inventory.openMenuFromComputer": ["String"],
  "overhaul_career_garage_inventory.purchaseLicensePlateText": ["Number", "String", "Number"],
  "overhaul_career_garage_inventory.removeVehicleObject": ["Number"],
  "overhaul_career_garage_inventory.renameVehicle": ["Number", "String"],
  "overhaul_career_garage_inventory.returnLoanedVehicleFromInventory": ["Number"],
  "overhaul_career_garage_inventory.sellVehicle": ["Number"],
  "overhaul_career_garage_inventory.sellVehicleFromInventory": ["Number"],
  "overhaul_career_garage_inventory.setFavoriteVehicle": ["Number"],
  "overhaul_career_garage_inventory.setLicensePlateText": ["Number", "String"],
  "overhaul_career_guide_tutorialPopups.introPopup": ["String", "Boolean"],
  "overhaul_career_logistics_cargoScreen.abandonAcceptedOffer": ["Number"],
  "overhaul_career_logistics_cargoScreen.clearTransientMoveForCargo": ["Number"],
  "overhaul_career_logistics_cargoScreen.dropOffPopupClosed": ["String"],
  "overhaul_career_logistics_cargoScreen.moveCargoFromUi": ["Number", "Object"],
  "overhaul_career_logistics_cargoScreen.setBigMapPanEnabled": ["Boolean"],
  "overhaul_career_logistics_cargoScreen.setCargoRoute": ["Number", "Boolean"],
  "overhaul_career_logistics_cargoScreen.setCargoScreenTab": ["String"],
  "overhaul_career_logistics_cargoScreen.showLocationRoutePreview": ["Any", "Boolean"],
  "overhaul_career_logistics_cargoScreen.showRoutePreview": ["Object"],
  "overhaul_career_logistics_cargoScreen.spawnOffer": ["Number", "Any"],
  "overhaul_career_logistics_cargoScreen.toggleOfferForSpawning": ["Number"],
  "overhaul_career_logistics_general.setAutomaticRoute": ["Boolean"],
  "overhaul_career_logistics_general.setDeliveryTimePaused": ["Boolean"],
  "overhaul_career_logistics_general.setDetailedDropOff": ["Boolean"],
  "overhaul_career_logistics_general.setSetting": ["String", "Any"],
  "overhaul_career_logistics_loanerVehicles.getLoanedVehiclesByOrg": ["String"],
  "overhaul_career_logistics_loanerVehicles.markForSpawning": ["Object"],
  "overhaul_career_logistics_loanerVehicles.returnVehicle": ["Number"],
  "overhaul_career_logistics_loanerVehicles.spawnAndLoanVehicle": ["Object", "Object"],
  "overhaul_career_logistics_progress.activateSound": ["String", "Boolean"],
  "overhaul_career_maintenance_fuel.onChangeFlowRate": ["Number", "Number"],
  "overhaul_career_maintenance_fuel.uiButtonStartFueling": ["String"],
  "overhaul_career_maintenance_fuel.uiButtonStartFuelingTank": ["Number"],
  "overhaul_career_maintenance_fuel.uiButtonStopFueling": ["String"],
  "overhaul_career_maintenance_fuel.uiButtonStopFuelingTank": ["Number"],
  "overhaul_career_maintenance_fuel.uiSetSelectedTankIndex": ["Number"],
  "overhaul_career_market_inspectVehicle.onInspectScreenChanged": ["Boolean"],
  "overhaul_career_market_marketplace.acceptOffer": ["Number", "Number"],
  "overhaul_career_market_marketplace.declineOffer": ["Number", "Number"],
  "overhaul_career_market_marketplace.makeNegotiationOffer": ["Number"],
  "overhaul_career_market_marketplace.menuOpened": ["Boolean"],
  "overhaul_career_market_marketplace.removeVehicleListing": ["Number"],
  "overhaul_career_market_marketplace.startNegotiateBuyingOffer": ["Number", "Number"],
  "overhaul_career_market_marketplace.startNegotiateSellingOffer": ["Number"],
  "overhaul_career_market_vehicleShopping.buyFromPurchaseMenu": ["String", "Any"],
  "overhaul_career_market_vehicleShopping.cancelPurchase": ["String"],
  "overhaul_career_market_vehicleShopping.navigateToPos": ["Object"],
  "overhaul_career_market_vehicleShopping.openPurchaseMenu": ["String", "Number"],
  "overhaul_career_market_vehicleShopping.quickTravelToVehicle": ["Number"],
  "overhaul_career_market_vehicleShopping.selectSeller": ["String"],
  "overhaul_career_market_vehicleShopping.showVehicle": ["Number"],
  "overhaul_career_market_vehicleShopping.updateInsuranceSelection": ["Number"],
  "overhaul_career_parts_painting.setPaints": ["Object"],
  "overhaul_career_parts_partShopping.installPartByPartShopId": ["Number"],
  "overhaul_career_parts_partShopping.removePartBySlot": ["String"],
  "overhaul_career_parts_tuning.apply": ["Object"],
  "overhaul_career_parts_tuning.removeVarFromShoppingCart": ["String"],
  "overhaul_career_parts_vehiclePerformance.startDragTest": ["Number"],
  "overhaul_career_progression_logbook.setLogbookEntryRead": ["String", "Boolean"],
  "overhaul_career_progression_milestones_milestones.claim": ["Number"],
  "overhaul_career_progression_skillsPage.getBranchSkillCardData": ["String"],
  "overhaul_career_progression_skillsPage.getLandingPageData": ["String"],
  "overhaul_career_repair_insurance.calculateInsurancePremium": ["Number", "Object", "Object"],
  "overhaul_career_repair_insurance.calculateRenewalPriceDetails": ["Number", "Any"],
  "overhaul_career_repair_insurance.calculateVehiclePremium": ["Number", "Object", "Object"],
  "overhaul_career_repair_insurance.changeInvVehInsurance": ["Number", "Number"],
  "overhaul_career_repair_insurance.changeInvVehInsuranceCoverageOptions": ["Number", "Object"],
  "overhaul_career_repair_insurance.getInvVehHaveFuelDiscount": ["Object"],
  "overhaul_career_repair_insurance.getProposablePoliciesForVehInv": ["Number"],
  "overhaul_career_repair_insurance.inventoryVehNeedsRepair": ["Number"],
  "overhaul_career_repair_insurance.openChooseInsuranceScreen": ["String", "Object"],
  "overhaul_career_repair_insurance.openRepairMenu": ["Object", "Any"],
  "overhaul_career_repair_insurance.payInsuranceScoreReset": ["Number"],
  "overhaul_career_repair_insurance.purchaseInsurance": ["Number"],
  "overhaul_career_repair_insurance.saveNewInsuranceCoverageOptions": ["Number", "Object"],
  "overhaul_career_repair_insurance.saveNewVehicleCoverageOptions": ["Number", "Object"],
  "overhaul_career_repair_insurance.sendChangeInsuranceDataToTheUI": ["Number"],
  "overhaul_career_repair_insurance.sendChooseInsuranceDataToTheUI": ["String", "Number", "Number"],
  "overhaul_career_repair_insurance.startRepairInGarage": ["Object", "Object"],
  "overhaul_career_repair_repairScreen.openRepairMenu": ["Object", "Any"],
  "overhaul_career_repair_repairScreen.startRepairInGarage": ["Number", "Object"],
  "overhaul_career_saveSystem.removeProfile": ["String"],
  "overhaul_career_saveSystem.removeSaveFolder": ["String", "String"],
  "overhaul_career_saveSystem.renameProfile": ["String", "String"],
  "overhaul_career_saveSystem.saveCurrent": ["Any", "Any", "Optional(String)"],
  "overhaul_career_ui_uiUtils.callCareerPauseContextButtons": ["Number"],
}

const ARG_TRANSFORMERS = {
  Boolean,
  String,
  Number,
  Integer: value => +value | 0,
  Object,
}

function coerceOverhaulArgs(path, args) {
  const declaredTypes = OVERHAUL_ARGUMENT_TYPES[path]
  if (!declaredTypes) return args
  return args.map((arg, index) => {
    const declaredType = declaredTypes[index]
    const type = declaredType?.startsWith("Optional(") ? declaredType.slice(9, -1) : declaredType
    const transform = type && ARG_TRANSFORMERS[type]
    return transform ? transform(arg) : arg
  })
}

function getApi() {
  return window.bngApi || window.beamng
}

function serializeArgs(path, args) {
  const api = getApi()
  return coerceOverhaulArgs(path, args)
    .map(arg => (typeof api?.serializeToLua === "function" ? api.serializeToLua(arg) : "nil"))
    .join(", ")
}

export function callModLua(path, ...args) {
  const api = getApi()
  if (!api?.engineLua) return Promise.resolve(undefined)
  const serialized = serializeArgs(path, args)
  const parts = String(path || "").split(".")
  // Stub namespaces (e.g. overhaul_career_work_employment) can exist on the
  // JS bridge before Lua has loaded the extension. Indexing a nil global is a
  // fatal engine error, so resolve roots via rawget and skip missing methods.
  if (parts.length >= 2) {
    const root = parts[0]
    const method = parts.slice(1).join(".")
    const expr =
      `(function()` +
      ` local m=rawget(_G,${JSON.stringify(root)})` +
      ` if type(m)~="table" then return nil end` +
      ` local f=m[${JSON.stringify(method)}]` +
      ` if type(f)~="function" then return nil end` +
      ` return f(${serialized})` +
      ` end)()`
    return new Promise(resolve => {
      api.engineLua(expr, resolve)
    })
  }
  return new Promise(resolve => {
    api.engineLua(`${path}(${serialized})`, resolve)
  })
}

export function callModLuaIfAvailable(path, ...args) {
  const api = getApi()
  if (!api?.engineLua) return Promise.resolve(undefined)
  const separator = path.lastIndexOf(".")
  const namespace = separator > 0 ? path.slice(0, separator) : path
  return new Promise(resolve => {
    api.engineLua(
      `(${namespace} and ${path}) and ${path}(${serializeArgs(path, args)}) or nil`,
      resolve,
    )
  })
}

function luaTargets() {
  const targets = []
  if (luaImport) targets.push(luaImport)
  if (window.bridge?.lua && window.bridge.lua !== luaImport) targets.push(window.bridge.lua)
  return targets
}

const liveNamespaces = new WeakSet()
const ownerNamespaces = new Map()

function wrapNamespace(nsName, ns, luaTarget) {
  if (!ns || typeof ns !== "object") return ns
  if (ns.__overhaulProxy) return ns
  return new Proxy(ns, {
    get(target, prop, receiver) {
      if (prop === "__overhaulProxy") return true
      const live = liveNamespaces.has(receiver)
      if (typeof prop === "symbol") return live ? undefined : Reflect.get(target, prop, receiver)
      const current = live ? luaTarget?.[nsName] : receiver
      const source = current === receiver ? target : current
      const value = source && typeof source === "object" ? Reflect.get(source, prop, source) : undefined
      if (typeof value === "function") return value.bind(source)
      if (!live && value !== undefined) return value
      return (...args) => callModLua(`${nsName}.${String(prop)}`, ...args)
    },
  })
}

// Owner handles share the installed namespace proxy. A retained business handle follows root replacement,
// while ordinary bridge namespaces retain the stock wrapper behavior.
export function getLuaNamespace(name) {
  if (!name) return undefined
  if (ownerNamespaces.has(name)) return ownerNamespaces.get(name)
  const current = luaImport[name]
  const namespace = current && typeof current === "object"
    ? wrapNamespace(name, current, luaImport) : wrapNamespace(name, {}, luaImport)
  // Missing owners keep a detached handle: discovery alone owns bridge namespace presence and cleanup.
  if (current && typeof current === "object") luaImport[name] = namespace
  liveNamespaces.add(namespace)
  ownerNamespaces.set(name, namespace)
  return namespace
}

let discoveredNamespaces = []
const declaredProxies = new WeakMap()

function patchLuaObject(lua) {
  if (!lua) return
  let owned = declaredProxies.get(lua)
  if (!owned) { owned = new Map(); declaredProxies.set(lua, owned) }
  for (const [name, proxy] of owned) {
    if (discoveredNamespaces.includes(name)) continue
    if (lua[name] === proxy) delete lua[name]
    owned.delete(name)
  }

  if (!lua.__overhaulBridgeInstalled) {
    for (const key of Object.keys(lua)) {
      if (lua[key] && typeof lua[key] === "object") {
        lua[key] = wrapNamespace(key, lua[key], lua)
      }
    }
  }

  for (const name of [...MOD_NAMESPACES, ...discoveredNamespaces]) {
    const current = lua[name]
    if (!current || typeof current !== "object") {
      lua[name] = wrapNamespace(name, {}, lua)
      if (!MOD_NAMESPACES.includes(name)) owned.set(name, lua[name])
    } else if (!current.__overhaulProxy) {
      lua[name] = wrapNamespace(name, current, lua)
    }
  }

  for (const name of MOD_FUNCTIONS) {
    if (typeof lua[name] !== "function") {
      lua[name] = (...args) => callModLua(name, ...args)
    }
  }

  lua.__overhaulBridgeInstalled = true
}

export function installLuaBridgeFallbacks() {
  for (const lua of luaTargets()) patchLuaObject(lua)
  return luaImport
}

installLuaBridgeFallbacks()

onLuaNamespacesChanged(names => {
  discoveredNamespaces = names
  installLuaBridgeFallbacks()
})

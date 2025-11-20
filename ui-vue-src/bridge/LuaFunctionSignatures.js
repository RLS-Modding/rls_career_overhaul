import { Any, Integer, run, runRaw } from "./libs/Lua.js"
import { getMockedData } from "../../devutils/mock.js"
import { sendGUIHook } from "../../devutils/browser.js"

const withMocked = (sig, getData) => ((sig.mocked = getData), sig)

// Define Lua function signatures, and normal functions here
//
// Signatures are transformed to proper 'run' calls at runtime, other functions are left untouched -
// this allows for the addition of more complex functions should they be needed
//
// If an arrow function is used, it is expected to return a signature:
//    undefined/falsey - all parameter types will be as passed in arguments
//    String/Number/etc. - all params will be converted to correct type
//    [String, Number, ...] - params will convert according that specified for each one
//
// If a normal function is used, it will not be transformed.
//
// The run & runRaw functions both return Promises, so that you may utilise any return value from the Lua call,
// this is much the same to passing a callback to engineLua in the Angular code
//
// If you want an alternative function to be used if the bngAPI is unavailable, you can build such using 'withMocked'.
// Simply pass your normal function/signature as the first parameter, and the mock function as the second one. The
// mock function will always be treated as a mock function - regardless of whether it is an arrow function. It should
// accept the same paramaeters as the non-mock version. If a mock function does not return a promise, its return value
// will automatically be wrapped in one
//

export default {
  // -- Dev -----------------------------------------------------------------------
  dev: {
    getMockedData: key => String,
  },

  // -- Real ----------------------------------------------------------------------

  // TODO - incomplete, add as neeeded

  getVehicleColor: () => {},
  getVehicleColorPalette: index => Integer,
  resetGameplay: playerID => Integer,
  quit: () => {},
  checkFSErrors: () => {},
  returnToMainMenu: () => {},



  guihooks: {
    // can take multiple params - just add them individually after the hook name
    trigger: withMocked(hookName => String, sendGUIHook),
  },

  simTimeAuthority: {
    togglePause: () => {},
    getPause: () => {},
    pause: (state) => Boolean,
    pushPauseRequest: () => {},
    popPauseRequest: () => {},
  },

  commands: {
    toggleCamera: () => {},
  },

  ui_audio: {
    playEventSound: (soundClass, type) => [String, String],
  },

  career_career: {
    closeAllMenus: () => {},
    isActive: () => {},
    sendAllCareerSaveSlotsData: () => {},
    sendCurrentSaveSlotData: () => {},
    createOrLoadCareerAndStart: (id, specificAutosave, tutorial, hardcore, challengeId) => [String, Any, Boolean, Boolean, String],
    applyChallengeConfig: config => Object
  },

  career_saveSystem: {
    saveCurrent: () => {},
    removeSaveSlot: id => String,
    renameSaveSlot: (name, newName) => [String, String],
  },

  career_challengeModes: {
    discoverChallenges: () => {},
    getChallengeOptionsForCareerCreation: () => {},
    getChallengeEditorData: () => {},
    createChallengeFromUI: data => Any,
    startChallenge: id => String,
    getActiveChallenge: () => {},
    isChallengeActive: () => {},
    requestChallengeCompleteData: () => {},
    getChallengeSeeded: id => String,
    requestChallengeSeeded: id => {},
    getChallengeDataForEdit: id => String,
    requestChallengeDataForEdit: id => {},
    deleteChallenge: id => String,
    encodeChallengeDataToSeed: data => Any,
    decodeSeedToChallengeData: seed => String,
    requestGenerateRandomSeed: () => {},
    requestSeedEncode: (requestId, challengeData) => [String, Any],
    requestSeedDecode: (requestId, seed) => [String, String],
    createChallengeFromSeedUI: (seed, name, description) => [String, String, String],
    generateRandomChallengeData: () => {}
  },

  career_modules_uiUtils: {
    getCareerStatusData: withMocked(
      () => {},
      () => getMockedData("career.status")
    ),
    getCareerSimpleStats: withMocked(
      () => {},
      () => getMockedData("career.simpleStats")
    ),
    getCareerPauseContextButtons: () => {},
    callCareerPauseContextButtons: id => Number,
    getCareerCurrentLevelName: () => {},
  },

  career_modules_fuel: {
    requestRefuelingTransactionData: () => {},
    sendUpdateDataToUI: () => {},
    uiButtonStartFueling: energyType => String,
    uiButtonStopFueling: energyType => String,
    onChangeFlowRate: flowRate => Number,
    payPrice: () => {},
    uiCancelTransaction: () => {},
  },

  career_modules_logbook: {
    getLogbook: withMocked(
      () => {},
      () => getMockedData("logbook.sample")
    ),
    setLogbookEntryRead: (id, state) => [String, Boolean],
  },

  career_modules_milestones_milestones: {
    getMilestones: () => {},
    claim: id => {},
    unclaimedMilestonesCount: () => {},
  },

  career_modules_branches_landing: {
    openBigMapWithMissionSelected: id => String,
    getBranchSkillCardData: id => String,
    getBranchPageData: id => String,
    getLandingPageData: domain => String,
    getCargoProgressForUI: () => {},
  },

  career_modules_partShopping: {
    cancelShopping: () => {},
    applyShopping: () => {},
    installPartByPartShopId: id => Number,
    removePartBySlot: slot => String,
    sendShoppingDataToUI: () => {},
  },

  career_modules_vehicleShopping: {
    showVehicle: id => String,
    navigateToPos: (pos, vehicleId) => Object, // vehicleId is optional
    openShop: (seller, computerId) => [Any, Any], // i think this needs to be Any instead of String to also allow nil
    cancelShopping: () => {},
    quickTravelToVehicle: id => String,
    openPurchaseMenu: (purchaseType, shopId) => [String, String],
    openInventoryMenuForTradeIn: () => {},
    buyFromPurchaseMenu: (purchaseType, options) => [String, Any],
    cancelPurchase: purchaseType => String,
    getShoppingData: () => {},
    sendPurchaseDataToUi: () => {},
    removeTradeInVehicle: () => {},
    onShoppingMenuClosed: () => {},
    // lightweight refresh + navigation helpers
    updateVehicleList: fromScratch => Boolean,
    navigateToDealership: dealershipId => String,
    taxiToDealership: dealershipId => String,
    getTaxiPriceToDealership: dealershipId => String,
    setShoppingUiOpen: open => Boolean,
  },

  career_modules_marketplace: {
    getListings: () => {},
    menuOpened: open => Boolean,
    acceptOffer: (inventoryId, offerIndex) => [Number, Number],
    declineOffer: (inventoryId, offerIndex) => [Number, Number],
    listVehicles: (inventoryIds) => [Array],
    openMenu: () => {},
    removeVehicleListing: inventoryId => Number,
  },

  career_modules_testDrive: {
    stop: () => {},
  },

  career_modules_inspectVehicle: {
    startTestDrive: () => {},
    onInspectScreenChanged: enabled => Boolean,
    onPurchaseMenuClosed: () => {},
    repairVehicle: () => {},
  },

  career_modules_loanerVehicles: {
    markForSpawning: loanInfo => {},
    spawnAndLoanVehicle: (vehicleInfo, loanInfo) => [Object, Object],
    getLoanedVehiclesByOrg: orgId => String,
    returnVehicle: inventoryId => Number,
  },

  career_modules_inventory: {
    sellVehicle: id => Number,
    sellVehicleFromInventory: id => Number,
    instantSellVehicle: id => Number,
    returnLoanedVehicleFromInventory: id => Number,
    expediteRepairFromInventory: (inventoryId, price) => [Number, Number],
    enterVehicle: id => Number,
    openMenuFromComputer: computerId => String,
    closeMenu: () => {},
    chooseVehicleFromMenu: (vehId, buttonId, repairPrevVeh) => [Number, Number, Boolean],
    setFavoriteVehicle: id => Number,
    sendDataToUi: () => {},
    removeVehicleObject: id => Number,
    getVehicle: id => Number,
    getVehicles: () => {},
    getVehicleUiData: id => Number,
    isEmpty: () => {},
    setLicensePlateText: (inventoryId, text) => [Number, String],
    purchaseLicensePlateText: (inventoryId, text, money) => [Number, String, Number],
    isLicensePlateValid: text => String,
    isVehicleNameValid: text => String,
    renameVehicle: (inventoryId, name) => [Number, String],
    getVehiclesForSale: () => {},
    removeVehicleFromSale: id => Number,
    removeVehicle: id => Number,
    deliverVehicle: (id, money) => [Number, Number],
    storeVehicle: id => Number,
  },

  career_modules_vehiclePerformance: {
    startDragTest: id => Number,
    startDragTestFromOutsideMenu: (id, computerId) => [Number, String],
    cancelTest: () => {},
  },

  career_modules_partInventory: {
    openMenu: computerId => Any,
    closeMenu: () => {},
    sendUIData: () => {},
    sellParts: ids => Array,
    partInventoryClosed: () => {},
  },

  career_modules_insurance: {
    getProposablePoliciesForVehInv: invVehId => Number,
    changeVehPolicy: (invVehId, policyId) => [Number, Number],
      applyVehPolicyChange: (invVehId, policyId, overridesIdx0) => [Number, Number],
      setVehPerkOverride: (invVehId, perkName, choiceIndex) => [Number, String, Number],
    payBonusReset: policyId => Number,
    purchasePolicy: id => Number,
    calculatePremiumDetails: (policyId, tempPerks) => [Number, Any],
    getPremiumWithPolicyScoreForVehicle: (policyId, invVehId) => [Number, Number],
    changePolicyPerks: (policyId, changedPerks) => [Number, Object],
    startRepairInGarage: (vehicleInfo, repairOptionData) => [Object, Object],
    openRepairMenu: (vehicleInfo, originComputerId) => [Object, Any],
    getRepairData: () => {},
    closeMenu: () => {},
    sendUIData: () => {},
      getApplicablePoliciesForVehicle: invVehId => Number,
    inventoryVehNeedsRepair: inventoryId => Number,
  },

  career_modules_tuning: {
    apply: tuningValues => Object,
    start: (vehId, origin) => [Any, Any],
    getTuningData: () => {},
    close: () => {},
    applyShopping: () => {},
    cancelShopping: () => {},
    removeVarFromShoppingCart: varName => String,
  },

  career_modules_painting: {
    apply: () => {},
    start: (vehId, origin) => [Any, Any],
    getPaintData: () => {},
    close: () => {},
    setPaints: paint => Object,
    getFactoryPaint: () => {},
    onUIOpened: () => {},
  },

  career_modules_questManager: {
    setQuestAsNotNew: id => String,
    claimRewardsById: id => String,
  },

  career_modules_computer: {
    onMenuClosed: () => {},
    getComputerUIData: () => {},
    computerButtonCallback: (buttonId, inventoryId) => [String, Any],
    openComputerMenuById: computerId => String,
  },

  career_modules_delivery_general: {
    setAutomaticRoute: enabled => Boolean,
    setDetailedDropOff: enabled => Boolean,
    setSetting: (key, value) => {},
    getSettings: () => {},
    setDeliveryTimePaused: paused => {},
  },

  career_modules_delivery_cargoScreen: {
    requestCargoDataForUi: (facilityId, parkingSpotPath, updateMaxTimeStamp) => [Any, Any, Any],
    moveCargoFromUi: (cargoId, targetLocation) => [Number, Object],
    commitDeliveryConfiguration: () => {},
    cancelDeliveryConfiguration: () => {},
    exitDeliveryMode: () => {},
    exitCargoOverviewScreen: () => {},
    showCargoRoutePreview: cargoId => Any,
    showVehicleOfferRoutePreview: offerId => Any,
    setCargoRoute: (cargoId, origin) => [Number, Boolean],
    showLocationRoutePreview: (location, asProvider) => {},
    showCargoContainerHelpPopup: () => {},
    setBestRoute: () => {},
    spawnOffer: (offerId, fadeToBlack) => [Number, Any],
    abandonAcceptedOffer: vehId => Number,
    setCargoScreenTab: tab => String,
    unloadCargoPopupClosed: () => {},
    moveMaterialFromUi: () => {},
    requestDropOffData: () => {},
    confirmDropOffData: (data, facId, psPath) => {},
    dropOffPopupClosed: mode => {},
    clearTransientMoveForCargo: cargoId => {},
    clearTransientMovesForStorage: materialType => {},
    applyTransientMoves: () => {},
    toggleOfferForSpawning: id => {},
    tryLoadAll: cargoIds => {},
    showRoutePreview: route => {},
    deliveryScreenExternalButtonPressed: id => Any,
  },

  career_modules_delivery_progress: {
    activateSound: (soundLabel, active) => {},
  },

  career_modules_linearTutorial: {
    introPopup: (key, force) => {},
    wasIntroPopupsSeen: pages => {},
    isLinearTutorialActive: () => {},
  },

  gameplay_drag_general: {
    screenshotTimeslip: () => {},
    getHistory: saveFile => [Object],
  },

  gameplay_crashTest_scenarioManager: {
    nextStepFromUI: () => {},
  },

  gameplay_discover: {
    getDiscoverPages: () => {},
    startDiscover: discoverId => String,
  },

  freeroam_organizations: {
    getUIData: () => {},
    getUIDataForOrg: orgId => String,
  },

  core_replay: {
    onInit: () => {},
    loadFile: filename => String,
    stop: () => {},
    openReplayFolderInExplorer: () => {},
    getRecordings: () => {},
    removeRecording: filename => String,
    togglePlay: () => {},
    toggleRecording: () => {},
    cancelRecording: () => {},
    toggleSpeed: speed => Number,
    pause: () => {},
    seek: positionPercent => Number,
    acceptRename: (oldFilename, newFilename) => [String, String],
    saveMissionReplay: filename => {},
    removeMissionSavedReplay: filename => {},
  },


  core_gamestate: {
    requestGameState: () => {},
  },

  core_gameContext: {
    getGameContext: withMocked(
      params => {},
      params => getMockedData("gameContext.gameContextData")
    ),
  },

  core_online: {
    requestState: () => {},
  },

  core_hardwareinfo: {
    requestState: () => {},
    getInfo: () => {},
  },

  gameplay_statistic: {
    sendGUIState: () => {},
  },

  core_quickAccess: {
    getUiData: () => {},
    selectItem: (id, buttonDown, actionIndex) => [Number, Boolean, Number],
    contextAction: (id, buttonDown, actionIndex) => [Number, Boolean, Number],
    back: () => {},
    setEnabled: (enabled, level, force) => [Boolean, String, Boolean],
    openDynamicSlotConfigurator: index => Number,
    getDynamicSlotConfigurationData: () => {},
    setDynamicSlotConfiguration: (key, data) => [String, Object],
    toggle: () => [],
    tryAction: action => String,

  },

  ui_bindingsLegend: {
    sendDataToUI: () => {},
    triggerInputAction: (action, value) => [String, Number],
  },

  freeroam_bigMapMode: {
    enterBigMap: (instant) => Object,
    exitBigMap: (force) => Boolean,
    setBigmapScreenBounds: (windowBounds, mapBounds) => {},
    navigateToMission: (poiId) => String,
    selectPoi: (poiId) => String,
    poiHovered: (poiId, active) => [String, Boolean],
    teleportToPoi: (poiId) => String,
    setOnlyIdsVisible: (poiIds) => Array,
    deselect: () => {},
    openPopupCallback: () => {},
    toggleBigMap: () => {},
    setUiFocus: (focus) => Boolean,
  },

  freeroam_bigMapPoiProvider: {
    sendMissionLocationsToMinimap: () => {},
    sendCurrentLevelMissionsToBigmap: () => {},
    toggleGroupVisibility: groupKey => String,
  },

  freeroam_vueBigMap: {
    enterBigMap: () => {},
    exitBigMap: () => {},

    getPoiData: () => {},
    getFilters: () => {},
    getGroups: () => {},
    toggleFiltersByIds: (filterIds) => Object,
    toggleFilterSectionById: (sectionId) => Object,
    getGameStateInfo: () => {},

    selectPoiFromList: (poiId) => String,
    hoverPoiFromList: (poiId, active) => [String, Boolean],
    executePoiAction: (actionId) => Number,

  },

  freeroam_freeroam: {
    startTrackBuilder: mapName => String,
  },

  extensions: {
    isExtensionLoaded: extensionName => Boolean,
    load: extensionName => String,
    unload: extensionName => String,
    hook: hook => String,

    tech_license: {
      requestState: () => {},
      isValid: () => {},
    },

    core_input_actionFilter: {
      addAction: (filter, actionName, filtered) => [Number, String, Boolean],
      setGroup: (name, actioNames) => [String, Any],
    },

    core_input_bindings: {
      FFBSafetyDataRequest: () => {},
      resetBindings: () => {},
      resetBindingsForDevice: deviceName => {},
      setMenuActionMapEnabled: state => Boolean,
      getMenuActionMapEnabled: () => {},
      setMenuActionEnabled: (enabled, actionName) => [Boolean, String],
      notifyUI: reason => String,
      saveBindingsToDisk: deviceContents => Object,
      getRecentDevices: () => {},
    },

    core_vehicle_partmgmt: {
      getConfigList: () => {},
      highlightParts: (parts, vehID) => [Object, Number],
      loadLocal: filename => String,
      resetPartsToLoadedConfig: () => {},
      resetVarsToLoadedConfig: () => {},
      resetAllToLoadedConfig: () => {},
      openConfigFolderInExplorer: () => {},
      removeLocal: configName => String,
      savedefault: () => {},
      saveLocal: filename => String,
      sendDataToUI: () => {},
      selectPart: (part, subparts) => [String, Boolean],
      selectParts: (parts, vehID) => [Object, Number],
      selectReset: () => {},
      setConfigVars: vars => Object,
      setPartsConfig: config => Object, // deprecated
      setPartsTreeConfig: config => Object, // there's also second "respawn" argument for this
      showHighlightedParts: vehID => Number,
      setDynamicTextureMaterials: () => {},
      partsSelectorChanged: parts => Object,
      sendPartsSelectorStateToUI: () => {},
    },

    core_vehicle_mirror: {
      getAnglesOffset: () => {},
      focusOnMirror: mirror_name => Any, //optional String
      setAngleOffset: (mirrorName, x, z, v, save) => [String, Number, Number, Boolean, Boolean],
    },

    gameplay_drift_general: {
      onDriftAppMounted: () => {},
      onDriftAppUnmounted: () => {},
    },

    gameplay_missions_missionScreen: {
      getMissionScreenData: withMocked(
        () => {},
        () => getMockedData("missionDetails.getMissionScreenData")
      ),
      startMissionById: (missionId, userSettings, startingOptions) => [String, Object, Object],
      stopMissionById: id => [String],
      changeUserSettings: (missionId, userSettings) => [String, Object],
      startFromWithinMission: (id, userSettings) => [String, Object],
      getActiveStarsForUserSettings: (id, userSettings) => [String, Object],
      requestStartingOptionsForUserSettings: (id, userSettings) => [String, Object],
      isAnyMissionActive: () => {},
      isMissionStartOrEndScreenActive: () => {},
      openAPMChallenges: (branch, skill) => [String, String],
      navigateToMission: id => [String],
      setPreselectedMissionId: id => [String],
      showMissionRules: id => [String],
      getMissionTiles: () => {},
      activateSound: (soundLabel, active, frequency) => {},
      activateSoundBlur: active => {
        Boolean
      },
      openVehicleSelectorForMissionBySetting: (mId, settingKey) => [String, String],
    },

    gameplay_missions_missionManager: {
      getCurrentTaskdataTypeOrNil: () => {},
    },

    gameplay_garageMode: {
      start: () => {},
      isActive: () => {},
      setCamera: view => String,
      setLighting: lights => Array,
      getLighting: () => {},
      setGarageMenuState: state => String,
      stop: () => {},
      testVehicle: () => {},
    },

    ui_dynamicDecals: {
      initialize: () => {},
      exit: () => {},
      requestUpdatedData: () => {},
      setupEditor: () => {},
      loadSaveFile: path => String,
      createSaveFile: () => {},
      saveChanges: filename => {},
      cancelChanges: () => {},
      exportSkin: skinName => String,
      moveSelectedLayer: order => Number,
      setDecalTexture: filePath => String,
      setDecalColor: colorData => Object,
      setDecalScale: decalData => Object,
      setDecalRotation: decalRotation => Number,
      setDecalSkew: decalSkew => Object,
      setDecalApplyMultiple: applyMultiple => Boolean,
      setDecalResetOnApply: resetOnApply => Boolean,
      setDecalPositionX: positionX => Number,
      setDecalPositionY: positionY => Number,
      updateDecalPosition: (positionX, positionY) => [Number, Number],
      toggleApplyingDecal: enable => Boolean,
      toggleActionMap: enable => Boolean,
      toggleDecalVisibility: enable => Boolean,
      redo: () => {},
      undo: () => {},
      createLayer: layerData => Object,
      createFillLayer: fillLayerData => Object,
      createGroupLayer: layerData => Object,
      updateLayer: layerData => Object,
      deleteSelectedLayer: () => {},
      selectLayer: layerUid => String,
      toggleStampActionMap: enable => Boolean,
      toggleLayerHighlight: uid => String,
      toggleLayerVisibility: uid => String,
    },

    ui_liveryEditor: {
      save: filename => String,
      setup: () => {},
      deactivate: () => {},
      setDecalTexture: texturePath => String,
      useMousePosition: enable => Boolean,
      useSurfaceNormal: enable => Boolean,
      requestSettingsData: () => {},
    },

    ui_liveryEditor_colorPresets: {
      getPresets: () => {},
      addPreset: () => {},
    },

    ui_liveryEditor_editor: {
      setup: () => {},
      startEditor: () => {},
      exitEditor: () => {},
      startSession: () => {},
      applyDecal: () => {},
      applySkin: () => {},
      createNew: () => {},
      loadFile: path => String,
      save: filename => String,
      applyChanges: () => {},
    },

    ui_liveryEditor_editMode: {
      reapply: () => {},
      requestReapply: () => {},
      cancelReapply: () => {},
      setActiveLayer: layerUid => String,
      setActiveLayerDirection: direction => Number,
      removeAppliedLayer: layerUid => String,
      resetCursorProperties: properties => Array,
      toggleHighlightActive: () => {},
      activate: () => {},
      deactivate: () => {},
      apply: () => {},
      requestApply: () => {},
      cancelRequestApply: () => {},
      toggleRequestApply: () => {},
      saveChanges: params => Object,
      cancelChanges: () => {},
      duplicateActiveLayer: () => {},
    },

    ui_liveryEditor_camera: {
      setOrthographicView: view => String,
      switchOrthographicViewByDirection: (x, y) => [Number, Number],
    },

    ui_liveryEditor_controls: {
      toggleUseMousePos: () => {},
    },

    ui_liveryEditor_history: {
      redo: () => {},
      undo: () => {},
    },

    ui_liveryEditor_layerAction: {
      performAction: action => String,
      toggleEnabledByLayerUid: uid => String,
    },

    ui_liveryEditor_layerEdit: {
      setup: () => {},
      setLayer: layerUid => String,
      editNewDecal: params => Object,
      translateLayer: (x, y) => [Number, Number],
      holdTranslate: (axis, value) => [String, Number],
      holdTranslateScalar: (axis, value) => [String, Number],
      holdScale: (axis, value) => [String, Number],
      holdSkew: (axis, value) => [String, Number],
      holdPrecise: enable => Boolean,
      scaleLayer: (x, y) => [Number, Number],
      skewLayer: (x, y) => [Number, Number],
      rotateLayer: (steps, counterClockwise) => [Number, Boolean],
      setPosition: (x, y) => [Number, Number],
      setScale: (x, y) => [Number, Number],
      setRotation: degrees => Number,
      setSkew: (x, y) => [Number, Number],
      setMirrored: settings => [Boolean, Boolean, Number],
      setLayerMaterials: properties => Object,
      activateStampReapply: () => {},
      cancelStampReapply: () => {},
      requestLayerMaterials: () => {},
      saveChanges: () => {},
      cancelChanges: () => {},
      requestStateData: () => {},
      requestInitialLayerData: () => {},
      requestTransform: () => {},
      endTransform: () => {},
      showCursorOrLayer: show => Boolean,
      requestReposition: () => {},
      cancelReposition: () => {},
      applyReposition: () => {},
      toggleUseMouseOrCursor: () => {},
      setIsRotationPrecise: value => Boolean,
      setAllowRotationAction: value => Boolean,
    },

    ui_liveryEditor_layers: {
      requestInitialData: () => {},
    },

    ui_liveryEditor_layers_cursor: {
      requestData: () => {},
    },

    ui_liveryEditor_layers_decals: {
      addLayer: params => Object,
      setLayer: uid => String,
    },

    ui_liveryEditor_layers_decal: {
      addLayerCentered: params => Object,
    },

    ui_liveryEditor_layers_fill: {
      updateLayer: params => Object,
      saveChanges: () => {},
      restoreLayer: () => {},
      restoreDefault: () => {},
      requestLayerData: () => {},
    },

    ui_liveryEditor_resources: {
      requestData: () => {},
      getDecalTextures: () => {},
      getTextureCategories: () => {},
      getTexturesByCategory: category => String,
    },

    ui_liveryEditor_selection: {
      duplicateSelectedLayer: () => {},
      getSelectedLayersData: () => {},
      setSelected: layerUid => String,
      setMultipleSelected: layerUids => Array,
      clearSelection: () => {},
      toggleSelection: layerIds => {},
      select: (layerIds, highlight) => [Array, Boolean],
      toggleHighlightSelectedLayer: () => {},
      requestInitialData: () => {},
    },

    ui_liveryEditor_tools: {
      useTool: tool => String,
      closeCurrentTool: () => {},
    },

    ui_liveryEditor_tools_material: {
      setColor: rgbaArray => Array,
      setMetallicIntensity: metallicIntensity => Number,
      setNormalIntensity: normalIntensity => Number,
      setRoughnessIntensity: roughnessIntensity => Number,
      setDecal: decalTexture => String,
    },

    ui_liveryEditor_tools_misc: {
      duplicate: () => {},
    },

    ui_liveryEditor_tools_group: {
      moveOrderUp: () => {},
      moveOrderDown: () => {},
      changeOrderToTop: () => {},
      changeOrderToBottom: () => {},
      moveOrderUpById: layerUid => [String],
      moveOrderDownById: layerUid => [String],
      setOrder: order => Number,
      changeOrder: (oldOrder, oldParent, newOrder, newParent) => [Number, String, Number, String],
      groupLayers: () => {},
      ungroupLayer: () => {},
    },

    ui_liveryEditor_tools_transform: {
      translate: (x, y) => [Number, Number],
      setPosition: (x, y) => [Number, Number],
      rotate: degrees => Number,
      scale: (stepsX, stepsY) => [Number, Number],
      setScale: (scaleX, scaleY) => [Number, Number],
      setRotation: degrees => Number,
      skew: (skewX, skewY) => [Number, Number],
      setSkew: (skewX, skewY) => [Number, Number],
      useStamp: () => {},
      cancelStamp: () => {},
    },

    ui_liveryEditor_tools_settings: {
      deleteLayer: () => {},
      setMirrored: (mirrored, flip) => [Boolean, Boolean],
      setVisibility: show => Boolean,
      toggleVisibility: () => {},
      toggleVisibilityById: layerUid => String,
      toggleLock: () => {},
      toggleLockById: layerUid => String,
      setMirrored: (mirrored, flip) => [Boolean, Boolean],
      setMirrorOffset: offset => Number,
      setUseMousePos: value => Boolean,
      setProjectSurfaceNormal: value => Boolean,
      rename: name => String,
    },

    ui_liveryEditor_userData: {
      requestUpdatedData: () => {},
      getSaveFiles: () => {},
      createSaveFile: filename => String,
      renameFile: (filename, newFilename) => [String, String],
      deleteSaveFile: filename => String,
    },

    ui_gameBlur: {
      replaceGroup: (groupName, list) => [String, Object],
    },

    ui_router: {
      addOrUpdateRoute: (route, config, options) => [String, Object, Object],
      push: (routeName, params) => [String, Object],
      back: () => {},
      forward: () => {},
      loadComplete: uiType => String,
      routeChangeComplete: uiType => String,
    },

    editor_api_dynamicDecals: {
      setup: () => {},
      getLayerStack: () => {},
      setLayerNameBuildString: buildString => String,
      onUpdate_: () => {},

      pushDynamicDecalsActionMap: () => {},
      popDynamicDecalsActionMap: () => {},

      addBrushStrokeLayer: () => {},
      highlightLayer: layerTable => {},
      highlightLayerByUid: layerUidString => {},
      disableDecalHighlighting: () => {},
      getHighlightedLayer: () => {},
      setLayerVisibility: (layerUidString, visibilityBool) => [String, Boolean],
      toggleLayerVisibility: layerUidString => String,
      changeDecalSize: (increaseBool, stepNumber) => {},
      changeDecalRotation: (clockwiseBool, stepRadianNumber) => {},
    },
  },

  ActionMap: {
    enableBindingCapturing: state => Boolean,
  },

  gameplay_markerInteraction: {
    startMissionById: (missionId, userSettings) => [Any, Object],
    closeViewDetailPrompt: force => Boolean,
    changeUserSettings: (missionId, userSettings) => [String, Object],
  },

  ui_missionInfo: {
    performActivityAction: id => {},
    setActivityIndexVisible: index => {},
    closeDialogue: () => {},
  },

  ui_apps_genericMissionData: {
    sendAllData: () => {},
    setData: args => Object,
    clearData: () => {},
  },
  ui_apps_pointsBar: {
    requestAllData: () => {},
  },
  ui_gameplayAppContainers: {
    // New individual app visibility API
    getVisibleApps: (containerId) => String,
    onGameplayAppContainerMounted: () => {},
    onGameplayAppContainerUnmounted: () => {},
    getAvailableApps: (containerId) => String,
    setAppVisibility: (containerId, appId, visible) => [String, String, Boolean],
    getAppVisibility: (containerId, appId) => [String, String],
    showApp: (containerId, appId) => [String, String],
    hideApp: (containerId, appId) => [String, String],
    toggleApp: (containerId, appId) => [String, String],
    hideAllApps: (containerId) => String,

    // Legacy API (deprecated but kept for compatibility)
    getContainerContext: (containerId) => String,
    setContainerContext: (containerId, context) => [String, String],
    resetContainerContext: (containerId) => String,
    getAvailableContexts: (containerId) => String,
  },


  scenetree: {
    "maincef:setMaxFPSLimit": fps => Integer, // This name is problematic and need to use [] syntax to call - intellisense should pick it up
  },

  settings: {
    notifyUI: () => {},
    setState: state => Object,
    getValue: value => String,
    setValue: (settingName, value) => [String, Any],
  },

  core_camera: {
    setFOV: (playerId, fovDeg) => [Integer, Number],
  },

  core_modmanager: {
    requestState: () => {},
  },

  core_vehicles: {
    cloneCurrent: () => {},
    getModel: model => String,
    getCurrentVehicleDetails: withMocked(
      () => {},
      () => getMockedData("vehicle.details")
    ),
    getVehicleLicenseText: id => Number, // TODO - not sure if this will be used - may need to send some Lua code directly - consider how to do this
    loadDefault: () => {},
    removeAll: () => {},
    removeAllExceptCurrent: () => {},
    removeCurrent: () => {},
    requestList: () => {},
    requestListEnd: () => {},
    setPlateText: plateText => String,
    setMeshVisibility: state => Number,
    spawnDefault: () => {},
    spawnNewVehicle: (model, args) => [String, Object],
    replaceVehicle: (model, args) => [String, Object],
    isLicensePlateValid: text => Any,
    getModelList: () => {},
    getModel: () => {},
  },

  ui_vehicleSelector: {
    //getVehicleTiles: () => {},
    getTiles: (currentPath, pathChanged) => [Object, Boolean],
    getFilters: () => {},
    getActiveFilters: () => {},
    toggleFilter: (propName, option) => [String, String],
    updateRangeFilter: (propName, min, max) => [String, Number, Number],
    resetRangeFilter: propName => String,
    resetSetFilter: propName => String,
    getDisplayDataOptions: () => {},
    setDisplayDataOption: (key, value) => [String, Any],
    resetDisplayDataToDefaults: () => {},
    toggleFavourite: (model, config) => [String, String],
    getSearchText: () => {},
    setSearchText: (searchText) => {},
    getScreenHeaderTitleAndPath: (path) => Object,

    profilerFinish: (tag) => String,
    closedFromUI: () => {},
  },
  ui_vehicleSelector_detailsInteraction: {
    getDetails: itemDetails => Object,
    executeButton: (buttonId, additionalData) => [Number, Object],
    getManagementDetails: () => {},
    exitCallback: () => {},
    executeDoubleClick: itemDetails => Object,
    exploreFolder: path => String,
    goToMod: modId => String,
  },

  ui_topBar: {
    hide: () => {},
    requestData: () => {},
    requestEntries: () => {},
    setActiveItem: itemId => String,
    selectItem: itemId => String,
    show: () => {},
  },


  core_vehicle_manager: {
    reloadAllVehicles: () => {},
    toggleDebug: () => {},
    getDebug: () => {},
  },

  core_vehicle_colors: {
    setVehicleColor: (index, value) => [Integer, Object],
  },

  core_recoveryPrompt: {
    getUIData: () => {},
    buttonPressed: id => [String],
    uiPopupButtonPressed: index => [Integer],
    uiPopupCancelPressed: () => {},
    onPopupClosed: () => {},
  },

  core_remoteController: {
    devicesConnected: () => Boolean,
    getQRCode: () => {},
  },

  core_levels: {
    startLevel: () => {},
  },

  util_screenshotCreator: {
    startWork: workOptions => Any,
  },

  util_groundModelDebug: {
    openWindow: () => {},
  },

  scenario_scenariosLoader: {
    getList: () => {},
    start: scenario => Object,
  },

  ui_apps_minimap_minimap: {
    setDrawTransform: (x, y, width, height) => [Number, Number, Number, Number],
    hide: () => {},
    toggleOptions: () => {},
    getMode: () => {},
    setOcclusionTransform: (id, x, y, width, height) => [String, Number, Number, Number, Number],
    resetOcclusionTransform: (id) => [String],
  },

  ui_apps_minimap_additionalInfo: {
    requestAdditionalInfo: () => {},
  },

  WinInput: {
    setForwardRawEvents: state => Boolean,
  },

  Engine: {
    Audio: {
      playOnce: (channel, sound) => [String, String],
    },
    Render: {
      getAdapterType: () => {},
    },
    UI: {
      getUIEngine: () => {},
    },
    Platform: {
      getFSInfo: () => {},
    },
  },

  Steam: {
    showFloatingGamepadTextInput: (type, left, top, width, height) => [Number, Number, Number, Number, Number],
  },

  setCEFTyping: state => Boolean,

  // -- Testing -------------------------------------------------------------------

  // noParams: () => {},
  // oneParam: firstParam => {},
  // manyParams: (first, second, third) => {},
  // singleStringParam: myString => String,
  // multiStringParams: (str1, str2) => [String, String],
  // mixedParamTypes: (int1, str1, int2) => [Number, String, Number],

  // noTransform: function(str) { run('myFunction', [str]) },

  // namespace: {
  //  noParams: () => {},
  //  oneParam: firstParam => {},
  //  manyParams: (first, second, third) => {},
  //  singleStringParam: myString => String,
  //  multiStringParams: (str1, str2) => [String, String],
  //  mixedParamTypes: (int1, str1, int2) => [Number, String, Number],

  //  inner: {
  //    test1: () => {},
  //    test2: param => {},
  //    test3: strParam => String,
  //    test4: (multi1, multi2) => [String, Boolean]
  //  }
  // }

  career_modules_sleep: {
    closeMenu: () => {},
    closeAllMenus: () => {},
    toggleDayNightCycle: toggle => Boolean,
    sleep: time => Number,
    getDayNightCycle: () => {}
  },

  career_modules_loans: {
    openMenuFromComputer: computerId => String,
    closeMenu: () => {},
    closeAllMenus: () => {},
    getLoanOffers: () => {},
    getActiveLoans: () => {},
    calculatePayment: (amount, rate, payments) => [Number, Number],
    takeLoan: (orgId, amount, payments) => [String, Number, Number],
    prepayLoan: (loanId, amount) => [String, Number],
    getNotificationsEnabled: () => Boolean,
    setNotificationsEnabled: enabled => Boolean,
    clearAllLoans: () => Number,
  },

  career_modules_assignRole: {
    canPay: () => {},
    startCertification: () => {},
    requestAssignmentData: () => {}
  },

  career_modules_carmeets: {
    rsvpToMeet: attendanceLevel => {},
    decline: () => {},
    closeMenu: () => {},
    openMenu: () => {},
    checkAvailableMeets: () => {},
    requestRSVPData: () => {},
    cancelRSVP: () => {},
    setRoute: () => {},
    updateAttendance: attendanceLevel => {}
  },

  career_modules_garageManager: {
    requestGarageData: () => {},
    canPay: () => {},
    buyGarage: () => {},
    cancelGaragePurchase: () => {},
    getGaragePrice: () => {},
    canSellGarage: () => {},
    sellGarage: () => {}
  },

  career_modules_business_businessManager: {
    requestBusinessData: () => {},
    canPayBusiness: () => {},
    canAffordDownPayment: () => {},
    buyBusiness: () => {},
    financeBusiness: () => {},
    cancelBusinessPurchase: () => {},
    getPurchasedBusinesses: businessType => String,
  },

  career_modules_business_businessComputer: {
    getAllRequiredParts: (businessId, vehicleId, parts, cartParts) => [String, Integer, Array, Array],
    addPartToCart: (businessId, vehicleId, currentCart, partToAdd) => [String, Integer, Array, Object],
    getBusinessComputerUIData: (businessType, businessId) => [String, String],
    acceptJob: (businessId, jobId) => [String, Integer],
    declineJob: (businessId, jobId) => [String, Integer],
    completeJob: (businessId, jobId) => [String, Integer],
    canCompleteJob: (businessId, jobId) => [String, Integer],
    abandonJob: (businessId, jobId) => [String, Integer],
    pullOutVehicle: (businessId, vehicleId) => [String, Integer],
    putAwayVehicle: (businessId) => String,
    getActiveJobs: (businessId) => String,
    getNewJobs: (businessId) => String,
    getVehiclePartsTree: (businessId, vehicleId) => [String, Integer],
    requestVehiclePartsTree: (businessId, vehicleId) => [String, Integer],
    getVehicleTuningData: (businessId, vehicleId) => [String, Integer],
    requestVehicleTuningData: (businessId, vehicleId) => [String, Integer],
    applyVehicleTuning: (businessId, vehicleId, tuningVars) => [String, Integer, Object],
    loadWheelDataExtension: (businessId, vehicleId) => [String, Integer],
    unloadWheelDataExtension: (businessId, vehicleId) => [String, Integer],
    clearVehicleDataCaches: () => {},
    getBusinessAccountBalance: (businessType, businessId) => [String, String],
    purchaseCartItems: (businessId, accountId, cartData) => [String, String, Object],
    installPartOnVehicle: (businessId, vehicleId, partName, slotPath) => [String, Integer, String, String],
    initializePreviewVehicle: (businessId, vehicleId) => [String, Integer],
    applyTuningToVehicle: (businessId, vehicleId, tuningVars) => [String, Integer, Object],
    calculateTuningCost: (businessId, vehicleId, tuningVars, originalVars) => Number,
    getTuningShoppingCart: (businessId, vehicleId, tuningVars, originalVars) => Object,
    addTuningToCart: (businessId, vehicleId, currentTuningVars, baselineTuningVars) => [String, Integer, Object, Object],
    getVehiclePowerWeight: (businessId, vehicleId) => Object,
    resetVehicleToOriginal: (businessId, vehicleId) => [String, Integer],
    applyPartsToVehicle: (businessId, vehicleId, parts) => [String, Integer, Array],
    applyCartPartsToVehicle: (businessId, vehicleId, parts) => [String, Integer, Array],
    requestPartInventory: (businessId) => String,
    sellPart: (businessId, partId) => [String, Integer],
    sellAllParts: (businessId) => String,
    sellPartsByVehicle: (businessId, vehicleNiceName) => [String, String],
  },

  career_modules_business_tuningShop: {
    getUIData: (businessId) => String,
    getJobsForBusiness: (businessId) => String,
    getActiveJobs: (businessId) => String,
    getNewJobs: (businessId) => String,
    acceptJob: (businessId, jobId) => [String, Integer],
    declineJob: (businessId, jobId) => [String, Integer],
    abandonJob: (businessId, jobId) => [String, Integer],
    completeJob: (businessId, jobId) => [String, Integer],
    canCompleteJob: (businessId, jobId) => [String, Integer],
    getAbandonPenalty: (businessId, jobId) => [String, Integer],
  },

  career_modules_business_businessPartCustomization: {
    initializePreviewVehicle: (businessId, vehicleId) => [String, Integer],
    resetVehicleToOriginal: (businessId, vehicleId) => [String, Integer],
    applyPartsToVehicle: (businessId, vehicleId, parts) => [String, Integer, Array],
    applyCartPartsToVehicle: (businessId, vehicleId, parts) => [String, Integer, Array],
    installPartOnVehicle: (businessId, vehicleId, partName, slotPath) => [String, Integer, String, String],
    getVehiclePowerWeight: (businessId, vehicleId) => Object,
    getPreviewVehicleConfig: (businessId) => Object,
    getInitialVehicleState: (businessId) => Object,
    findRemovedParts: (businessId, vehicleId) => [String, Integer],
    clearPreviewVehicle: (businessId) => String,
    onPowerWeightReceived: (requestId, power, weight) => [String, Number, Number],
  },

  career_modules_business_businessVehicleTuning: {
    requestVehicleTuningData: (businessId, vehicleId) => [String, Integer],
    getVehicleTuningData: (businessId, vehicleId) => [String, Integer],
    applyTuningToVehicle: (businessId, vehicleId, tuningVars) => [String, Integer, Object],
    calculateTuningCost: (businessId, vehicleId, tuningVars, originalVars) => Number,
    applyVehicleTuning: (businessId, vehicleId, tuningVars, accountId) => [String, Integer, Object, String],
    clearTuningDataCache: () => [],
  },

  career_modules_business_businessInventory: {
    getBusinessVehicles: (businessId) => String,
    storeVehicle: (businessId, vehicleData) => [String, Any],
    removeVehicle: (businessId, vehicleId) => [String, Integer],
    getVehicleById: (businessId, vehicleId) => [String, Integer],
    pullOutVehicle: (businessId, vehicleId) => [String, Integer],
    putAwayVehicle: (businessId) => String,
    getPulledOutVehicle: (businessId) => String,
  },

  career_modules_business_businessSkillTree: {
    requestSkillTrees: (requestId, businessType, businessId) => [String, String, String],
    requestPurchaseUpgrade: (requestId, businessType, businessId, treeId, nodeId) => [String, String, String, String, String],
    getNodeProgress: (businessId, treeId, nodeId) => [String, String, String],
  },

  gameplay_taxi: {
    prepareTaxiJob: () => {},
    acceptJob: () => {},
    rejectJob: () => {},
    setAvailable: () => {},
    stopTaxiJob: () => {},
    getTaxiJob: () => {},
    requestTaxiState: () => {}
  },

  career_modules_hardcore: {
    isHardcoreMode: () => {}
  },

  gameplay_repo: {
    generateJob: () => {},
    getRepoJobInstance: () => {},
    requestRepoState: () => {},
    cancelJob: () => {},
    completeJob: () => {},
    isRepoVehicle: () => {}
  },

  overhaul_maps: {
    getOtherAvailableMaps: () => {},
    getMapsExcludingWestCoast: () => {},
    getCompatibleMaps: () => {}
  },

  career_modules_playerAttributes: {
    addAttributes: (change, reason, fullprice) => [Object, Any, Boolean],
    setAttributes: (newValues, reason) => [Object, Any],
    getAttribute: attributeName => Any,
    getAttributeValue: attributeName => Any,
    getAllAttributes: () => {},
    getAttributeLog: () => {},
    onSaveCurrentSaveSlot: currentSavePath => String,
    onExtensionLoaded: () => {},
    onCareerModulesActivated: () => {},
  },

  career_modules_payment: {
    canPay: price => Object,
  },

  career_modules_bank: {
    createAccount: (name, accountType, initialDeposit) => [String, String, Number],
    deleteAccount: accountId => String,
    renameAccount: (accountId, newName) => [String, String],
    deposit: (accountId, amount) => [String, Number],
    withdraw: (accountId, amount) => [String, Number],
    transfer: (fromAccountId, toAccountId, amount) => [String, String, Number],
    getAccounts: () => {},
    getAccountBalance: accountId => String,
    getBusinessAccount: (businessType, businessId) => [String, String],
    getPendingTransfers: () => {},
    cancelPendingTransfer: transferId => String,
    getAccountTransactions: (accountId, limit) => [String, Number],
  },

  career_modules_switchMap: {
    switchMap: (level) => {}
  }
}

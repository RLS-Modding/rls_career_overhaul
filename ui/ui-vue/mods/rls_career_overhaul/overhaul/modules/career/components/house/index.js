// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

// RLS house controls: the Style Guide's buttons, switch, dropdown, slider, number field and prompt as
// components that keep the game's controller focus and click sounds. Use these instead of BngButton /
// BngSwitch / BngDropdown / BngSlider / BngInput / openPrompt on career screens.
import { markRaw } from "vue"
import { addPopup } from "@/services/popup"
import { ACCENTS } from "@/common/components/base"
import HousePrompt from "./HousePrompt.vue"
import HouseConfirm from "./HouseConfirm.vue"
import HouseProgress from "./HouseProgress.vue"
import HouseFormDialog from "./HouseFormDialog.vue"
import HouseAmountPrompt from "./HouseAmountPrompt.vue"
import { openOverhaulPopup } from "../../utils/openOverhaulPopup.js"
import { $translate } from "@/services/translation"

export { default as HouseLoader } from "./HouseLoader.vue"
export { default as HouseButton } from "./HouseButton.vue"
export { default as HouseSwitch } from "./HouseSwitch.vue"
export { default as HouseMenu } from "./HouseMenu.vue"
export { default as HouseSlider } from "./HouseSlider.vue"
export { default as HouseAmountField } from "./HouseAmountField.vue"
export { default as HouseAccordion } from "./HouseAccordion.vue"
export { default as HouseTabs } from "./HouseTabs.vue"
export { default as HouseActionHint } from "./HouseActionHint.vue"
export { HousePrompt, HouseConfirm, HouseProgress, HouseFormDialog }

/**
 * House-style text prompt. Same contract as the game's openPrompt: resolves to the entered text,
 * or false when cancelled.
 * @param {string} message
 * @param {string} title
 * @param {{ defaultValue?, placeholder?, maxLength?, validate?, errorMessage?, confirmLabel?, cancelLabel? }} [opts]
 */
export const openHousePrompt = (message = "", title = "", opts = {}) =>
  addPopup(HousePrompt, { message, title, ...opts }).promise

// Returns a number (including zero), or false on Cancel. Pad operation needs no typing.
export const openHouseAmountPrompt = (message = "", title = "", opts = {}) =>
  openOverhaulPopup(HouseAmountPrompt, { message, title, ...opts }).promise

/**
 * House confirmation popup. Same contract as the game's openConfirmation: resolves to the clicked
 * button's value. Buttons: [{ label, value, extras: { default, cancel, confirm, destructive, accent, disabled } }].
 */
export const openHouseConfirmation = (
  title = "",
  message = "",
  buttons = [
    { label: $translate.instant("ui.common.okay"), value: true, extras: { default: true } },
    { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true } },
  ]
) => addPopup(HouseConfirm, { title, message, buttons }).promise

/**
 * House progress popup. Same contract as the game's openProgress: returns the popup, whose
 * .progress.update(value, message) moves the bar and .progress.done() closes it.
 */
export const openHouseProgress = (
  message = "",
  title = "",
  { buttons = [], indeterminate, min, max, initialValue, valueLabelFormat, timeout, cancellable } = {}
) => {
  let pendingUpdate
  const tunnel = {
    update: (...args) => {
      pendingUpdate = args
    },
    flushPendingUpdate: update => {
      if (!pendingUpdate) return
      update(...pendingUpdate)
      pendingUpdate = null
    },
  }
  const popup = addPopup(HouseProgress, { message, title, buttons, indeterminate, min, max, initialValue, valueLabelFormat, timeout, cancellable, tunnel })
  popup.progress = popup.props.tunnel
  popup.progress.done = popup.return
  return popup
}

/**
 * House form dialog. Same contract as the game's openFormDialog: resolves to { value, formData? }.
 */
export const openHouseFormDialog = (
  component,
  formModel,
  formValidator,
  title,
  description,
  buttons = [
    { label: $translate.instant("ui.common.okay"), value: true, emitData: true },
    { label: $translate.instant("ui.common.cancel"), value: false, extras: { cancel: true, outsideCancel: true, accent: ACCENTS.text } },
  ],
  maxWidth
) =>
  addPopup(HouseFormDialog, { view: markRaw(component), formModel, formValidator, title, description, buttons, maxWidth })
    // The popup host only wraps outside-click cancels for components named "FormDialog"; normalise every
    // close path (button, Back/Menu, outside click) to the { value, formData? } contract.
    .promise.then(normaliseFormResult)

const normaliseFormResult = result =>
  result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "value") ? result : { value: result }

/** House message popup with a single OK (same contract as the game's openMessage). */
export const openHouseMessage = (title, message) =>
  addPopup(HouseConfirm, { title, message, buttons: [{ label: $translate.instant("ui.common.okay"), value: true, extras: { default: true } }] }).promise

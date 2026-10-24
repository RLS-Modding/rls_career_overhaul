// Backup flow for one save card: the name step, the save-then-copy Lua sequence, and the success
// state that returns to the menu after a short pause. Owns only its own refs. The card passes in
// what it reads (id, active), the injected name check, and the one thing that tells the card a
// copy was made, so this file never sees the card's props, emits or other view state.
import { ref } from "vue"
import { lua } from "@/bridge"
import { safeLua } from "../../../utils/safeLua.js"

/** How long "Backup created" stays on screen before the card returns to its menu. */
export const BACKUP_SUCCESS_RESET_MS = 1500
const BACKUP_SAVE_POLL_MS = 100
const BACKUP_SAVE_TIMEOUT_MS = 20000

/**
 * @param {object} deps
 * @param {() => string} deps.getId the save being copied
 * @param {() => boolean} deps.getActive whether that save is the one being played
 * @param {(name: string) => string | null | undefined} deps.validateName returns a problem or nothing
 * @param {() => void} deps.onSuccess called once the copy exists, before the success pause
 */
export function useProfileBackup({ getId, getActive, validateName, onSuccess }) {
  // null | "name" | "loading" | "success"
  const step = ref(null)
  const name = ref("")
  const nameError = ref(null)

  function validate(value) {
    const res = validateName(value)
    nameError.value = res || null
    return !res
  }

  function open() {
    name.value = ""
    nameError.value = null
    step.value = "name"
  }

  function close() {
    step.value = null
    name.value = ""
    nameError.value = null
  }

  function setName(value) {
    name.value = value
    validate(name.value)
  }

  /** Poll the save system rather than guessing how long async save hooks need. */
  async function waitForBackupSave() {
    const deadline = Date.now() + BACKUP_SAVE_TIMEOUT_MS
    while (true) {
      let busy
      try {
        busy = await lua.overhaul_career_saveSystem.isSavePending()
      } catch (error) {
        safeLua(() => { throw error }, 'ProfileCard failed to read the backup save state')
        return false
      }
      if (!busy) return true

      const remaining = deadline - Date.now()
      if (remaining <= 0) return false
      await new Promise(resolve => window.setTimeout(resolve, Math.min(BACKUP_SAVE_POLL_MS, remaining)))
    }
  }

  async function confirm() {
    if (!validate(name.value) || nameError.value) return
    const trimmed = name.value.trim()
    step.value = "loading"
    try {
      let ok
      if (getActive()) {
        // Start the source snapshot first, then wait on the actual save state so
        // duplicateSaveSlot cannot observe its temporary corrupted marker.
        await lua.overhaul_career_saveSystem.saveCurrent(false, { force: true, manual: true })
        if (!(await waitForBackupSave())) throw new Error("Backup save timed out")
        ok = await lua.overhaul_career_saveSystem.duplicateSaveSlot(getId(), trimmed, { sourceSaveReady: true })
      } else {
        ok = await lua.overhaul_career_saveSystem.duplicateSaveSlot(getId(), trimmed)
      }
      if (ok) {
        await lua.overhaul_career_career.sendAllCareerProfilesData()
        step.value = "success"
        onSuccess()
        window.setTimeout(() => {
          step.value = null
          name.value = ""
        }, BACKUP_SUCCESS_RESET_MS)
      } else {
        step.value = "name"
        nameError.value = "Backup failed"
      }
    } catch (error) {
      step.value = "name"
      nameError.value = "Backup failed"
      safeLua(() => { throw error }, 'ProfileCard backup failed')
    }
  }

  return { step, name, nameError, open, close, setName, confirm }
}

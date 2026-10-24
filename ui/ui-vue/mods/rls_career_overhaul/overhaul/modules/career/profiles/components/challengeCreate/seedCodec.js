import { ref } from 'vue'

// Seed traffic with the Lua encoder and decoder. Owns the pending request ids and the latest encode id, so
// a response to an older encode is dropped. Decoded challenge data goes to onDecoded, which writes the form.
export function createSeedCodec({ lua, seedInput, seedError, onDecoded }) {
  const pendingRequests = ref(new Set())
  let latestEncodeRequestId = null

  function requestEncode(payload) {
    const requestId = 'encode_' + Date.now() + '_' + Math.random()
    latestEncodeRequestId = requestId
    pendingRequests.value.add(requestId)

    lua.overhaul_career_challengeModes.requestSeedEncode(requestId, payload)
  }

  function applySeedToForm(seed) {
    seedError.value = ''
    if (!seed || seed.trim() === '') {
      seedError.value = 'Seed cannot be empty'
      return
    }

    const requestId = 'decode_' + Date.now() + '_' + Math.random()
    pendingRequests.value.add(requestId)

    lua.overhaul_career_challengeModes.requestSeedDecode(requestId, seed)
  }

  function handleSeedGenerated(payload) {
    if (!payload || payload.success === false) {
      seedError.value = payload?.error || 'Failed to generate seed'
      return
    }

    if (!payload.seed || payload.seed.trim() === '') {
      seedError.value = 'Generated seed is empty'
      return
    }

    seedInput.value = payload.seed
    seedError.value = ''
    applySeedToForm(payload.seed)
  }

  function handleSeedEncodeResponse(payload) {
    if (!payload || !pendingRequests.value.has(payload.requestId)) {
      return
    }

    pendingRequests.value.delete(payload.requestId)
    if (payload.requestId !== latestEncodeRequestId) return

    if (payload.success) {
      seedInput.value = payload.seed || ''
      seedError.value = ''
    } else {
      seedError.value = payload.error || 'Failed to encode seed'
    }
  }

  function handleSeedDecodeResponse(payload) {
    if (!payload || !pendingRequests.value.has(payload.requestId)) {
      return
    }

    pendingRequests.value.delete(payload.requestId)

    if (payload.success) {
      onDecoded(payload.data)
    } else {
      seedError.value = payload.error || 'Failed to decode seed'
    }
  }

  return { requestEncode, applySeedToForm, handleSeedGenerated, handleSeedEncodeResponse, handleSeedDecodeResponse }
}

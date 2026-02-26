<template>
  <div class="offer-chat-container-wrapper">
    <div ref="offerChatContainer" class="offer-chat-container">
      <TransitionGroup name="message" tag="div">
        <div
          v-for="(item, index) in processedOfferHistory"
          :key="item.typingId || `${item.myOffer || item.theirOffer || 'message'}-${index}`"
          class="message"
          :class="item.messageClass">
          <div v-if="item.isTyping" class="above">
            <span class="spinner" aria-label="Typing"></span>
            Typing...
          </div>
          <div v-else-if="item.negotiationStatus === 'failed'" class="red">
            <BngIcon type="abandon" /> Negotiation failed!
          </div>
          <div v-else-if="item.negotiationStatus === 'accepted'" class="green">
            <BngIcon type="checkmark" :color="'var(--bng-add-green-400)'" /> Accepted!
          </div>
          <!-- this only applies to my first message-->
          <div v-else-if="item.offerStatus" class="above">
            <template v-if="item.offerStatus === 'initial'">
              {{ !props.amISelling ?  'Initial offer' : 'Asking Price' }}
            </template>
            <template v-else>
              Counter offer
            </template>
          </div>
          <div v-else-if="item.negotiationStatus" class="above">
            {{ statusTextFromStatus(item.negotiationStatus) }}
          </div>
          <div v-if="!item.isTyping && item.negotiationStatus !== 'failed' && item.negotiationStatus !== 'accepted'" class="price">
            <BngUnit class="money" :money="item.myOffer || item.theirOffer || 0" />
          </div>
        </div>
      </TransitionGroup>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch, nextTick, onMounted } from "vue"
import { BngIcon, BngUnit } from "@/common/components/base"

const props = defineProps({
  offerHistory: {
    type: Array,
    default: () => []
  },
  negotiationStatus: {
    type: String,
    default: ''
  },
  startingPrice: {
    type: Number,
    default: 0
  },
  amISelling: {
    type: Boolean,
    default: false
  }
})

const offerChatContainer = ref(null)

const statusTextFromStatus = (status) => {
  switch (String(status || '')) {
    case 'counterOffer':
      return 'Counter offer'
    case 'counterOfferLastChance':
      return 'Last chance counter offer'
    case 'accepted':
      return 'Accepted'
    case 'failed':
      return 'Negotiation failed'
    case 'refused':
      return 'Offer refused'
    case 'initial':
      return !props.amISelling ? 'Asking Price' : 'Initial offer'
    case 'thinking':
      return 'Thinking'
    default:
      return ''
  }
}

const fillInOfferHistory = (history) => {
  if (!history || !Array.isArray(history)) return []

  let previousTheirOffer = null
  let previousMyOffer = null
  let hasSeenMyOffer = false
  let hasSeenTheirOffer = false
  let isFirstInitialOffer = true

  return history.map((item) => {
    const isMyOffer = item.myOffer != null
    const isTheirOffer = item.theirOffer != null
    const currentOffer = isMyOffer ? item.myOffer : item.theirOffer

    let difference = null
    if (isTheirOffer && isFirstInitialOffer) {
      isFirstInitialOffer = false
    } else {
      difference = currentOffer - props.startingPrice
    }

    let offerStatus = null
    if (isMyOffer) {
      if (!hasSeenMyOffer) {
        offerStatus = 'initial'
        hasSeenMyOffer = true
      } else {
        offerStatus = 'counterOffer'
      }
    }

    if (isMyOffer) {
      previousMyOffer = item.myOffer
    } else if (isTheirOffer) {
      previousTheirOffer = item.theirOffer
      hasSeenTheirOffer = true
    }

    return {
      theirOffer: item.theirOffer,
      myOffer: item.myOffer,
      negotiationStatus: item.negotiationStatus,
      messageClass: isMyOffer ? 'sent-message' : 'received-message',
      difference: difference,
      offerStatus: offerStatus
    }
  })
}

const typingMessageId = ref(null)
const previousOfferHistoryLength = ref(0)

watch(() => props.negotiationStatus, (newStatus) => {
  if (newStatus === 'typing' && typingMessageId.value === null) {
    typingMessageId.value = `typing-${Date.now()}`
  }
})

const processedOfferHistory = computed(() => {
  const history = fillInOfferHistory(props.offerHistory)
  const currentHistoryLength = (props.offerHistory || []).length
  const hasNewEntry = currentHistoryLength > previousOfferHistoryLength.value

  if (hasNewEntry && typingMessageId.value !== null) {
    const responseId = typingMessageId.value
    const responseData = history[history.length - 1]

    const result = [...history]
    result[result.length - 1] = {
      ...responseData,
      typingId: responseId,
      isTyping: false
    }

    typingMessageId.value = null
    previousOfferHistoryLength.value = currentHistoryLength
    return result
  }

  if (currentHistoryLength !== previousOfferHistoryLength.value) {
    previousOfferHistoryLength.value = currentHistoryLength
  }

  if (props.negotiationStatus === 'typing' && typingMessageId.value !== null) {
    return [...history, {
      theirOffer: null,
      myOffer: null,
      negotiationStatus: 'typing',
      messageClass: 'received-message',
      difference: null,
      isTyping: true,
      typingId: typingMessageId.value
    }]
  }

  return history
})

watch(processedOfferHistory, () => {
  nextTick(() => {
    if (offerChatContainer.value) {
      const container = offerChatContainer.value
      const isNearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 100
      if (isNearBottom) {
        container.scrollTop = container.scrollHeight
      }
    }
  })
}, { deep: true })

const scrollToBottom = () => {
  nextTick(() => {
    if (offerChatContainer.value) {
      offerChatContainer.value.scrollTop = offerChatContainer.value.scrollHeight
    }
  })
}

const reset = () => {
  typingMessageId.value = null
  previousOfferHistoryLength.value = (props.offerHistory || []).length
}

onMounted(() => {
  reset()
  scrollToBottom()
})

defineExpose({
  scrollToBottom,
  reset
})
</script>

<style scoped lang="scss">
.offer-chat-container-wrapper {
  background: var(--bng-ter-blue-gray-900);
  border-radius: var(--bng-corners-2);
  border: 1px solid var(--bng-cool-gray-800);
  overflow: hidden;
  flex: 1;
}

.offer-chat-container {
  display: flex;
  flex-direction: column;
  justify-content: flex-start;
  align-items: center;
  padding: 0.5rem;
  overflow-y: auto;
  height: 100%;
  &::-webkit-scrollbar {
    display: none;
  }
  &::-webkit-scrollbar-track {
    display: none;
  }
  &::-webkit-scrollbar-thumb {
    display: none;
  }

  > div {
    display: flex;
    flex-direction: column;
    align-items: center;
    width: 100%;
    gap: 0.5rem;
  }

  --delay-stagger: 0.3s;

  .message {
    padding: 0.5rem 0.75rem;
    border-radius: 0.75rem;
    max-width: 50%;
    background: var(--bng-ter-blue-gray-500);
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
    overflow: hidden;
    >* {
      display: flex;
      flex-direction: row;
      gap: 0.25rem;
      opacity: 0;
      animation: fadeInElement calc(1*var(--delay-stagger)) ease-out forwards;
    }
    .above {
      font-size: 0.8rem;
      font-weight: 300;
      color: var(--bng-cool-gray-200);
      --bng-icon-color: var(--bng-cool-gray-200);
      display: flex;
      align-items: center;
      gap: 0.5rem;
      animation-delay: calc(2*var(--delay-stagger));

      .spinner {
        display: inline-block;
        width: 0.75rem;
        height: 0.75rem;
        border: 0.1rem solid rgba(255, 255, 255, 0.3);
        border-top-color: #ffffff;
        border-radius: 50%;
        animation: spinner-rotate 0.8s linear infinite;
        flex-shrink: 0;
      }
    }
    .below {
      font-size: 0.8rem;
      font-weight: 300;
      color: var(--bng-cool-gray-200);
      --bng-icon-color: var(--bng-cool-gray-200);
      display: flex;
      align-items: center;
      animation-delay: calc(3*var(--delay-stagger));
    }

    .price {
      font-size: 1.5rem;
      align-self: flex-start;
      align-items: flex-end;
      flex: 0 0 auto;
      display: flex;
      flex-direction: column;
      min-width: 0;
      margin-top: -0.1rem;
      animation-delay: calc(4*var(--delay-stagger));
      :deep(.info-item) {
        padding: 0;
      }
    }
    .green {
      color: var(--bng-add-green-400);
      --bng-icon-color: var(--bng-add-green-400);
      font-weight: 600;
      font-size: 1.5rem;
      display: flex;
      align-items: center;
      :deep(.icon-base) {
        margin-top: -0.25rem;
      }
    }
    .red {
      color: var(--bng-add-red-400);
      --bng-icon-color: var(--bng-add-red-400);
      font-size: 1.5rem;
      font-weight: 600;
      display: flex;
      align-items: center;
      :deep(.icon-base) {
        margin-top: -0.25rem;
      }
    }
    .arrow {
      font-size: 1.25rem;
      margin-bottom: -0.5rem;
    }
  }

  .sent-message {
    align-self: flex-end;
    border-bottom-right-radius: 0;
    align-items: flex-end;
    background: var(--bng-orange-700);
  }

  .received-message {
    align-self: flex-start;
    border-bottom-left-radius: 0;
    background: var(--bng-ter-blue-gray-700);
  }
}

@keyframes spinner-rotate {
  to {
    transform: rotate(360deg);
  }
}

@keyframes fadeInElement {
  from {
    opacity: 0;
    transform: translateY(-0.5rem);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

.message-enter-active {
  transition: all 0.4s ease-out;
}

.message-leave-active {
  transition: all 0.3s ease-in;
}

.message-enter-from {
  opacity: 0;
  max-height: 3rem;

  &.received-message {
    transform: translateX(-2rem);
  }

  &.sent-message {
    transform: translateX(2rem);
  }
}

.message-enter-to {
  max-height: 20rem;
}

.message-leave-from {
  max-height: 20rem;
}

.message-leave-to {
  opacity: 0;
  max-height: 3rem;
  padding-top: 0;
  padding-bottom: 0;
  margin: 0;

  &.received-message {
    transform: translateX(-2rem);
  }

  &.sent-message {
    transform: translateX(2rem);
  }
}

.message-move {
  transition: transform 0.4s ease-out;
}
</style>
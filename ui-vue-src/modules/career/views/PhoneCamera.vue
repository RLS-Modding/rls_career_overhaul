<template>
  <PhoneWrapper app-name="Camera" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="camera-container">
      <div class="camera-header">
        <BngIcon :type="icons.photo" class="header-icon" />
        <h1>Camera</h1>
      </div>

      <div class="camera-hint">
        <p>Point your view at your car or the scene you want, then tap <strong>Take Photo</strong>. The phone will close briefly and a clean screenshot will be saved.</p>
      </div>

      <div class="camera-actions">
        <button
          class="take-photo-btn"
          :disabled="taking"
          @click="takePhoto"
        >
          <BngIcon v-if="!taking" :type="icons.photo" class="btn-icon" />
          <span v-else class="btn-spinner">...</span>
          <span>{{ taking ? 'Taking...' : 'Take Photo' }}</span>
        </button>
      </div>

      <div class="camera-footer">
        <small>Photos save to <strong>screenshots/phone/</strong></small>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
import { BngIcon, icons } from '@/common/components/base'
import { ref } from 'vue'
import { lua } from '@/bridge'

const taking = ref(false)

async function takePhoto() {
  if (taking.value) return
  taking.value = true
  try {
    await lua.gameplay_phoneCamera.takePhoto()
  } catch (e) {
    console.error('Camera takePhoto failed', e)
  } finally {
    taking.value = false
  }
}
</script>

<style scoped lang="scss">
.camera-container {
  padding: 16px;
  display: flex;
  flex-direction: column;
  align-items: center;
  min-height: 100%;
  box-sizing: border-box;
}

.camera-header {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 20px;

  .header-icon {
    font-size: 2em;
    color: #fff;
  }

  h1 {
    margin: 0;
    font-size: 1.4rem;
    color: #fff;
    font-weight: 600;
  }
}

.camera-hint {
  background: rgba(255, 255, 255, 0.08);
  border-radius: 12px;
  padding: 14px;
  margin-bottom: 24px;
  width: 100%;
  box-sizing: border-box;

  p {
    margin: 0;
    font-size: 0.9rem;
    line-height: 1.45;
    color: rgba(255, 255, 255, 0.9);

    strong {
      color: #fff;
    }
  }
}

.camera-actions {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
}

.take-photo-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
  width: 140px;
  height: 140px;
  border-radius: 50%;
  border: 3px solid rgba(255, 255, 255, 0.5);
  background: rgba(0, 0, 0, 0.4);
  color: #fff;
  font-size: 0.95rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  .btn-icon {
    font-size: 2.5em;
  }

  .btn-spinner {
    font-size: 1.5em;
  }

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.9);
    transform: scale(1.03);
  }

  &:active:not(:disabled) {
    transform: scale(0.98);
  }

  &:disabled {
    opacity: 0.7;
    cursor: not-allowed;
  }
}

.camera-footer {
  margin-top: auto;
  padding-top: 16px;

  small {
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.75rem;

    strong {
      color: rgba(255, 255, 255, 0.8);
    }
  }
}
</style>

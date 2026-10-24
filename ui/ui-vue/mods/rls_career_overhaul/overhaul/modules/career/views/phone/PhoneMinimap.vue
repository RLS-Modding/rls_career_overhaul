<template>

    <div class="minimap-container" ref="container">
      <div class="map-base">
      </div>
    </div>

</template>

<script setup>
import { ref, onMounted, onUnmounted } from "vue";
import { useMinimapStore } from "../../stores/minimapStore";

const store = useMinimapStore();
const container = ref(null);
let mapView = null;

onMounted(() => {
  store.acquire();
  mapView = store.mountMap(container.value.querySelector('.map-base'), { fit: 'slice' });
});

onUnmounted(() => {
  mapView?.dispose();
  store.release();
});
</script>

<style scoped>
.map-base {
  position: relative;
  flex: 1;
  min-height: 0;
  width: 100%;
  transform-origin: center center;
}

.minimap-container {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  background: rgba(40, 40, 40, 0.9);
}

.minimap-layer {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
}
</style>

<template>
  <div class="skill-tree-tab">
    <div v-if="trees.length === 0" class="empty-state">
      No skill trees available
    </div>
    <div v-else class="skill-tree-container">
      <div class="tree-view">
        <div 
          class="tree-canvas" 
          ref="canvasRef"
          @mousedown="startPan"
          @mousemove="onPan"
          @mouseup="stopPan"
          @mouseleave="stopPan"
          @wheel.prevent="onWheel"
          @contextmenu.prevent
        >
          <div 
            class="tree-content"
            :style="{
              transform: `translate(${translateX}px, ${translateY}px) scale(${scale})`,
              transformOrigin: '0 0'
            }"
          >
            <svg 
              class="tree-connections" 
              width="100%" 
              height="100%"
              style="position: absolute; top: 0; left: 0; pointer-events: none; overflow: visible;"
            >
              <defs>
                <marker 
                  v-for="tree in trees" 
                  :key="tree.treeId" 
                  :id="`arrowhead-${tree.treeId}`" 
                  markerWidth="10" 
                  markerHeight="10" 
                  refX="10" 
                  refY="3" 
                  orient="auto" 
                  markerUnits="userSpaceOnUse"
                >
                  <polygon points="0 0, 10 3, 0 6" fill="rgba(255, 255, 255, 0.7)" />
                </marker>
              </defs>
              <path
                v-for="(connection, idx) in allConnections"
                :key="idx"
                :d="connection.path"
                stroke="rgba(255, 255, 255, 0.6)"
                stroke-width="2"
                fill="none"
                :marker-end="`url(#arrowhead-${connection.treeId})`"
              />
            </svg>
            <template v-for="tree in trees" :key="tree.treeId">
              <div 
                class="tree-group"
                :style="{
                  left: getTreeOffsetX(tree.treeId) + 'px',
                  top: getTreeOffsetY(tree.treeId) + 'px'
                }"
              >
                <div
                  class="tree-name-label"
                  :style="getTreeNameStyle(tree)"
                >
                  {{ tree.treeName }}
                </div>
                <SkillTreeNode
                  v-for="node in tree.nodes"
                  :key="node.id"
                  :node="node"
                  :tree-id="tree.treeId"
                  @upgrade="(node) => handleUpgrade(node, tree.treeId)"
                />
              </div>
            </template>
          </div>
        </div>
      </div>
    </div>
    <Teleport to="body">
      <SkillTreeUpgradeModal
        v-if="showModal && modalNode"
        :show="showModal"
        :node="modalNode"
        :tree-id="modalTreeId"
        @confirm="confirmUpgrade"
        @cancel="showModal = false"
      />
    </Teleport>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick, reactive } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import SkillTreeNode from "./SkillTreeNode.vue"
import SkillTreeUpgradeModal from "./SkillTreeUpgradeModal.vue"
import { Teleport } from "vue"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"

const events = useEvents()

const props = defineProps({
  data: Object
})

const store = useBusinessComputerStore()
const trees = ref([])
const showModal = ref(false)
const modalNode = ref(null)
const modalTreeId = ref(null)
const canvasRef = ref(null)
const canvasWidth = ref(10000)
const canvasHeight = ref(10000)

const translateX = ref(0)
const translateY = ref(0)
const scale = ref(1.0)
const isPanning = ref(false)
const panStartX = ref(0)
const panStartY = ref(0)
const panStartTranslateX = ref(0)
const panStartTranslateY = ref(0)

const treeOffsets = ref({})

const NODE_WIDTH = ref(200)
const NODE_HEIGHT = ref(200)
const NODE_SPACING_X = 280
const NODE_SPACING_Y = 300
const TREE_SPACING = 300

const getTreeOffsetX = (treeId) => {
  if (!treeOffsets.value[treeId]) {
    return 0
  }
  return treeOffsets.value[treeId].x || 0
}

const getTreeOffsetY = (treeId) => {
  if (!treeOffsets.value[treeId]) {
    return 0
  }
  return treeOffsets.value[treeId].y || 0
}

const allConnections = computed(() => {
  const allConns = []
  trees.value.forEach(tree => {
    if (!tree || !tree.nodes) return
    const treeOffsetX = getTreeOffsetX(tree.treeId)
    const treeOffsetY = getTreeOffsetY(tree.treeId)
    
    tree.nodes.forEach(node => {
      if (node.dependencies && node.dependencies.length > 0) {
        node.dependencies.forEach(depId => {
          const depNode = tree.nodes.find(n => n.id === depId)
          if (depNode && node.position && depNode.position) {
            const parentX = treeOffsetX + (depNode.position.x || 0) + (NODE_WIDTH.value / 2)
            const parentY = treeOffsetY + (depNode.position.y || 0)
            const childX = treeOffsetX + (node.position.x || 0) + (NODE_WIDTH.value / 2)
            const childY = treeOffsetY + (node.position.y || 0) + NODE_HEIGHT.value
            
            const midY = parentY + ((childY - parentY) / 2)
            
            const path = `M ${parentX} ${parentY} L ${parentX} ${midY} L ${childX} ${midY} L ${childX} ${childY}`
            
            allConns.push({
              path: path,
              treeId: tree.treeId,
              parentX: parentX,
              parentY: parentY,
              childX: childX,
              childY: childY
            })
          }
        })
      }
    })
  })
  return allConns
})

const pendingRequests = ref(new Map())

const loadTrees = () => {
  const businessType = props.data?.businessType || store.businessType
  if (!businessType || !store.businessId) {
    console.log('[SkillTreeTab] Cannot load trees - missing businessType or businessId', { businessType, businessId: store.businessId, propsData: props.data })
    return
  }
  
  const requestId = `trees_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { type: 'trees' })
  
  console.log('[SkillTreeTab] Requesting trees', { requestId, businessType, businessId: store.businessId })
  lua.career_modules_business_businessSkillTree.requestSkillTrees(requestId, businessType, store.businessId)
}

const initializeNodePositions = (trees) => {
  trees.forEach(tree => {
    if (tree.nodes) {
      tree.nodes.forEach(node => {
        if (!node.position) {
          node.position = { x: 0, y: 0 }
        } else if (!node.position.x && !node.position.y) {
          node.position.x = 0
          node.position.y = 0
        }
      })
    }
  })
}

const measureNodeSize = () => {
  nextTick(() => {
    const nodeElements = document.querySelectorAll('.skill-node')
    if (nodeElements.length > 0) {
      let maxWidth = 0
      let maxHeight = 0
      nodeElements.forEach(el => {
        const rect = el.getBoundingClientRect()
        maxWidth = Math.max(maxWidth, rect.width)
        maxHeight = Math.max(maxHeight, rect.height)
      })
      if (maxWidth > 0) {
        NODE_WIDTH.value = maxWidth
        console.log('[SkillTreeTab] Measured node width:', maxWidth)
      }
      if (maxHeight > 0) {
        NODE_HEIGHT.value = maxHeight
        console.log('[SkillTreeTab] Measured node height:', maxHeight)
      }
    }
  })
}

const handleTreesResponse = (data) => {
  console.log('[SkillTreeTab] Received trees response', data)
  if (!pendingRequests.value.has(data.requestId)) {
    console.warn('[SkillTreeTab] Received response for unknown requestId:', data.requestId)
    return
  }
  pendingRequests.value.delete(data.requestId)
  
  if (data.success && data.trees) {
    console.log('[SkillTreeTab] Successfully loaded', data.trees.length, 'trees')
    trees.value = data.trees || []
    initializeNodePositions(trees.value)
    if (trees.value.length > 0) {
      nextTick(() => {
        measureNodeSize()
        nextTick(() => {
          calculateTreeOffsets()
          resetView()
        })
      })
    }
  } else {
    console.warn('[SkillTreeTab] Failed to load trees or no trees returned', data)
    trees.value = []
  }
}

const handleTreesUpdated = (data) => {
  console.log('[SkillTreeTab] Received trees update', data)
  const businessType = props.data?.businessType || store.businessType
  if (data.businessType === businessType && data.businessId === store.businessId) {
    if (data.trees) {
      console.log('[SkillTreeTab] Updating trees:', data.trees.length)
      trees.value = data.trees || []
      initializeNodePositions(trees.value)
      nextTick(() => {
        measureNodeSize()
        nextTick(() => {
          calculateTreeOffsets()
          resetView()
        })
      })
    }
  } else {
    console.log('[SkillTreeTab] Ignoring update - businessType/businessId mismatch', {
      received: { businessType: data.businessType, businessId: data.businessId },
      expected: { businessType, businessId: store.businessId }
    })
  }
}

const handleUpgrade = (node, treeId) => {
  modalNode.value = node
  modalTreeId.value = treeId
  showModal.value = true
}

const confirmUpgrade = () => {
  if (!modalNode.value || !modalTreeId.value || !store.businessId) return
  
  const requestId = `purchase_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { 
    type: 'purchase',
    treeId: modalTreeId.value,
    nodeId: modalNode.value.id
  })
  
  lua.career_modules_business_businessSkillTree.requestPurchaseUpgrade(
    requestId, 
    store.businessId, 
    modalTreeId.value, 
    modalNode.value.id
  )
  
  showModal.value = false
  modalNode.value = null
  modalTreeId.value = null
}

const handlePurchaseResponse = (data) => {
  console.log('[SkillTreeTab] Received purchase response', data)
  if (!pendingRequests.value.has(data.requestId)) {
    console.warn('[SkillTreeTab] Received purchase response for unknown requestId:', data.requestId)
    return
  }
  pendingRequests.value.delete(data.requestId)
  
  if (!data.success) {
    console.error('[SkillTreeTab] Failed to purchase upgrade:', data)
  } else {
    console.log('[SkillTreeTab] Purchase successful')
  }
}

const startPan = (event) => {
  if (event.button !== 2) return
  isPanning.value = true
  panStartX.value = event.clientX
  panStartY.value = event.clientY
  panStartTranslateX.value = translateX.value
  panStartTranslateY.value = translateY.value
  event.preventDefault()
}

const onPan = (event) => {
  if (!isPanning.value) return
  const deltaX = event.clientX - panStartX.value
  const deltaY = event.clientY - panStartY.value
  translateX.value = panStartTranslateX.value + deltaX
  translateY.value = panStartTranslateY.value + deltaY
  event.preventDefault()
}

const stopPan = () => {
  isPanning.value = false
}

const onWheel = (event) => {
  const zoomStep = 0.05
  const minScale = 0.1
  const maxScale = 5.0
  
  const delta = event.deltaY > 0 ? -zoomStep : zoomStep
  const newScale = Math.max(minScale, Math.min(maxScale, scale.value + delta))
  
  if (canvasRef.value) {
    const rect = canvasRef.value.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    const worldX = (mouseX - translateX.value) / scale.value
    const worldY = (mouseY - translateY.value) / scale.value
    
    translateX.value = mouseX - (worldX * newScale)
    translateY.value = mouseY - (worldY * newScale)
  }
  
  scale.value = newScale
}

watch(() => [props.data, store.businessId, store.businessType], () => {
  loadTrees()
}, { immediate: true, deep: true })

const autoLayoutAllTrees = () => {
  trees.value.forEach(tree => {
    if (tree.nodes && tree.nodes.length > 0) {
      autoLayoutTree(tree)
    }
  })
}

const autoLayoutTree = (tree) => {
  if (!tree || !tree.nodes || tree.nodes.length === 0) {
    console.warn('[SkillTreeTab] autoLayoutTree called with invalid tree:', tree)
    return
  }
  
  console.log(`[SkillTreeTab] Starting auto-layout for tree: ${tree.treeId} with ${tree.nodes.length} nodes`)
  
  const nodeMap = new Map()
  const levels = {}
  const nodeLevels = new Map()
  
  tree.nodes.forEach(node => {
    nodeMap.set(node.id, node)
  })
  
  const getNodeLevel = (nodeId, visited = new Set()) => {
    if (visited.has(nodeId)) {
      return nodeLevels.get(nodeId) || 0
    }
    visited.add(nodeId)
    
    const node = nodeMap.get(nodeId)
    if (!node) {
      return 0
    }
    
    if (nodeLevels.has(nodeId)) {
      return nodeLevels.get(nodeId)
    }
    
    if (!node.dependencies || node.dependencies.length === 0) {
      nodeLevels.set(nodeId, 0)
      return 0
    }
    
    let maxDepLevel = -1
    node.dependencies.forEach(depId => {
      const depLevel = getNodeLevel(depId, visited)
      if (depLevel > maxDepLevel) {
        maxDepLevel = depLevel
      }
    })
    
    const level = maxDepLevel + 1
    nodeLevels.set(nodeId, level)
    return level
  }
  
  tree.nodes.forEach(node => {
    const level = getNodeLevel(node.id)
    if (!levels[level]) {
      levels[level] = []
    }
    levels[level].push(node)
  })
  
  const maxNodesInLevel = Math.max(...Object.values(levels).map(nodes => nodes.length), 0)
  const maxLevel = Math.max(...Object.keys(levels).map(Number), 0)
  
  console.log(`[SkillTreeTab] Tree layout: ${maxLevel + 1} levels, max ${maxNodesInLevel} nodes per level`)
  
  if (!canvasRef.value) {
    console.warn('[SkillTreeTab] canvasRef not available, using fallback dimensions')
  }
  
  const rect = canvasRef.value?.getBoundingClientRect()
  const containerWidth = rect?.width > 0 ? rect.width : 2000
  const containerHeight = rect?.height > 0 ? rect.height : 1500
  
  console.log(`[SkillTreeTab] Container dimensions: ${containerWidth}x${containerHeight}`)
  
  if (containerWidth <= 0 || containerHeight <= 0) {
    console.error('[SkillTreeTab] Invalid container dimensions, using fallback')
  }
  
  const HORIZONTAL_SPACING = NODE_SPACING_X
  const VERTICAL_SPACING = NODE_SPACING_Y
  
  console.log(`[SkillTreeTab] Using fixed spacing: horizontal=${HORIZONTAL_SPACING}px, vertical=${VERTICAL_SPACING}px`)
  
  const START_Y = 100
  const START_X = 100
  
  for (let level = 0; level <= maxLevel; level++) {
    const nodes = levels[level]
    if (!nodes || nodes.length === 0) continue
    
    const y = START_Y + (level * VERTICAL_SPACING)
    
    const levelTotalWidth = (nodes.length - 1) * HORIZONTAL_SPACING
    const levelStartX = START_X + Math.max(0, (containerWidth - levelTotalWidth - (nodes.length * NODE_WIDTH.value)) / 2)
    
    console.log(`[SkillTreeTab] Level ${level}: positioning ${nodes.length} nodes at y=${y}, startX=${levelStartX.toFixed(0)}`)
    
    nodes.forEach((node, idx) => {
      const x = levelStartX + (idx * HORIZONTAL_SPACING)
      
      if (!node.position) {
        node.position = { x: 0, y: 0 }
      }
      
      node.position.x = x
      node.position.y = y
      
      console.log(`[SkillTreeTab]   Node ${node.id}: position (${x.toFixed(0)}, ${y.toFixed(0)})`)
    })
  }
  
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity
  
  tree.nodes.forEach(node => {
    if (node.position) {
      const x = node.position.x || 0
      const y = node.position.y || 0
      const nodeRight = x + NODE_WIDTH.value
      const nodeBottom = y + NODE_HEIGHT.value
      
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, nodeRight)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, nodeBottom)
    }
  })
  
  if (minX !== Infinity && maxX !== -Infinity && minY !== Infinity && maxY !== -Infinity) {
    if (!tree.bounds) {
      tree.bounds = {}
    }
    tree.bounds.minX = minX
    tree.bounds.maxX = maxX
    tree.bounds.minY = minY
    tree.bounds.maxY = maxY
    tree.bounds.width = maxX - minX
    tree.bounds.height = maxY - minY
  }
  
  console.log('[SkillTreeTab] Auto-layout completed for tree:', tree.treeId, `(${tree.nodes.length} nodes)`)
}

const DEFAULT_TREE_WIDTH = 400
const TREE_NAME_VERTICAL_OFFSET = 160

const getTreeNameStyle = (tree) => {
  const bounds = tree?.bounds || {}
  const width = bounds.width || DEFAULT_TREE_WIDTH
  const minX = bounds.minX || 0
  const minY = bounds.minY || 0

  const left = minX + (width / 2)
  const top = Math.max(0, minY - TREE_NAME_VERTICAL_OFFSET)

  return {
    left: `${left}px`,
    top: `${top}px`,
    transform: 'translateX(-50%)'
  }
}

const calculateTreeOffsets = () => {
  const SPACING = TREE_SPACING
  let currentX = 100
  let currentY = 100
  
  trees.value.forEach((tree, index) => {
    if (index === 0) {
      treeOffsets.value[tree.treeId] = {
        x: currentX,
        y: currentY
      }
      if (tree.bounds) {
        currentX += (tree.bounds.width || 0) + SPACING
      }
      return
    }
    
    const prevTree = trees.value[index - 1]
    const prevOffset = treeOffsets.value[prevTree.treeId]
    const prevBounds = prevTree.bounds
    
    if (prevBounds && prevBounds.width) {
      currentX = prevOffset.x + prevBounds.width + SPACING
    } else {
      currentX += TREE_SPACING
    }
    
    treeOffsets.value[tree.treeId] = {
      x: currentX,
      y: currentY
    }
  })
}

const resetView = () => {
  translateX.value = 0
  translateY.value = 0
  scale.value = 1.0
  
  if (trees.value.length === 0 || !canvasRef.value) return
  
  nextTick(() => {
    let minX = Infinity
    let maxX = -Infinity
    let minY = Infinity
    let maxY = -Infinity
    
    trees.value.forEach(tree => {
      const treeOffsetX = getTreeOffsetX(tree.treeId)
      const treeOffsetY = getTreeOffsetY(tree.treeId)
      
      if (tree.nodes && tree.nodes.length > 0) {
        tree.nodes.forEach(node => {
          if (node.position) {
            const x = treeOffsetX + (node.position.x || 0)
            const y = treeOffsetY + (node.position.y || 0)
            minX = Math.min(minX, x)
            maxX = Math.max(maxX, x + NODE_WIDTH.value)
            minY = Math.min(minY, y)
            maxY = Math.max(maxY, y + NODE_HEIGHT.value)
          }
        })
      }
    })
    
    if (minX !== Infinity && canvasRef.value) {
      const rect = canvasRef.value.getBoundingClientRect()
      const totalWidth = maxX - minX
      const totalHeight = maxY - minY
      const centerX = minX + (totalWidth / 2)
      const centerY = minY + (totalHeight / 2)
      
      const initialScale = Math.min(
        (rect.width * 0.8) / totalWidth,
        (rect.height * 0.8) / totalHeight,
        1.0
      )
      
      scale.value = initialScale
      translateX.value = (rect.width / 2) - (centerX * initialScale)
      translateY.value = (rect.height / 2) - (centerY * initialScale)
    }
  })
}

onMounted(() => {
  console.log('[SkillTreeTab] Component mounted, registering event listeners')
  events.on('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.on('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.on('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  window.addEventListener('mousemove', onPan)
  window.addEventListener('mouseup', stopPan)
  console.log('[SkillTreeTab] Event listeners registered, loading trees')
  loadTrees()
})

onBeforeUnmount(() => {
  events.off('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.off('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.off('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  window.removeEventListener('mousemove', onPan)
  window.removeEventListener('mouseup', stopPan)
})
</script>

<style scoped lang="scss">
.skill-tree-tab {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.empty-state {
  padding: 2rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.skill-tree-container {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.tree-view {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  height: 100%;
}

.tree-group {
  position: absolute;
}

.tree-name-label {
  position: absolute;
  color: #F54900;
  font-size: 5rem;
  font-weight: 600;
  white-space: nowrap;
  pointer-events: none;
}

.tree-canvas {
  flex: 1;
  position: relative;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.2);
}


.tree-content {
  position: relative;
  width: 100%;
  height: 100%;
  z-index: 1;
}

.tree-connections {
  position: absolute;
  top: 0;
  left: 0;
  pointer-events: none;
  width: 100%;
  height: 100%;
}
</style>


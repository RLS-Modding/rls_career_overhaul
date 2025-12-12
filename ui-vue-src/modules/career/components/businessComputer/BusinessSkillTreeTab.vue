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
                  :ref="el => setNodeRef(el, tree.treeId, node.id)"
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
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick, reactive, inject } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import SkillTreeNode from "./SkillTreeNode.vue"
import SkillTreeUpgradeModal from "./SkillTreeUpgradeModal.vue"
import { Teleport } from "vue"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"

const events = useEvents()
const controllerNav = inject('controllerNav', null)

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

const VIEW_STATE_STORAGE_KEY = 'rlsBusinessSkillTreeViewState'
let viewStateSaveTimeout = null

const canUseLocalStorage = () => typeof window !== 'undefined' && typeof window.localStorage !== 'undefined'

const getBusinessIdentifiers = () => {
  const businessType = props.data?.businessType || store.businessType
  const businessId = props.data?.businessId || store.businessId
  return {
    businessType,
    businessId
  }
}

const getViewStateKey = () => {
  const ids = getBusinessIdentifiers()
  if (!ids.businessType || !ids.businessId) return null
  return `${ids.businessType}_${ids.businessId}`
}

const readViewStateStorage = () => {
  if (!canUseLocalStorage()) return {}
  try {
    const raw = window.localStorage.getItem(VIEW_STATE_STORAGE_KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null ? parsed : {}
  } catch (error) {
    return {}
  }
}

const writeViewStateStorage = (data) => {
  if (!canUseLocalStorage()) return
  try {
    window.localStorage.setItem(VIEW_STATE_STORAGE_KEY, JSON.stringify(data))
  } catch (error) {
  }
}

const persistViewState = () => {
  if (!canUseLocalStorage()) return
  const key = getViewStateKey()
  if (!key) return
  const storage = readViewStateStorage()
  storage[key] = {
    translateX: translateX.value,
    translateY: translateY.value,
    scale: scale.value
  }
  writeViewStateStorage(storage)
}

const scheduleViewStateSave = () => {
  if (!canUseLocalStorage()) return
  if (viewStateSaveTimeout) {
    clearTimeout(viewStateSaveTimeout)
  }
  viewStateSaveTimeout = setTimeout(() => {
    viewStateSaveTimeout = null
    persistViewState()
  }, 150)
}

const restorePersistedViewState = () => {
  if (!canUseLocalStorage()) return false
  try {
    const storage = readViewStateStorage()
    const key = getViewStateKey()
    const state = storage[key]
    if (!state) return false
    const nextScale = typeof state.scale === 'number' ? Math.max(0.1, Math.min(5.0, state.scale)) : 1.0
    translateX.value = typeof state.translateX === 'number' ? state.translateX : 0
    translateY.value = typeof state.translateY === 'number' ? state.translateY : 0
    scale.value = nextScale
    return true
  } catch (error) {
    return false
  }
}

const applyTreeViewState = () => {
  if (!restorePersistedViewState()) {
    resetView()
  }
}

const treeOffsets = ref({})
const nodeSizes = ref(new Map())
const nodeRefs = ref(new Map())

const NODE_WIDTH = ref(200)
const NODE_HEIGHT = ref(200)
const NODE_SPACING_X = 280
const NODE_SPACING_Y = 300
const TREE_SPACING = 300

const setNodeRef = (el, treeId, nodeId) => {
  if (el) {
    const key = `${treeId}_${nodeId}`
    nodeRefs.value.set(key, el)
  }
}

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
            const depSize = nodeSizes.value.get(depId) || { width: NODE_WIDTH.value, height: NODE_HEIGHT.value }
            const nodeSize = nodeSizes.value.get(node.id) || { width: NODE_WIDTH.value, height: NODE_HEIGHT.value }
            
            const parentX = treeOffsetX + (depNode.position.x || 0) + (depSize.width / 2)
            const parentY = treeOffsetY + (depNode.position.y || 0)
            const childX = treeOffsetX + (node.position.x || 0) + (nodeSize.width / 2)
            const childY = treeOffsetY + (node.position.y || 0) + nodeSize.height
            
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
let bankRefreshTimeout = null

const loadTrees = () => {
  const businessType = props.data?.businessType || store.businessType
  if (!businessType || !store.businessId) {
    return
  }
  
  const requestId = `trees_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { type: 'trees' })
  
  lua.career_modules_business_businessSkillTree.requestSkillTrees(requestId, businessType, store.businessId)
}

const scheduleTreesRefresh = () => {
  if (bankRefreshTimeout) return
  bankRefreshTimeout = setTimeout(() => {
    bankRefreshTimeout = null
    loadTrees()
  }, 100)
}

const handleAccountUpdate = (data) => {
  const businessType = props.data?.businessType || store.businessType
  const businessId = props.data?.businessId || store.businessId
  if (!data || !businessType || !businessId) return
  const accountId = "business_" + businessType + "_" + businessId
  if (data.accountId === accountId) {
    scheduleTreesRefresh()
  }
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
    let maxWidth = 0
    let maxHeight = 0
    
    trees.value.forEach(tree => {
      if (!tree || !tree.nodes) return
      const treeOffsetX = getTreeOffsetX(tree.treeId)
      const treeOffsetY = getTreeOffsetY(tree.treeId)
      
      tree.nodes.forEach(node => {
        const key = `${tree.treeId}_${node.id}`
        let domEl = null
        
        const ref = nodeRefs.value.get(key)
        if (ref) {
          if (ref.$el) {
            domEl = ref.$el
          } else if (ref instanceof HTMLElement) {
            domEl = ref
          } else if (ref.getBoundingClientRect) {
            domEl = ref
          }
        }
        
        if (!domEl && node.position) {
          const nodeElements = document.querySelectorAll('.skill-node')
          const expectedX = treeOffsetX + (node.position.x || 0)
          const expectedY = treeOffsetY + (node.position.y || 0)
          
          domEl = Array.from(nodeElements).find(elem => {
            const rect = elem.getBoundingClientRect()
            const canvasRect = canvasRef.value?.getBoundingClientRect()
            if (!canvasRect) return false
            
            const elemX = (rect.left - canvasRect.left - translateX.value) / scale.value
            const elemY = (rect.top - canvasRect.top - translateY.value) / scale.value
            
            return Math.abs(elemX - expectedX) < 5 && Math.abs(elemY - expectedY) < 5
          })
        }
        
        if (domEl) {
          const rect = domEl.getBoundingClientRect()
          const currentScale = scale.value || 1.0
          const width = rect.width / currentScale
          const height = rect.height / currentScale
          
          nodeSizes.value.set(node.id, { width, height })
          maxWidth = Math.max(maxWidth, width)
          maxHeight = Math.max(maxHeight, height)
        }
      })
    })
    
    if (maxWidth > 0) {
      NODE_WIDTH.value = maxWidth
    }
    if (maxHeight > 0) {
      NODE_HEIGHT.value = maxHeight
    }
  })
}

const handleTreesResponse = (data) => {
  if (!pendingRequests.value.has(data.requestId)) {
    return
  }
  pendingRequests.value.delete(data.requestId)
  
  if (data.success && data.trees) {
    trees.value = data.trees || []
    nodeRefs.value.clear()
    nodeSizes.value.clear()
    initializeNodePositions(trees.value)
    if (trees.value.length > 0) {
      nextTick(() => {
        measureNodeSize()
        nextTick(() => {
          calculateTreeOffsets()
          applyTreeViewState()
        })
      })
    }
  } else {
    trees.value = []
  }
}

const handleTreesUpdated = (data) => {
  const businessType = props.data?.businessType || store.businessType
  if (data.businessType === businessType && data.businessId === store.businessId) {
    if (data.trees) {
      trees.value = data.trees || []
      nodeRefs.value.clear()
      nodeSizes.value.clear()
      initializeNodePositions(trees.value)
      nextTick(() => {
        measureNodeSize()
        nextTick(() => {
          calculateTreeOffsets()
          applyTreeViewState()
        })
      })
    }
  }
}

const handleUpgrade = (node, treeId) => {
  if (node.commingSoon) {
    return
  }
  modalNode.value = node
  modalTreeId.value = treeId
  showModal.value = true
}

const confirmUpgrade = () => {
  if (!modalNode.value || !modalTreeId.value || !store.businessId) return
  
  const businessType = props.data?.businessType || store.businessType
  if (!businessType) return
  
  const requestId = `purchase_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { 
    type: 'purchase',
    treeId: modalTreeId.value,
    nodeId: modalNode.value.id
  })
  
  lua.career_modules_business_businessSkillTree.requestPurchaseUpgrade(
    requestId,
    businessType,
    store.businessId, 
    modalTreeId.value, 
    modalNode.value.id
  )
  
  showModal.value = false
  modalNode.value = null
  modalTreeId.value = null
}

const handlePurchaseResponse = (data) => {
  if (!pendingRequests.value.has(data.requestId)) {
    return
  }
  pendingRequests.value.delete(data.requestId)
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

let lastPannedElement = null

const panToElement = (element) => {
  if (!element || !canvasRef.value) return
  
  // Skip if we already panned to this element
  if (lastPannedElement === element) return
  lastPannedElement = element
  
  const canvasRect = canvasRef.value.getBoundingClientRect()
  const elementRect = element.getBoundingClientRect()
  const targetScale = 1
  
  // Calculate the element's center in world space (tree-content coordinates)
  const worldX = (elementRect.left + elementRect.width / 2 - canvasRect.left - translateX.value) / scale.value
  const worldY = (elementRect.top + elementRect.height / 2 - canvasRect.top - translateY.value) / scale.value
  
  // Calculate target translation to center element at target scale
  const targetX = canvasRect.width / 2 - worldX * targetScale
  const targetY = canvasRect.height / 2 - worldY * targetScale
  
  const startX = translateX.value
  const startY = translateY.value
  const startScale = scale.value
  const duration = 250
  const startTime = performance.now()
  
  const animate = (currentTime) => {
    const elapsed = currentTime - startTime
    const progress = Math.min(elapsed / duration, 1)
    const eased = 1 - Math.pow(1 - progress, 3) // ease-out cubic
    
    scale.value = startScale + (targetScale - startScale) * eased
    translateX.value = startX + (targetX - startX) * eased
    translateY.value = startY + (targetY - startY) * eased
    
    if (progress < 1) {
      requestAnimationFrame(animate)
    } else {
      scheduleViewStateSave()
    }
  }
  
  requestAnimationFrame(animate)
}

// Watch for controller focus changes - will be set up in onMounted
let focusWatchStop = null

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

watch([translateX, translateY, scale], () => {
  scheduleViewStateSave()
})

const autoLayoutAllTrees = () => {
  trees.value.forEach(tree => {
    if (tree.nodes && tree.nodes.length > 0) {
      autoLayoutTree(tree)
    }
  })
}

const autoLayoutTree = (tree) => {
  if (!tree || !tree.nodes || tree.nodes.length === 0) {
    return
  }
  
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
  
  const rect = canvasRef.value?.getBoundingClientRect()
  const containerWidth = rect?.width > 0 ? rect.width : 2000
  const containerHeight = rect?.height > 0 ? rect.height : 1500
  
  const HORIZONTAL_SPACING = NODE_SPACING_X
  const VERTICAL_SPACING = NODE_SPACING_Y
  
  const START_Y = 100
  const START_X = 100
  
  for (let level = 0; level <= maxLevel; level++) {
    const nodes = levels[level]
    if (!nodes || nodes.length === 0) continue
    
    const y = START_Y + (level * VERTICAL_SPACING)
    
    const levelTotalWidth = (nodes.length - 1) * HORIZONTAL_SPACING
    const levelStartX = START_X + Math.max(0, (containerWidth - levelTotalWidth - (nodes.length * NODE_WIDTH.value)) / 2)
    
    nodes.forEach((node, idx) => {
      const x = levelStartX + (idx * HORIZONTAL_SPACING)
      
      if (!node.position) {
        node.position = { x: 0, y: 0 }
      }
      
      node.position.x = x
      node.position.y = y
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
  restorePersistedViewState()
  events.on('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.on('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.on('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  events.on('bank:onAccountUpdate', handleAccountUpdate)
  window.addEventListener('mousemove', onPan)
  window.addEventListener('mouseup', stopPan)
  
  if (controllerNav) {
    focusWatchStop = watch(
      () => controllerNav.currentFocusedElement.value,
      (focusedEl) => {
        if (focusedEl && focusedEl.classList.contains('skill-node')) {
          panToElement(focusedEl)
        }
      }
    )
  }
  
  loadTrees()
})

onBeforeUnmount(() => {
  events.off('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.off('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.off('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  events.off('bank:onAccountUpdate', handleAccountUpdate)
  window.removeEventListener('mousemove', onPan)
  window.removeEventListener('mouseup', stopPan)
  if (focusWatchStop) {
    focusWatchStop()
    focusWatchStop = null
  }
  if (bankRefreshTimeout) {
    clearTimeout(bankRefreshTimeout)
    bankRefreshTimeout = null
  }
  if (viewStateSaveTimeout) {
    clearTimeout(viewStateSaveTimeout)
    viewStateSaveTimeout = null
  }
})
</script>

<style scoped lang="scss">
.skill-tree-tab {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.empty-state {
  padding: 2em;
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
  font-size: 5em;
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

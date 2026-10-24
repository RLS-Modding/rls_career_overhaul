<template>
  <div :class="['rls-house', 'skill-tree-tab', { 'skill-tree-tab--multi': trees.length > 1 }]">
    <div v-if="trees.length === 0" class="empty empty-state">
      <p>No skill trees available</p>
    </div>
    <div v-else class="skill-tree-container" v-bng-on-ui-nav:action_3,action_4="onPadZoom" v-bng-on-ui-nav:context="fitTree">
      <div class="tree-view">
        <div 
          class="tree-canvas" 
          ref="canvasRef"
          v-bng-on-ui-nav:rotate_h_cam,rotate_v_cam="onStickPan"
          @focusin="onNodeFocus"
          @mousedown="startPan"
          @mousemove="onPan"
          @mouseup="stopPan"
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
                  <polygon points="0 0, 10 3, 0 6" fill="rgba(255, 255, 255, 0.3)" />
                </marker>
              </defs>
              <path
                v-for="(connection, idx) in allConnections"
                :key="idx"
                :d="connection.path"
                stroke="rgba(255, 255, 255, 0.2)"
                stroke-width="1.5"
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
      <p class="hint skill-tree-pan-hint">
        {{ isControllerUsed ? "Right stick to move around, the view follows the selected upgrade" : "Right click + drag to move around, scroll wheel to zoom" }}
      </p>
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
import { useSkillTreeAutoLayout } from "./useSkillTreeAutoLayout.js"
import { safeLua } from "../../utils/safeLua.js"

import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick, reactive } from "vue"
import { storeToRefs } from "pinia"
import useControls from "@/services/controls"
import { vBngOnUiNav } from "@/common/directives"
import { useBusinessSessionStore } from "../../stores/businessComputer/businessSessionStore.js"
import SkillTreeNode from "./SkillTreeNode.vue"
import SkillTreeUpgradeModal from "./SkillTreeUpgradeModal.vue"
import { Teleport } from "vue"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"

const events = useEvents()
const { isControllerUsed } = storeToRefs(useControls())

const props = defineProps({
  data: Object
})

const sessionStore = useBusinessSessionStore()
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
  const businessType = props.data?.businessType || sessionStore.businessType
  const businessId = props.data?.businessId || sessionStore.businessId
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
  safeLua(() => window.localStorage.setItem(VIEW_STATE_STORAGE_KEY, JSON.stringify(data)), "BusinessSkillTreeTab: writeViewStateStorage")
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
    clampViewToBounds()
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
const contentBounds = ref(null)

const NODE_WIDTH = ref(200)
const NODE_HEIGHT = ref(200)
const NODE_SPACING_X = 280
const NODE_SPACING_Y = 300
const TREE_SPACING = 300
const VIEWPORT_EDGE_MARGIN = 120

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
  const businessType = props.data?.businessType || sessionStore.businessType
  if (!businessType || !sessionStore.businessId) {
    return
  }
  
  const requestId = `trees_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { type: 'trees' })
  
  lua.overhaul_career_business_skillTree.requestSkillTrees(requestId, businessType, sessionStore.businessId)
}

const scheduleTreesRefresh = () => {
  if (bankRefreshTimeout) return
  bankRefreshTimeout = setTimeout(() => {
    bankRefreshTimeout = null
    loadTrees()
  }, 100)
}

const handleAccountUpdate = (data) => {
  const businessType = props.data?.businessType || sessionStore.businessType
  const businessId = props.data?.businessId || sessionStore.businessId
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
  const businessType = props.data?.businessType || sessionStore.businessType
  if (data.businessType === businessType && data.businessId === sessionStore.businessId) {
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
  if (!modalNode.value || !modalTreeId.value || !sessionStore.businessId) return
  
  const businessType = props.data?.businessType || sessionStore.businessType
  if (!businessType) return
  
  const requestId = `purchase_${Date.now()}_${Math.random()}`
  pendingRequests.value.set(requestId, { 
    type: 'purchase',
    treeId: modalTreeId.value,
    nodeId: modalNode.value.id
  })
  
  lua.overhaul_career_business_skillTree.requestPurchaseUpgrade(
    requestId,
    businessType,
    sessionStore.businessId,
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
  const clamped = clampTranslationToBounds(
    panStartTranslateX.value + deltaX,
    panStartTranslateY.value + deltaY
  )
  translateX.value = clamped.x
  translateY.value = clamped.y
  event.preventDefault()
}

const stopPan = () => {
  isPanning.value = false
}

let lastPannedElement = null

// The tree is a zoomable canvas laid out in fixed world px (Lua node positions, 200px nodes), so its
// text is sized in world px too (.tree-content font-size: 16px). The screen's em scale (1.48vh)
// becomes the zoom instead: 1 at 1080p, ~1.33 at 1440p. Before, the node text grew with the
// resolution inside fixed 200px nodes and rows started to overlap at 1440p and above.
const worldZoom = () => {
  const fontSize = canvasRef.value ? parseFloat(getComputedStyle(canvasRef.value).fontSize) : 0
  return fontSize > 0 ? fontSize / 16 : 1
}

const panToElement = (element) => {
  if (!element || !canvasRef.value) return
  
  // Skip if we already panned to this element
  if (lastPannedElement === element) return
  lastPannedElement = element
  
  const canvasRect = canvasRef.value.getBoundingClientRect()
  const elementRect = element.getBoundingClientRect()
  const targetScale = worldZoom()
  
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
    const clamped = clampTranslationToBounds(
      startX + (targetX - startX) * eased,
      startY + (targetY - startY) * eased,
      scale.value
    )
    translateX.value = clamped.x
    translateY.value = clamped.y
    
    if (progress < 1) {
      requestAnimationFrame(animate)
    } else {
      scheduleViewStateSave()
    }
  }
  
  requestAnimationFrame(animate)
}

// Controller: the d-pad moves focus between nodes (game crossfire); the view pans to the focused node,
// and the right stick pans freely so nodes outside the canvas can be brought into reach.
const onNodeFocus = (event) => {
  const node = event.target?.closest?.(".skill-node")
  if (node) panToElement(node)
}

const STICK_DEADZONE = 0.15
const STICK_PAN_SPEED = 14 // px per frame at full deflection
const stickPan = { x: 0, y: 0, raf: 0 }
const stepStickPan = () => {
  if (!stickPan.x && !stickPan.y) {
    stickPan.raf = 0
    return
  }
  const clamped = clampTranslationToBounds(
    translateX.value - stickPan.x * STICK_PAN_SPEED,
    translateY.value + stickPan.y * STICK_PAN_SPEED
  )
  translateX.value = clamped.x
  translateY.value = clamped.y
  lastPannedElement = null
  stickPan.raf = requestAnimationFrame(stepStickPan)
}
const onStickPan = (event) => {
  const { name, value } = event?.detail || {}
  const v = Math.abs(Number(value) || 0) < STICK_DEADZONE ? 0 : Number(value)
  if (name === "rotate_h_cam") stickPan.x = v
  else if (name === "rotate_v_cam") stickPan.y = v
  if (!stickPan.raf && (stickPan.x || stickPan.y)) stickPan.raf = requestAnimationFrame(stepStickPan)
  return false
}

const zoomAtCenter = delta => {
  const canvas = canvasRef.value
  if (!canvas) return
  const rect = canvas.getBoundingClientRect()
  onWheel({ deltaY: -delta, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, zoomDelta: delta })
}
const onPadZoom = event => {
  if (Number(event.detail?.value) > 0) zoomAtCenter(event.detail.name === "action_4" ? 0.15 : -0.15)
  return false
}
const fitTree = () => {
  lastPannedElement = null
  resetView()
  return false
}

const onWheel = (event) => {
  const zoomStep = 0.05
  const minScale = 0.1
  const maxScale = 5.0
  
  const delta = event.zoomDelta ?? (event.deltaY > 0 ? -zoomStep : zoomStep)
  const newScale = Math.max(minScale, Math.min(maxScale, scale.value + delta))
  
  if (canvasRef.value) {
    const rect = canvasRef.value.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top
    
    const worldX = (mouseX - translateX.value) / scale.value
    const worldY = (mouseY - translateY.value) / scale.value
    
    const clamped = clampTranslationToBounds(
      mouseX - (worldX * newScale),
      mouseY - (worldY * newScale),
      newScale
    )
    translateX.value = clamped.x
    translateY.value = clamped.y
  }
  
  scale.value = newScale
}

watch(() => [props.data, sessionStore.businessId, sessionStore.businessType], () => {
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

const { autoLayoutTree } = useSkillTreeAutoLayout({
  canvasRef, NODE_WIDTH, NODE_HEIGHT, NODE_SPACING_X, NODE_SPACING_Y
})

const DEFAULT_TREE_WIDTH = 400
const TREE_NAME_VERTICAL_OFFSET = 160
const TREE_NAME_VERTICAL_OFFSET_MULTI = 220

const getTreeNameHeaderLift = () =>
  trees.value.length > 1 ? TREE_NAME_VERTICAL_OFFSET_MULTI : TREE_NAME_VERTICAL_OFFSET

const getTreeNameStyle = (tree) => {
  const bounds = tree?.bounds || {}
  const width = bounds.width || DEFAULT_TREE_WIDTH
  const minX = bounds.minX || 0
  const minY = bounds.minY || 0
  const labelWidth = Math.max(width, NODE_WIDTH.value, 160)
  // Always a full header lift above the top node row (clamping to 0 put the label on top of
  // the first row whenever a tree started near y = 0).
  const top = minY - getTreeNameHeaderLift()

  // Centred over the tree and allowed to grow into the gap between trees, so a one-column tree
  // ("QUALITY OF LIFE" at 1440p) doesn't break a word mid-way inside a 200px node width.
  return {
    left: `${minX + labelWidth / 2}px`,
    top: `${top}px`,
    width: 'max-content',
    maxWidth: `${labelWidth + TREE_SPACING * 0.8}px`,
    transform: 'translateX(-50%)',
    textAlign: 'center',
    boxSizing: 'border-box',
    paddingLeft: '6px',
    paddingRight: '6px',
  }
}

const computeContentBounds = () => {
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity

  trees.value.forEach(tree => {
    const treeOffsetX = getTreeOffsetX(tree.treeId)
    const treeOffsetY = getTreeOffsetY(tree.treeId)
    const bounds = tree?.bounds

    if (bounds) {
      const localMinX = bounds.minX || 0
      const localMaxX = bounds.maxX || (localMinX + (bounds.width || NODE_WIDTH.value))
      const localMinY = bounds.minY || 0
      const localMaxY = bounds.maxY || (localMinY + (bounds.height || NODE_HEIGHT.value))

      minX = Math.min(minX, treeOffsetX + localMinX)
      maxX = Math.max(maxX, treeOffsetX + localMaxX)
      minY = Math.min(minY, treeOffsetY + localMinY - getTreeNameHeaderLift())
      maxY = Math.max(maxY, treeOffsetY + localMaxY)
      return
    }

    tree.nodes?.forEach(node => {
      if (!node.position) return
      const x = treeOffsetX + (node.position.x || 0)
      const y = treeOffsetY + (node.position.y || 0)
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x + NODE_WIDTH.value)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y + NODE_HEIGHT.value)
    })
  })

  if (minX === Infinity || maxX === -Infinity || minY === Infinity || maxY === -Infinity) {
    contentBounds.value = null
    return null
  }

  contentBounds.value = {
    minX,
    maxX,
    minY,
    maxY,
    width: maxX - minX,
    height: maxY - minY
  }

  return contentBounds.value
}

const clampTranslationToBounds = (nextX, nextY, nextScale = scale.value) => {
  if (!canvasRef.value) {
    return { x: nextX, y: nextY }
  }

  const bounds = contentBounds.value || computeContentBounds()
  if (!bounds) {
    return { x: nextX, y: nextY }
  }

  const rect = canvasRef.value.getBoundingClientRect()
  const marginX = Math.min(VIEWPORT_EDGE_MARGIN, rect.width * 0.25)
  const marginY = Math.min(VIEWPORT_EDGE_MARGIN, rect.height * 0.25)
  const scaledWidth = bounds.width * nextScale
  const scaledHeight = bounds.height * nextScale

  let x = nextX
  let y = nextY

  if (scaledWidth + (marginX * 2) <= rect.width) {
    x = (rect.width / 2) - ((bounds.minX + (bounds.width / 2)) * nextScale)
  } else {
    const minTranslateX = rect.width - marginX - (bounds.maxX * nextScale)
    const maxTranslateX = marginX - (bounds.minX * nextScale)
    x = Math.min(maxTranslateX, Math.max(minTranslateX, nextX))
  }

  if (scaledHeight + (marginY * 2) <= rect.height) {
    y = (rect.height / 2) - ((bounds.minY + (bounds.height / 2)) * nextScale)
  } else {
    const minTranslateY = rect.height - marginY - (bounds.maxY * nextScale)
    const maxTranslateY = marginY - (bounds.minY * nextScale)
    y = Math.min(maxTranslateY, Math.max(minTranslateY, nextY))
  }

  return { x, y }
}

const clampViewToBounds = () => {
  const clamped = clampTranslationToBounds(translateX.value, translateY.value, scale.value)
  translateX.value = clamped.x
  translateY.value = clamped.y
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

  computeContentBounds()
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
        worldZoom()
      )
      
      scale.value = initialScale
      computeContentBounds()
      const clamped = clampTranslationToBounds(
        (rect.width / 2) - (centerX * initialScale),
        (rect.height / 2) - (centerY * initialScale),
        initialScale
      )
      translateX.value = clamped.x
      translateY.value = clamped.y
    }
  })
}

onMounted(() => {
  restorePersistedViewState()
  events.on('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.on('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.on('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  events.on('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  window.addEventListener('mousemove', onPan)
  window.addEventListener('mouseup', stopPan)

  loadTrees()
})

onBeforeUnmount(() => {
  events.off('businessSkillTree:onTreesResponse', handleTreesResponse)
  events.off('businessSkillTree:onTreesUpdated', handleTreesUpdated)
  events.off('businessSkillTree:onPurchaseResponse', handlePurchaseResponse)
  events.off('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  window.removeEventListener('mousemove', onPan)
  window.removeEventListener('mouseup', stopPan)
  if (stickPan.raf) {
    cancelAnimationFrame(stickPan.raf)
    stickPan.raf = 0
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
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Skill tree canvas, house style: dark canvas, faint connectors, tree names as big faint captions,
   the pan / zoom hint as a faint hint. World units (node positions, label offsets) stay in px. */

.skill-tree-tab {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.empty-state {
  border-radius: var(--radius-panel);
  background: var(--panel);
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
  border-radius: var(--radius-panel);
}

.tree-group {
  position: absolute;
}

.tree-name-label {
  position: absolute;
  color: rgba(255, 255, 255, 0.4);
  font-size: 5em;
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  white-space: nowrap;
  line-height: 1.15;
  pointer-events: none;
  overflow-wrap: anywhere;
}

.skill-tree-tab--multi .tree-name-label {
  font-size: 2.35em;
  white-space: normal;
}

.tree-canvas {
  flex: 1;
  position: relative;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.28);
}

.tree-content {
  position: relative;
  width: 100%;
  height: 100%;
  z-index: 1;
  /* world px, see worldZoom() */
  font-size: 16px;
}

.tree-connections {
  position: absolute;
  top: 0;
  left: 0;
  pointer-events: none;
  width: 100%;
  height: 100%;
}

.skill-tree-pan-hint {
  flex-shrink: 0;
  padding: 0.55em 0.75em 0.35em;
  text-align: center;
  user-select: none;
}
</style>

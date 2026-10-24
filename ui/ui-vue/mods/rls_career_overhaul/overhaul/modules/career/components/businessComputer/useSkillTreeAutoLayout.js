// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Private skill-tree layout; the screen keeps ownership of viewport and node measurements.
// Inject the same refs so geometry reads occur at their original points in each layout pass.
export function useSkillTreeAutoLayout({ canvasRef, NODE_WIDTH, NODE_HEIGHT, NODE_SPACING_X, NODE_SPACING_Y }) {
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
  return { autoLayoutTree }
}

// Projects a win condition's variable definitions into the rows the form renders, sorted by their `order`.
// Types the form has no input for are dropped here, so the templates never see them.
export function projectVariables(defs) {
  const result = []
  for (const [variableId, definition] of Object.entries(defs)) {
    const type = definition.type || 'number'
    if (type === 'number' || type === 'integer') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {
          min: definition.min,
          max: definition.max,
          step: definition.step || (definition.decimals !== undefined ? Math.pow(10, -(definition.decimals)) : 1)
        }
      })
    } else if (type === 'string') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {
          maxlength: definition.maxLength,
          minlength: definition.minLength,
          placeholder: definition.placeholder
        }
      })
    } else if (type === 'boolean') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {}
      })
    } else if (type === 'array') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {}
      })
    } else if (type === 'multiselect') {
      result.push({
        id: variableId,
        type: type,
        label: definition.label || variableId,
        hint: definition.hint,
        props: {},
        options: definition.options
      })
    }
  }
  result.sort((a, b) => {
    const da = (defs[a.id] && defs[a.id].order) || 0
    const db = (defs[b.id] && defs[b.id].order) || 0
    return da - db
  })
  return result
}

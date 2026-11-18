export function validNitrousTune(t) {
  if (t === undefined) return true
  if (!t || typeof t !== 'object') return false
  if (t.mode === 'original') return true
  if (!['speed','rpmGear'].includes(t.mode)) return false
  const fields=t.mode==='speed' ? [['minSpeed','maxSpeed',0,1000]] : [['minRPM','maxRPM',0,50000],['minGear','maxGear',1,64]]
  return fields.every(([a,b,min,max])=>Number.isFinite(t[a]) && Number.isFinite(t[b]) && t[a]>=min && t[b]<=max &&
    (a==='minGear' ? t[a]<=t[b] && Number.isInteger(t[a]) && Number.isInteger(t[b]) : t[a]<t[b]))
}
function sameNitrous(a,b) {
  const mode=a?.mode || 'original'
  if(mode!==(b?.mode || 'original')) return false
  const keys=mode==='speed'?['minSpeed','maxSpeed']:mode==='rpmGear'?['minRPM','maxRPM','minGear','maxGear']:[]
  return keys.every(k=>a[k]===b[k])
}
// Calibration editor helpers. Keep these bounds aligned with common/rlsFuelModel.lua.
// Editing and smoothing are conveniences, not automatic engine-safety calibration.
// Overboost fuel cut, psi above factory boost (stockBoostCutMarginPsi and range).
export const BOOST_CUT_STOCK = 4.5, BOOST_CUT_MIN = 1, BOOST_CUT_MAX = 25
export function boostCutMargin(t) {
  return Number.isFinite(t?.boostCut) ? t.boostCut : BOOST_CUT_STOCK
}
export function validFuelTune(t) {
  if (!validNitrousTune(t?.nitrous)) return false
  if (!t || ![1, 2].includes(t.version) || !Array.isArray(t.rpm) || (t.rpm.length < 2 || t.rpm.length > 501 || (t.version === 1 && t.rpm.length !== 12)) ||
      !Array.isArray(t.load) || t.load.length !== 8) return false
  if (![t.rpm, t.load].every(a => a.every((v, i) => Number.isFinite(v) && (!i || v > a[i - 1])))) return false
  if (t.rpm[0] !== 0 || t.rpm.at(-1) > 50000 || t.load[0] !== 0 || t.load[7] !== 1) return false
  if (t.decel !== undefined) {
    if (!t.decel || typeof t.decel !== 'object') return false
    const d = decelSettings(t)
    if (!['original', 'custom'].includes(d.mode) || !Number.isFinite(d.cutDelay) || d.cutDelay < 0 || d.cutDelay > 5 ||
      !Number.isFinite(d.fueling) || d.fueling < 0 || d.fueling > 2 || !Number.isFinite(d.retard) || d.retard < 0 || d.retard > 20 ||
      (t.decel.continuous !== undefined && typeof t.decel.continuous !== 'boolean') || (t.decel.enabled !== undefined && typeof t.decel.enabled !== 'boolean') ||
      (t.decel.allowStockAfterfire !== undefined && typeof t.decel.allowStockAfterfire !== 'boolean')) return false
  }
  if (t.boostCut !== undefined && !(Number.isFinite(t.boostCut) && t.boostCut >= BOOST_CUT_MIN && t.boostCut <= BOOST_CUT_MAX)) return false
  if (!Number.isFinite(t.afrTrim ?? 0) || Math.abs(t.afrTrim ?? 0) > 20) return false
  if (t.boost && !validBoost(t.boost, t.rpm.length)) return false
  return ['lambda', 'timing'].every(f => Array.isArray(t[f]) && t[f].length === 8 &&
    t[f].every(r => Array.isArray(r) && r.length === t.rpm.length && r.every(v => Number.isFinite(v) &&
      v >= (f === 'lambda' ? (t.fuelType === 'diesel' ? 12/14.5 : .6) : -20) && v <= (f === 'lambda' ? (t.fuelType === 'diesel' ? 200/14.5 : 1.4) : 20))))
}

export function conservativeFuelTune(reference, nitro = false) {
  // Retain the installed calibration axes, including after an engine-part change.
  const rpm = [...reference.rpm], load = [...reference.load]
  return {version: reference.version, fuelType: reference.fuelType, afrTrim: reference.afrTrim ?? 0, ...(reference.nitrous ? {nitrous: {...reference.nitrous}} : {}), ...(reference.boost ? {boost: JSON.parse(JSON.stringify(reference.boost))} : {}), rpm, load,
    lambda: load.map(l => rpm.map(() => reference.fuelType === 'diesel' ? (60 - 42*l)/14.5 : nitro ? 1 - .28 * Math.max(0, Math.min(1, l / .75)) : 1 - .14 * Math.max(0, Math.min(1, (l - .55) / .45)))),
    timing: load.map(() => rpm.map(() => 0))}
}

export function sameFuelTune(a, b) {
  if (!validFuelTune(a) || !validFuelTune(b)) return false
  if (!sameNitrous(a.nitrous,b.nitrous)) return false
  if (a.version !== b.version || !['rpm', 'load'].every(f => a[f].length === b[f].length && a[f].every((v, i) => v === b[f][i]))) return false
  if ((a.afrTrim ?? 0) !== (b.afrTrim ?? 0) || (a.fuelType ?? 'gasoline') !== (b.fuelType ?? 'gasoline') || !sameBoost(a.boost,b.boost)) return false
  const da = decelSettings(a), db = decelSettings(b)
  if (Object.keys(da).some(k => da[k] !== db[k])) return false
  if (Math.abs(boostCutMargin(a) - boostCutMargin(b)) > 1e-8) return false
  // Lua/CEF serialization rounds floating values and can reorder object keys.
  return ['lambda', 'timing'].every(f => a[f].every((r, y) => r.every((v, x) => Math.abs(v - b[f][y][x]) <= 1e-8)))
}

export function decelSettings(t) {
  const d = t?.decel || {}
  return {mode: d.mode ?? 'original', cutDelay: d.cutDelay ?? .5, fueling: d.fueling ?? 1, retard: d.retard ?? 0, continuous: d.continuous === true, enabled: d.enabled !== false, allowStockAfterfire: d.allowStockAfterfire === true}
}

export function simpleFuelTune(reference, lambda, timing, nitro = false) {
  const tune = conservativeFuelTune(reference, nitro)
  tune.decel = decelSettings(reference)
  if (reference.boostCut !== undefined) tune.boostCut = reference.boostCut
  const smooth = v => { v = Math.max(0, Math.min(1, v)); return v * v * (3 - 2 * v) }
  tune.load.forEach((load, y) => tune.rpm.forEach((rpm, x) => {
    const weight = smooth((load - .45) / .30) * smooth((rpm / tune.rpm.at(-1) - .20) / .20)
    tune.lambda[y][x] = Number((tune.lambda[y][x] + (lambda - (reference.fuelType === 'diesel' ? 18/14.5 : nitro ? .72 : .86)) * weight).toFixed(4))
    tune.timing[y][x] = Number((timing * weight).toFixed(4))
  }))
  return tune
}

export function simpleFuelSettings(tune, nitro = false) {
  const lambda = Math.max(tune.fuelType === 'diesel' ? 12/14.5 : nitro ? .6 : .8, Math.min(tune.fuelType === 'diesel' ? 200/14.5 : nitro ? 1 : .94, tune.lambda[7].at(-1)))
  const timing = Math.max(-20, Math.min(20, tune.timing[7].at(-1)))
  const baseline = conservativeFuelTune(tune, nitro)
  baseline.decel = decelSettings(tune)
  if (tune.boostCut !== undefined) baseline.boostCut = tune.boostCut
  return {lambda, timing, custom: !sameFuelTune(tune, baseline) && !sameFuelTune(tune, simpleFuelTune(tune, lambda, timing, nitro))}
}

export function validBoost(b, rows) {
  return (b.enabled === undefined || typeof b.enabled === 'boolean') && ['original','caps','map'].includes(b.mode) && Number.isFinite(b.offset ?? 0) && Math.abs(b.offset ?? 0) <= 30 &&
    Array.isArray(b.gears) && b.gears.length > 0 && b.gears.length <= 64 && b.gears.every((g,i) => Number.isInteger(g) && g>0 && (!i || g>b.gears[i-1])) &&
    ['caps','offsets'].every(k => Array.isArray(b[k]) && b[k].length === b.gears.length && b[k].every(v => Number.isFinite(v) && (k === 'caps' ? v>=0 && v<=200 : Math.abs(v)<=30))) &&
    Array.isArray(b.targets) && b.targets.length === rows && b.targets.every(r => Array.isArray(r) && r.length === b.gears.length && r.every(v => Number.isFinite(v) && v>=0 && v<=200))
}
function sameBoost(a,b) {
  if (!a || !b) return !a && !b
  return (a.enabled===true)===(b.enabled===true) && a.mode===b.mode && Math.abs((a.offset ?? 0)-(b.offset ?? 0))<1e-8 && ['gears','caps','offsets','targets'].every(k => {
    const av=a[k].flat(),bv=b[k].flat();return av.length===bv.length && av.every((v,i)=>Math.abs(v-bv[i])<1e-8)
  })
}
export function rpmAxis(limit,spacing='even') {
  limit = Math.round(Number(limit))
  if (!Number.isFinite(limit) || limit<1000 || limit>50000 || !['even',100,500,1000].includes(spacing)) throw new Error('Use 1,000–50,000 RPM and even, 100, 500 or 1,000 spacing.')
  if (spacing==='even') return Array.from({length:12},(_,i)=>Math.round(limit*i/11))
  const a=Array.from({length:Math.floor(limit/spacing)+1},(_,i)=>i*spacing)
  if(a.at(-1)!==limit)a.push(limit)
  return a
}
function interpolateAt(axis,values,x) {
  x=Math.max(axis[0],Math.min(axis.at(-1),x))
  const i=Math.min(axis.length-2,Math.max(0,axis.findIndex((v,i)=>i<axis.length-1 && x<=axis[i+1])))
  const f=(x-axis[i])/(axis[i+1]-axis[i]);return values[i]*(1-f)+values[i+1]*f
}
export function resizeFuelTune(t,limit,spacing) {
  const out=JSON.parse(JSON.stringify(t));out.version=2;out.rpm=rpmAxis(limit,spacing)
  for(const k of ['lambda','timing'])out[k]=t[k].map(row=>out.rpm.map(r=>interpolateAt(t.rpm,row,r)))
  if(t.boost)out.boost.targets=out.rpm.map(r=>t.boost.gears.map((_,col)=>interpolateAt(t.rpm,t.boost.targets.map(row=>row[col]),r)))
  return out
}
export function gearBoost(t,gears,baseline=0) {
  const old=t.boost
  const last=(old?.gears.length ?? 0)-1
  const lastOffsetPsi=(old?.offset ?? 0)+(old?.offsets[last] ?? 0)
  // Preserve negative trim through interpolation so intermediate RPMs stay safe.
  const newOffsetPsi=Math.min(lastOffsetPsi,0)
  const newTargetPsi=valuePsi=>Math.min(Math.max(0,Math.min(200,baseline))-newOffsetPsi,valuePsi+lastOffsetPsi-newOffsetPsi,200)
  return {enabled:old?.enabled === true,mode:old?.mode ?? 'caps',offset:old?.offset ?? 0,gears:[...gears],
    caps:gears.map(g=>old?.caps[old.gears.indexOf(g)] ?? (old?newTargetPsi(old.caps[last]):baseline)),
    offsets:gears.map(g=>old?.offsets[old.gears.indexOf(g)] ?? newOffsetPsi-(old?.offset ?? 0)),
    targets:t.rpm.map((_,r)=>gears.map(g=>old?.targets[r]?.[old.gears.indexOf(g)] ?? (old?newTargetPsi(old.targets[r][last]):baseline)))}
}
export function adaptFuelBoost(tune,gears,baselinePsi=0) {
  if(!tune?.boost || JSON.stringify(tune.boost.gears)===JSON.stringify(gears))return false
  if(!gears.length && (tune.boost.enabled!==true || tune.boost.mode==='original'))return false
  if(gears.length)tune.boost=gearBoost(tune,gears,baselinePsi)
  else delete tune.boost
  return true
}

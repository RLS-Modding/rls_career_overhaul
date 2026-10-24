(function () {
  var fields = null

  function text(value) {
    return value === undefined || value === null ? '' : String(value)
  }

  function getFields() {
    if (!fields) {
      fields = {
        speedVal: document.querySelector('#Speed .small-value'),
        speedUnit: document.querySelector('#Speed .small-unit'),
        ripems: document.querySelector('#RPMBlock .small-value'),
        gear: document.querySelector('#SpeedSelector p')
      }
    }
    return fields
  }

  window.setUnits = function () {}

  window.updateData = function (data) {
    var f = getFields()
    if (!f.gear) { fields = null; return }

    var gear = data.gear
    if (gear === -1) gear = 'R'
    else if (gear === -2) gear = 'R2'
    else if (gear === 0) gear = 'N'

    f.gear.textContent = text(gear)
    f.ripems.textContent = text(data.ripems)
    f.speedVal.textContent = (data.speed * 3.6).toFixed(0)
    f.speedUnit.textContent = 'km/h'
  }
})()

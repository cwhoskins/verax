## Simultaneous switching noise: `switching` copies of one IBIS output
## switch together, `quiet` copies hold, and all of them hang from the
## die's own power and ground rails, which reach the board through the
## package's power and ground pins. The shared pin inductance turns the
## switching current's `dI/dt` into ground bounce and power droop; the
## quiet outputs carry it to their receivers.
##
## - **Rails** (power-aware, `SiNet.supply`): the pullup and POWER clamp
##   hang from the die's power node, the pulldown and GND clamp from its
##   ground node, each read against its own reference
##   (`engine/mna.NlDevice`). `[ISSO PU]`/`[ISSO PD]` scale the pullup and
##   pulldown with the rail's deviation, and `[Composite Current]` adds the
##   pre-driver current the I/V tables do not hold, rail to rail at each
##   transition (`ibis/behave`).
## - **Package**: each signal pin `pkgSignal`; the power (ground) pins are
##   `powerPins` (`groundPins`) copies of `pkgPower` (`pkgGround`) in
##   parallel -- `R/n`, `L/n`, no mutual inductance (an `Assumption`).
##   Beyond them the board supply is ideal; `dieDecap` is the capacitance
##   between the die rails (IBIS 5 states none; `0` = none).
## - `C_comp` stays referenced to the global ground (IBIS: GND is the
##   reference for C_comp unless split into `C_comp_*`, not modelled).
## - **Measures**: ground bounce = peak `|v(ground die)|`, power droop =
##   peak `nominal - v(power die)`, and at each quiet receiver the largest
##   excursion from its level and its noise margin (`measure.measureNoise`).

import std/[math, strutils]
import ./simulate
import ./measure
import ../netlist/annotations

type
  SsnSpec* = object
    name*: string
    driver*: DriverBehaviour
    receiver*: ReceiverBehaviour
    switching*: int
    quiet*: int
    quietHigh*: bool
    line*: LineSection
      ## Each output's trace to its receiver.
    length*: float
    pkgSignal*: PackageRlc
    powerPins*, groundPins*: int
    pkgPower*, pkgGround*: PackageRlc
    supply*: float
      ## Board supply, volts; `NaN` = the driver's pullup rail.
    dieDecap*: float

  SsnResult* = object
    status*: SiStatus
    reason*: string
    groundBounce*, powerDroop*: float
    quietNoise*, quietMargin*: float
      ## Worst over the quiet receivers; `quietMargin` is `NaN` without
      ## thresholds or quiet outputs.
    at*: array[4, string]
      ## The run that set each figure, in the order above.
    runs*: int
    assumptions*: seq[Assumption]
    issues*: seq[Issue]

proc ssnNet*(s: SsnSpec): SiNet =
  result = newSiNet(s.name)
  if s.switching < 1:
    result.unsupported.add "SSN needs at least one switching output"
    return
  if s.powerPins < 1 or s.groundPins < 1:
    result.unsupported.add "SSN needs at least one power and one ground pin"
    return
  let vNom = if s.supply.isNaN: s.driver.rails.pullup else: s.supply
  let vccDie = result.addNode("vcc:die")
  let gndDie = result.addNode("gnd:die")
  result.supply = SiSupply(present: true, vccDie: vccDie, gndDie: gndDie)
  # Power: die - R/n - L/n - board supply. Ground: die - R/n - L/n - 0.
  let vccBoard = result.addNode("vcc:board")
  result.addSource(vccBoard, 0, vNom, "board supply")
  let pm = result.addNode("vcc:pkg")
  result.addResistor(vccDie, pm, s.pkgPower.r / s.powerPins.float, "power pins R")
  result.addInductor(pm, vccBoard, s.pkgPower.l / s.powerPins.float, "power pins L")
  let gm = result.addNode("gnd:pkg")
  result.addResistor(gndDie, gm, s.pkgGround.r / s.groundPins.float, "ground pins R")
  result.addInductor(gm, 0, s.pkgGround.l / s.groundPins.float, "ground pins L")
  if s.dieDecap > 0: result.addCapacitor(vccDie, gndDie, s.dieDecap, "die decap")
  result.assumptions.add packageAssumption()
  result.assumptions.add note("net " & s.name, $s.powerPins & " power and " & $s.groundPins &
    " ground pins in parallel with no mutual inductance; the board supply ideal beyond them" &
    (if s.dieDecap > 0: "; " & $s.dieDecap & " F between the die rails" else: "; no on-die decap"))
  result.assumptions.add note("net " & s.name, "C_comp referenced to the global ground")
  for k in 0 ..< s.switching + s.quiet:
    let isQuiet = k >= s.switching
    let tag = (if isQuiet: "Q" & $(k - s.switching) else: "S" & $k)
    result.conductorNames.add tag
    let pin =
      if k == 0:
        result.setDriver(tag & ".drv", s.driver, s.pkgSignal)
        result.driverPort.pinNode
      else:
        result.addExtraDriver(tag & ".drv", s.driver, s.pkgSignal, k,
                              (if not isQuiet: dmStimulus
                               elif s.quietHigh: dmQuietHigh else: dmQuietLow))
    var far = pin
    if s.length > 0:
      far = result.addNode(tag & ":far")
      result.addLine(pin, far, s.line.z0, s.line.tdPerM * s.length, tag & " trace")
    discard result.addReceiver(tag & ".rx", s.receiver, s.pkgSignal, far, k)

proc ssn*(s: SsnSpec, stimuli: openArray[Stimulus], o = defaultSiOptions()): SsnResult =
  ## Every stimulus; the worst of each figure and the run that set it.
  let net = ssnNet(s)
  result.assumptions = net.assumptions
  result.issues = net.issues
  if net.unsupported.len > 0:
    result.status = ssUnsupported
    result.reason = net.unsupported.join("; ")
    return
  let vNom = if s.supply.isNaN: s.driver.rails.pullup else: s.supply
  result.quietMargin = NaN
  for stim in stimuli:
    let r = simulate(net, stim, o)
    inc result.runs
    result.issues.add r.issues
    if r.status != ssOk:
      result.status = r.status
      result.reason = $stim & ": " & r.reason
      return
    let what = $stim
    for x in r.v[net.supply.gndDie]:
      if abs(x) > result.groundBounce:
        result.groundBounce = abs(x)
        result.at[0] = what
    for x in r.v[net.supply.vccDie]:
      if vNom - x > result.powerDroop:
        result.powerDroop = vNom - x
        result.at[1] = what
    for k in s.switching ..< s.switching + s.quiet:
      let w = r.receivers[k].v
      let n = measureNoise(r.t, w, r.receivers[k].label, w[0], s.quietHigh,
                           s.receiver.thresholds)
      if n.noise > result.quietNoise:
        result.quietNoise = n.noise
        result.at[2] = what
      if not n.noiseMargin.isNaN and (result.quietMargin.isNaN or n.noiseMargin < result.quietMargin):
        result.quietMargin = n.noiseMargin
        result.at[3] = what
  result.status = ssOk

proc `$`*(r: SsnResult): string =
  proc mv(x: float): string = (if x.isNaN: "n/a" else: formatFloat(x * 1e3, ffDecimal, 1) & " mV")
  "ground bounce " & mv(r.groundBounce) & " (" & r.at[0] & "), power droop " &
    mv(r.powerDroop) & " (" & r.at[1] & "), quiet-line noise " & mv(r.quietNoise) &
    ", noise margin " & mv(r.quietMargin)

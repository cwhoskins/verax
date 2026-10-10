## Synthetic `.ibs` fixtures for the SI tests (docs/ibis_simulator_plan.md,
## stage 0). Imported by tests, never compiled as one (`listFiles("tests")`
## is non-recursive).
##
## Every buffer here is **linear**: pullup and pulldown are resistors to their
## rails, clamps are resistive leaks, so every downstream number has a closed
## form. The waveforms are *generated* from a stated `Ku(t)`/`Kd(t)` -- the
## extraction tests then check they get those coefficients back.

import std/[math, strutils]

type
  LinearDriver* = object
    ## A resistor-model buffer and the fixtures its waveforms are drawn into.
    name*: string
    modelType*: string            ## `Output`, `3-state`, `Open_drain`, ...
    vcc*: float
    rpu*, rpd*: float             ## `0` omits that table
    rgc*, rpc*: float             ## clamp leak resistances; `0` omits the table
    cComp*: float
    tEdge*: float                 ## `Ku`/`Kd` ramp 0..1 over `[0, tEdge]`
    tEnd*: float
    samples*: int
    fixtures*: seq[tuple[r, v, c: float]]
    extraFixtureLines*: string    ## appended to every waveform header
    clampsInTables*: bool
      ## Write the clamp current *into* the pullup/pulldown tables as well:
      ## the "clamps counted twice" mistake, for the test that must catch it.
    withRamp*: bool
    withWaveforms*: bool
    modelSpec*: string            ## raw `[Model Spec]` body, or ""
    extraModelLines*: string      ## raw `[Model]` subparameter lines
    network*: tuple[lf, rdut, ldut, cdut: float]
      ## A full IBIS fixture network on every waveform (all positive, with
      ## `cComp` and each fixture's `c` positive too), integrated as ODEs.
    probeAtFixture*: bool
      ## Tabulate the fixture node instead of the DUT pin.
    preDriverPulse*: tuple[amp, t0, width: float]
      ## With `amp != 0`, every waveform gets a `[Composite Current]`: the
      ## pullup's own current plus this triangular pulse (the pre-driver).
    extraModelTables*: string
      ## Raw keyword blocks inside the `[Model]` (`[ISSO PD]` ...).

proc defaultLinearDriver*(): LinearDriver =
  LinearDriver(name: "lin_drv", modelType: "Output", vcc: 3.3, rpu: 25.0,
               rpd: 20.0, rgc: 0.0, rpc: 0.0, cComp: 0.0, tEdge: 1e-9,
               tEnd: 2e-9, samples: 41,
               fixtures: @[(50.0, 0.0, 0.0), (50.0, 3.3, 0.0)],
               withRamp: true, withWaveforms: true)

proc num(x: float): string = formatFloat(x, ffScientific, 12)

proc preDriverAt*(d: LinearDriver, t: float): float =
  ## The synthetic pre-driver pulse: a triangle of `amp` peaking mid-width.
  let p = d.preDriverPulse
  if p.amp == 0 or p.width <= 0: return 0.0
  let x = (t - p.t0) / p.width
  if x <= 0 or x >= 1: 0.0 else: p.amp * (1.0 - abs(2.0 * x - 1.0))

proc kAt*(d: LinearDriver, rising: bool, t: float): tuple[ku, kd: float] =
  ## The coefficients the waveforms were generated from.
  let f = clamp(t / d.tEdge, 0.0, 1.0)
  let up = if rising: f else: 1.0 - f
  (ku: (if d.rpu > 0: up else: 0.0), kd: (if d.rpd > 0: 1.0 - up else: 0.0))

proc bufCurrent*(d: LinearDriver, ku, kd, v: float): float =
  ## Current **out of** the die at pad voltage `v`, clamps counted once.
  if d.rpu > 0: result += ku * (d.vcc - v) / d.rpu
  if d.rpd > 0: result -= kd * v / d.rpd
  if d.rgc > 0: result -= v / d.rgc
  if d.rpc > 0: result += (d.vcc - v) / d.rpc

proc padVoltage(d: LinearDriver, rising: bool, fx: tuple[r, v, c: float],
                t: float): float =
  ## Algebraic solve (no capacitance): everything is linear in `v`.
  let (ku, kd) = d.kAt(rising, t)
  var g = 1.0 / fx.r
  var i = fx.v / fx.r
  if d.rpu > 0: g += ku / d.rpu; i += ku * d.vcc / d.rpu
  if d.rpd > 0: g += kd / d.rpd
  if d.rgc > 0: g += 1.0 / d.rgc
  if d.rpc > 0: g += 1.0 / d.rpc; i += d.vcc / d.rpc
  i / g

proc waveformPoints*(d: LinearDriver, rising: bool,
                     fx: tuple[r, v, c: float]): seq[tuple[t, v: float]] =
  ## The V/T table for one fixture. With capacitance, RK4 over 2000 sub-steps
  ## per sample, from the DC point at `t = 0`.
  if d.network.lf > 0:
    # State (vd, iL, vp, iF, vf): die, die -> pin, pin, pin -> fixture,
    # fixture node. DC start: vd from the algebraic solve into Rf + R_dut.
    let nw = d.network
    proc deriv(t: float, s: array[5, float]): array[5, float] =
      let (ku, kd) = d.kAt(rising, t)
      result[0] = (d.bufCurrent(ku, kd, s[0]) - s[1]) / d.cComp
      result[1] = (s[0] - s[2] - nw.rdut * s[1]) / nw.ldut
      result[2] = (s[1] - s[3]) / nw.cdut
      result[3] = (s[2] - s[4]) / nw.lf
      result[4] = (s[3] - (s[4] - fx.v) / fx.r) / fx.c
    let vd0 = d.padVoltage(rising, (fx.r + nw.rdut, fx.v, 0.0), 0.0)
    let i0 = (vd0 - fx.v) / (fx.r + nw.rdut)
    let vp0 = vd0 - nw.rdut * i0
    var s = [vd0, i0, vp0, i0, vp0]
    var t = 0.0
    result.add (0.0, (if d.probeAtFixture: s[4] else: s[2]))
    let dtS = d.tEnd / (d.samples - 1).float
    const sub = 400
    for k in 1 ..< d.samples:
      let h = dtS / sub.float
      for _ in 0 ..< sub:
        let k1 = deriv(t, s)
        var s2, s3, s4: array[5, float]
        for q in 0 ..< 5: s2[q] = s[q] + h / 2 * k1[q]
        let k2 = deriv(t + h / 2, s2)
        for q in 0 ..< 5: s3[q] = s[q] + h / 2 * k2[q]
        let k3 = deriv(t + h / 2, s3)
        for q in 0 ..< 5: s4[q] = s[q] + h * k3[q]
        let k4 = deriv(t + h, s4)
        for q in 0 ..< 5: s[q] += h / 6 * (k1[q] + 2 * k2[q] + 2 * k3[q] + k4[q])
        t += h
      result.add (dtS * k.float, (if d.probeAtFixture: s[4] else: s[2]))
    return
  let ctot = d.cComp + fx.c
  for k in 0 ..< d.samples:
    let t = d.tEnd * k.float / (d.samples - 1).float
    if ctot == 0.0:
      result.add (t, d.padVoltage(rising, fx, t))
  if ctot == 0.0: return
  proc dvdt(t, v: float): float =
    let (ku, kd) = d.kAt(rising, t)
    (d.bufCurrent(ku, kd, v) - (v - fx.v) / fx.r) / ctot
  var v = d.padVoltage(rising, fx, 0.0)
  var t = 0.0
  result.add (0.0, v)
  let dtS = d.tEnd / (d.samples - 1).float
  const sub = 2000
  for k in 1 ..< d.samples:
    let h = dtS / sub.float
    for _ in 0 ..< sub:
      let k1 = dvdt(t, v)
      let k2 = dvdt(t + h / 2, v + h / 2 * k1)
      let k3 = dvdt(t + h / 2, v + h / 2 * k2)
      let k4 = dvdt(t + h, v + h * k3)
      v += h / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
      t += h
    result.add (dtS * k.float, v)

proc ivRows(f: proc(v: float): float, vlo, vhi: float, n = 7): string =
  ## `<v> <I_into_device> NA NA` rows, `n` evenly spaced.
  for k in 0 ..< n:
    let v = vlo + (vhi - vlo) * k.float / (n - 1).float
    result.add num(v) & "  " & num(f(v)) & "  NA  NA\n"

proc toIbs*(d: LinearDriver): string =
  ## The `.ibs` text: one component `LINDEV` with pin 1 on this model.
  let vcc = d.vcc
  var m = "[Model] " & d.name & "\n"
  m.add "Model_type " & d.modelType & "\n"
  m.add "C_comp " & num(d.cComp) & " NA NA\n"
  m.add "Vinl = 0.8\nVinh = 2.0\n"
  m.add d.extraModelLines
  m.add "[Voltage Range] " & num(vcc) & " NA NA\n"
  if d.modelSpec.len > 0:
    m.add "[Model Spec]\n" & d.modelSpec
  m.add d.extraModelTables
  # IBIS currents are *into* the device; table voltages keep each table's
  # reference (pullup/power clamp relative to the rail).
  let gcLeak = proc(v: float): float =
    (if d.rgc > 0: v / d.rgc else: 0.0)
  let pcLeak = proc(vt: float): float =
    (if d.rpc > 0: -vt / d.rpc else: 0.0)
  if d.rpd > 0:
    m.add "[Pulldown]\n"
    m.add ivRows(proc(v: float): float =
      v / d.rpd + (if d.clampsInTables: gcLeak(v) else: 0.0), -vcc, 2 * vcc)
  if d.rpu > 0:
    m.add "[Pullup]\n"
    m.add ivRows(proc(vt: float): float =
      -vt / d.rpu + (if d.clampsInTables: pcLeak(vt) else: 0.0), -vcc, 2 * vcc)
  if d.rgc > 0:
    m.add "[GND Clamp]\n" & ivRows(gcLeak, -vcc, 2 * vcc)
  if d.rpc > 0:
    m.add "[POWER Clamp]\n" & ivRows(pcLeak, -vcc, 2 * vcc)
  if d.withRamp:
    # 20-80 % of the swing into 50 ohm to ground for rising, to the rail for
    # falling -- a nominal figure; only `dt` matters to the fallback.
    let dt = 0.6 * d.tEdge
    m.add "[Ramp]\n"
    m.add "dV/dt_r " & num(0.6 * vcc) & "/" & num(dt) & " NA NA\n"
    m.add "dV/dt_f " & num(0.6 * vcc) & "/" & num(dt) & " NA NA\n"
    m.add "R_load = 50\n"
  if d.withWaveforms:
    for rising in [true, false]:
      for fx in d.fixtures:
        m.add (if rising: "[Rising Waveform]\n" else: "[Falling Waveform]\n")
        m.add "R_fixture = " & num(fx.r) & "\n"
        m.add "V_fixture = " & num(fx.v) & "\n"
        if fx.c != 0.0: m.add "C_fixture = " & num(fx.c) & "\n"
        if d.network.lf > 0:
          m.add "L_fixture = " & num(d.network.lf) & "\n"
          m.add "R_dut = " & num(d.network.rdut) & "\n"
          m.add "L_dut = " & num(d.network.ldut) & "\n"
          m.add "C_dut = " & num(d.network.cdut) & "\n"
        m.add d.extraFixtureLines
        let pts = d.waveformPoints(rising, fx)
        for (t, v) in pts:
          m.add num(t) & "  " & num(v) & "  NA  NA\n"
        if d.preDriverPulse.amp != 0:
          m.add "[Composite Current]\n"
          for (t, v) in pts:
            let (ku, _) = d.kAt(rising, t)
            m.add num(t) & "  " & num(ku * (d.vcc - v) / d.rpu + d.preDriverAt(t)) & "  NA  NA\n"
  result = "[IBIS Ver] 3.2\n[File Name] synthetic.ibs\n[File Rev] 1.0\n"
  result.add "[Component] LINDEV\nManufacturer verax tests\n"
  result.add "[Package]\nR_pkg 0.2 NA NA\nL_pkg 2nH NA NA\nC_pkg 0.5pF NA NA\n"
  result.add "[Pin] signal_name model_name R_pin L_pin C_pin\n"
  result.add "1 OUT " & d.name & "\n2 VCC POWER\n3 GND GND\n"
  result.add m
  result.add "[End Model]\n[End]\n"

proc linearReceiverIbs*(name = "lin_rx", vcc = 3.3, rgc = 0.0, rpc = 0.0,
                        cComp = 2e-12, modelSpec = ""): string =
  ## An `Input` model: clamps (optional linear leaks) and `C_comp`.
  var m = "[Model] " & name & "\nModel_type Input\n"
  m.add "C_comp " & num(cComp) & " NA NA\nVinl = 0.8\nVinh = 2.0\n"
  m.add "[Voltage Range] " & num(vcc) & " NA NA\n"
  if modelSpec.len > 0: m.add "[Model Spec]\n" & modelSpec
  if rgc > 0:
    m.add "[GND Clamp]\n" & ivRows(proc(v: float): float = v / rgc, -vcc, 2 * vcc)
  if rpc > 0:
    m.add "[POWER Clamp]\n" & ivRows(proc(vt: float): float = -vt / rpc, -vcc, 2 * vcc)
  result = "[IBIS Ver] 3.2\n[File Name] rx.ibs\n[File Rev] 1.0\n"
  result.add "[Component] RXDEV\nManufacturer verax tests\n"
  result.add "[Package]\nR_pkg 0.2 NA NA\nL_pkg 2nH NA NA\nC_pkg 0.5pF NA NA\n"
  result.add "[Pin] signal_name model_name R_pin L_pin C_pin\n"
  result.add "1 IN " & name & "\n2 VCC POWER\n3 GND GND\n"
  result.add m & "[End Model]\n[End]\n"

const selectorIbs* = """
[IBIS Ver] 3.2
[File Name] sel.ibs
[File Rev] 1.0
[Component] SELDEV
Manufacturer verax tests
[Package]
R_pkg 0.1 NA NA
L_pkg 1nH NA NA
C_pkg 0.3pF NA NA
[Pin] signal_name model_name R_pin L_pin C_pin
1 IO  io_sel
2 IN  rx_only  0.3  3nH  0.6pF
3 VCC POWER
4 NC  NC
[Model Selector] io_sel
io_fast   fast drive
io_slow   slow drive
[Model] io_fast
Model_type I/O
C_comp 1pF NA NA
[Voltage Range] 3.3 NA NA
[Pulldown]
-3.3 -0.165 NA NA
 6.6  0.33  NA NA
[Pullup]
-3.3  0.165 NA NA
 6.6 -0.33  NA NA
[Ramp]
dV/dt_r 1.98/0.3n NA NA
dV/dt_f 1.98/0.3n NA NA
[End Model]
[Model] io_slow
Model_type I/O
C_comp 1pF NA NA
[Voltage Range] 3.3 NA NA
[Pulldown]
-3.3 -0.066 NA NA
 6.6  0.132 NA NA
[Pullup]
-3.3  0.066 NA NA
 6.6 -0.132 NA NA
[Ramp]
dV/dt_r 1.98/0.9n NA NA
dV/dt_f 1.98/0.9n NA NA
[End Model]
[Model] rx_only
Model_type Input
C_comp 2pF NA NA
[Voltage Range] 3.3 NA NA
[End Model]
[End]
"""
  ## A `[Model Selector]` pin, a per-pin RLC override, a `POWER` and an `NC`
  ## pin.

const incompleteCornersIbs* = """
[IBIS Ver] 3.2
[File Name] corners.ibs
[File Rev] 1.0
[Component] CDEV
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
C_comp 2pF NA 2.5pF
[Voltage Range] 3.3 3.0 3.6
[Pulldown]
0.0  0.0    0.0    0.0
3.3  0.165  0.150  NA
[Pullup]
0.0  0.0    0.0    0.0
3.3 -0.132 -0.120 -0.150
[Ramp]
dV/dt_r 1.98/0.5n 1.8/0.7n 2.16/0.4n
dV/dt_f 1.98/0.5n 1.8/0.7n 2.16/0.4n
[End Model]
[End]
"""
  ## typ complete; min missing `C_comp`; max missing one `[Pulldown]` row.

const malformedRowIbs* = """
[IBIS Ver] 3.2
[Component] BAD
[Pin] signal_name model_name
1 OUT drv
[Model] drv
Model_type Output
[Voltage Range] 3.3 NA NA
[Model Spec]
Vinh 2.0 oops 2.2
[End Model]
[End]
"""

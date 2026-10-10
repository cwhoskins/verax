## Building the typed `IbisFile` from the lexer's tree:
## `readIbis(s)`/`readIbisFile(path)`. No writer.
##
## - **Every failure is an `IbisError` with line context** where possible.
## - **Unrecognised keywords degrade, not error**: they stay in
##   `IbisFile.sections`, so a 3.2-shaped reader can open a 7.x file.

import std/[streams, strutils, tables]
import ./types
import ./parse

export types

proc tokens(s: string): seq[string] =
  ## Whitespace-separated row tokens; `=` around a value (`Vinl = 0.8`) is
  ## noise.
  for t in s.splitWhitespace():
    if t != "=": result.add t

proc firstArg(sec: IbisSection): string =
  ## The keyword's own name argument -- `[Model] my_model` -> `my_model`.
  let a = sec.args.splitWhitespace()
  if a.len > 0: a[0] else: ""

proc modelTypeOf(raw: string): ModelType =
  case canonicalKeyword(raw)
  of "input": mtInput
  of "output": mtOutput
  of "i/o", "io": mtIO
  of "3-state", "3_state", "tristate": mtThreeState
  of "open_drain": mtOpenDrain
  of "i/o_open_drain", "io_open_drain": mtIO
  of "open_sink": mtOpenSink
  of "i/o_open_sink", "io_open_sink": mtIO
  of "open_source": mtOpenSource
  of "i/o_open_source", "io_open_source": mtIO
  of "input_ecl": mtInputEcl
  of "output_ecl": mtOutputEcl
  of "i/o_ecl", "io_ecl": mtIoEcl
  of "3-state_ecl", "3_state_ecl": mtThreeStateEcl
  of "terminator": mtTerminator
  of "series": mtSeries
  of "series_switch": mtSeriesSwitch
  else: mtOther

proc parseIv(sec: IbisSection): IvTable =
  ## `[Pulldown]` / `[Pullup]` / `[GND Clamp]` / `[POWER Clamp]`: rows of
  ## `<voltage> <I_typ> <I_min> <I_max>`.
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    var v: float
    if not parseIbisNumber(tk[0], v):
      raise newException(IbisError,
        "line " & $n & ": [" & sec.rawKeyword & "] row does not start with a voltage: " & text)
    result.add IvPoint(v: v, i: parseTriplet(tk, 1))

proc pairTriplets(tk: seq[string], first: int): tuple[a, b: Triplet] =
  ## `[Ramp]` corners are `dV/dt`: split each into a `dV` and a `dt`
  ## triplet.
  var aToks, bToks: seq[string]
  for k in 0 .. 2:
    let idx = first + k
    if idx >= tk.len: break
    if isNA(tk[idx]):
      aToks.add "NA"; bToks.add "NA"
      continue
    let halves = tk[idx].split('/')
    if halves.len != 2:
      raise newException(IbisError, "[Ramp] value is not dV/dt: '" & tk[idx] & "'")
    aToks.add halves[0]
    bToks.add halves[1]
  (parseTriplet(aToks), parseTriplet(bToks))

proc parseRamp(sec: IbisSection): RampSpec =
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    case canonicalKeyword(tk[0])
    of "dv/dt_r", "dv_dt_r":
      (result.dvR, result.dtR) = pairTriplets(tk, 1)
    of "dv/dt_f", "dv_dt_f":
      (result.dvF, result.dtF) = pairTriplets(tk, 1)
    of "r_load":
      if tk.len > 1 and parseIbisNumber(tk[1], result.rLoad):
        result.rLoadPresent = true
    else: discard

proc parseWaveform(sec: IbisSection): Waveform =
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    let head = canonicalKeyword(tk[0])
    template scalar(dst: untyped) =
      if tk.len > 1: discard parseIbisNumber(tk[1], dst)
    case head
    of "r_fixture": scalar(result.rFixture)
    of "v_fixture": result.vFixture = parseTriplet(tk, 1)
    of "v_fixture_min", "v_fixture_max":
      var v: float
      if tk.len < 2 or not parseIbisNumber(tk[1], v):
        raise newException(IbisError,
          "line " & $n & ": [" & sec.rawKeyword & "] " & tk[0] & " has no value")
      result.vFixture.set((if head == "v_fixture_min": coMin else: coMax), v)
    of "c_fixture": scalar(result.cFixture)
    of "l_fixture": scalar(result.lFixture)
    of "r_dut": scalar(result.rDut)
    of "l_dut": scalar(result.lDut)
    of "c_dut": scalar(result.cDut)
    else:
      var t: float
      if parseIbisNumber(tk[0], t):
        result.points.add VtPoint(t: t, v: parseTriplet(tk, 1))

proc parseModelSpec(sec: IbisSection): ModelSpec =
  ## `[Model Spec]`: rows of `<subparameter> <typ> <min> <max>`. An unknown
  ## subparameter stays in `raw`; a malformed number raises.
  result.present = true
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    template row(dst: untyped) =
      try:
        dst = parseTriplet(tk, 1)
      except IbisError as e:
        raise newException(IbisError,
          "line " & $n & ": [Model Spec] " & tk[0] & ": " & e.msg)
    case canonicalKeyword(tk[0])
    of "vinh": row(result.vinh)
    of "vinl": row(result.vinl)
    of "vinh+": row(result.vinhPlus)
    of "vinh-": row(result.vinhMinus)
    of "vinl+": row(result.vinlPlus)
    of "vinl-": row(result.vinlMinus)
    of "s_overshoot_high": row(result.sOvershootHigh)
    of "s_overshoot_low": row(result.sOvershootLow)
    of "d_overshoot_high": row(result.dOvershootHigh)
    of "d_overshoot_low": row(result.dOvershootLow)
    of "d_overshoot_time": row(result.dOvershootTime)
    of "pulse_high": row(result.pulseHigh)
    of "pulse_low": row(result.pulseLow)
    of "pulse_time": row(result.pulseTime)
    of "vmeas": row(result.vmeas)
    of "vref": row(result.vref)
    of "cref": row(result.cref)
    of "rref": row(result.rref)
    else: discard

proc parseReceiverThresholds(sec: IbisSection): ReceiverThresholds =
  ## `[Receiver Thresholds]`: `<subparameter> = <value>` rows.
  result.present = true
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    template scalar(dst: ModelParam) =
      var v: float
      if tk.len < 2 or not parseIbisNumber(tk[1], v):
        raise newException(IbisError,
          "line " & $n & ": [Receiver Thresholds] " & tk[0] & " is not a number: " & text)
      dst = ModelParam(present: true, value: v)
    case canonicalKeyword(tk[0])
    of "vth": scalar(result.vth)
    of "vth_min": scalar(result.vthMin)
    of "vth_max": scalar(result.vthMax)
    of "vinh_ac": scalar(result.vinhAc)
    of "vinh_dc": scalar(result.vinhDc)
    of "vinl_ac": scalar(result.vinlAc)
    of "vinl_dc": scalar(result.vinlDc)
    of "threshold_sensitivity": scalar(result.thresholdSensitivity)
    of "vcross_low": scalar(result.vcrossLow)
    of "vcross_high": scalar(result.vcrossHigh)
    of "vdiff_ac": scalar(result.vdiffAc)
    of "vdiff_dc": scalar(result.vdiffDc)
    of "tslew_ac": scalar(result.tslewAc)
    of "tdiffslew_ac": scalar(result.tdiffslewAc)
    of "reference_supply":
      if tk.len > 1: result.referenceSupply = tk[1]
    else: discard

proc parsePackage(sec: IbisSection): Package =
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    case canonicalKeyword(tk[0])
    of "r_pkg": result.rPkg = parseTriplet(tk, 1)
    of "l_pkg": result.lPkg = parseTriplet(tk, 1)
    of "c_pkg": result.cPkg = parseTriplet(tk, 1)
    else: discard

proc parsePins(sec: IbisSection): seq[PinEntry] =
  ## `[Pin]`'s column headers are the keyword's own argument; every body
  ## line is a data row: `<name> <signal> <model> [R_pin L_pin C_pin]`.
  for (n, text) in sec.body:
    let tk = text.splitWhitespace()
    if tk.len == 0: continue
    if tk.len < 3:
      raise newException(IbisError,
        "line " & $n & ": [Pin] row has fewer than 3 columns: " & text)
    var pe = PinEntry(name: tk[0], signal: tk[1], model: tk[2])
    if tk.len > 3 and not isNA(tk[3]) and parseIbisNumber(tk[3], pe.rPin):
      pe.present.incl prR
    if tk.len > 4 and not isNA(tk[4]) and parseIbisNumber(tk[4], pe.lPin):
      pe.present.incl prL
    if tk.len > 5 and not isNA(tk[5]) and parseIbisNumber(tk[5], pe.cPin):
      pe.present.incl prC
    result.add pe

proc parseDiffPins(sec: IbisSection): seq[DiffPin] =
  for (n, text) in sec.body:
    let tk = text.splitWhitespace()
    if tk.len < 2:
      raise newException(IbisError,
        "line " & $n & ": [Diff Pin] row has fewer than 2 columns: " & text)
    var dp = DiffPin(pin: tk[0], invPin: tk[1])
    template col(k: int, dst: ModelParam) =
      if tk.len > k and not isNA(tk[k]):
        var v: float
        if parseIbisNumber(tk[k], v): dst = ModelParam(present: true, value: v)
    col(2, dp.vdiff)
    col(3, dp.tdelayTyp)
    col(4, dp.tdelayMin)
    col(5, dp.tdelayMax)
    result.add dp

proc parseModel(sec: IbisSection): IbisModel =
  result.name = firstArg(sec)
  result.raw = sec
  result.ramp.rLoad = 50.0
  for (n, text) in sec.body:
    let tk = tokens(text)
    if tk.len == 0: continue
    let head = canonicalKeyword(tk[0])
    template scalar(dst: ModelParam) =
      if tk.len > 1:
        var v: float
        if parseIbisNumber(tk[1], v): dst = ModelParam(present: true, value: v)
    case head
    of "model_type":
      if tk.len > 1:
        result.rawType = tk[1]
        result.modelType = modelTypeOf(tk[1])
    of "polarity":
      if tk.len > 1: result.polarity = tk[1]
    of "enable":
      if tk.len > 1: result.enable = tk[1]
    of "vinl": scalar(result.vinl)
    of "vinh": scalar(result.vinh)
    of "vmeas": scalar(result.vmeas)
    of "cref": scalar(result.cref)
    of "rref": scalar(result.rref)
    of "vref": scalar(result.vref)
    of "c_comp": result.cComp = parseTriplet(tk, 1)
    else: discard
  var prev = ""
  for ch in sec.children:
    defer: prev = ch.keyword
    case ch.keyword
    of "pulldown": result.pulldown = parseIv(ch)
    of "pullup": result.pullup = parseIv(ch)
    of "gnd_clamp": result.gndClamp = parseIv(ch)
    of "power_clamp": result.powerClamp = parseIv(ch)
    of "pullup_reference": result.pullupRef = parseTriplet(tokens(ch.args))
    of "pulldown_reference": result.pulldownRef = parseTriplet(tokens(ch.args))
    of "gnd_clamp_reference": result.gndClampRef = parseTriplet(tokens(ch.args))
    of "power_clamp_reference": result.powerClampRef = parseTriplet(tokens(ch.args))
    of "temperature_range": result.temperatureRange = parseTriplet(tokens(ch.args))
    of "voltage_range": result.voltageRange = parseTriplet(tokens(ch.args))
    of "ramp": result.ramp = parseRamp(ch)
    of "rising_waveform":
      result.risingWaveforms.add parseWaveform(ch)
    of "falling_waveform":
      result.fallingWaveforms.add parseWaveform(ch)
    of "composite_current":
      # Under the waveform table it follows.
      var pts: seq[VtPoint]
      for (n, text) in ch.body:
        let tk = tokens(text)
        var t: float
        if tk.len > 0 and parseIbisNumber(tk[0], t):
          pts.add VtPoint(t: t, v: parseTriplet(tk, 1))
      if prev == "rising_waveform": result.risingWaveforms[^1].composite = pts
      elif prev == "falling_waveform": result.fallingWaveforms[^1].composite = pts
      else:
        raise newException(IbisError, "line " & $ch.line &
          ": [Composite Current] does not follow a [Rising Waveform] or [Falling Waveform]")
    of "isso_pu": result.issoPu = parseIv(ch)
    of "isso_pd": result.issoPd = parseIv(ch)
    of "model_spec": result.modelSpec = parseModelSpec(ch)
    of "receiver_thresholds": result.receiverThresholds = parseReceiverThresholds(ch)
    else: discard

proc parseComponent(sec: IbisSection): IbisComponent =
  result.name = firstArg(sec)
  result.raw = sec
  for (n, text) in sec.body:
    let tk = text.splitWhitespace()
    if tk.len < 2: continue
    case canonicalKeyword(tk[0])
    of "manufacturer": result.manufacturer = tk[1 .. ^1].join(" ")
    of "package": result.packageName = tk[1 .. ^1].join(" ")
    of "si_location": result.siLocation = tk[1]
    of "timing_location": result.timingLocation = tk[1]
    else: discard
  for ch in sec.children:
    case ch.keyword
    of "package": result.pkg = parsePackage(ch)
    of "pin": result.pins.add parsePins(ch)
    of "diff_pin": result.diffPins.add parseDiffPins(ch)
    else: discard

proc parseModelSelector(sec: IbisSection): ModelSelector =
  result.name = firstArg(sec)
  for (n, text) in sec.body:
    let tk = text.splitWhitespace()
    if tk.len == 0: continue
    result.choices.add (model: tk[0], description: tk[1 .. ^1].join(" "))

proc headerText(sec: IbisSection): string =
  ## Free-text keywords (`[Notes]`) may put content on the keyword line, in
  ## the body, or both.
  if sec.args.len > 0: return sec.args
  var parts: seq[string]
  for ln in sec.body: parts.add ln.text
  parts.join(" ")

proc readIbis*(s: Stream, name = ""): IbisFile =
  ## Parse an IBIS stream (`name` for messages). Raises `IbisError` on bad
  ## structure or an unparseable modelled number.
  let secs = splitSections(s, name)
  result.sections = secs
  for sec in secs:
    case sec.keyword
    of "ibis_ver": result.ibisVersion = sec.args
    of "file_name": result.fileName = sec.args
    of "file_rev": result.fileRev = sec.args
    of "date": result.date = headerText(sec)
    of "source": result.source = headerText(sec)
    of "notes": result.notes = headerText(sec)
    of "disclaimer": result.disclaimer = headerText(sec)
    of "copyright": result.copyright = headerText(sec)
    of "component": result.components.add parseComponent(sec)
    of "model": result.models.add parseModel(sec)
    of "model_selector": result.modelSelectors.add parseModelSelector(sec)
    of "end": break
    else: discard   # kept in result.sections, modelled nowhere -- by design

proc readIbisFile*(path: string): IbisFile =
  ## `readIbis` on a file; raises `IbisError` if it can't be opened.
  var s: FileStream
  try:
    s = openFileStream(path, fmRead)
  except IOError, OSError:
    raise newException(IbisError, "cannot open IBIS file: " & path)
  defer: s.close()
  readIbis(s, path)

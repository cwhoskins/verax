## Stage 8.4 of docs/ibis_simulator_plan.md: PRBS stimulus and the eye
## diagram (height, width) as SI figures, judged like the rest.

import std/[unittest, streams, strutils, math]

import verax/ibis
import verax/si/simulate
import verax/si/eye
import verax/si/sweep
import verax/si/constrain
import ./fixtures/ibis/synthetic

suite "PRBS":
  test "one period: 2^n - 1 bits, one more one than zero, the longest runs":
    for (k, n) in [(prbs7, 7), (prbs9, 9), (prbs15, 15)]:
      let s = prbs(k)
      check s.len == (1 shl n) - 1
      check s.count('1') == 1 shl (n - 1)
      check s.count('0') == (1 shl (n - 1)) - 1
      check '1'.repeat(n) in s & s
      check '1'.repeat(n + 1) notin s & s
      check '0'.repeat(n - 1) in s & s
      check '0'.repeat(n) notin s & s

  test "periodic":
    let s = prbs(prbs7, 3 * 127)
    check s[0 ..< 127] == s[127 ..< 254]
    check s[0 ..< 127] == prbs(prbs7)

suite "eye of a known wave":
  # NRZ, 0 / 3.3 V, linear transitions of tr starting at each bit boundary.
  # A "1" is above Vinh from tr Vinh/V after its start to UI + tr (1 -
  # Vinh/V); a "0" below Vinl from tr (1 - Vinl/V) to UI + tr Vinl/V.
  const v = 3.3
  const ui = 2e-9
  const tr = 0.5e-9
  const vinh = 2.0
  const vinl = 0.8
  let bits = prbs(prbs7)
  var t, w: seq[float]
  t.add 0.0
  w.add (if bits[0] == '1': v else: 0.0)
  for k in 1 ..< bits.len:
    let t0 = k.float * ui
    let a = if bits[k - 1] == '1': v else: 0.0
    let b = if bits[k] == '1': v else: 0.0
    t.add t0; w.add a
    t.add t0 + tr; w.add b
  t.add bits.len.float * ui
  w.add w[^1]

  test "height is the swing, width the closed form to one offset step":
    var o = defaultEyeOptions()
    o.phases = 200
    o.maxOffset = ui
    let e = eyeOf(t, w, bits, ui, 0.0, vinh, vinl, true, o)
    check abs(e.height - v) < 1e-9
    let start = max(tr * vinh / v, tr * (1 - vinl / v))
    let stop = ui + min(tr * (1 - vinh / v), tr * vinl / v)
    checkpoint "width " & $e.width & " vs " & $(stop - start)
    # The search stops at one UI of offset, so the opening is cut there.
    check abs(e.width - (ui - start)) <= 2 * ui / 200
    var o2 = o
    o2.maxOffset = 2 * ui
    let e2 = eyeOf(t, w, bits, ui, 0.0, vinh, vinl, true, o2)
    check abs(e2.width - (stop - start)) <= 2 * ui / 200
    check abs(e2.margin - 0.8) < 1e-9   # min(3.3 - 2.0, 0.8 - 0)

  test "a channel delay is found by the offset search":
    var td = t
    for x in td.mitems: x += 3.3e-9
    let e = eyeOf(td, w, bits, ui, 0.0, vinh, vinl, true)
    check abs(e.height - v) < 1e-9
    check e.bestOffset > 3.3e-9 and e.bestOffset < 3.3e-9 + ui

proc thevenin(r = 50.0): LinearDriver =
  result = defaultLinearDriver()
  result.rpu = r
  result.rpd = r

proc drvB(d: LinearDriver): DriverBehaviour =
  driverBehaviour(readIbis(newStringStream(d.toIbs())).model(d.name))

proc rxB(cComp = 0.0): ReceiverBehaviour =
  receiverBehaviour(readIbis(newStringStream(linearReceiverIbs(cComp = cComp))).model("lin_rx"))

suite "eye of a simulated channel":
  # 50 ohm into 20 pF: RC = 1 ns. The eye closes as the UI shrinks.
  let t = SiTemplate(name: "rc", driver: drvB(thevenin()), topology: ttPointToPoint,
                     driverPort: TemplatePort(label: "U1.1"), line: idealLine(50.0, 6e-9),
                     receivers: @[rxB(20e-12)], receiverPorts: @[TemplatePort(label: "U2.1")])
  let net = t.build(templateParams(0.02))

  proc eyeAt(ui: float): Eye =
    let sw = sweepNet([SweepCorner(corner: coTyp, net: net)],
                      sweepStimuli(ui, prbsBits = 127))
    check sw.status == ssOk
    check sw.eyes
    for me in sw.measured:
      if me.isEye: return me.eye

  test "height and width shrink with the UI; a fast enough UI closes it":
    let wide = eyeAt(10e-9)
    let mid = eyeAt(3e-9)
    let shut = eyeAt(0.8e-9)
    checkpoint $wide & "\n" & $mid & "\n" & $shut
    check wide.height > 3.2
    check mid.height < wide.height
    check mid.width < wide.width and mid.width > 0
    check shut.width == 0.0
    check shut.margin < 0

  test "the sweep reports the eye; judge applies a minimum":
    let sw = sweepNet([SweepCorner(corner: coTyp, net: net)], sweepStimuli(3e-9, prbsBits = 127))
    check {sfEyeHeight, sfEyeWidth} <= sw.figuresOf(0)
    check "eye height" in renderText(sw)
    var c = defaultCriteria()
    c.ui = 3e-9
    c.eyeBits = 127
    c.minEyeWidth = 2.9e-9
    let p = judge([t], templateParams(0.02), c)
    check p.verdict == vFail
    var named = false
    for f in p.failures:
      if "eye width" in f: named = true
    check named

## `plot`: tick generation, decimation, and that the SVG is well formed and
## carries what a page script reads back (`data-xmap`, `data-name`).

import std/[math, strutils, unittest, xmlparser, xmltree]
import verax/plot

suite "plot ticks":
  test "linear ticks are 1-2-5 steps covering the range":
    check linearTicks(0.0, 10.0) == @[0.0, 2.0, 4.0, 6.0, 8.0, 10.0]
    let t = linearTicks(-0.3, 0.7)
    check t[0] >= -0.3 and t[^1] <= 0.7
    check 0.0 in t    # snapped, never -1e-17

  test "log ticks: decades are majors, multiples minors":
    let (major, minor) = logTicks(10.0, 1e6)
    check major == @[10.0, 100.0, 1e3, 1e4, 1e5, 1e6]
    check 20.0 in minor and 5e5 in minor

  test "under two decades, 2 and 5 become majors":
    let (major, _) = logTicks(10.0, 100.0)
    check 20.0 in major and 50.0 in major

suite "decimate":
  test "short series come back unchanged":
    let (x, y) = decimate(@[1.0, 2.0, 3.0], @[4.0, 5.0, 6.0])
    check x == @[1.0, 2.0, 3.0] and y == @[4.0, 5.0, 6.0]

  test "long series are bounded and keep their extremes":
    var x, y: seq[float]
    for i in 0 ..< 100_000:
      x.add float(i)
      y.add sin(float(i) / 50.0)
    y[54_321] = 9.0      # a one-sample spike must survive
    y[12_345] = -9.0
    let (dx, dy) = decimate(x, y, 1000)
    check dx.len <= 1000
    check 9.0 in dy and -9.0 in dy

suite "svg":
  proc sample(): Plot =
    result = Plot(title: "t", xAxis: axis("time", "s"),
                  yAxis: axis("voltage", "V"))
    result.series.add Series(name: "V(a)", x: @[0.0, 1e-3, 2e-3],
                             y: @[4.998, 5.0, 5.002])
    result.series.add Series(name: "V(b)", x: @[0.0, 1e-3, 2e-3],
                             y: @[4.999, 5.001, NaN], slot: 1)
    result.limits.add Limit(kind: lkMax, value: 5.0015, label: "max")

  test "well-formed, with the read-back attributes":
    let doc = parseXml(plotSvg(sample()))
    check doc.tag == "svg"
    let panels = doc.findAll("g")
    var mapped = 0
    for g in panels:
      if g.attr("class") == "vx-panel":
        inc mapped
        check g.attr("data-xmap").split(',').len == 5
    check mapped == 1
    var names: seq[string]
    for pl in doc.findAll("polyline"):
      if pl.attr("class") == "vx-line": names.add pl.attr("data-name")
    check "V(a)" in names and "V(b)" in names

  test "adjacent y tick labels are distinct on a narrow range":
    let svg = plotSvg(sample())
    var labels: seq[string]
    for t in parseXml(svg).findAll("text"):
      if t.attr("text-anchor") == "end": labels.add t.innerText
    check labels.len >= 3
    for i in 1 ..< labels.len: check labels[i] != labels[i - 1]

  test "a stacked figure draws one legend, x labels only at the bottom":
    var a = sample()
    var b = sample()
    b.title = ""
    let doc = parseXml(stackSvg([a, b]))
    var legendTexts = 0
    for t in doc.findAll("text"):
      if t.innerText == "V(a)" and t.attr("dy") != "4": inc legendTexts
    check legendTexts == 1
    var timeLabels = 0
    for t in doc.findAll("text"):
      if t.innerText == "time": inc timeLabels
    check timeLabels == 1

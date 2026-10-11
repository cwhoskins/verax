## The test report as one self-contained HTML file: inline SVG, inline CSS
## and a small script (crosshair readout on plots, open logs before
## printing). No external resources, so it can be mailed, archived, or
## printed to PDF from any browser (`report/pdf` automates that when a
## headless converter is installed).
##
## Order: cover and summary, contents, structural issues, tests with a
## verdict (failures first), then **everything inconclusive or not run**,
## then the run index. Status is never colour alone: each badge carries an
## icon and a word.

import std/[strutils]
import ../eng
import ../contract/evaluate
import ./content

proc h(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
                 ("\"", "&quot;"))

proc statusWord(s: EvalStatus): string =
  case s
  of esPass: "PASS"
  of esFail: "FAIL"
  of esNotEvaluated: "NOT EVALUATED"
  of esNotEvaluable: "NOT EVALUABLE"

proc badge(s: EvalStatus): string =
  let (cls, icon) = case s
    of esPass: ("pass", "✓")
    of esFail: ("fail", "✗")
    of esNotEvaluated: ("unrun", "–")
    of esNotEvaluable: ("unknown", "?")
  "<span class=\"badge " & cls & "\"><span aria-hidden=\"true\">" & icon &
    "</span> " & statusWord(s) & "</span>"

proc sevWord(s: Severity): string =
  case s
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

proc issueList(issues: seq[Issue]): string =
  if issues.len == 0: return ""
  result = "<ul class=\"issues\">"
  for i in issues:
    result.add "<li><span class=\"sev " & sevWord(i.severity) & "\">" &
      sevWord(i.severity) & "</span> <code>" & h(i.kind) & "</code> " &
      h(i.message) & "</li>"
  result.add "</ul>"

const css = """
:root {
  color-scheme: light;
  --vx-surface: #fcfcfb; --vx-page: #f9f9f7;
  --vx-ink: #0b0b0b; --vx-ink2: #52514e; --vx-muted: #898781;
  --vx-grid: #e1e0d9; --vx-base: #c3c2b7; --vx-border: rgba(11,11,11,0.10);
  --vx-s1: #2a78d6; --vx-s2: #eb6834; --vx-s3: #1baf7a; --vx-s4: #eda100;
  --vx-s5: #e87ba4; --vx-s6: #008300; --vx-s7: #4a3aa7; --vx-s8: #e34948;
  --vx-good: #0ca30c; --vx-good-text: #006300; --vx-warning: #fab219;
  --vx-serious: #ec835a; --vx-critical: #d03b3b;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --vx-surface: #1a1a19; --vx-page: #0d0d0d;
    --vx-ink: #ffffff; --vx-ink2: #c3c2b7; --vx-muted: #898781;
    --vx-grid: #2c2c2a; --vx-base: #383835; --vx-border: rgba(255,255,255,0.10);
    --vx-s1: #3987e5; --vx-s2: #d95926; --vx-s3: #199e70; --vx-s4: #c98500;
    --vx-s5: #d55181; --vx-s6: #008300; --vx-s7: #9085e9; --vx-s8: #e66767;
    --vx-good-text: #0ca30c;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--vx-page); color: var(--vx-ink);
  font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 900px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 26px; margin: 0 0 4px; }
h2 { font-size: 20px; margin: 0 0 4px; }
h3 { font-size: 15px; margin: 20px 0 6px; color: var(--vx-ink2);
  text-transform: uppercase; letter-spacing: .04em; }
section.page, header.page, nav.page { background: var(--vx-surface);
  border: 1px solid var(--vx-border); border-radius: 8px; padding: 20px 24px;
  margin: 0 0 20px; }
.sub { color: var(--vx-ink2); margin: 0 0 12px; }
.circuit { font-weight: 600; }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12.5px; }
pre { background: var(--vx-page); border: 1px solid var(--vx-border);
  border-radius: 6px; padding: 10px; overflow-x: auto; white-space: pre-wrap;
  word-break: break-word; }
table { border-collapse: collapse; width: 100%; margin: 6px 0 10px; }
th, td { text-align: left; vertical-align: top; padding: 5px 8px;
  border-bottom: 1px solid var(--vx-grid); }
th { color: var(--vx-ink2); font-weight: 600; font-size: 12.5px; }
td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
.kv td:first-child { color: var(--vx-ink2); width: 30%; }
.role { font-size: 12px; font-weight: 600; padding: 0 6px; border-radius: 4px;
  border: 1px solid var(--vx-border); white-space: nowrap; }
.role-stimulus, .role-load { color: #3a7bd5; border-color: #3a7bd5; }
.role-probe { color: #c4521f; border-color: #eb6834; }
.badge { display: inline-block; padding: 1px 8px; border-radius: 999px;
  font-size: 12px; font-weight: 700; white-space: nowrap;
  border: 1.5px solid currentColor; }
.badge.pass { color: var(--vx-good-text); }
.badge.fail { color: var(--vx-critical); }
.badge.unrun { color: var(--vx-ink2); }
.badge.unknown { color: var(--vx-ink2); border-style: dashed; }
.sev { font-size: 11px; font-weight: 700; text-transform: uppercase;
  padding: 0 5px; border-radius: 4px; border: 1px solid currentColor; }
.sev.error { color: var(--vx-critical); }
.sev.warning { color: var(--vx-ink2); }
.sev.info { color: var(--vx-muted); }
ul.issues, ul.plain { padding-left: 18px; margin: 4px 0 10px; }
ul.issues li, ul.plain li { margin: 3px 0; }
figure { margin: 10px 0 16px; }
figure .svgbox { position: relative; background: var(--vx-surface); }
figure svg { max-width: 100%; height: auto; display: block; }
figure.schematic .svgbox { background: #ffffff; border: 1px solid var(--vx-border);
  border-radius: 6px; overflow: auto; max-height: 80vh; cursor: zoom-in; }
figure.schematic.zoomed .svgbox { cursor: zoom-out; }
figure.schematic.zoomed svg { max-width: none; }
figcaption { color: var(--vx-ink2); font-size: 12.5px; margin-top: 4px; }
.note { color: var(--vx-ink2); font-style: italic; }
.toc ol { padding-left: 22px; margin: 4px 0; }
.toc li { margin: 3px 0; }
.toc a { color: var(--vx-ink); text-decoration: none; }
.toc a:hover { text-decoration: underline; }
.toc .circ { color: var(--vx-ink2); font-size: 12.5px; }
.stats { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0; }
.stat { border: 1px solid var(--vx-border); border-radius: 8px;
  padding: 8px 14px; min-width: 110px; }
.stat b { display: block; font-size: 22px; }
.stat span { color: var(--vx-ink2); font-size: 12px; }
.run { border-top: 1px solid var(--vx-grid); padding-top: 8px; margin-top: 12px; }
.runmeta { color: var(--vx-ink2); font-size: 12.5px; }
details summary { cursor: pointer; color: var(--vx-ink2); font-size: 12.5px; }
.vx-tip { position: absolute; pointer-events: none; display: none;
  background: var(--vx-surface); color: var(--vx-ink);
  border: 1px solid var(--vx-border); border-radius: 6px; padding: 6px 8px;
  font-size: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.15); white-space: nowrap;
  font-variant-numeric: tabular-nums; z-index: 2; }
.vx-tip i { display: inline-block; width: 10px; height: 2px;
  vertical-align: middle; margin-right: 5px; }
a.back { font-size: 12.5px; }
@page { size: A4; margin: 14mm 12mm; }
@media print {
  :root { color-scheme: light; }
  body { background: #fff; font-size: 11.5px; }
  main { max-width: none; padding: 0; }
  section.page, header.page, nav.page { border: none; padding: 0;
    margin: 0 0 10mm; break-inside: auto; }
  section.test { break-before: page; }
  figure { break-inside: avoid; }
  figure.schematic .svgbox { max-height: none; overflow: visible; }
  figure.schematic.zoomed svg { max-width: 100%; }
  pre { white-space: pre-wrap; font-size: 9.5px; }
  .vx-tip { display: none !important; }
  details.deck { display: none; }
}
"""

const script = """
(function () {
  function eng(v, u) {
    if (!isFinite(v)) return String(v);
    if (v === 0) return '0 ' + u;
    var p = ['f','p','n','µ','m','','k','M','G','T'];
    if (u === 'dB' || u === '°') return v.toPrecision(3) + ' ' + u;
    var e = Math.floor(Math.log10(Math.abs(v)) / 3);
    e = Math.max(-5, Math.min(4, e));
    return (v / Math.pow(10, 3 * e)).toPrecision(3) + ' ' + p[e + 5] + u;
  }
  function inv(m, px) {
    var t = (px - m[0]) / (m[1] - m[0]);
    if (m[4] === 1) {
      var a = Math.log10(m[2]), b = Math.log10(m[3]);
      return Math.pow(10, a + t * (b - a));
    }
    return m[2] + t * (m[3] - m[2]);
  }
  document.querySelectorAll('svg.vx-plot').forEach(function (svg) {
    var box = svg.parentNode;
    var tip = document.createElement('div');
    tip.className = 'vx-tip';
    box.appendChild(tip);
    var NS = 'http://www.w3.org/2000/svg';
    var panels = Array.prototype.map.call(svg.querySelectorAll('g.vx-panel'), function (g) {
      var xm = g.dataset.xmap.split(',').map(Number);
      var ym = g.dataset.ymap.split(',').map(Number);
      var lines = Array.prototype.map.call(g.querySelectorAll('polyline.vx-line'), function (pl) {
        return { name: pl.dataset.name, color: pl.getAttribute('stroke'),
          pts: pl.getAttribute('points').trim().split(/\s+/).map(function (p) {
            return p.split(',').map(Number); }) };
      });
      var cross = document.createElementNS(NS, 'line');
      cross.setAttribute('y1', ym[1]); cross.setAttribute('y2', ym[0]);
      cross.setAttribute('stroke', 'var(--vx-muted,#898781)');
      cross.setAttribute('stroke-width', '1');
      cross.style.display = 'none';
      g.appendChild(cross);
      return { xm: xm, ym: ym, lines: lines, cross: cross,
               xu: g.dataset.xunit, yu: g.dataset.yunit };
    });
    if (!panels.length) return;
    svg.addEventListener('mousemove', function (ev) {
      var pt = svg.createSVGPoint();
      pt.x = ev.clientX; pt.y = ev.clientY;
      var p = pt.matrixTransform(svg.getScreenCTM().inverse());
      var xm = panels[0].xm;
      if (p.x < xm[0] || p.x > xm[1]) { hide(); return; }
      var rows = ['<b>' + eng(inv(xm, p.x), panels[0].xu) + '</b>'];
      panels.forEach(function (pn) {
        pn.cross.setAttribute('x1', p.x); pn.cross.setAttribute('x2', p.x);
        pn.cross.style.display = '';
        var best = {};
        pn.lines.forEach(function (ln) {
          ln.pts.forEach(function (q) {
            var d = Math.abs(q[0] - p.x);
            if (d < 6 && (!best[ln.name] || d < best[ln.name].d))
              best[ln.name] = { d: d, y: q[1], c: ln.color };
          });
        });
        Object.keys(best).forEach(function (n) {
          rows.push('<i style="background:' + best[n].c + '"></i>' + n + ': ' +
                    eng(inv(pn.ym, best[n].y), pn.yu));
        });
      });
      tip.innerHTML = rows.join('<br>');
      tip.style.display = 'block';
      var r = box.getBoundingClientRect();
      var x = ev.clientX - r.left + 14, y = ev.clientY - r.top + 14;
      if (x + tip.offsetWidth > r.width) x = ev.clientX - r.left - tip.offsetWidth - 14;
      tip.style.left = x + 'px'; tip.style.top = y + 'px';
    });
    function hide() {
      tip.style.display = 'none';
      panels.forEach(function (pn) { pn.cross.style.display = 'none'; });
    }
    svg.addEventListener('mouseleave', hide);
  });
  document.querySelectorAll('figure.schematic .svgbox').forEach(function (b) {
    b.title = 'Click to toggle full size';
    b.addEventListener('click', function () {
      b.parentNode.classList.toggle('zoomed');
    });
  });
  window.addEventListener('beforeprint', function () {
    document.querySelectorAll('details.log').forEach(function (d) { d.open = true; });
  });
})();
"""

proc figureHtml(f: Figure, cls = ""): string =
  if f.svg.len == 0 and f.note.len == 0: return ""
  result = "<figure" & (if cls.len > 0: " class=\"" & cls & "\"" else: "") & ">"
  if f.svg.len > 0:
    result.add "<div class=\"svgbox\">" & f.svg & "</div>"
  var cap = h(f.caption)
  if f.note.len > 0:
    cap.add (if cap.len > 0: " " else: "") & "<span class=\"note\">" &
            h(f.note.strip) & "</span>"
  if cap.len > 0: result.add "<figcaption>" & cap & "</figcaption>"
  result.add "</figure>"

proc criteriaTable(claims: seq[ClaimRow]): string =
  result = "<table><thead><tr><th>Claim</th><th>Quantity</th>" &
    "<th>Conditions</th><th>Pass criterion</th><th>Severity</th></tr></thead><tbody>"
  for c in claims:
    var crit = "<code>" & h(c.expect) & "</code>"
    if c.acceptance.len > 0: crit.add "<br><span class=\"sub\">accepts " &
                                      h(c.acceptance) & "</span>"
    if c.rationale.len > 0: crit.add "<br><span class=\"sub\">because " &
                                     h(c.rationale) & "</span>"
    result.add "<tr><td><code>" & h(c.id) & "</code></td><td><code>" &
      h(c.quantity) & "</code>(" & h(c.subjects) & ")</td><td>" &
      h(c.conditions) & "</td><td>" & crit & "</td><td>" &
      sevWord(c.severity) & "</td></tr>"
  result.add "</tbody></table>"

proc resultsTable(claims: seq[ClaimRow]): string =
  result = "<table><thead><tr><th>Claim</th><th>Expected</th>" &
    "<th>Measured</th><th>Margin</th><th>Result</th></tr></thead><tbody>"
  for c in claims:
    var measured = h(c.measured)
    if c.status in {esNotEvaluated, esNotEvaluable} and c.reason.len > 0:
      measured.add "<br><span class=\"sub\">" & h(c.reason) & "</span>"
    result.add "<tr><td><code>" & h(c.id) & "</code></td><td class=\"num\">" &
      h(c.expect) & "</td><td>" & measured & "</td><td>" & h(c.margin) &
      "</td><td>" & badge(c.status) & "</td></tr>"
  result.add "</tbody></table>"

proc runHtml(r: RunInfo): string =
  result = "<div class=\"run\" id=\"run-" & $r.index & "\">"
  result.add "<div class=\"runmeta\">Run " & $r.index & ": <b>" & h(r.label) &
    "</b> &middot; <code>" & h(r.analysis.strip) & "</code>"
  if r.setup.len > 0:
    result.add " &middot; setup <code>" & h(r.setup.join("; ")) & "</code>"
  result.add " &middot; " & $r.ms & " ms"
  if r.ok: result.add " &middot; " & $r.vectors & " vectors &times; " &
                      $r.points & " points"
  else: result.add " &middot; <b>failed</b>"
  result.add "</div>"
  if not r.ok and r.error.len > 0:
    result.add "<pre>" & h(r.error) & "</pre>"
  if r.opValues.len > 0:
    result.add "<table class=\"kv\"><thead><tr><th>Node</th><th>Operating point</th></tr></thead><tbody>"
    for (k, v) in r.opValues:
      result.add "<tr><td>" & h(k) & "</td><td class=\"num\">" & h(v) & "</td></tr>"
    result.add "</tbody></table>"
  result.add figureHtml(r.plot)
  result.add "</div>"

proc diagnosticsHtml(s: TestSection): string =
  var body = ""
  if s.issues.len > 0:
    body.add "<p><b>Issues reported by the analysis</b></p>" & issueList(s.issues)
  if s.assumptions.len > 0:
    body.add "<p><b>Values nobody stated</b> (assumed by the simulation)</p><ul class=\"plain\">"
    for a in s.assumptions: body.add "<li>" & h(a) & "</li>"
    body.add "</ul>"
  if s.reusedOp:
    body.add "<p class=\"note\">This test ran no simulation of its own: it " &
      "reused an operating point another test already solved.</p>"
  for r in s.runs:
    if r.logNotes.len > 0:
      body.add "<p><b>ngspice, run " & $r.index & "</b></p><pre>" &
        h(r.logNotes.join("\n")) & "</pre>"
    if r.log.len > 0:
      body.add "<details class=\"log\"><summary>Full ngspice log, run " &
        $r.index & "</summary><pre>" & h(r.log) & "</pre></details>"
    if r.deck.len > 0:
      body.add "<details class=\"deck\"><summary>Deck that ran, run " &
        $r.index & "</summary><pre>" & h(r.deck) & "</pre></details>"
  if body.len == 0: body = "<p class=\"note\">Nothing reported.</p>"
  "<h3>Warnings, errors and log</h3>" & body

proc benchHtml(b: BenchView): string =
  ## The test bench: scope, what drove and read the circuit, what closed
  ## the cut, and which parts are drawn for their simulation models.
  if b.strategy.len == 0 and b.rows.len == 0 and b.folded.len == 0: return ""
  result = "<h3>Test bench</h3>"
  if b.strategy.len > 0:
    result.add "<p>Scope <code>" & h(b.strategy) & "</code>" &
      (if b.strategyDoc.len > 0: ": " & h(b.strategyDoc) else: "") & ".</p>"
  if b.rows.len > 0:
    result.add "<table><thead><tr><th>Role</th><th>Element</th><th>Nets</th>" &
      "<th>What it does</th></tr></thead><tbody>"
    for r in b.rows:
      result.add "<tr><td><span class=\"role role-" & h(r.role) & "\">" &
        h(r.role) & "</span></td><td><code>" & h(r.designator) &
        "</code></td><td><code>" & h(r.nets) & "</code></td><td>" & h(r.text) &
        "</td></tr>"
    result.add "</tbody></table>"
  if b.detached.len > 0:
    result.add "<p>Removed so the stimulus could take their place: <code>" &
      h(b.detached.join(", ")) & "</code>.</p>"
  if b.dropped.len > 0:
    result.add "<p>Cut away by the scope (not simulated): <code>" &
      h(b.dropped.join(", ")) & "</code>.</p>"
  if b.folded.len > 0:
    result.add "<details><summary>Drawn as the design part, simulated as " &
      $b.folded.len & " model(s)</summary><ul>"
    for f in b.folded: result.add "<li><code>" & h(f) & "</code></li>"
    result.add "</ul></details>"

proc sectionHtml(s: TestSection, uncheckedLinks: seq[(string, string)]): string =
  result = "<section class=\"page test\" id=\"" & s.anchor & "\">"
  result.add "<h2>Test " & $s.number & " &mdash; " & h(s.title) & " " &
    badge(s.status) & "</h2>"
  result.add "<p class=\"sub\">Circuit under test: <span class=\"circuit\">" &
    h(s.circuit) & "</span></p>"

  result.add "<h3>Description</h3>"
  result.add "<p>" & (if s.setup.len > 0: h(s.setup) else:
    "<span class=\"note\">The evaluator gives no description of its setup.</span>") &
    "</p>"
  if s.nets.len > 0:
    var ns: seq[string]
    for n in s.nets: ns.add "<code>" & h(n) & "</code>"
    result.add "<p>Nets the test injects at or reads: " &
      ns.join(", ") & ".</p>"
  result.add "<p class=\"runmeta\">Evaluator <code>" & h(s.evaluator) & "</code>.</p>"

  result.add "<h3>Pass criteria</h3>" & criteriaTable(s.claims)
  result.add "<h3>Circuit</h3>" & figureHtml(s.schematic, "schematic")
  result.add benchHtml(s.bench)
  result.add "<h3>Results</h3>" & resultsTable(s.claims)
  for (anchor, id) in uncheckedLinks:
    result.add "<p class=\"note\">Claim <code>" & h(id) &
      "</code> was not evaluated; see <a href=\"#" & anchor &
      "\">inconclusive / not run</a>.</p>"
  if s.runs.len == 0:
    result.add "<p class=\"note\">No simulator run is attributed to this test.</p>"
  for r in s.runs: result.add runHtml(r)
  result.add diagnosticsHtml(s)
  result.add "</section>"

proc uncheckedHtml(e: UncheckedEntry): string =
  let c = e.claim
  result = "<div class=\"run\" id=\"" & e.anchor & "\">"
  result.add "<p><code>" & h(c.id) & "</code> " & badge(c.status) & "<br>"
  result.add "<span class=\"sub\">Circuit under test: <span class=\"circuit\">" &
    h(e.circuit) & "</span></span></p>"
  result.add "<table class=\"kv\"><tbody>"
  result.add "<tr><td>Quantity</td><td><code>" & h(c.quantity) & "</code>(" &
    h(c.subjects) & ")</td></tr>"
  if c.conditions.len > 0:
    result.add "<tr><td>Conditions</td><td>" & h(c.conditions) & "</td></tr>"
  result.add "<tr><td>Pass criterion</td><td><code>" & h(c.expect) & "</code>" &
    (if c.acceptance.len > 0: " (accepts " & h(c.acceptance) & ")" else: "") &
    "</td></tr>"
  result.add "<tr><td>Why it was not checked</td><td>" &
    h(if c.reason.len > 0: c.reason else: "no reason given") & "</td></tr>"
  if c.evaluator.len > 0:
    result.add "<tr><td>Evaluator</td><td><code>" & h(c.evaluator) & "</code></td></tr>"
  if e.hints.len > 0:
    result.add "<tr><td>Did you mean</td><td>" & h(e.hints.join(", ")) & "</td></tr>"
  if c.rationale.len > 0:
    result.add "<tr><td>Rationale</td><td>" & h(c.rationale) & "</td></tr>"
  result.add "</tbody></table>"
  result.add issueList(c.issues)
  if e.section.len > 0:
    result.add "<a class=\"back\" href=\"#" & e.section &
      "\">&larr; the test this claim belongs to</a>"
  result.add "</div>"

proc renderHtml*(m: ReportModel): string =
  var o = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" &
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" &
    "<title>" & h(m.design) & " test report</title><style>" & css &
    "</style></head><body><main>\n"

  # cover
  o.add "<header class=\"page\" id=\"summary\"><h1>" & h(m.design) &
    " &mdash; simulation test report</h1>"
  o.add "<p class=\"sub\">Generated " & h(m.generated) & " by verax</p>"
  o.add "<div class=\"stats\">"
  for (n, w) in [(m.total, "claims"), (m.passed, "passed"), (m.failed, "failed"),
                 (m.notEvaluated + m.notEvaluable, "not checked")]:
    o.add "<div class=\"stat\"><b>" & $n & "</b><span>" & w & "</span></div>"
  o.add "</div><table class=\"kv\"><tbody>"
  o.add "<tr><td>Outcome</td><td>exit " & $m.exitCode & " (" & h(m.exitLabel) &
    ")</td></tr>"
  o.add "<tr><td>Simulator</td><td>" & h(m.simulator) & "</td></tr>"
  o.add "<tr><td>Capabilities used</td><td>" & h(m.capabilities) & "</td></tr>"
  if m.missing.len > 0:
    o.add "<tr><td>Requested but unavailable</td><td>" & h(m.missing) & "</td></tr>"
  if m.environment.len > 0:
    o.add "<tr><td>Environment</td><td>" & h(m.environment) & "</td></tr>"
  o.add "<tr><td>Tests</td><td>" & $m.tests.len & " with a verdict, " &
    $m.inconclusive.len & " inconclusive, " & $m.runs.len &
    " simulator run(s)</td></tr>"
  o.add "</tbody></table></header>\n"

  # contents
  o.add "<nav class=\"page toc\"><h2>Contents</h2><ol>"
  o.add "<li><a href=\"#summary\">Summary</a></li>"
  if m.structural.len > 0:
    o.add "<li><a href=\"#structure\">Structural issues (" &
      $m.structural.len & ")</a></li>"
  o.add "<li><a href=\"#tests\">Tests</a><ol>"
  for s in m.tests:
    o.add "<li><a href=\"#" & s.anchor & "\">Test " & $s.number & " &mdash; " &
      h(s.title) & "</a> " & badge(s.status) & "<br><span class=\"circ\">" &
      h(s.circuit) & "</span></li>"
  o.add "</ol></li>"
  if m.inconclusive.len + m.unchecked.len > 0:
    o.add "<li><a href=\"#inconclusive\">Inconclusive / not run</a><ol>"
    for s in m.inconclusive:
      o.add "<li><a href=\"#" & s.anchor & "\">Test " & $s.number &
        " &mdash; " & h(s.title) & "</a> " & badge(s.status) & "</li>"
    for e in m.unchecked:
      o.add "<li><a href=\"#" & e.anchor & "\"><code>" & h(e.claim.id) &
        "</code></a> " & badge(e.claim.status) & "</li>"
    o.add "</ol></li>"
  if m.runs.len > 0:
    o.add "<li><a href=\"#runs\">Appendix: simulator runs</a></li>"
  o.add "</ol></nav>\n"

  if m.structural.len > 0:
    o.add "<section class=\"page\" id=\"structure\"><h2>Structural issues</h2>" &
      "<p class=\"sub\">Found before any simulation; an error here can make " &
      "every number below untrustworthy.</p>" & issueList(m.structural) &
      "</section>\n"

  o.add "<div id=\"tests\"></div>"
  if m.tests.len == 0:
    o.add "<section class=\"page\"><p class=\"note\">No test produced a " &
      "verdict.</p></section>"
  for s in m.tests:
    var links: seq[(string, string)]
    for e in m.unchecked:
      if e.section == s.anchor: links.add (e.anchor, e.claim.id)
    o.add sectionHtml(s, links) & "\n"

  if m.inconclusive.len + m.unchecked.len > 0:
    o.add "<section class=\"page test\" id=\"inconclusive\"><h2>Inconclusive / " &
      "not run</h2><p class=\"sub\">Nothing verified these claims. They are " &
      "not passes.</p>"
    if m.unchecked.len > 0:
      o.add "<h3>Claims with no verdict</h3>"
      for e in m.unchecked: o.add uncheckedHtml(e)
    o.add "</section>\n"
    for s in m.inconclusive:
      o.add sectionHtml(s, @[]) & "\n"

  if m.runs.len > 0:
    o.add "<section class=\"page test\" id=\"runs\"><h2>Appendix: simulator " &
      "runs</h2><table><thead><tr><th>#</th><th>Label</th><th>Analysis</th>" &
      "<th>Status</th><th>Points</th><th>Time</th></tr></thead><tbody>"
    for r in m.runs:
      o.add "<tr><td class=\"num\"><a href=\"#run-" & $r.index & "\">" &
        $r.index & "</a></td><td>" & h(r.label) & "</td><td><code>" &
        h(r.analysis.strip) & "</code></td><td>" &
        (if r.ok: "ok" else: "<b>failed</b>") & "</td><td class=\"num\">" &
        $r.points & "</td><td class=\"num\">" & eng(float(r.ms) / 1000, "s") &
        "</td></tr>"
    o.add "</tbody></table></section>\n"

  o.add "</main><script>" & script & "</script></body></html>\n"
  o

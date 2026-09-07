## Run-archive schematic output: the SVG/JSON pair writer, and the interactive
## `runFULL.html` hierarchy browser.
##
## `svg.nim` and `json.nim` each render one scene one way. This module is the
## composition layer above them: it drives `layout` over a whole design and its
## sub-circuits, writes the archive files, and assembles the self-contained
## HTML explorer. It is what `verify` calls when `$NIMCIR_KEEP_RUNS` is set and
## what `spice/ngspice` uses to drop a `runNNN` scene beside its deck -- both
## sit above `schematic` on the dependency spine, so this stays a leaf on
## `netlist` like the rest of the submodule.

import std/[json, os, strutils, tables]

import ../netlist/types
import ./scene
import ./pipeline
import ./layout
import ./svg
import ./json

proc safeSheetName*(s: string): string =
  ## A subcircuit name reduced to a filename fragment: anything outside
  ## `[A-Za-z0-9._-]` becomes `_`, so `runFULL.<name>.svg` is always a legal
  ## path regardless of what the `.SUBCKT` was called.
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}: result.add ch
    else: result.add '_'

proc writeScenePair*(s: Schematic, base: string) =
  ## Writes one routed scene to the archive as both SVG and JSON, sharing the
  ## single layout so the two files can never disagree about geometry.
  writeSvgFile(s, base & ".svg")
  writeSceneJsonFile(s, base & ".json")

# --- the runFULL.html hierarchy browser -----------------------------------

type
  ExplorerSheet* = object
    ## One sheet of the interactive `runFULL.html` browser: the sheet id used
    ## in the hierarchy links, its display title, the inline SVG, and the
    ## clickable part list (each part carrying the child-sheet id it opens, or
    ## `null`). Built from the same routed scene the SVG/JSON pair is written
    ## from -- never a second layout.
    id*, title*, svg*: string
    parts*: JsonNode

proc explorerSheet*(n: Netlist, s: Schematic, id: string,
                    childOf: OrderedTable[string, string]): ExplorerSheet =
  ## Fold one netlist level and its routed scene into an `ExplorerSheet`.
  ## `childOf` contains the archive IDs resolved for this occurrence, rather
  ## than deriving an ID from a child name: same-named, non-equivalent blocks
  ## need separate sheets.

  var parts = newJArray()
  for p in s.parts:
    var pins = newJArray()
    for pin in p.pins:
      var members = newJArray()
      for m in pin.members: members.add %*{"name": m.name, "net": m.net}
      pins.add %*{"name": pin.name, "net": pin.net, "x": pin.x, "y": pin.y,
                  "members": members}
    parts.add %*{
      "designator": p.designator, "label": p.label, "kind": p.kind, "name": p.name,
      "value": p.value, "x": p.x, "y": p.y,
      "bodyW": p.bodyW, "bodyH": p.bodyH, "pins": pins,
      "child": (if p.designator in childOf: %childOf[p.designator]
                else: newJNull())}
  var svg = renderSvg(s)
  let close = svg.find("?>")
  if svg.startsWith("<?xml") and close >= 0:
    svg = svg[close + 2 .. ^1].strip(leading = true, trailing = false)
  ExplorerSheet(id: id, title: (if n.name.len > 0: n.name else: id),
                svg: svg, parts: parts)

proc explorerSheet*(n: Netlist, s: Schematic, id: string): ExplorerSheet =
  ## Compatibility helper for a caller that has no resolved archive map.
  var childOf = initOrderedTable[string, string]()
  for desig, child in n.children:
    if child.name.len > 0:
      childOf[desig] = safeSheetName(child.name)
  explorerSheet(n, s, id, childOf)

const explorerTemplate = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Schematic &mdash; $TITLE$</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.4 ui-sans-serif, system-ui, sans-serif;
         background: #f4f5f7; color: #1a1a1a; }
  header { display: flex; align-items: center; gap: 12px; padding: 8px 12px;
           background: #fff; border-bottom: 1px solid #d8dbe0; position: sticky;
           top: 0; z-index: 5; }
  button { font: inherit; padding: 4px 10px; border: 1px solid #c3c7cf;
           border-radius: 6px; background: #fff; cursor: pointer; }
  button:disabled { opacity: .4; cursor: default; }
  #crumbs { display: flex; gap: 6px; flex-wrap: wrap; color: #555; }
  #crumbs span { cursor: pointer; }
  #crumbs span:last-child { color: #1a1a1a; font-weight: 600; cursor: default; }
  #zoom { margin-left: auto; display: flex; gap: 4px; }
  main { position: relative; overflow: auto; height: calc(100vh - 84px); }
  #sheet { display: inline-block; padding: 20px; }
  #sheet svg { background: #fff; border: 1px solid #d8dbe0; }
  rect.hit { fill: transparent; }
  rect.hit:hover { fill: rgba(52,132,220,.14); }
  rect.nav { cursor: pointer; }
  rect.nav:hover { fill: rgba(46,180,110,.18); stroke: #2eb46e;
                   stroke-width: 1.5; stroke-dasharray: 5 3; }
  rect.bundle { cursor: pointer; }
  rect.bundle:hover { fill: rgba(130,80,223,.18); stroke: #8250df;
                      stroke-width: 1.5; }
  aside { position: fixed; top: 45px; right: 0; width: 300px;
          height: calc(100vh - 45px); background: #fff;
          border-left: 1px solid #d8dbe0; transform: translateX(100%);
          transition: transform .15s ease; overflow: auto; padding: 16px; }
  aside.open { transform: none; }
  aside h2 { margin: 0 0 2px; font-size: 15px; }
  aside .kind { color: #777; margin-bottom: 12px; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 4px 10px; margin: 0; }
  dt { color: #777; }
  dd { margin: 0; word-break: break-word; }
  table { width: 100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align: left; padding: 3px 4px; border-bottom: 1px solid #eee;
           font-size: 13px; }
  .close { position: absolute; top: 10px; right: 12px; border: none;
           background: none; font-size: 18px; }
  .hint { margin: 0; color: #888; font-size: 12px; padding: 6px 12px;
          background: #fff; border-bottom: 1px solid #d8dbe0; }
</style>
</head>
<body>
<header>
  <button id="up">&#9650; Up</button>
  <nav id="crumbs"></nav>
  <span id="zoom">
    <button data-z="-1">&minus;</button><button data-z="0">Fit</button><button data-z="1">+</button>
  </span>
</header>
<p class="hint">Single-click a component for its properties. Double-click a block outlined in green to open its sheet.</p>
<main><div id="sheet"></div></main>
<aside id="props">
  <button class="close" id="pclose">&times;</button>
  <h2 id="pname"></h2>
  <div class="kind" id="pkind"></div>
  <div id="pbody"></div>
</aside>
<script>
const MODEL = $MODEL$;
const SVGNS = "http://www.w3.org/2000/svg";
let stack = [MODEL.root];
let scale = 1;

const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function current() { return MODEL.sheets[stack[stack.length - 1]]; }

function render() {
  const sheet = current();
  document.getElementById("up").disabled = stack.length <= 1;
  document.getElementById("crumbs").innerHTML = stack.map((id, i) =>
    `<span data-i="${i}">${esc(MODEL.sheets[id].title)}</span>`).join(" &#9656; ");
  const host = document.getElementById("sheet");
  host.innerHTML = sheet.svg;
  const svg = host.querySelector("svg");
  if (!svg) return;
  const vb = svg.getAttribute("viewBox").trim().split(/\s+/).map(Number);
  svg.setAttribute("width", vb[2] * scale);
  svg.setAttribute("height", vb[3] * scale);
  for (const p of sheet.parts) {
    const r = document.createElementNS(SVGNS, "rect");
    r.setAttribute("x", p.x - p.bodyW / 2);
    r.setAttribute("y", p.y - p.bodyH / 2);
    r.setAttribute("width", p.bodyW);
    r.setAttribute("height", p.bodyH);
    r.setAttribute("class", p.child ? "hit nav" : "hit");
    const tip = document.createElementNS(SVGNS, "title");
    tip.textContent = p.child
      ? `${p.label || p.designator || p.kind} — double-click to open ${p.child}`
      : (p.label || p.designator || p.kind || "");
    r.appendChild(tip);
    let timer = null;
    r.addEventListener("click", () => {
      if (timer) return;
      timer = setTimeout(() => { timer = null; showProps(p); }, 220);
    });
    r.addEventListener("dblclick", () => {
      clearTimeout(timer); timer = null;
      if (p.child && MODEL.sheets[p.child]) { stack.push(p.child); render(); }
    });
    svg.appendChild(r);
  }
  // A merged bus/interface pin is click-to-expand. Appended after every part
  // rect so a pin wins the hit test (SVG hit-tests topmost-first).
  for (const p of sheet.parts) {
    for (const pin of (p.pins || [])) {
      if (!pin.members || !pin.members.length) continue;
      const b = document.createElementNS(SVGNS, "rect");
      const g = 40;
      b.setAttribute("x", pin.x - g / 2);
      b.setAttribute("y", pin.y - g / 2);
      b.setAttribute("width", g);
      b.setAttribute("height", g);
      b.setAttribute("class", "hit bundle");
      const tip = document.createElementNS(SVGNS, "title");
      tip.textContent = `${pin.name} — ${pin.members.length} nets, click to expand`;
      b.appendChild(tip);
      b.addEventListener("click", () => showPinProps(pin));
      svg.appendChild(b);
    }
  }
}

function showPinProps(pin) {
  document.getElementById("pname").textContent = pin.name;
  document.getElementById("pkind").textContent = `${pin.members.length} nets`;
  document.getElementById("pbody").innerHTML =
    "<table><thead><tr><th>Pin</th><th>Net</th></tr></thead><tbody>" +
    pin.members.map(m =>
      `<tr><td>${esc(m.name)}</td><td>${esc(m.net)}</td></tr>`).join("") +
    "</tbody></table>";
  document.getElementById("props").classList.add("open");
}

function showProps(p) {
  document.getElementById("pname").textContent = p.label || p.designator || "(no designator)";
  document.getElementById("pkind").textContent = p.kind || "";
  const rows = [
    ["Name", p.name], ["Value", p.value], ["Kind", p.kind],
    ["Child sheet", p.child]
  ].filter(row => row[1]);
  let html = "<dl>" + rows.map(row =>
    `<dt>${esc(row[0])}</dt><dd>${esc(row[1])}</dd>`).join("") + "</dl>";
  if (p.pins && p.pins.length) {
    html += "<table><thead><tr><th>Pin</th><th>Net</th></tr></thead><tbody>" +
      p.pins.map(pin =>
        `<tr><td>${esc(pin.name)}</td><td>${esc(pin.net)}</td></tr>`).join("") +
      "</tbody></table>";
  }
  document.getElementById("pbody").innerHTML = html;
  document.getElementById("props").classList.add("open");
}

document.getElementById("up").onclick = () => {
  if (stack.length > 1) { stack.pop(); render(); }
};
document.getElementById("pclose").onclick = () =>
  document.getElementById("props").classList.remove("open");
document.getElementById("crumbs").onclick = e => {
  const i = e.target.dataset.i;
  if (i !== undefined) { stack = stack.slice(0, +i + 1); render(); }
};
document.getElementById("zoom").onclick = e => {
  const z = e.target.dataset.z;
  if (z === undefined) return;
  scale = z === "0" ? 1
        : Math.max(.2, Math.min(4, scale * (z === "1" ? 1.25 : .8)));
  render();
};

render();
</script>
</body>
</html>
"""

proc renderExplorerHtml*(sheets: seq[ExplorerSheet]): string =
  ## The self-contained hierarchy browser: every sheet's SVG and part list
  ## inlined into one HTML file, no external resources.
  var sheetObj = newJObject()
  for sh in sheets:
    sheetObj[sh.id] = %*{"title": sh.title, "svg": sh.svg, "parts": sh.parts}
  let model = %*{"root": (if sheets.len > 0: sheets[0].id else: ""),
                 "sheets": sheetObj}
  let title = if sheets.len > 0: sheets[0].title else: "design"
  explorerTemplate
    .replace("$TITLE$", title.multiReplace(("&", "&amp;"), ("<", "&lt;"),
                                           (">", "&gt;")))
    .replace("$MODEL$", ($model).replace("</", "<\\/"))

proc keepFullSchematic*(nl: Netlist) =
  ## Renders the authored design as `runFULL.svg`/`runFULL.json` in a run
  ## archive, plus one `runFULL.<sheet-id>.svg`/`.json` per distinct rendered
  ## child-sheet variant, and one `runFULL.html` that browses the hierarchy
  ## interactively -- when an archive is being kept and before any derived
  ## fragment is simulated.
  ##
  ## The per-run `runNNN.svg`/`runNNN.json` files are the *derived* fragments
  ## -- isolated, flattened, model-substituted -- so none of them is the
  ## circuit the author wrote. These are: the full `Design.netlist` and each
  ## block it builds on, drawn with interface ports, once and overwritten
  ## every run, so the archive carries both the design as stated and the
  ## fragments as simulated. Each SVG and its JSON come from the same routed
  ## scene. They are deliberately **not** index rows: the index names one
  ## analysis run per row, and none of these pictures is a run.
  ##
  ## `runFULL.html` inlines those same routed scenes as SVG and adds a
  ## navigation layer: single-click a component for a properties panel,
  ## double-click a hierarchical block to descend to its sheet, and an *Up*
  ## button (a breadcrumb history) to come back out. It is self-contained --
  ## no external file, so it opens straight from disk.
  ##
  ## Equivalent deep clones of a subcircuit (two channels of a stereo stage,
  ## say) are drawn once.  A shared `Netlist.name` alone is not enough: both
  ## the rendered scene and the resolved sheets its instances lead to must
  ## agree.  Non-equivalent occurrences get deterministic, globally unique
  ## IDs (`name`, then `name.2`, `name.3`).
  ##
  ## Best effort, and off unless `$NIMCIR_KEEP_RUNS` is set, on the same
  ## reasoning as the archive itself: drawing a picture must never be able to
  ## change what is checked, or fail it.
  let dir = getEnv("NIMCIR_KEEP_RUNS")
  if dir.len == 0: return
  try:
    createDir(dir)
    let options = archiveLayoutOptions()
    type ArchiveSheet = object
      id, name, sceneJson: string
      netlist: Netlist
      scene: Schematic
      childOf: OrderedTable[string, string]

    var sheets: seq[ArchiveSheet]
    var usedIds = initTable[string, bool]()

    proc sameTargets(a, b: OrderedTable[string, string]): bool =
      if a.len != b.len: return false
      for designator, target in a:
        if not b.hasKey(designator) or b[designator] != target: return false
      true

    proc allocateId(name: string): string =
      let base = safeSheetName(name)
      var n = 1
      while true:
        result = if n == 1: base else: base & "." & $n
        if not usedIds.hasKey(result):
          usedIds[result] = true
          return
        inc n

    proc walk(n: Netlist): string
    proc walkUnnamed(n: Netlist) =
      ## Preserve the old treatment of an unnamed intermediate child: it has
      ## no sheet of its own, but its named descendants are still archived.
      for _, child in n.children:
        if child.name.len > 0: discard walk(child)
        else: walkUnnamed(child)

    proc walk(n: Netlist): string =
      var childOf = initOrderedTable[string, string]()
      for designator, child in n.children:
        if child.name.len > 0:
          childOf[designator] = walk(child)
        else:
          walkUnnamed(child)

      let scene = layout(n, options)
      let sceneJson = sceneToJsonString(scene)
      for sheet in sheets:
        if sheet.name == n.name and sheet.sceneJson == sceneJson and
           sameTargets(sheet.childOf, childOf):
          return sheet.id

      result = allocateId(n.name)
      sheets.add ArchiveSheet(id: result, name: n.name, netlist: n,
                              scene: scene, sceneJson: sceneJson,
                              childOf: childOf)

    let rootScene = layout(nl, options)
    var rootChildren = initOrderedTable[string, string]()
    for designator, child in nl.children:
      if child.name.len > 0:
        rootChildren[designator] = walk(child)
      else:
        walkUnnamed(child)
    writeScenePair(rootScene, dir / "runFULL")

    var explorerSheets: seq[ExplorerSheet]
    explorerSheets.add explorerSheet(nl, rootScene, "@root", rootChildren)
    for sheet in sheets:
      writeScenePair(sheet.scene, dir / ("runFULL." & sheet.id))
      explorerSheets.add explorerSheet(sheet.netlist, sheet.scene, sheet.id,
                                       sheet.childOf)
    writeFile(dir / "runFULL.html", renderExplorerHtml(explorerSheets))
  except CatchableError:
    discard

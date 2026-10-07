## Run-archive schematic output: SVG/JSON pairs and the interactive
## `runFULL.html` hierarchy browser. Drives `layout` over a design and its
## sub-circuits; used by `verify` (`$VERAX_KEEP_RUNS`) and `spice/ngspice`.
## Depends only on `netlist`, like the rest of the submodule.

import std/[json, os, strutils, tables]

import ../netlist/types
import ./scene
import ./pipeline
import ./layout
import ./svg
import ./json

proc safeSheetName*(s: string): string =
  ## A subcircuit name as a filename fragment (anything outside
  ## `[A-Za-z0-9._-]` becomes `_`).
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}: result.add ch
    else: result.add '_'

proc writeScenePair*(s: Schematic, base: string) =
  ## Writes one routed scene as SVG and JSON from the same layout.
  writeSvgFile(s, base & ".svg")
  writeSceneJsonFile(s, base & ".json")

# --- the runFULL.html hierarchy browser -----------------------------------

type
  ExplorerSheet* = object
    ## One browser sheet: its id, title, inline SVG, and clickable part list
    ## (each with the child-sheet id it opens, or `null`). From the same
    ## routed scene as the SVG/JSON.
    id*, title*, svg*: string
    parts*: JsonNode

proc explorerSheet*(n: Netlist, s: Schematic, id: string,
                    childOf: OrderedTable[string, string]): ExplorerSheet =
  ## Fold one netlist level and its scene into an `ExplorerSheet`. `childOf`
  ## holds resolved archive IDs, since same-named non-equivalent blocks need
  ## separate sheets.

  var parts = newJArray()
  for p in s.parts:
    var pins = newJArray()
    for pin in p.pins:
      var members = newJArray()
      for m in pin.members: members.add %*{"name": m.name, "net": m.net}
      pins.add %*{"name": pin.name, "net": pin.net, "x": pin.x, "y": pin.y,
                  "members": members, "tag": pin.tag}
    # An array representative carries `members` and `count`; each links to
    # its own child sheet.
    var arrMembers = newJArray()
    for d in p.members:
      arrMembers.add %*{"designator": d,
        "child": (if d in childOf: %childOf[d] else: newJNull())}
    parts.add %*{
      "designator": p.designator, "label": p.label, "kind": p.kind, "name": p.name,
      "value": p.value, "x": p.x, "y": p.y, "count": p.count,
      "arrayMembers": arrMembers,
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
    tip.textContent = p.count >= 2
      ? `${p.label} — ${p.count} instances, double-click to open ${p.child || "the sheet"}`
      : p.child
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
  document.getElementById("pname").textContent = pin.tag || pin.name;
  document.getElementById("pkind").textContent = `${pin.members.length} members`;
  document.getElementById("pbody").innerHTML =
    "<table><thead><tr><th>Member</th><th>Net</th></tr></thead><tbody>" +
    pin.members.map(m =>
      `<tr><td>${esc(m.name)}</td><td>${esc(m.net) || "(open)"}</td></tr>`).join("") +
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
  if (p.arrayMembers && p.arrayMembers.length) {
    html += "<table class=\"members\"><thead><tr><th>Instance</th><th>Sheet</th>" +
      "</tr></thead><tbody>" + p.arrayMembers.map(m =>
        `<tr data-sheet="${esc(m.child || "")}"><td>${esc(m.designator)}</td>` +
        `<td>${esc(m.child || "—")}</td></tr>`).join("") + "</tbody></table>";
  }
  document.getElementById("pbody").innerHTML = html;
  const mt = document.querySelector("#pbody table.members");
  if (mt) mt.addEventListener("click", e => {
    const row = e.target.closest("tr[data-sheet]");
    if (row && row.dataset.sheet && MODEL.sheets[row.dataset.sheet]) {
      stack.push(row.dataset.sheet); render();
    }
  });
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
  ## The self-contained browser: every sheet's SVG and parts inlined.
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
  ## Renders the authored design as `runFULL.svg`/`.json`, one
  ## `runFULL.<sheet-id>.svg`/`.json` per distinct child sheet, and
  ## `runFULL.html` -- before any fragment is simulated. The `runNNN` files
  ## are derived fragments; these are the circuit as written. Not index rows
  ## (they aren't runs).
  ##
  ## `runFULL.html` adds navigation: click for properties, double-click a
  ## block to descend, *Up* to return. Self-contained.
  ##
  ## Equivalent clones (same name, scene and resolved sheets) are drawn once;
  ## others get unique IDs (`name`, `name.2`, ...).
  ##
  ## Best effort, only with `$VERAX_KEEP_RUNS`; never affects checking.
  let dir = getEnv("VERAX_KEEP_RUNS")
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
      ## An unnamed intermediate child has no sheet, but its named
      ## descendants are archived.
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

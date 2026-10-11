## The simulation test report: `collectReport` runs a design's checks and
## keeps every simulator run; `buildModel` turns that into test sections;
## `renderHtml` writes one self-contained HTML file; `htmlToPdf` converts it
## when a converter is installed. Sits above `readiness`, `spice`,
## `schematic` and `plot`. See `report/CLAUDE.md`.

import std/[os, strutils]
import ./contract/design
import ./contract/evaluate
import ./pcb/types as pcbtypes
import ./report/collect
import ./report/content
import ./report/html
import ./report/pdf

export collect, content, html, pdf

proc writeReportFile*(r: SimReport, path: string): string =
  ## Writes an already-collected report to `path` and says what it did.
  ## `.pdf` writes the HTML beside it and converts it, keeping the HTML
  ## when conversion is impossible; anything else is written as HTML.
  ## Raises only if a file cannot be written.
  let page = renderHtml(buildModel(r))
  if path.toLowerAscii.endsWith(".pdf"):
    let htmlPath = path.changeFileExt("html")
    writeFile(htmlPath, page)
    let (ok, msg) = htmlToPdf(htmlPath, path)
    if ok: msg & " (HTML kept at " & htmlPath & ")"
    else: "wrote " & htmlPath & "; no PDF: " & msg
  else:
    writeFile(path, page)
    "wrote " & path

proc writeReport*(d: Design, path: string, allowed = allCapabilities,
                  board: Pcb = nil): tuple[report: SimReport, message: string] =
  ## Runs the checks and writes the report (see `writeReportFile`).
  let r = collectReport(d, allowed, board)
  (r, writeReportFile(r, path))

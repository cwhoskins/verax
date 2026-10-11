## Optional HTML -> PDF through whatever headless converter is installed.
## verax ships none and never requires one: without a converter the HTML
## stays the deliverable (print it to PDF from a browser).

import std/[os, osproc, streams, strutils]

const converters = ["chromium", "chromium-browser", "google-chrome",
                    "google-chrome-stable", "weasyprint", "wkhtmltopdf"]

proc findPdfConverter*(): string =
  ## The first converter on `PATH`, or "".
  for c in converters:
    if findExe(c).len > 0: return c
  ""

proc htmlToPdf*(htmlPath, pdfPath: string): tuple[ok: bool, message: string] =
  ## Converts an HTML file already on disk. Never raises: a missing or
  ## failing converter is reported in `message`.
  let tool = findPdfConverter()
  if tool.len == 0:
    return (false, "no HTML-to-PDF converter found on PATH (tried " &
      converters.join(", ") & "); open the HTML in a browser and print it " &
      "to PDF")
  let exe = findExe(tool)
  var args: seq[string]
  if tool.startsWith("chrom") or tool.startsWith("google-chrome"):
    args = @["--headless", "--disable-gpu", "--no-pdf-header-footer",
             "--print-to-pdf=" & absolutePath(pdfPath),
             "file://" & absolutePath(htmlPath)]
  elif tool == "weasyprint":
    args = @[htmlPath, pdfPath]
  else:
    args = @["--enable-local-file-access", "--print-media-type", htmlPath, pdfPath]
  try:
    let p = startProcess(exe, args = args, options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code == 0 and fileExists(pdfPath):
      (true, "wrote " & pdfPath & " with " & tool)
    else:
      (false, tool & " failed (exit " & $code & "): " & output.strip)
  except OSError as e:
    (false, tool & " could not be run: " & e.msg)

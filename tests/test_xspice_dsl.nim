import std/[os, osproc, strutils, tempfiles, unittest]

## Exercises the `codeModel` macro *through its interface-only expansion*
## (`-d:xspiceGenIfs`), which emits no FFI and so needs no ngspice headers.
## That makes these runnable anywhere, unlike `test_xspice_build.nim`.
##
## Deliberately no `check not compiles(...)` tests for macro `error()`s: the
## macro emits a top-level `{.exportc.}` proc, which cannot be instantiated
## inside an expression, so `compiles()` returns false for a *valid* model too
## and the assertions would be vacuous. Verified, not assumed.

let repoRoot = currentSourcePath().parentDir.parentDir
let gainModel = repoRoot / "examples" / "xspice_gain.nim"
let dffModel = repoRoot / "examples" / "xspice_dff.nim"

proc renderViaDsl(model: string): string =
  ## Compile the example model in interface-only mode, run it, read the
  ## `ifspec.ifs` it writes. This is exactly step 1 of the `.cm` pipeline.
  let bd = createTempDir("nimcir_dsltest_", "")
  defer: removeDir(bd)
  let exe = bd / "genifs"
  let (output, code) = execCmdEx(quoteShellCommand(@[
    "nim", "c", "-d:xspiceGenIfs", "--hints:off", "--mm:arc",
    "--path:" & repoRoot / "src", "--nimcache:" & bd / "nc",
    "-o:" & exe, model]))
  if code != 0:
    raise newException(ValueError, "genIfs build failed:\n" & output)
  let (o2, c2) = execCmdEx(quoteShellCommand(@[exe, bd]))
  if c2 != 0:
    raise newException(ValueError, "genIfs run failed:\n" & o2)
  readFile(bd / "ifspec.ifs")

let ifs = renderViaDsl(gainModel)
let dffIfs = renderViaDsl(dffModel)

test "the macro's interface-only mode builds with no ngspice headers at all":
  check ifs.len > 0

test "NAME_TABLE carries the model name and the derived C function name":
  check "Spice_Model_Name:     nimgain" in ifs
  check "C_Function_Name:      cm_nimgain" in ifs

test "ports render in declaration order, which is what fixes conn[i]":
  let inp = ifs.find("Port_Name:            inp")
  let outp = ifs.find("Port_Name:            outp")
  check inp >= 0
  check outp > inp

test "port direction and allowed types survive the DSL":
  check "Direction:            in" in ifs
  check "Direction:            out" in ifs
  check "Allowed_Types:        [v,vd,i,id,vnam]" in ifs

test "parameters render in declaration order with their defaults":
  let g = ifs.find("Parameter_Name:       gain")
  let o = ifs.find("Parameter_Name:       in_offset")
  check g >= 0
  check o > g
  check "Default_Value:        1.0" in ifs
  check "Default_Value:        0.0" in ifs

test "a supplied default implies Null_Allowed: yes":
  # cmpp rejects a Default_Value together with Null_Allowed: no outright, so
  # the DSL flips it rather than emitting a spec cmpp would refuse.
  for tbl in ifs.split("PARAMETER_TABLE:")[1 .. ^1]:
    check "Null_Allowed:         yes" in tbl
    check "Null_Allowed:         no" notin tbl

test "descriptions given in the DSL reach the ifs":
  check "Description:          \"gain\"" in ifs
  check "Description:          \"input offset\"" in ifs

test "a digital model renders d-typed ports and a STATIC-free interface":
  check "Spice_Model_Name:     nimdff" in dffIfs
  check dffIfs.count("Default_Type:         d") == 3
  check dffIfs.count("Allowed_Types:        [d]") == 3

test "an int parameter renders as Data_Type: int, not real":
  let icBlock = dffIfs.split("Parameter_Name:       ic")[1]
  check icBlock.split("Vector:")[0].contains("Data_Type:            int")

test "both example models render interfaces cmpp's grammar accepts":
  # Structural sanity: every table block that exists carries its mandatory
  # rows. Actual cmpp acceptance is asserted in test_xspice_build.nim.
  for text in [ifs, dffIfs]:
    check text.startsWith("NAME_TABLE:")
    check text.count("Port_Name:") == text.count("Direction:")
    check text.count("Parameter_Name:") == text.count("Data_Type:")

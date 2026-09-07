## Renders a `ModelSpec` as the `ifspec.ifs` text that ngspice's `cmpp -ifs`
## consumes.
##
## Two deliberate simplifications over the files shipped in ngspice's own
## `src/xspice/icm/`:
##
## * **One row per table block.** Upstream `.ifs` files pack several ports or
##   parameters into one `PORT_TABLE:`/`PARAMETER_TABLE:` as aligned columns.
##   Repeating the table header instead is equally legal (ngspice's own
##   `digital/d_dff/ifspec.ifs` repeats both headers), and it removes all
##   column-alignment logic -- which would otherwise have to reason about the
##   widest entry in the block.
## * **Fixed label column.** `cmpp`'s lexer tokenizes; it does not care about
##   alignment. The padding here is purely so a human can read the generated
##   file when debugging a build.
##
## Pure string work -- no filesystem, no ngspice, no C. Testable anywhere.

import std/[os, strutils]
import ./spec

const labelWidth = 22

func field(label, value: string): string =
  label.alignLeft(labelWidth) & value & "\n"

func quoted(s: string): string =
  ## `Description:` values are quoted strings in the `.ifs` grammar.
  '"' & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & '"'

func descField(text: string): string =
  ## An empty `Description:` is *not* the same as no description: cmpp lexes
  ## `""` as zero elements and rejects the table with "Wrong number of
  ## elements in sub-table". Omitting the line is accepted. That is only safe
  ## because this renderer emits exactly one row per table block, so there is
  ## no sibling column whose element count could disagree.
  if text.len == 0: "" else: field("Description:", quoted(text))

func render(b: Bound): string =
  ## `-` for an inactive bound, `[lo hi]` otherwise, with an open side `-`.
  if not b.active: return "-"
  let lo = if b.lo.len == 0: "-" else: b.lo
  let hi = if b.hi.len == 0: "-" else: b.hi
  "[" & lo & " " & hi & "]"

func yesNo(b: bool): string = (if b: "yes" else: "no")

func renderIfs*(spec: ModelSpec): string =
  ## Render `spec` as `ifspec.ifs` text. Call `validate(spec)` first; this
  ## proc renders whatever it is given.
  result = "NAME_TABLE:\n\n"
  result &= field("C_Function_Name:", spec.cFunction)
  result &= field("Spice_Model_Name:", spec.name)
  result &= descField(spec.description)

  for p in spec.ports:
    result &= "\n\nPORT_TABLE:\n\n"
    result &= field("Port_Name:", p.name)
    result &= descField(p.description)
    result &= field("Direction:", p.dir.ifsName)
    result &= field("Default_Type:", p.default.ifsName)
    var allowed: seq[string]
    for t in p.allowed: allowed.add t.ifsName
    result &= field("Allowed_Types:", "[" & allowed.join(",") & "]")
    result &= field("Vector:", yesNo(p.vector))
    result &= field("Vector_Bounds:", render(p.vectorBounds))
    result &= field("Null_Allowed:", yesNo(p.nullAllowed))

  for p in spec.params:
    result &= "\n\nPARAMETER_TABLE:\n\n"
    result &= field("Parameter_Name:", p.name)
    result &= descField(p.description)
    result &= field("Data_Type:", p.dataType.ifsName)
    result &= field("Default_Value:", p.default)
    result &= field("Limits:", render(p.limits))
    result &= field("Vector:", yesNo(p.vector))
    result &= field("Vector_Bounds:", render(p.vectorBounds))
    result &= field("Null_Allowed:", yesNo(p.nullAllowed))

  if spec.stateVars.len > 0:
    for v in spec.stateVars:
      result &= "\n\nSTATIC_VAR_TABLE:\n\n"
      result &= field("Static_Var_Name:", v.name)
      result &= descField(v.description)
      result &= field("Data_Type:", v.dataType.ifsName)

proc writeIfsFile*(dir, text: string) =
  ## Write rendered `.ifs` text as `<dir>/ifspec.ifs` -- the filename
  ## `cmpp -ifs` insists on, since it reads from the working directory.
  writeFile(dir / "ifspec.ifs", text)

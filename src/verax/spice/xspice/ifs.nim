## Renders a `ModelSpec` as the `ifspec.ifs` text `cmpp -ifs` consumes. Two
## simplifications vs ngspice's own files: **one row per table block**
## (repeated headers are legal, and need no column alignment), and a fixed
## label column (for human readability only). Pure string work.

import std/[os, strutils]
import ./spec

const labelWidth = 22

func field(label, value: string): string =
  label.alignLeft(labelWidth) & value & "\n"

func quoted(s: string): string =
  ## `Description:` values are quoted strings in the `.ifs` grammar.
  '"' & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & '"'

func descField(text: string): string =
  ## Omit an empty `Description:` (cmpp rejects `""` as zero elements).
  ## Safe because each table block has one row.
  if text.len == 0: "" else: field("Description:", quoted(text))

func render(b: Bound): string =
  ## `-` for an inactive bound, `[lo hi]` otherwise, with an open side `-`.
  if not b.active: return "-"
  let lo = if b.lo.len == 0: "-" else: b.lo
  let hi = if b.hi.len == 0: "-" else: b.hi
  "[" & lo & " " & hi & "]"

func yesNo(b: bool): string = (if b: "yes" else: "no")

func renderIfs*(spec: ModelSpec): string =
  ## Render `spec` as `.ifs` text; call `validate(spec)` first.
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
  ## Write `<dir>/ifspec.ifs` (the filename `cmpp -ifs` requires).
  writeFile(dir / "ifspec.ifs", text)

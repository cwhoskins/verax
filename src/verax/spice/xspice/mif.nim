## Raw FFI bindings for ngspice's Model Interface (MIF): the structs a code
## model receives and the `cm_*` helpers it may call.
##
## **Opt-in**: needs ngspice headers (`-d:ngspiceSrc=/path`, or
## `--passC:-I<tree>/src/include` as `xspice/build.nim` passes), so not
## exported from `verax/spice/xspice`.
##
## **Every struct is `{.importc, header.}`, never hand-declared**: the C
## compiler computes offsets from the real header, and a typo is a compile
## error rather than silently wrong fields. Only fields read are declared.
##
## Build caveat: `SPICEdev`'s `CIDER`/`KLU` members must match the installed
## simulator, or ngspice segfaults silently (see `xspice/build.nim`).

const ngspiceSrc* {.strdefine.} = ""
when ngspiceSrc.len > 0:
  {.passC: "-I" & ngspiceSrc & "/src/include".}

import std/os
const shimDir = currentSourcePath().parentDir / "private"
{.passC: "-I" & shimDir.}

const shim = "mifshim.h"

type
  MifBoolean* = cint

  MifComplex* {.importc: "Mif_Complex_t", header: shim, bycopy.} = object
    real*, imag*: cdouble

  Digital* {.importc: "Digital_t", header: shim, bycopy.} = object
    ## What a digital port's `pvalue` points at.
    state*: cint
    strength*: cint

  MifValue* {.importc: "Mif_Value_t", header: shim, union, bycopy.} = object
    ## Params read the member for their `Data_Type`, ports by `Default_Type`:
    ## digital/user-defined use `pvalue`, every analog type `rvalue`. The real
    ## union has exactly these six (no digital member).
    bvalue*: MifBoolean
    ivalue*: cint
    rvalue*: cdouble
    cvalue*: MifComplex
    svalue*: cstring
    pvalue*: pointer

  MifPartial* {.importc: "Mif_Partial_t", header: shim, bycopy.} = object
    port*: ptr UncheckedArray[cdouble]

  MifAcGain* {.importc: "Mif_AC_Gain_t", header: shim, bycopy.} = object
    port*: ptr UncheckedArray[MifComplex]

  MifPortData* {.importc: "Mif_Port_Data_t", header: shim, bycopy.} = object
    is_null*: MifBoolean
    input*, output*: MifValue
    partial*: ptr UncheckedArray[MifPartial]
    ac_gain*: ptr UncheckedArray[MifAcGain]
    changed*: MifBoolean
    load*, total_load*, delay*: cdouble

  MifConnData* {.importc: "Mif_Conn_Data_t", header: shim, bycopy.} = object
    is_null*: MifBoolean
    is_input*, is_output*: MifBoolean
    size*: cint
    port*: ptr UncheckedArray[ptr MifPortData]

  MifParamData* {.importc: "Mif_Param_Data_t", header: shim, bycopy.} = object
    is_null*: MifBoolean
    size*: cint
    element*: ptr UncheckedArray[MifValue]

  MifInstVarData* {.importc: "Mif_Inst_Var_Data_t", header: shim, bycopy.} = object
    size*: cint
    element*: ptr UncheckedArray[MifValue]

  MifCircData* {.importc: "Mif_Circ_Data_t", header: shim, bycopy.} = object
    init*: MifBoolean
    anal_type*: cint
    anal_init*: MifBoolean
    call_type*: cint
    time*, frequency*, temperature*: cdouble
    t*: array[8, cdouble]
    tstep*, tstop*: cdouble

  MifPrivate* {.importc: "Mif_Private_t", header: shim, bycopy.} = object
    ## The single argument every code model receives (`cmpp`'s `ARGS`).
    circuit*: MifCircData
    num_conn*: cint
    conn*: ptr UncheckedArray[ptr MifConnData]
    num_param*: cint
    param*: ptr UncheckedArray[ptr MifParamData]
    num_inst_var*: cint
    inst_var*: ptr UncheckedArray[ptr MifInstVarData]

# --- enum values -------------------------------------------------------------
#
# C enumerator values can't be `importc`'d; routing them through the C
# compiler as constants makes a removed enumerator a compile error instead
# of a silent mismatch.
# The shim is re-included because a TYPESECTION emit precedes Nim's own
# `#include`; its guard makes the repeat free.
{.emit: """/*TYPESECTION*/
#include "mifshim.h"
static const int veraxMifDc          = MIF_DC;
static const int veraxMifAc          = MIF_AC;
static const int veraxMifTran        = MIF_TRAN;
static const int veraxMifNoise       = MIF_NOI;
static const int veraxMifAnalog      = MIF_ANALOG;
static const int veraxMifEventDriven = MIF_EVENT_DRIVEN;
static const int veraxMifStepPending = MIF_STEP_PENDING;
static const int veraxDigZero        = ZERO;
static const int veraxDigOne         = ONE;
static const int veraxDigUnknown     = UNKNOWN;
static const int veraxStrStrong      = STRONG;
static const int veraxStrResistive   = RESISTIVE;
static const int veraxStrHiImpedance = HI_IMPEDANCE;
static const int veraxStrUndetermined = UNDETERMINED;
""".}

let
  rawMifDc* {.importc: "veraxMifDc", nodecl.}: cint
  rawMifAc* {.importc: "veraxMifAc", nodecl.}: cint
  rawMifTran* {.importc: "veraxMifTran", nodecl.}: cint
  rawMifNoise* {.importc: "veraxMifNoise", nodecl.}: cint
  rawMifAnalog* {.importc: "veraxMifAnalog", nodecl.}: cint
  rawMifEventDriven* {.importc: "veraxMifEventDriven", nodecl.}: cint
  rawMifStepPending* {.importc: "veraxMifStepPending", nodecl.}: cint
  rawDigZero* {.importc: "veraxDigZero", nodecl.}: cint
  rawDigOne* {.importc: "veraxDigOne", nodecl.}: cint
  rawDigUnknown* {.importc: "veraxDigUnknown", nodecl.}: cint
  rawStrStrong* {.importc: "veraxStrStrong", nodecl.}: cint
  rawStrResistive* {.importc: "veraxStrResistive", nodecl.}: cint
  rawStrHiImpedance* {.importc: "veraxStrHiImpedance", nodecl.}: cint
  rawStrUndetermined* {.importc: "veraxStrUndetermined", nodecl.}: cint

type
  Analysis* = enum
    ## Nim mirror of `Mif_Analysis_t`, for exhaustive `case`.
    maDc, maAc, maTran, maNoise
  CallType* = enum
    mcAnalog, mcEventDriven, mcStepPending
  DigitalState* = enum
    dsZero, dsOne, dsUnknown
  DigitalStrength* = enum
    dgStrong, dgResistive, dgHiImpedance, dgUndetermined

proc toAnalysis*(raw: cint): Analysis =
  if raw == rawMifAc: maAc
  elif raw == rawMifTran: maTran
  elif raw == rawMifNoise: maNoise
  else: maDc

proc toCallType*(raw: cint): CallType =
  if raw == rawMifEventDriven: mcEventDriven
  elif raw == rawMifStepPending: mcStepPending
  else: mcAnalog

proc toDigitalState*(raw: cint): DigitalState =
  if raw == rawDigOne: dsOne
  elif raw == rawDigUnknown: dsUnknown
  else: dsZero

proc fromDigitalState*(s: DigitalState): cint =
  case s
  of dsZero: rawDigZero
  of dsOne: rawDigOne
  of dsUnknown: rawDigUnknown

proc toDigitalStrength*(raw: cint): DigitalStrength =
  if raw == rawStrResistive: dgResistive
  elif raw == rawStrHiImpedance: dgHiImpedance
  elif raw == rawStrUndetermined: dgUndetermined
  else: dgStrong

proc fromDigitalStrength*(s: DigitalStrength): cint =
  case s
  of dgStrong: rawStrStrong
  of dgResistive: rawStrResistive
  of dgHiImpedance: rawStrHiImpedance
  of dgUndetermined: rawStrUndetermined

# --- cm_* helpers ------------------------------------------------------------
#
# These link to `dlmain.c`'s wrappers, which forward through the `coreitf`
# table ngspice fills at dlopen -- which is why a `.cm` doesn't link
# libngspice.

proc cmMessageSend*(msg: cstring): cint {.importc: "cm_message_send", header: shim, discardable.}
proc cmAnalogAlloc*(tag: cint, bytes: cint) {.importc: "cm_analog_alloc", header: shim.}
proc cmAnalogGetPtr*(tag: cint, timepoint: cint): pointer {.importc: "cm_analog_get_ptr", header: shim.}
proc cmAnalogIntegrate*(integrand: cdouble, integral, partial: ptr cdouble): cint {.importc: "cm_analog_integrate", header: shim.}
proc cmAnalogConverge*(state: ptr cdouble): cint {.importc: "cm_analog_converge", header: shim.}
proc cmAnalogSetTempBkpt*(time: cdouble): cint {.importc: "cm_analog_set_temp_bkpt", header: shim.}
proc cmAnalogSetPermBkpt*(time: cdouble): cint {.importc: "cm_analog_set_perm_bkpt", header: shim.}
proc cmAnalogNotConverged*() {.importc: "cm_analog_not_converged", header: shim.}
proc cmAnalogAutoPartial*() {.importc: "cm_analog_auto_partial", header: shim.}
proc cmAnalogRampFactor*(): cdouble {.importc: "cm_analog_ramp_factor", header: shim.}
proc cmEventAlloc*(tag: cint, bytes: cint) {.importc: "cm_event_alloc", header: shim.}
proc cmEventGetPtr*(tag: cint, timepoint: cint): pointer {.importc: "cm_event_get_ptr", header: shim.}
proc cmEventQueue*(time: cdouble): cint {.importc: "cm_event_queue", header: shim.}
proc cmNetlistGetC*(): cdouble {.importc: "cm_netlist_get_c", header: shim.}
proc cmNetlistGetL*(): cdouble {.importc: "cm_netlist_get_l", header: shim.}
proc cmSmoothCorner*(xInput, xCenter, yCenter, domain, lowerSlope, upperSlope: cdouble,
                     yOutput, dyDx: ptr cdouble) {.importc: "cm_smooth_corner", header: shim.}

## Raw FFI bindings for ngspice's Model Interface (MIF) -- the structs a code
## model receives and the `cm_*` helpers it may call.
##
## **Opt-in.** This module needs ngspice's headers on the C include path, so it
## is deliberately not exported from `nimcir/spice/xspice`. Point it at a
## source tree with `-d:ngspiceSrc=/path/to/ngspice-46`, or supply
## `--passC:-I<tree>/src/include` yourself (which is what `xspice/build.nim`
## does).
##
## **Every struct is `{.importc, header.}`, never hand-declared.** The C
## compiler computes each field offset from the same header ngspice itself was
## built with, and a field-name typo becomes a C compile error. Hand-writing
## these layouts would mean reproducing `Mif_Port_Data_t`'s twenty fields
## including two nested aggregates, where the first mismatch silently puts
## every later field at the wrong offset and you get wrong voltages with no
## diagnostic. Nim only ever declares the fields it actually reads; the rest
## are resolved by name against the real struct.
##
## A matching caveat applies to the *build* rather than the source: ngspice's
## `SPICEdev` struct has `#ifdef CIDER` and `#ifdef KLU` members, so a `.cm`
## whose headers disagree with the installed simulator's build flags will
## segfault inside ngspice with no error message. See `xspice/build.nim`.

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
    ## ngspice's `put_type`/`put_conn_type` decide which member an accessor
    ## reads: params by declared `Data_Type`, ports by `Default_Type` --
    ## digital and user-defined nodes use `pvalue`, every analog port type
    ## uses `rvalue`. There is deliberately no digital member here; the real
    ## union has exactly these six.
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
    ## The single argument every code model receives. `cmpp` spells this
    ## `ARGS`, expanding to `Mif_Private_t *mif_private`.
    circuit*: MifCircData
    num_conn*: cint
    conn*: ptr UncheckedArray[ptr MifConnData]
    num_param*: cint
    param*: ptr UncheckedArray[ptr MifParamData]
    num_inst_var*: cint
    inst_var*: ptr UncheckedArray[ptr MifInstVarData]

# --- enum values -------------------------------------------------------------
#
# C enumerator values cannot be `importc`'d directly, and hard-coding them
# works right up until ngspice reorders an enum, at which point it fails
# silently. Laundering them through the C compiler as constants means a
# removed enumerator is a compile error instead.

# The shim is re-included here because a TYPESECTION emit is placed ahead of
# the #include Nim generates for the importc'd types, so the enumerators would
# otherwise be undeclared. The header's own guard makes the repeat free.
{.emit: """/*TYPESECTION*/
#include "mifshim.h"
static const int nimcirMifDc          = MIF_DC;
static const int nimcirMifAc          = MIF_AC;
static const int nimcirMifTran        = MIF_TRAN;
static const int nimcirMifNoise       = MIF_NOI;
static const int nimcirMifAnalog      = MIF_ANALOG;
static const int nimcirMifEventDriven = MIF_EVENT_DRIVEN;
static const int nimcirMifStepPending = MIF_STEP_PENDING;
static const int nimcirDigZero        = ZERO;
static const int nimcirDigOne         = ONE;
static const int nimcirDigUnknown     = UNKNOWN;
static const int nimcirStrStrong      = STRONG;
static const int nimcirStrResistive   = RESISTIVE;
static const int nimcirStrHiImpedance = HI_IMPEDANCE;
static const int nimcirStrUndetermined = UNDETERMINED;
""".}

let
  rawMifDc* {.importc: "nimcirMifDc", nodecl.}: cint
  rawMifAc* {.importc: "nimcirMifAc", nodecl.}: cint
  rawMifTran* {.importc: "nimcirMifTran", nodecl.}: cint
  rawMifNoise* {.importc: "nimcirMifNoise", nodecl.}: cint
  rawMifAnalog* {.importc: "nimcirMifAnalog", nodecl.}: cint
  rawMifEventDriven* {.importc: "nimcirMifEventDriven", nodecl.}: cint
  rawMifStepPending* {.importc: "nimcirMifStepPending", nodecl.}: cint
  rawDigZero* {.importc: "nimcirDigZero", nodecl.}: cint
  rawDigOne* {.importc: "nimcirDigOne", nodecl.}: cint
  rawDigUnknown* {.importc: "nimcirDigUnknown", nodecl.}: cint
  rawStrStrong* {.importc: "nimcirStrStrong", nodecl.}: cint
  rawStrResistive* {.importc: "nimcirStrResistive", nodecl.}: cint
  rawStrHiImpedance* {.importc: "nimcirStrHiImpedance", nodecl.}: cint
  rawStrUndetermined* {.importc: "nimcirStrUndetermined", nodecl.}: cint

type
  Analysis* = enum
    ## Nim-native mirror of `Mif_Analysis_t`, so a model body can write an
    ## ordinary exhaustive `case`/`==` instead of comparing raw `cint`s.
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
# These resolve at link time to the wrappers compiled in from ngspice's
# `src/xspice/icm/dlmain.c`, which forward through a `coreitf` function-pointer
# table that ngspice fills in at dlopen time. That is why a `.cm` does *not*
# link against libngspice -- it looks like a missing dependency and is not.

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

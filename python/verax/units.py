"""Typed electrical quantities for authoring annotations from Python.

Mirrors ``verax/units.nim`` exactly (same suffix names, same SI-base-unit
storage), but is plain Python rather than a wrapper around the Nim
constructors -- per §3 of ``docs/python_compatibility.md``, ``units.nim``
"is deliberately not a dimensional-analysis system... there is nothing here
for Python to lose": the whole point of the module is that a value can't be
misread by a factor of 1000, which a Python-side tagged float gives just as
well as a Nim ``distinct float`` does.

The one thing that *does* cross into Nim and run for real is the unit
*check* against the annotation registry (``esr`` must be ohms) -- see
``Quantity.unit`` and ``verax_py.nim``'s ``setAnnByUnit``, which reconstructs
the matching Nim ``Quantity`` subtype from ``.unit`` and runs the exact same
``annotations.setAnnotation`` overload the Nim DSL's ``spec:`` block expands
to. This module only carries the tag and does the decade conversion; it does
not re-implement the check.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Quantity:
    """An SI-base-unit float plus the unit symbol the annotation registry
    knows it by (``"V"``, ``"ohm"``, ``"F"``, ``"H"``, ``"Hz"``, ``"s"``,
    ``"A"``, ``"W"``, ``"deg"``, ``"dB"``, ``"degC"``, or ``""`` for a bare
    dimensionless ratio). Never constructed directly -- use a suffix
    function below, the same discipline `20.mohm` enforces in Nim.
    """

    si: float
    unit: str

    def __repr__(self) -> str:  # pragma: no cover - display only
        return f"{self.si:g} {self.unit}".strip()


def _ctor(scale: float, unit: str):
    def make(x: float) -> Quantity:
        return Quantity(float(x) * scale, unit)

    return make


# Voltage
V = _ctor(1.0, "V")
mV = _ctor(1e-3, "V")
uV = _ctor(1e-6, "V")
kV = _ctor(1e3, "V")

# Resistance
ohm = _ctor(1.0, "ohm")
uohm = _ctor(1e-6, "ohm")
mohm = _ctor(1e-3, "ohm")
kohm = _ctor(1e3, "ohm")
Mohm = _ctor(1e6, "ohm")
Gohm = _ctor(1e9, "ohm")

# Capacitance
F = _ctor(1.0, "F")
mF = _ctor(1e-3, "F")
uF = _ctor(1e-6, "F")
nF = _ctor(1e-9, "F")
pF = _ctor(1e-12, "F")

# Inductance
H = _ctor(1.0, "H")
mH = _ctor(1e-3, "H")
uH = _ctor(1e-6, "H")
nH = _ctor(1e-9, "H")
pH = _ctor(1e-12, "H")

# Frequency
Hz = _ctor(1.0, "Hz")
kHz = _ctor(1e3, "Hz")
MHz = _ctor(1e6, "Hz")
GHz = _ctor(1e9, "Hz")

# Time
s = _ctor(1.0, "s")
ms = _ctor(1e-3, "s")
us = _ctor(1e-6, "s")
ns = _ctor(1e-9, "s")
ps = _ctor(1e-12, "s")

# Current
A = _ctor(1.0, "A")
mA = _ctor(1e-3, "A")
uA = _ctor(1e-6, "A")
nA = _ctor(1e-9, "A")

# Power
W = _ctor(1.0, "W")
mW = _ctor(1e-3, "W")
kW = _ctor(1e3, "W")

# Temperature -- Celsius only, for the reason units.nim gives: a kelvin
# suffix would look like a conversion and isn't one (a *rise* of 20 K is
# 20 degC; an *absolute* 20 K is -253 degC).
degC = _ctor(1.0, "degC")

# Dimensionless
pct = _ctor(1e-2, "")
ppm = _ctor(1e-6, "")

# Phase and logarithmic ratio
deg = _ctor(1.0, "deg")
dB = _ctor(1.0, "dB")

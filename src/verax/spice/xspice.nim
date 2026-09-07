## Authoring ngspice XSPICE code models -- behavioural device models compiled
## into a `.cm` shared object that ngspice `dlopen`s and instantiates as an
## `A` device.
##
## This hub exports the parts that need no ngspice toolchain: `spec` (the
## declarative interface of a code model), `ifs` (rendering it as the
## `ifspec.ifs` file ngspice's `cmpp` consumes), and `instance` (adding an
## `A`-device instance of a model to a `Netlist`). Everything that needs
## an ngspice *source tree* -- the FFI bindings, the `codeModel` macro, the
## `.cm` build driver -- is opt-in per-import, the same rule `verax/spice.nim`
## applies to `verax/spice/ngspice`.
##
## That split is not cosmetic: openSUSE's `libngspice-devel` ships only
## `sharedspice.h`, so on a stock machine you can still author and render a
## code model interface here, and only the build step needs the source tree.

import ./xspice/spec
import ./xspice/ifs
import ./xspice/instance

export spec, ifs, instance

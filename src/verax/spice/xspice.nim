## Authoring ngspice XSPICE code models (compiled `.cm` objects instantiated
## as `A` devices). This hub exports what needs no ngspice sources: `spec`,
## `ifs`, `instance`. The FFI, `codeModel` macro and build driver need a
## source tree and are opt-in per import (distro dev packages ship only
## `sharedspice.h`).

import ./xspice/spec
import ./xspice/ifs
import ./xspice/instance

export spec, ifs, instance

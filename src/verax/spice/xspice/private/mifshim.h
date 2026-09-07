/* Include-order shim for verax's XSPICE bindings.
 *
 * ngspice's MIF headers have real ordering requirements (mifcmdat.h needs
 * miftypes.h, which needs ngspice.h for Mif_Boolean_t/Mif_Complex_t). Rather
 * than scatter that knowledge across dozens of Nim `header:` pragmas, every
 * binding in ../mif.nim names this one file. If ngspice reshuffles its
 * headers between releases, exactly one file here changes.
 */
#ifndef VERAX_MIFSHIM_H
#define VERAX_MIFSHIM_H

#include "ngspice/ngspice.h"
#include "ngspice/cm.h"
#include "ngspice/cmtypes.h"
#include "ngspice/miftypes.h"
#include "ngspice/mifcmdat.h"
#include "ngspice/cmproto.h"

#endif

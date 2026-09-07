#ifndef TANDEM_CLIBUSBMUXD_SHIM_H
#define TANDEM_CLIBUSBMUXD_SHIM_H

/* libusbmuxd's client API. We only want usbmuxd_read_pair_record() and
   usbmuxd_read_buid(): the pair record is what lets us speak lockdown to the
   phone directly by IP, bypassing usbmuxd's Bonjour device list. */
#include <usbmuxd.h>

#endif

# Third-party software

Tandem itself is MIT-licensed (see [`LICENSE`](LICENSE)). It links, and the
released `.app` bundles, the libraries below.

`tools/bundle-dylibs.sh` copies each dylib out of its Homebrew keg into
`Tandem.app/Contents/Frameworks/`, rewrites its install name to `@rpath`, and
copies the upstream licence text from that same keg into
`Tandem.app/Contents/Resources/Licenses/<formula>/`. The build fails rather
than shipping a library whose licence file it could not find, so the texts in
the bundle always match the versions beside them.

| Library | Licence | Used for |
|---|---|---|
| [libimobiledevice](https://libimobiledevice.org) | LGPL-2.1-or-later | Talking lockdown and `diagnostics_relay` to the iPhone |
| [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | LGPL-2.1-or-later | Device discovery and the pair record, via the `usbmuxd` daemon macOS already runs |
| [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) | LGPL-2.1-or-later | Shared support code for the two above |
| [libplist](https://github.com/libimobiledevice/libplist) | LGPL-2.1-or-later | Property-list encoding on the lockdown wire |
| [OpenSSL 3](https://www.openssl.org) (`libssl`, `libcrypto`) | Apache-2.0 | The TLS session the direct lockdown client opens to the phone |

The LGPL-2.1 libraries are used unmodified and are linked dynamically, as
separate dylibs inside `Contents/Frameworks`; they can be replaced with
compatible builds of the same libraries by anyone who wants to.

## Acknowledgements

[AirBattery](https://github.com/lihaoyun6/AirBattery) (MIT) is not linked or
bundled, but two ideas were taken from it: the container path that lets an
unsigned app hand data to its own sandboxed widget extension without an App
Group, and its notes on reading Apple device batteries over BLE.

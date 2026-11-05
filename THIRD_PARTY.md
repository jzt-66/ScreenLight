# Third-party component

Display discovery and IOAV transport mapping are derived from:

- m1ddc, Copyright (c) 2021 waydabber
- https://github.com/waydabber/m1ddc
- Revision: 7339ceebb03f691b1eaeb8471dca301d215d19c8
- MIT license: `Vendor/m1ddc/LICENSE`

Only `ioregistry.m`, `ioregistry.h`, and `utils.h` are vendored. Discovery resource
handling is adjusted locally. The brightness packet encoder, validating decoder,
JSON helper, queueing, and user interface are implemented for ScreenLight.

IOAV and CoreDisplay interfaces used by the transport are private macOS APIs.
This local arm64 app is not sandboxed, notarized, or distributed through the App
Store. Future macOS versions can require transport changes. No administrator,
Accessibility, Screen Recording, or network permission is required.

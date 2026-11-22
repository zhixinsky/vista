# Third-party code

WQFiles access, container discovery, localization and core modules are vendored
unmodified from https://github.com/kolbicz/WQFiles at
`0d9c28c7e283e729b7cef4e18adcce145920dbdb`.

Copyright belongs to the upstream authors. GPL-3.0-or-later; full license in
`WQFiles/LICENSE` and `ios/LICENSE`. Its access implementation credits
Taj C (forcequit) and https://github.com/forcequitOS/worse_query.

The new CarVista Workshop source in ios/Sources is GPL-3.0-or-later.
The original repository's prebuilt IPA is not part of this new app or its build.
Corresponding source: https://github.com/zhixinsky/CarVista

NeoSpring WebKit document in Sources/RespringDocument.swift is adapted from
https://github.com/frs0n/placard/blob/7f470dd0242f9d69ea5ad17e521566487706c891/placard/NeoSpringView.swift
under GPL-3.0 (full license: ios/LICENSE). Credits: rooootdev, skadz108, neonmodder123.
Local lifecycle wrapper adds explicit triggering, timeout, background cleanup, and simulator exclusion.

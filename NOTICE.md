# Third-party notices

Chirp itself is MIT-licensed (see [LICENSE](LICENSE)). It bundles the following
open-source components, whose licenses require their text — or their text plus
copyright notice — to be reproduced here. This file mirrors the same notices
shown in-app under Settings → Legal.

## FluidAudio

Chirp's fastest recognition engine — runs NVIDIA's Parakeet TDT model via
Core ML on the Neural Engine. Pulled as a remote Swift Package dependency,
not vendored.

License: Apache-2.0
Copyright 2025 FluidInference

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use this file except in compliance with the License. You may obtain a copy of
the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations under
the License. Full license text: https://www.apache.org/licenses/LICENSE-2.0

## Harper

The fast, deterministic grammar and style checker that runs alongside Apple
Intelligence on every dictation. Wrapped by a small Rust FFI layer
(`Vendor/harper-ffi`, source included) and vendored as a prebuilt binary
framework at `Vendor/harper.xcframework`.

License: Apache-2.0
Copyright 2024 Elijah Potter

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use this file except in compliance with the License. You may obtain a copy of
the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations under
the License. Full license text: https://www.apache.org/licenses/LICENSE-2.0

## Manrope

The typeface used for body text and interface controls throughout Chirp.
Page and section titles use New York, Apple's system serif — bundled with
macOS itself, not a separate font requiring its own notice here.

License: SIL Open Font License 1.1
Copyright 2018 The Manrope Project Authors (https://github.com/sharanda/manrope)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is available with a FAQ at: http://scripts.sil.org/OFL

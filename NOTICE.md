# Third-party notices

Chirp itself is MIT-licensed (see [LICENSE](LICENSE)). It bundles the following
open-source components, whose licenses require their text — or their text plus
copyright notice — to be reproduced here. This file mirrors the same notices
shown in-app under Settings → Legal.

## WhisperKit

One of Chirp's on-device speech recognition engines — runs Whisper models via
Core ML on the Neural Engine. Pulled as a remote Swift Package dependency, not
vendored.

License: MIT
Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## whisper.cpp / ggml

Runs Whisper models via Metal on the GPU, as an alternative to the
WhisperKit engine above. Vendored as a prebuilt binary framework at
`Vendor/whisper.xcframework`.

License: MIT
Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

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

The typeface used throughout Chirp's interface.

License: SIL Open Font License 1.1
Copyright 2018 The Manrope Project Authors (https://github.com/sharanda/manrope)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is available with a FAQ at: http://scripts.sil.org/OFL

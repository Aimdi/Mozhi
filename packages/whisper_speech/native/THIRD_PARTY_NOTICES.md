# Third-party notices: libmozhi_whisper

`libmozhi_whisper.so` (shipped in the APK) is built from the sources below,
vendored as a pinned git submodule under `third_party/` and compiled
statically: OpenAI's Whisper speech recognition as implemented by
whisper.cpp, on the CPU backend of ggml. Everything here is MIT-licensed;
nothing is GPL or proprietary, and there is no Google code. The app (MIT)
must show these notices (it does, on its licenses page).

| Component | Where | License |
| --- | --- | --- |
| whisper.cpp v1.9.5 (Whisper inference: model loading, log-mel spectrogram, encoder/decoder, sampling) | `third_party/whisper.cpp` ([ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), tag `v1.9.5`, commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`) | MIT (© 2023-2026 The ggml authors) |
| ggml 0.26.0 (tensor library, CPU backend only) | `third_party/whisper.cpp/ggml` (vendored by whisper.cpp) | MIT (© 2023-2026 The ggml authors) |
| YaRN RoPE scaling (a function in `ggml/src/ggml-cpu/ops.cpp`; unused by Whisper) | from [jquesnelle/yarn](https://github.com/jquesnelle/yarn) | MIT (© 2023 Jeffrey Quesnelle and Bowen Peng) |
| LLVM libc++ (NDK, linked statically) | Android NDK r28 | Apache-2.0 WITH LLVM-exception |

Not compiled in: whisper.cpp's examples, tests, server, bindings and the
Core ML / OpenVINO / Vitis AI encoders; ggml's GPU and accelerator
backends (CUDA, Vulkan, OpenCL, Metal, SYCL, ...), BLAS, OpenMP,
llamafile's sgemm and KleidiAI. No source file is modified.

The speech recognition **models** are downloaded at run time (never
bundled) from Hugging Face
(<https://huggingface.co/ggerganov/whisper.cpp>, files `ggml-tiny.bin`
and `ggml-base.bin`: OpenAI's Whisper weights converted to ggml by the
whisper.cpp project) or imported from files, and are licensed MIT
(© 2022 OpenAI, <https://github.com/openai/whisper/blob/main/LICENSE>).

The `mozhi_whisper` shim itself (`src/`, `tool/`) is MIT, like the app.

License texts: MIT below (the same text for whisper.cpp, ggml, YaRN and the
Whisper weights, with the copyright lines above); Apache-2.0
<https://www.apache.org/licenses/LICENSE-2.0>.

```
MIT License

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
```

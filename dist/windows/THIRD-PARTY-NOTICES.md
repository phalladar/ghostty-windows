# Third-party notices

Ghostty for Windows is an unofficial community port of
[Ghostty](https://github.com/ghostty-org/ghostty). It is not affiliated
with or endorsed by the Ghostty project or its maintainers.

## Ghostty

Ghostty for Windows is derived from Ghostty, which is licensed under the
MIT License:

    Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

The full license text is in `LICENSE`.

## Microsoft ConPTY (`conpty.dll`, `OpenConsole.exe`)

Release builds bundle `conpty.dll` and `OpenConsole.exe` from the
[Microsoft.Windows.Console.ConPTY](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY)
NuGet package, built from [microsoft/terminal](https://github.com/microsoft/terminal).

    MIT License

    Copyright (c) Microsoft Corporation. All rights reserved.

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

## Embedded fonts

`ghostty.exe` embeds fonts that Ghostty ships with (including JetBrains
Mono, Noto Emoji and Symbols Nerd Font). Their licenses (SIL Open Font
License 1.1, MIT and BSD-2-Clause) and the list of which font uses which
license are in `licenses/fonts/`.

## Other dependencies

Ghostty statically links further open-source libraries (for example
FreeType, HarfBuzz, oniguruma, simdutf and glslang). Their licenses are in
their upstream sources, which Ghostty's build fetches as listed in
`build.zig.zon` and the `pkg/` directory of the source repository.

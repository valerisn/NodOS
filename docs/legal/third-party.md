# Third-party notices

NodOS declares no package dependencies (`build.zig.zon` lists none) and the
dashboard loads no scripts, fonts, styles or images from anywhere else.

## Zig standard library

Every NodOS binary contains parts of the Zig standard library, compiled in. These parts are MIT licensed; the rest of NodOS is under the NodOS Free Use License.

```
The MIT License (Expat)

Copyright (c) Zig contributors

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

## Build and test tooling

CI uses GitHub Actions (`actions/checkout`, `mlugg/setup-zig`), Python 3 and
ShellCheck. None of them is part of a release.

## When you add a dependency

Add its name, version, license and copyright notice here in the same pull
request, and mention it in `NOTICE`. Licenses that are not permissive (GPL,
AGPL, SSPL and similar) are not accepted.

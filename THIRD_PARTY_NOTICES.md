# Third-party notices

This project vendors exactly one third-party component and inherits the licenses of the
noise libraries shipped inside it. No other third-party code, asset or plugin is used
(hard rule #4: no third-party deps beyond Voxel Tools).

## 1. Voxel Tools (godot_voxel) - MIT

- Copyright (c) 2016-2026 Marc Gilleron (Zylann) and contributors
- https://github.com/Zylann/godot_voxel
- Vendored at `addons/zylann.voxel/` as the **GDExtension** build, release **1.7.0**,
  git `75d3c6d996ed2331c80edcd8c3ebc947afc0f041`, from
  `GodotVoxelExtension.zip` (archive sha256
  `600737572a5e25541ba6f503e842a3717ba19afafa5474510a6ceff995a1d2d8`).
- Unmodified: `docs/reports/addon_manifest.json` records the sha256 of all 35 installed
  files and `tests/smoke/test_extension.gd` S2i re-verifies them on every test run.
- License text: MIT, see `addons/zylann.voxel/LICENSE.md`.

## 2. FastNoise2 - MIT (bundled inside Voxel Tools)

- Copyright (c) 2020 Jordan Peck (Auburn) and contributors
- https://github.com/Auburn/FastNoise2
- Used indirectly: Voxel Tools links FastNoise2 for its graph noise nodes. Not registered
  as a Godot class in 1.7 (verified in `docs/reports/voxel_api_dump.json`), so this project
  never calls it directly.

## 3. FastNoiseLite - MIT (bundled inside Voxel Tools)

- Copyright (c) 2023 Auburn and contributors
- https://github.com/Auburn/FastNoiseLite
- Used indirectly through Voxel Tools' `ZN_FastNoiseLite` resource (graph noise params)
  and, for the `noise2d` adapter, through Godot's own engine-bundled `FastNoiseLite`
  (same upstream, same MIT terms, shipped by the Godot engine itself).

## MIT license text (applies to all three)

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

## 4. Godot Engine

- Copyright (c) 2014-present Godot Engine contributors; Copyright (c) 2007-2014 Juan
  Linietsky, Ariel Manzur. MIT. https://godotengine.org
- The engine binary used to build and test this project is Godot 4.7.2-stable (official).
  The engine is a build/test tool here, not a vendored dependency.

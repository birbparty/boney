# Rive Runtime — Implementation Reference (for a Nim port)

> Compiled reference for building a from-scratch **Rive animation runtime in Nim**
> that plugs into two existing Nim renderers: **boxy** (OpenGL atlas/quad, multi-platform
> incl. 3DS/Vita) and **clckr**'s raylib seam. This file is the canonical context doc for
> future coding sessions — read it before touching loader/scene-graph/renderer code.
>
> **Grounding caveat (read this):** every symbol, type key, property key, and enum value
> below was gathered from official sources (the `rive-app/rive-runtime` GitHub repo,
> `help.rive.app`, `rive.app/docs`, and DeepWiki synthesis). A handful came via DeepWiki's
> synthesis rather than direct header reads — those are flagged inline. **Per plan-grounding
> discipline, confirm any exact name/value against the actual `include/rive/` headers before
> locking it into code.** The numeric keys especially are wire format — verify, don't trust.

---

## 0. TL;DR architecture decision

The C++ runtime cleanly separates a **renderer-independent core** (`.riv` parsing, object
model, animation, state machines) from a **swappable Renderer/Factory seam**. Mirror that seam
exactly in Nim. It is the single boundary that lets us build and test the loader + scene graph +
animation engine against a headless/no-op renderer *before* wiring boxy or raylib.

```
.riv bytes ──▶ File (uses Factory to mint resources)
                 └─▶ Artboard ──▶ ArtboardInstance
                                     ├─ LinearAnimationInstance  ─┐
                                     └─ StateMachineInstance      ─┤ advance(dt)
                                                                   ▼
                                  Artboard::updateComponents() (dependency-sorted)
                                                                   ▼
                                  Artboard::draw(Renderer*)  ──▶  boxy / raylib backend
```

Two abstract surfaces a backend implements:
- **`Factory`** — creates resources (paths, paints, images, buffers, gradients). Often off the render thread / at load time.
- **`Renderer`** — issues per-frame draw commands consuming those resources.

Everything else (`RenderPath`, `RenderPaint`, `RenderImage`, `RenderBuffer`, `RenderShader`)
are resource handles the Factory mints and the Renderer consumes.

---

## 1. Licensing — safe to reimplement

- **MIT licensed** (`rive-app/rive-runtime/LICENSE`, `Copyright (c) 2020 Rive`). Free to
  reimplement or even directly translate, provided the MIT notice is retained when porting code
  directly. A clean-room implementation from the format spec has no obligation.
- **Trademark:** MIT covers code/format, not the "Rive" name/logo. Name the project as
  "a Nim runtime for Rive files," not "Rive for Nim" (avoid implying official endorsement).
- No patent grant (MIT), but Rive has not asserted format patents; the format spec is public.

---

## 2. Ecosystem & reference ports to study

**No Nim Rive runtime exists** — this would be the first. (Multiple searches: zero Nim bindings,
parsers, or runtimes.) Best references, ranked:

| Project | Language | Nature | Reference value |
|---|---|---|---|
| **rive-flutter ≤ 0.13.x** | Pure Dart | Full hand-written core reimpl (pre-0.14, before C++ FFI replaced it) | ⭐ **Highest** — a complete idiomatic reimpl in a GC'd language; structurally closest to a Nim port. Pin a pre-0.14 tag (e.g. 0.13.x). |
| **rive-rs** | Rust (+ some C++) | Hand-written Rust core, Vello renderer; known gaps (image-mesh, high clip counts, strokes all round) | ⭐ High — non-GC idioms (closer to Nim's perf model); core/renderer split. |
| **rive-runtime** | C++ | Canonical low-level runtime | ⭐ Canonical truth for behavior + type/property keys. |
| rive-sharp | C# (+native) | Wrapper over `rive.dll`, not a reimpl | Medium — API shape only. |

No Go/Zig community runtime of note. (Beware "RiveScript" — an unrelated chatbot DSL — polluting searches.)

**Inspection tooling for validating our parser:**
- `rive-app/rive-code-generator-wip` — official WIP tool; parses `.riv`, extracts artboards,
  component names, state-machine inputs; emits JSON/Dart. Use as ground-truth diff target.
- Rive editor JSON export — human-readable serialization of the same data.
- `rive-app/awesome-rive` — curated index.

Key repos:
- https://github.com/rive-app/rive-runtime (canonical C++ core, MIT)
- https://github.com/rive-app/rive-flutter (pure-Dart core in ≤0.13.x history — best port reference)
- https://github.com/rive-app/rive-rs (Rust core, MIT)
- https://github.com/rive-app/rive-code-generator-wip (.riv inspection)
- https://github.com/rive-app/help-center/blob/master/runtimes/advanced_topics/format.md (format spec)

---

## 3. The `.riv` binary format

**Custom binary format — NOT FlatBuffers, NOT Protobuf.** There is no `.fbs`/`.proto` schema;
the schema *is* the numeric type-key / property-key tables in the C++ headers (generated from
`dev/defs/*.json`). **Little-endian throughout.** Non-fixed integers are **LEB128 varuints**.

### 3.1 Header (`include/rive/runtime_header.hpp`, `RuntimeHeader::read`)

Read in exact order:
1. **Fingerprint** — 4 bytes ASCII `"RIVE"` (`0x52 0x49 0x56 0x45`). Byte-by-byte compare; mismatch = malformed.
2. **Major version** — `readVarUintAs<int>()`. Majors are NOT cross-compatible. **`RuntimeHeader::read`
   itself does NOT gate on the version** — it only reads the number. The mismatch check lives at the
   `File::import` layer (`src/file.cpp`): `if (header.majorVersion() != majorVersion) → ImportResult::unsupportedVersion`.
   The target constant lives in `file.hpp` (`static const int majorVersion = 7; static const int minorVersion = 0;`),
   so "major 7" is **as of this writing**, not a header constant — cite the upstream source, don't hardcode a bare `7`.
3. **Minor version** — `readVarUintAs<int>()`. Minor bumps are backward/forward compatible.
4. **File ID** — `readVarUintAs<int>()`.
5. **Table of Contents (ToC)** — see below.

### 3.2 Table of Contents — the forward-compat mechanism

Lets an older runtime safely load a newer file by skipping unknown properties.
- **Property key list:** a sequence of varuints (every property key used anywhere in the file),
  terminated by a `0` sentinel.
- **Backing-type bitset:** immediately after, a bit-packed region giving **2 bits per property key**
  naming the backing field type. **Verified** against `RuntimeHeader::read` (`runtime_header.hpp`):
  ```cpp
  int currentInt = 0;
  int currentBit = 8;                       // forces a read on the first iteration
  for (auto propertyKey : propertyKeys) {
      if (currentBit == 8) {                // reload only after 8 bits (4 keys) consumed
          currentInt = reader.readUint32();
          currentBit = 0;
      }
      int fieldIndex = (currentInt >> currentBit) & 3;   // 2 bits per key
      header.m_PropertyToFieldIndex[propertyKey] = fieldIndex;
      currentBit += 2;
  }
  ```
  **Exactly 4 property keys are packed per `uint32` word** (only the low 8 bits are used; the high
  24 bits of each word are padding/unused). Stored as `std::unordered_map<int,int>
  m_PropertyToFieldIndex`; `propertyFieldId(key)` returns the field index or `-1` if unknown.

**2-bit backing-type codes** (load-bearing for the parser):

| code | backing type |
|------|--------------|
| 0 | Uint / Bool |
| 1 | String |
| 2 | Float (double in editor, 32-bit float at runtime) |
| 3 | Color |

> ✅ **Resolved (was ⚠️):** stride confirmed at **4 keys per `uint32`** by direct read of
> `runtime_header.hpp` (loop above). An earlier guess of 16 keys/word was wrong — do not use it.

### 3.3 Primitive encodings (`src/core/binary_reader.cpp`)

- **varuint** — LEB128 unsigned (`readVarUint64` → `decode_uint_leb`); overflow flag + return 0 on 0 bytes.
- **uint (fixed)** — 4-byte LE (`readUint32`/`readUint16`/`readByte`).
- **float (runtime)** — 4-byte IEEE-754 (`readFloat32`). `readFloat64` only under `WITH_RIVE_TOOLS`.
- **string** — LEB128 length prefix + UTF-8 bytes (`readString`).
- **bytes** — LEB128 length prefix + raw bytes (`readBytes` → `Span<const uint8_t>`).
- Safety flags: `m_Overflowed`, `m_IntRangeError`; `reachedEnd()` true at EOF or on either error.

### 3.4 Object stream

After the header, a flat list of serialized objects until EOF:
- **Object** = varuint **type key** + its property list.
- **Property** = varuint **property key** + value (encoded per backing type).
- **Property key `0` terminates the current object's property list**; next object's type key follows.
- Unknown type keys are still skippable because every property within can be skipped via the ToC backing type.

### 3.5 Object reconstruction (`readRuntimeObject`, `src/file.cpp`)

Per object:
1. `int coreObjectKey = reader.readVarUintAs<int>()`.
2. `Core* object = CoreRegistry::makeCoreInstance(coreObjectKey)` (null placeholder if unknown — props still consumed).
3. Loop property keys (varuint); `0` ends object.
4. Known property → `object->deserialize(propertyKey, reader)` (generated per-class switch).
5. Unknown property → look up ToC backing type, call the matching field-type deserializer
   (`CoreUintType` / `CoreStringType` / `CoreDoubleType` / `CoreColorType` / `CoreBoolType` /
   `CoreBytesType`) to advance past it without storing.

> ⚠️ Confirm exact filenames under `src/core/field_types/` — the path tried 404'd, but the classes exist.

### 3.6 ImportStack — two-phase deserialize-then-resolve

The flat object stream is reassembled into a tree via an `ImportStack` (`src/file.cpp`):
- As objects deserialize, certain ones push an `ImportStackObject` (`ArtboardImporter`,
  `LinearAnimationImporter`, `StateMachineImporter`, `FileAssetImporter`, …).
- Children attach to the latest matching importer via `importStack.latest<T>()` — e.g. a
  `KeyedProperty` grabs `latest<LinearAnimationImporter>()`; a `StateMachineLayer` grabs
  `latest<ArtboardImporter>()`.
- After the read loop, `importStack.resolve()` wires parent/child relationships once all referenced objects exist.
- General components link via `parentId` (Component key **5**, runtime type `uint`) — an index into
  the artboard's object list. Special cases: DataBind tracks `lastBindableObject`; ViewModels run
  `completeViewModelInstance()`; FileAssets load via `FileAssetImporter`.

### 3.7 Compatibility model summary

- **Forward compat:** old runtime + new file → unknown type/property keys skipped via ToC; rest renders.
- **Backward compat:** new runtime + old file → missing properties fall back to `initialValueRuntime` defaults.
- **Hard break only on major version mismatch** (target **7**).

---

## 4. Core object model & type/property keys

Generated bases live under `include/generated/*_base.hpp`, one per def in `dev/defs/*.json`.
The def JSON is the single source of truth shared by editor + every runtime.

### 4.1 Def JSON schema (example: `component.json`)

```json
{
  "name": "Component",
  "key": { "int": 10, "string": "component" },
  "abstract": true,
  "properties": {
    "parentId": {
      "type": "Id", "typeRuntime": "uint",
      "initialValue": "Core.missingId", "initialValueRuntime": "0",
      "key": { "int": 5, "string": "parentId" }
    },
    "name": { "type": "String", "initialValue": "''", "key": { "int": 4 } }
  }
}
```

When generating/hand-porting the Nim layer, honor:
- `name` (class), `key.int` (type key), `key.string`, `abstract`/`extends` (inheritance).
- per-property: `type` (editor) vs `typeRuntime` (runtime backing, e.g. `Id`→`uint`);
  `key.int` (globally unique property key); `initialValue` vs `initialValueRuntime`;
  flags `runtime` (false = editor-only, **never serialized — skip it**), `coop`, `computed`.

### 4.2 Selected Core type keys (verify against `dev/defs/`)

| Object | type key | def file |
|---|---|---|
| Artboard | 1 | `artboard.json` |
| Component (abstract) | 10 | `component.json` |
| Drawable (abstract) | 13 | `drawable.json` |
| KeyFrame (abstract) | 29 | `animation/keyframe.json` |
| LinearAnimation | 31 | `animation/linear_animation.json` |
| StateMachine | 53 | `animation/state_machine.json` |
| InterpolatingKeyFrame | 170 | `animation/interpolating_keyframe.json` |
| ImageAsset | 105 | `assets/…` |
| FileAssetContents | 106 | `assets/file_asset_contents.json` |
| FontAsset | 141 | `assets/…` |
| AudioAsset | 406 | `assets/…` |

### 4.3 Key concept objects

- **Artboard** (1): root render container. Geometry (`width`/`height`/`x`/`y`/`clip`) inherited
  from `layout_component.json`. Adds `originX` (key 11, `ox`), `originY` (12, `oy`),
  `defaultStateMachineId` (236), `viewModelId` (583), `viewModelInstanceId` (584),
  `isComponent` (792), `includeInExport` (802). Owns its object list; children's `parentId`s index into it.
- **Component** (10) / **ContainerComponent**: base hierarchy node; `parentId` (5) links the tree.
- **Drawable** (13, extends `node.json`): `blendModeValue` key **23** (uint, default 3 = SrcOver),
  `drawableFlags` key **129** (uint). Note: def `key.string` values are **all lowercase**
  (`"drawableflags"`, `"linearanimation"`, `"enableworkarea"`), not camelCase — when hand-porting,
  key off `key.int` or use the lowercase strings to avoid a casing mismatch.
- **Draw order:** editor uses a `FractionalIndex` (`childOrder`, Component key 6). At runtime,
  resolved via `draw_rules.json` / `draw_target.json` (DrawRules/DrawTarget) + the artboard's sorted drawable list.

### 4.4 LinearAnimation (key 31) runtime properties

| prop | key | type | default |
|---|---|---|---|
| `fps` | 56 | uint | 60 |
| `duration` | 57 | uint (frames) | 60 |
| `speed` | 58 | double | 1 |
| `loopValue` | 59 | uint (enum) | 0 |
| `workStart` | 60 | uint | -1 |
| `workEnd` | 61 | uint | -1 |
| `enableWorkArea` | 62 | bool | false |
| `quantize` | 376 | bool | false |

Time = `frame / fps`. Other LinearAnimation props (playhead 132, viewport 133–134, scroll 256)
are editor-only (`runtime:false`) and won't appear in exported `.riv`.

### 4.5 Keyframes & interpolation

Hierarchy: **KeyFrames → KeyedProperty → KeyedObject → LinearAnimation**.
- **KeyFrame** (29): `frame` = key **67** (uint; time = frame / fps), plus `keyedPropertyId`.
- **InterpolatingKeyFrame** (170): adds `interpolationType` key **68** (uint enum: hold/linear/cubic/elastic)
  and `interpolatorId` key **69** (Id→uint, points at a CubicInterpolator/ElasticInterpolator).
- Concrete value keyframes: `keyframe_double/color/bool/uint/id/string/callback.json`.
- Interpolators: `cubic_interpolator.json`, `cubic_ease_interpolator.json`,
  `cubic_value_interpolator.json`, `elastic_interpolator.json`.
- Floats/colors interpolate; bools/ids/strings hold. Implementing **hold + linear + cubic-bezier**
  covers all standard editor eases.

### 4.6 State machine family (`dev/defs/animation/`)

`state_machine.json` (53), `state_machine_layer.json`, `state_machine_component.json`;
inputs (`state_machine_bool/number/trigger.json`, `state_machine_input.json`);
`state_machine_listener.json`, `state_machine_nested_input.json`;
transitions (`state_transition.json`, `blend_state_transition.json`);
conditions/comparators (`transition_condition.json`, `transition_bool/number/trigger_condition.json`,
`transition_value_*_comparator.json`); blend states (`blend_state.json`, `blend_state_1d.json`,
`blend_state_direct.json`, `blend_animation*.json`).

---

## 5. Renderer abstraction — the backend seam

All signatures from `rive-app/rive-runtime` `main`. A backend mirrors **Factory** + **Renderer**;
everything else is resource handles.

### 5.1 `rive::Renderer` (`include/rive/renderer.hpp`)

```cpp
class Renderer {
public:
    virtual ~Renderer() {}
    virtual void save() = 0;
    virtual void restore() = 0;
    virtual void transform(const Mat2D& transform) = 0;       // CONCATENATES, not set
    virtual void drawPath(RenderPath* path, RenderPaint* paint) = 0;
    virtual void clipPath(RenderPath* path) = 0;              // intersects current clip
    virtual void drawImage(const RenderImage*, ImageSampler, BlendMode, float opacity) = 0;
    virtual void drawImageMesh(const RenderImage*, ImageSampler,
                               rcp<RenderBuffer> vertices_f32,
                               rcp<RenderBuffer> uvCoords_f32,
                               rcp<RenderBuffer> indices_u16,
                               uint32_t vertexCount, uint32_t indexCount,
                               BlendMode, float opacity) = 0;
    virtual void modulateOpacity(float opacity) = 0;
    // Non-virtual conveniences (free once transform() exists):
    void translate(float x, float y);
    void scale(float sx, float sy);
    void rotate(float radians);
    void align(Fit, Alignment, const AABB& frame, const AABB& content, float scaleFactor = 1.0f);
};
```

Semantics for the Nim port:
- **Only 8 pure-virtuals.** `translate/scale/rotate/align` are concrete (compose a `Mat2D` and call `transform()`).
- `save`/`restore` = a state stack of `(Mat2D transform, clip state)`.
- `transform(Mat2D)` **concatenates** onto current. `Mat2D` is a 2×3 affine `[xx, xy, yx, yy, tx, ty]`.
- `clipPath` intersects current clip with the path. `modulateOpacity` multiplies a global opacity for subsequent draws.
- Driven by `Artboard::draw(Renderer*)` after `advance`.

### 5.2 `Factory` (`include/rive/factory.hpp`)

```cpp
virtual rcp<RenderBuffer> makeRenderBuffer(RenderBufferType, RenderBufferFlags, size_t sizeInBytes) = 0;
virtual rcp<RenderShader> makeLinearGradient(float sx, float sy, float ex, float ey,
                                             const ColorInt colors[], const float stops[], size_t count) = 0;
virtual rcp<RenderShader> makeRadialGradient(float cx, float cy, float radius,
                                             const ColorInt colors[], const float stops[], size_t count) = 0;
virtual rcp<RenderPath>   makeRenderPath(RawPath&, FillRule) = 0;
virtual rcp<RenderPath>   makeEmptyRenderPath() = 0;
virtual rcp<RenderPaint>  makeRenderPaint() = 0;
virtual rcp<RenderImage>  decodeImage(Span<const uint8_t>) = 0;
// decodeFont(), decodeAudio(), makeRenderPath(const AABB&) are CONCRETE — not needed for vector/image.
```
- `ColorInt` = packed 32-bit ARGB (`shapes/paint/color.hpp`). `Span<const uint8_t>` = lightweight slice.
- `rcp<T>` = intrusive refcounted ptr. In Nim, model as `ref object` + GC, or manual refcount if bridging C++.
- Factory creates resources once (often at load); Renderer draws each frame using them.

### 5.3 Resource abstractions a backend subclasses

**RenderPaint** (`renderer.hpp`):
```cpp
virtual void style(RenderPaintStyle) = 0;   // stroke | fill
virtual void color(ColorInt) = 0;
virtual void thickness(float) = 0;          // stroke width
virtual void join(StrokeJoin) = 0;
virtual void cap(StrokeCap) = 0;
virtual void feather(float) {}              // non-pure (Rive Renderer feathering)
virtual void blendMode(BlendMode) = 0;
virtual void shader(rcp<RenderShader>) = 0; // gradient, or null = solid color
virtual void invalidateStroke() = 0;
```

**RenderPath** extends **CommandPath** (`command_path.hpp`):
```cpp
// CommandPath:
virtual void rewind() = 0;
virtual void fillRule(FillRule) = 0;
virtual void addPath(CommandPath*, const Mat2D&) = 0;
virtual void moveTo(float x, float y) = 0;
virtual void lineTo(float x, float y) = 0;
virtual void cubicTo(float ox, float oy, float ix, float iy, float x, float y) = 0;  // out-tangent, in-tangent, dest
virtual void close() = 0;
// RenderPath adds:
virtual void addRenderPath(const RenderPath*, const Mat2D&) = 0;
virtual void addRawPath(const RawPath&) = 0;
```
> No `quadTo` at RenderPath level — cubics only. (RawPath *can* contain quads from `addOval` etc.)

**RenderImage** (`renderer.hpp`) — no pure-virtuals; subclass to carry a texture/atlas handle:
```cpp
protected: int m_Width = 0; int m_Height = 0; Mat2D m_uvTransform;
public: int width() const; int height() const; const Mat2D& uvTransform() const;
```

**RenderBuffer** (`renderer.hpp`) — map/unmap pattern:
```cpp
RenderBuffer(RenderBufferType, RenderBufferFlags, size_t sizeInBytes);
void* map();   // → onMap()
void unmap();  // → onUnmap()
protected: virtual void* onMap() = 0; virtual void onUnmap() = 0;
```
**RenderShader** — empty marker base; backends store gradient params / compiled shader in their subclass.

### 5.4 Enums — values are wire format, mirror EXACTLY

```cpp
enum class FillRule        { nonZero, evenOdd, clockwise };               // path_types.hpp
enum class RenderPaintStyle{ stroke, fill };                              // renderer.hpp
enum class PathVerb : uint8_t { move=0, line=1, quad=2, cubic=4, close=5 };// path_types.hpp
// NOTE: value 3 is intentionally skipped (it is `conic`, unused by Rive's exporter). The gap is
// deliberate — do NOT "fix" it by renumbering. Verified against blend_mode.hpp/path_types.hpp.
enum class RenderBufferType  { index, vertex };
enum class RenderBufferFlags { none=0, mappedOnceAtInitialization = 1<<0 };

// blend_mode.hpp — NON-CONTIGUOUS; do NOT auto-number in Nim:
enum class BlendMode : unsigned char {
    srcOver=3, screen=14, overlay=15, darken=16, lighten=17, colorDodge=18,
    colorBurn=19, hardLight=20, softLight=21, difference=22, exclusion=23,
    multiply=24, hue=25, saturation=26, color=27, luminosity=28
};

// image_sampler.hpp:
enum class ImageFilter : uint8_t { bilinear=0, nearest=1 };
enum class ImageWrap   : uint8_t { clamp=0, repeat=1, mirror=2 };
struct ImageSampler { ImageWrap wrapX=clamp, wrapY=clamp; ImageFilter filter=bilinear;
                      uint8_t asKey() const; static ImageSampler SamplerFromKey(uint8_t); };
```
> `StrokeCap` (`stroke_cap.hpp`) and `StrokeJoin` (`stroke_join.hpp`) — fetch for exact values
> (butt/round/square; miter/round/bevel) before implementing. `Mat2D` layout in `math/mat2d.hpp`.

### 5.5 Path / geometry model

- **Command form** (`moveTo/lineTo/cubicTo/close` + `fillRule`): cubics only; control-point order is
  `cubicTo(outX,outY, inX,inY, x,y)` — out-tangent of prev point, in-tangent of dest, dest.
- **Raw form** (`RawPath`, `math/raw_path.hpp`) — flat verb+point arrays passed to
  `makeRenderPath(RawPath&, FillRule)`:
  ```cpp
  void move(Vec2D); void line(Vec2D); void quad(Vec2D,Vec2D); void cubic(Vec2D,Vec2D,Vec2D); void close();
  void addRect(const AABB&, PathDirection=cw); void addOval(const AABB&, PathDirection=cw);
  void addPath(const RawPath&, const Mat2D* = nullptr);
  Span<const Vec2D> points() const; Span<const PathVerb> verbs() const;  // range-for yields (verb, pts)
  ```
  `RawPath` can contain `quad` verbs → the tessellator must handle quad AND cubic. For a
  tessellation/atlas backend: flatten cubics/quads to segments, triangulate honoring `FillRule`
  (`clockwise` is a Rive-Renderer optimization hint).
- **Gradients:** `makeLinearGradient(sx,sy,ex,ey, colors[], stops[], count)` /
  `makeRadialGradient(cx,cy,radius, colors[], stops[], count)` → `RenderShader`, attached via
  `paint->shader(...)`. Solid fills: `paint->color(ColorInt)` with null shader.

### 5.6 `drawImageMesh` — directly relevant to boxy's atlas/quad model

```cpp
drawImageMesh(const RenderImage*, ImageSampler,
              rcp<RenderBuffer> vertices_f32,  // 2 floats/vertex (x,y)
              rcp<RenderBuffer> uvCoords_f32,  // 2 floats/vertex (u,v)
              rcp<RenderBuffer> indices_u16,   // uint16 triangle indices
              uint32_t vertexCount, uint32_t indexCount, BlendMode, float opacity);
```
Indexed textured triangle mesh. For **boxy**: bind the `RenderImage`'s atlas-region texture, draw
the supplied index/vertex/UV buffers as a textured triangle list, apply current transform + opacity.
A flat `drawImage` is the degenerate case — one textured quad over `[0,0]..[w,h]` with `uvTransform()`.
If boxy only supports axis-aligned atlas quads, implement `drawImage` natively and submit a general
triangle batch for `drawImageMesh`.

### 5.7 No-op renderer = the scaffolding starting point

Canonical minimal backend: `utils/no_op_factory.cpp` (+ its header — confirm the exact include path;
the `include/utils/...` path is unverified, the header is more likely under `include/rive/...`). Proves how
little is needed to *parse and advance* without drawing:
- `NoOpFactory` returns `nullptr` for buffers/images, empty `NoOpRenderPath`/`NoOpRenderPaint`,
  and `FakeRenderShader` for gradients.
- `NoOpRenderPath`/`NoOpRenderPaint` are empty stubs (all setters `{}`).
- **Port NoOpFactory + NoOp resources first** so the parser/scene-graph/state-machine run green,
  then incrementally fill in boxy/raylib drawing in `drawPath`/`drawImage`/`drawImageMesh`.

---

## 6. Runtime lifecycle & animation/state-machine semantics

### 6.1 Lifecycle (canonical C++ names)

`File` (`file.hpp`) — parsed `.riv` container (source artboards, animation/SM defs, view models,
asset refs); created from bytes via `File::import(...)` **requiring a `Factory`**.
- `File::artboard()` (default) / `File::artboard(name)`; JS binding: `file.artboardByName(name)`.
- `Artboard::instance()` → **`ArtboardInstance`** (deep copy of mutable state, shares immutable defs). Always animate/draw an instance.
- `Artboard::linearAnimation(index/name)` / `Artboard::stateMachine(index/name)`; counts via
  `animationCount()` / `stateMachineCount()`.
- Instances: **`LinearAnimationInstance`** (`animation/linear_animation_instance.hpp`),
  **`StateMachineInstance`** (`animation/state_machine_instance.hpp`); both implement **`Scene`** (`scene.hpp`).

### 6.2 Per-frame order (this ordering matters)

- **Linear:** `animation.advance(dt)` → `animation.apply(mix)` → `artboard.advance(dt)`.
- **State machine:** `stateMachine.advance(dt)` → `artboard.advance(dt)` (SM applies values internally during its advance).
- **Convenience:** both expose `advanceAndApply(seconds)` — recommended single entry point.
- **Multiple animations:** advance each, but call `artboard.advance(...)` **once** per frame.

Drawing:
```
renderer.save()
renderer.align(Fit, Alignment, canvasBounds, artboard.bounds)  // → Mat2D via computeAlignment(...)
artboard.draw(renderer)                                         // Artboard::draw(Renderer*)
renderer.restore()
```
`Fit` = contain/cover/fill/fitWidth/fitHeight/none/scaleDown. C++ cleanup is RAII/`rcp<>`; JS binding
needs explicit `.delete()` (relevant only if mirroring a manual-free model).

### 6.3 Artboard advance loop, dependency sort, dirty system (the heart)

- **Component model:** `Component` base; `TransformComponent` adds matrices; `Drawable` is renderable.
- **Dirty flags:** `ComponentDirt` bit-flags (transform, world transform, path, render-opacity, …).
  - `Component::addDirt(ComponentDirt, bool recurse)` — mark dirty (+ optionally dependents), queue for update.
  - `Component::onDirty(ComponentDirt)` — virtual callback on newly dirty.
  - `Component::onDependenciesAdvanced()` / `onDependencySolve()` — after deps resolved in topo order.
- **Dependency order:** `m_DependencyOrder` is a **topologically sorted** component list (deps update
  before dependents), built once after import via `Artboard::sortDependencies()`.
- **Advance entry:** `Artboard::advance(float seconds)` → `Artboard::updateComponents()` walks
  `m_DependencyOrder` calling `Component::update(ComponentDirt)` on each dirty component, then resolves
  layout, constraints, nested artboards.

Cycle to replicate each frame: **(1) Animate** (SM/animation writes values, calls `addDirt`) →
**(2) Solve** (`updateComponents()` over `m_DependencyOrder`) → **(3) Draw** (`Artboard::draw` iterates
ordered drawables via `m_FirstDrawable`/`m_Drawables`, calls `Drawable::draw(Renderer*)`).

> ⚠️ `onDependencySolve`, `m_DependencyOrder`, `getBool/getNumber/getTrigger` came via DeepWiki synthesis — confirm spelling/casing in `include/rive/` before locking in.

### 6.4 State machine semantics

- **Definition vs instance:** `StateMachine` (immutable: states, transitions, input defs, layers) vs
  `StateMachineInstance` (mutable, implements `Scene`). `StateMachineInstance::advance()` evaluates each
  layer's transitions, blends animations, routes pointer events.
- **Inputs** (set from host code): Bool (`SMIBool.value`), Number (`SMINumber.value`),
  Trigger (`SMITrigger.fire()`, one-frame). Accessors: `getBool(name)`, `getNumber(name)`, `getTrigger(name)`.
- **States:** `EntryState`, `ExitState`, `AnyState`, `AnimationState` (plays a `LinearAnimation`),
  blend states (`BlendState`, `BlendState1D`, `BlendStateDirect`).
- **Transitions & conditions:** guarded by `TransitionBoolCondition` / `TransitionNumberCondition` /
  `TransitionTriggerCondition`; support **duration** (blend/mix), **exit time** (fraction complete before
  firing), randomization. Evaluated during `advance`.
- **Layers:** multiple `StateMachineLayer`/`...Instance` run in parallel, each mixing onto the artboard.
- **Pointer events** (interactivity only): `pointerDown/Move/Up/Exit(Vec2D)`.
- **Events:** `reportedEventAt(index)` / count — fired Rive Events (optional).

### 6.5 LinearAnimation details

`LinearAnimation` (`animation/linear_animation.hpp`): `fps()`, duration (frames), work area
(`workStart`/`workEnd`/`enableWorkArea`), speed, loop mode; holds `KeyedObject` records.
- **Loop enum** (`Loop`): `oneShot` (stop at boundary; `keepGoing()` false at end), `loop` (wrap),
  `pingPong` (reverse at boundaries).
- `LinearAnimationInstance::advance(seconds)` accumulates fps/speed-scaled time, applies loop/work-area
  wrapping, tracks direction (pingPong). `didLoop`/spilled-time handling matters for trigger/event timing.
- **Keyframes:** `KeyedObject` (per component) → `KeyedProperty` (per property, by Core key) → `KeyFrame`.
  `apply(float mix)` interpolates each property at current time, writing into the component (mix = blend weight).

### 6.6 Data binding / view models — NOT required for MVP

`ViewModel` (schema) / `ViewModelInstance` (values); property types number/string/bool/color/enum/trigger
+ nested view models. `DataBind` connects a VM property to a component property with direction
`ToTarget`/`ToSource`/`TwoWay`/`Once`. **Skip for phases 1–3** — components animate fine without it.

### 6.7 Text, fonts, raster assets, out-of-band loading

**Assets** (`include/rive/assets/`, base `FileAsset`): `ImageAsset` (105), `FontAsset` (141),
`AudioAsset` (406), `ScriptAsset` (486), `LibraryAsset` (501).
- **Embedded (in-band):** bytes in a `FileAssetContents` (type 106) right after the `FileAsset`
  metadata — `bytes` (key 212), `signature` (911), read via `readBytes()`.
- **Out-of-band (referenced):** only metadata serialized. Host supplies a `FileAssetLoader`
  (`file_asset_loader.hpp`) whose `loadContents(FileAsset&, Span<const uint8_t> inBandBytes, Factory*)`
  returns true if it took ownership of decoding; else fall back to in-band bytes.
  Resolution in `FileAssetImporter::resolve()`.
- **Deferred decoding via Factory:** `Factory::decodeImage(bytes)` → `rcp<RenderImage>`,
  `Factory::decodeFont(bytes)` → `rcp<RenderFont>`. **Implement the Factory seam first in Nim.**

**Text** (`include/rive/text/`): `Text` (drawable), `TextValueRun` (styled segment, can bind to VM data),
`TextStyle`. Shaping uses **HarfBuzz** + **SheenBidi**; glyphs become paths drawn through `Renderer`.
**Heavyweight — defer.** A `.riv` without text needs none of it.

---

## 7. Phased scope for the Nim port

### MVP — play a vector animation, no state machine (build first)

1. **Binary loader:** header (`"RIVE"`, major=7, minor, fileId) + ToC (2-bit backing types:
   0=uint/bool, 1=string, 2=float, 3=color) + object/property stream; **skip unknown props via ToC** (mandatory).
2. **Core object registry:** type key → object, property key → setter. At minimum: Backboard, Artboard,
   Node, Shape, Path/PointsPath, vertices (straight/cubic), Ellipse/Rectangle/Triangle, Fill, SolidColor,
   LinearGradient/RadialGradient + GradientStop, TransformComponent, ClippingShape. (Hand-port keys from defs.)
3. **Scene graph + dependency sort:** `Component`/`TransformComponent`/`Drawable`, `ComponentDirt`,
   `addDirt`/`onDirty`, topological `m_DependencyOrder`, `Artboard::updateComponents()`.
4. **LinearAnimation playback:** `KeyedObject`/`KeyedProperty`/`KeyFrame`, hold + linear + cubic-bezier,
   `Loop` modes, fps/duration/work-area, `advanceAndApply()`.
5. **Renderer abstraction:** implement `Renderer` (`save/restore/transform/clipPath/drawPath/
   drawImage/drawImageMesh/modulateOpacity`) + `RenderPath`/`RenderPaint`, `computeAlignment`/`Fit`/`Alignment`.
   Back with boxy/raylib (or a headless stub). Vector-only MVP can skip `drawImage*`.
6. **Factory:** minimal `makeRenderPath`/`makeRenderPaint`; image/font decode can throw "unsupported".

Renders + plays the default artboard's first linear animation for any vector-only `.riv`.

### Incremental phases toward parity

- **Phase 2 — State machines:** inputs (`SMIBool/SMINumber/SMITrigger`), `AnimationState`, transitions/
  conditions, layers, exit time + transition mixing; then blend states (`BlendState1D`, `BlendStateDirect`).
- **Phase 3 — Raster assets:** `ImageAsset`, `FileAssetLoader`, `Factory::decodeImage`, `drawImage`/
  `drawImageMesh`, meshes.
- **Phase 4 — Text:** `Text`/`TextValueRun`/`TextStyle`, `FontAsset`, `Factory::decodeFont`, HarfBuzz +
  SheenBidi shaping, glyph→path. (Largest single chunk.)
- **Phase 5 — Constraints, clipping refinements, nested artboards** (`NestedArtboard`,
  `ArtboardComponentList`), trim paths, dashing.
- **Phase 6 — Data binding, events, audio, scripting** (`ScriptAsset`/Luau, `WITH_RIVE_SCRIPTING` — likely out of scope).

**Dependency footprint:** a headless/core-only Nim port (parse → object tree → advance → emit geometry
against the abstract renderer) needs **zero GPU/C deps**. Text (HarfBuzz/SheenBidi) and raster decoding
(libpng/jpeg/webp) are the heavy native deps — both deferrable (Nim has its own image libs).

---

## 8. Integration targets (this repo's reason for existing)

### boxy (`~/git/boxy`) — OpenGL atlas/quad renderer (Nim, multi-platform)
- 2D GPU renderer on Pixie; OpenGL 4.1 desktop, GLSL ES web/Vita, citro3d 3DS. **No vector/animation/scene-graph today.**
- Atlas of tiled images; `addImage(key, image)` → `drawImage(key, ...)` per frame; transform stack
  (`saveTransform`/`restoreTransform`/`translate`/`rotate`/`scale`), layers (`pushLayer`/`popLayer(blendMode)`),
  effects (`blurEffect`, `dropShadowEffect`), 11 blend modes.
- Backend interface: `src/boxy/backends/backend_interface.nim` (abstract `Backend`).
- ⚠️ **Hard API constraints (verified against `~/git/boxy`):**
  - boxy's **only** public draw primitives are atlas quads (`addImage`/`drawImage`, internal `addQuad`),
    `drawRect`, and layer/effect ops. There is **no public arbitrary-triangle / indexed-mesh API** and
    **no `drawImageMesh` equivalent**. The citro3d backend draws quads only (two triangles each).
  - `enterRawOpenGLMode`/`exitRawOpenGLMode` (the raw-GL escape hatch) is **desktop-only**; on 3DS it is a
    no-op that prints `"enterRawOpenGLMode is not supported on Nintendo 3DS"`.
  - 3DS enforces **single-flush-per-frame** (`"ds3: single-flush-per-frame violated"`).
- **Rive integration shape (revised):**
  - **Desktop:** the "tessellate to triangles" path requires the boney adapter to author raw GL (shaders +
    VBOs) itself, OR a **new boxy backend capability** (a first-class `drawMesh(vertices, uvs, indices, texture)`).
    This is a real sub-project / boxy-side change, **not** a thin adapter. Scope it as its own task.
  - **3DS/Vita baseline:** because there is no triangle path on console, the only currently-viable route is
    **(b) CPU-rasterize Rive frames to a Pixie `Image` → `addImage`**. Treat this as the **console baseline**,
    not a fallback afterthought. It costs GPU vector crispness and per-frame atlas churn — budget for it.
  - Do **not** assume `drawImageMesh` "maps naturally" to boxy — it does not exist there today.
  - Key files: `src/boxy.nim` (main API), `src/boxy/backends/backend_interface.nim`, `examples/basic_windy.nim`.

### clckr (`~/git/birbparty/clckr`) — raylib clicker game (Nim, multi-platform)
- raylib via **naylib** (desktop) + a `raylib_console` subset (3DS/Vita). Bumpy/vmath for geometry.
- **Deliberately backend-agnostic:** `tests/game/test_core_purity.nim` *forbids* importing boxy in the
  portable core. Rive integration must keep the portable core clean and live at the raylib edge.
- Rendering seam: `src/game/render.nim` (`RenderCtx`, `render()`); platform seam: `src/game/platform.nim`,
  `src/game/raylib_api.nim` (a ~7-line re-export shim: `raylib` (naylib) on desktop, `raylib_console` subset
  on 3DS/Vita); deterministic core in `src/game/state.nim`, `frame.nim`, `animation.nim`.
- ⚠️ **Purity constraint (verified):** `tests/game/test_core_purity.nim` is a **fail-closed allowlist** that
  permits only `bumpy`, `vmath`, `std/*`, and the four core modules `frame`/`layout`/`state`/`animation`.
  clckr will import **boney's core, not boney's adapters** — so boney's core must satisfy that allowlist
  verbatim: it may import only `std/*`, math (`vmath`/`bumpy` are allowed), and its own pure modules; it must
  NOT pull in `chroma`/`pixie`/raylib/boxy. Define boney's own equivalent purity allowlist + test.
- **Rive integration shape (revised):** implement the Rive `Renderer` against raylib at the render edge.
  Desktop naylib exposes `rlgl` (`rlBegin`/`rlVertex`/`rlSetTexture`) for triangle submission, but the
  **`raylib_console` 3DS/Vita subset is NOT confirmed to expose rlgl** — clckr's own `render.nim` uses only
  high-level `drawTexture`/`drawRectangle`/`drawText`. So the same "no triangle primitive on console" risk as
  boxy applies here: ground what `raylib_console` actually exposes before committing to an rlgl tessellation
  path, and carry the **CPU-rasterize-to-texture** route as the console plan for clckr too.

### Cross-cutting constraint
Both repos target **3DS + Vita** (tiny RAM/VRAM, GLSL ES 1.00 / PICA200 fixed-function). The Rive core
must stay **renderer-agnostic and dependency-light**; tessellation/triangulation must be cheap; avoid
heavy native deps in the core. This argues strongly for the headless-core + thin-backend split above.

---

## 9. Sources

**Format & core:**
- https://help.rive.app/runtimes/advanced_topics/format · https://rive.app/docs/runtimes/advanced-topic/format
- https://github.com/rive-app/help-center/blob/master/runtimes/advanced_topics/format.md
- https://github.com/rive-app/rive-runtime/blob/main/src/core/binary_reader.cpp
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/runtime_header.hpp
- https://github.com/rive-app/rive-runtime/blob/main/src/file.cpp
- `dev/defs/*.json` — https://github.com/rive-app/rive-runtime/tree/main/dev/defs (and `/animation`)

**Renderer:**
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/renderer.hpp
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/factory.hpp
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/command_path.hpp
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/math/path_types.hpp · `math/raw_path.hpp` · `math/mat2d.hpp`
- https://github.com/rive-app/rive-runtime/blob/main/include/rive/shapes/paint/blend_mode.hpp · `image_sampler.hpp` · `stroke_cap.hpp` · `stroke_join.hpp`
- https://github.com/rive-app/rive-runtime/tree/main/utils (no_op_factory)
- https://rive.app/docs/runtimes/choose-a-renderer · https://rive.app/docs/runtimes/cpp/renderers

**Runtime API / animation / state machine:**
- https://rive.app/docs/runtimes/web/low-level-api-usage · https://rive.app/docs/runtimes/state-machines
- https://deepwiki.com/rive-app/rive-runtime (+ /4-animation-system, /3.3-asset-loading-system, /6-text-system, /7-data-binding-system)

**Licensing / ecosystem:**
- https://github.com/rive-app/rive-runtime/blob/main/LICENSE
- https://github.com/rive-app/rive-flutter · https://github.com/rive-app/rive-rs · https://github.com/rive-app/rive-sharp
- https://github.com/rive-app/rive-code-generator-wip · https://github.com/rive-app/awesome-rive

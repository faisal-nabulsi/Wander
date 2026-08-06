# SimStubs — running Wander in the iOS Simulator

`Wander/idevice/libidevice_ffi.a` is a vendored Rust static archive with a **device-only**
slice (`lipo -info` → `Non-fat file: architecture: arm64`, platform iOS). Every Swift file in
the app compiles fine for `-sdk iphonesimulator`; only the **link** step failed:

```
ld: building for 'iOS-simulator', but linking in object file
    (.../Wander/idevice/libidevice_ffi.a[2](...rcgu.o)) built for 'iOS'
```

This folder holds a simulator-arch stand-in so the UI can be run and screenshotted without a
device, a cert, or a physical install.

## Run it

```sh
cd /Users/faisalnabulsi/Developer/wander-ios

xcodebuild -project Wander.xcodeproj -scheme Wander \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcrun simctl boot 'iPhone 17 Pro'   # any booted simulator works

# REQUIRED, do not skip -- see "Blank white screen" below.
xcrun simctl privacy booted grant location-always com.stik.stikdebug
xcrun simctl location booted set 37.7749,-122.4194

xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/Wander-*/Build/Products/Debug-iphonesimulator/Wander.app
xcrun simctl launch booted com.stik.stikdebug
```

### Blank white screen on launch — not a stub problem

A fresh simulator has **no location fix at all**, which is a state a real phone never
reaches. The map-backed root view stays empty while `CLLocationManager` waits, and the log
shows `onLocationRequestTimeout` → `locationManager:didFailWithError:`. The process is
alive and the main thread is idle in its run loop — it is not a crash, a hang, or a
missing symbol.

Setting a location (the two `simctl` lines above) renders the UI immediately. If you are
ever staring at a white screen, check that first before suspecting the stubs.

## What is in here

| File | Purpose |
| --- | --- |
| `needed_symbols.txt` | The 80 FFI symbols the app's own object files actually reference. |
| `generate_stubs.py` | Parses `Wander/idevice/idevice.h` and emits C stubs for those symbols. |
| `idevice/idevice_ffi_sim_stubs.c` | Generated. Do not hand-edit. |
| `idevice/libidevice_ffi.a` | Built artifact: fat `arm64` + `x86_64` **simulator** archive. |
| `build_stub_lib.sh` | Regenerates the `.c` and rebuilds the `.a`. |

Every stub fails honestly rather than pretending to succeed:

* functions returning `IdeviceFfiError *` return a non-NULL, statically allocated error whose
  message says the library is stubbed out — so the app's normal error paths run;
* out-parameters are zeroed first, so no caller ever reads uninitialised memory;
* `*_free` functions never write through their arguments (they are handed caller-owned memory);
* `idevice_error_free` is a no-op, which is why the shared error object is safe to "free".

Result in the simulator: the Teleport / Joystick / Route tabs, their panels, maps, search,
geocoding and network features all work. Anything that needs the tunnel — teleport, joystick
movement, route playback, pairing, DDI mount — declines instead of spoofing. Verified: no crash.

## How it is wired up (Wander target, Debug + Release)

Three settings, all scoped so the **device build is untouched**:

1. The synchronized `Wander` folder no longer auto-links the archive —
   `membershipExceptions` gained `idevice/libidevice_ffi.a`. Xcode's auto-link also injected
   `-L .../Wander/idevice` *ahead of* any setting we control, which is why simply adding a
   search path was not enough. (`EXCLUDED_SOURCE_FILE_NAMES` does not affect the auto-link —
   it was tried and does nothing here.)
2. `OTHER_LDFLAGS = "$(inherited) -lidevice_ffi"` restores that link explicitly, for both SDKs.
3. `LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = ("$(PROJECT_DIR)/SimStubs/idevice", "$(inherited)")`.
   **Order matters.** `$(inherited)` inside an SDK-conditional resolves to the unconditional
   value, which still contains `Wander/idevice`; SimStubs must come first or `-lidevice_ffi`
   resolves to the device archive again.

Device builds resolve `-lidevice_ffi` from the unchanged `Wander/idevice` and never see this
folder. Verified from a clean derived-data path: the device binary contains the real Rust code
(`nm` shows `T _location_simulation_set`, `T _tunnel_create_rppairing`) and zero stub strings;
the simulator binary contains the stub marker string.

## When you need to touch this

Symptom: the simulator build fails with `Undefined symbol: _some_new_ffi_function`.

Cause: Swift code started calling an FFI entry point that has no stub yet.

Fix:

```sh
# add the missing symbol name to needed_symbols.txt, then
bash SimStubs/build_stub_lib.sh
```

To regenerate the list from scratch, link once for the simulator and diff the undefined
symbols in `.../Build/Intermediates.noindex/Wander.build/Debug-iphonesimulator/Wander.build/Objects-normal/arm64/*.o`
against `nm -gU Wander/idevice/libidevice_ffi.a`.

Not covered: the `WanderTests` / `WanderUITests` targets still point only at `Wander/idevice`,
so simulator **unit tests** would hit the same link error. Give those targets the same
`LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]` if you ever need them.

# Notational Velocity

Native macOS application, built with `Notation.xcodeproj` and the `Notation` scheme.

## Repository layout

- `Sources/Application`: application lifecycle, commands and global preferences.
- `Sources/Notes/Model`: notes, labels, identities and archive metadata.
- `Sources/Notes/Storage`: local persistence, file monitoring, journals and database preferences. The directory/file manager categories stay beside `NotationController`.
- `Sources/Notes/Storage/Crypto`: encryption and key derivation; historical codecs are under `Legacy`.
- `Sources/Editor`, `NoteList`, `Preferences`, `Interchange` and `Integrations`: their corresponding application subsystems.
- `Sources/Support`: shared Foundation and AppKit helpers.
- `Vendor`: imported hotkey, external-editor and split-view code, with its existing notices.
- `Resources`: images, scripting definitions and the active `en`, `de`, `fr`, `it`, `pt` and `zh_CN` localisations. Xcode localisation variant groups preserve bundle resource names.
- `Configuration`: the application Info.plist and prefix header.
- `Tests`: mirrors source subsystem ownership, including compatibility checks under `Notes/Model`, `Notes/Storage/Crypto` and `Preferences`; shared path helpers live in `Support`, fixed inputs in `Fixtures`, and project generators in `Tools`.
- `script`: build, launch and test entry points. Generated output stays under ignored `build`.

Physical source directories match Xcode groups. Target build phases explicitly select compiled files; adding a file to a folder does not add it to a target. Preserve archived Objective-C class names when organising files.

## Build and verification

```sh
make debug
make release
make test
make clean
```

`make debug` builds the Development configuration; `make release` builds Deployment. Both put the runnable app at `build/Notational Velocity.app`, replacing the previous build. The executable is inside the bundle at `Contents/MacOS/Notational Velocity`; Xcode intermediates stay under `build/app`. App builds disable code signing by default; use `make release CODE_SIGNING_ALLOWED=YES` to enable the project's signing settings. Running `make` without a target builds debug.

`make test` runs the compatibility and native integration unit suites, including localized resource loading, followed by the build-policy checks. `make clean` removes the entire `build` directory, including app bundles, intermediates, generated test notes, logs and reports. Everything under `build` is disposable; keep durable notes and documentation outside it. Targets run serially even when `make -j` is used because both app configurations share their build directory.

`./script/build_and_run.sh` builds and opens the development app with isolated preferences and notes. Its `--verify` option runs the full GUI acceptance suite, including TextEdit, full-screen transitions and quit/reopen checks, and requires an unlocked desktop. Use the build and test commands above for routine source and folder changes.

`./script/test_external_editor.sh` checks only the external-editor lifecycle. It opens a generated document in a separate background TextEdit instance with document restoration disabled, closes that instance, and removes its temporary document. Existing TextEdit instances are preserved. The full acceptance suite uses the same ownership checks, closes the editor in `finally`, and retains an exit-trap cleanup fallback for errors, timeouts and interrupts. Runner cleanup cancels future launches and makes pending launches close their returned instance. Only the PID, launch date and bundle identity recorded for the test instance permit termination.

To regenerate the test projects after changing source membership or paths:

```sh
/usr/bin/python3 Tests/Tools/bootstrap_test_project.py
/usr/bin/python3 Tests/Tools/create_integration_project.py
```

The compatibility project uses selected production files and extracted units. The integration project compiles the application's actual source list, excluding `main.m`. Both retain explicit source membership and mirror the relevant physical directories in Xcode. Test fixtures remain shared across subsystems; see [their provenance](Tests/Fixtures/README.md).

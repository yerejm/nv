# Notational Velocity

Native macOS application, built with `Notation.xcodeproj` and the `Notation` scheme.

## Interface and editing options

- Switch between stacked and widescreen panes from the View menu. Collapse or expand the note list and search field with ⌥⌘N or a divider double-click.
- Display preferences offer centered text width, System/Black & White/Low Contrast/Custom colors, alternating rows, separators and optional themed overlay scrollbars. Full screen caps text width and restores the previous layout on exit.
- Writing preferences offer character pairing, right-to-left editing, smart quotes, smart dashes and automatic spacing. ⌘Return inserts a paragraph below; ⇧⌘Return inserts one above. The existing Command-Return action on links still opens the link.
- The View menu can show word count permanently; holding Option shows it temporarily. Tagging multiple selected notes edits their shared tags while preserving tags unique to each note.
- Find uses the system-wide find text shared with other apps and stays open when switching notes; with no note selected, Find Next and Find Previous select one first. Native spelling and substitution settings persist.
- Desktop preferences control the Dock and menu bar icons. Click the menu bar icon to show or hide the note window; right-click for commands. Hiding the Dock enables the menu bar icon, and removing that icon restores the Dock.
- Export format and filename are independent: filenames can use a custom extension or no extension, and changing the format only updates an extension that belongs to an export format. Installed Sublime Text 2, Byword and iA Writer are included in external editor discovery.
- Notes in an encrypted database open in an ODB external editor from a RAM disk that NV creates for the first such edit and detaches when the last editor closes, the database changes or NV quits; notes larger than 8 MB are refused. The editor's own autosave, backup or session-restore copies are kept wherever the editor stores them and are not protected by this. Unencrypted notes use a private temporary folder.

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
make deprecations
make analyze
make clean
```

`make debug` builds the Development configuration; `make release` builds Deployment. Both put the runnable app at `build/Notational Velocity.app`, replacing the previous build. The executable is inside the bundle at `Contents/MacOS/Notational Velocity`; Xcode intermediates stay under `build/app`. App builds disable code signing by default; use `make release CODE_SIGNING_ALLOWED=YES` to enable the project's signing settings. Running `make` without a target builds debug.

`make test` runs the compatibility and native integration unit suites, including localized resource loading, followed by the build-policy checks. `make deprecations` rebuilds the app with Apple's soft-deprecated (`API_TO_BE_DEPRECATED`) APIs treated as deprecated and fails on any use outside the allowlist in `script/check_deprecations.sh`. `make analyze` runs the Clang static analyzer over a clean Development build and fails on any finding. `make clean` removes the entire `build` directory, including app bundles, intermediates, generated test notes, logs and reports. Everything under `build` is disposable; keep durable notes and documentation outside it. Targets run serially even when `make -j` is used because both app configurations share their build directory.

`./script/build_and_run.sh` builds and opens the development app with isolated preferences and notes. Its `--verify` option runs the full GUI acceptance suite, including TextEdit, full-screen transitions and quit/reopen checks, and requires an unlocked desktop. Use the build and test commands above for routine source and folder changes.

The app logs to the unified system log under the subsystem `net.notational.velocity`, with one category per area (`storage`, `notes`, `editor`, `import-export` and so on). `./script/build_and_run.sh --logs` opens the development app and streams its messages, including debug messages; otherwise use `log stream --info --debug --predicate 'subsystem == "net.notational.velocity"'`. Note text, titles, file names and paths are logged as private values and appear as `<private>`. Processes started directly from a shell, such as the unit-test host, have been observed to record them in full.

`./script/test_external_editor.sh` checks only the external-editor lifecycle. It opens a generated document in a separate background TextEdit instance with document restoration disabled, closes that instance, and removes its temporary document. Existing TextEdit instances are preserved. The full acceptance suite uses the same ownership checks, closes the editor in `finally`, and retains an exit-trap cleanup fallback for errors, timeouts and interrupts. Runner cleanup cancels future launches and makes pending launches close their returned instance. Only the PID, launch date and bundle identity recorded for the test instance permit termination.

To regenerate the test projects after changing source membership or paths:

```sh
/usr/bin/python3 Tests/Tools/bootstrap_test_project.py
/usr/bin/python3 Tests/Tools/create_integration_project.py
```

The compatibility project uses selected production files and extracted units. The integration project compiles the application's actual source list, excluding `main.m`. Both retain explicit source membership and mirror the relevant physical directories in Xcode. Test fixtures remain shared across subsystems; see [their provenance](Tests/Fixtures/README.md).

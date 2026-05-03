These issues are related to the Flutter-based UI (see `packages/kmdb_ui`).

Recent work related to these issues:

- plans/completed/plan_flutter_ui.md

Please review each section below with the developer to determine a possible fix.
Note the fix details in the appropriate sub-section and then offer to implement
the fix.

## Issue Summary

| Issue | Status | Files changed |
|-------|--------|---------------|
| Error when attempting to find a Document by ID | Fixed | `lib/database_columns.dart` |
| App name | Fixed | `lib/main.dart`, `macos/Runner/Info.plist` |
| Database-level functionality | Fixed | `lib/database_columns.dart` |
| Tab bar | Fixed | `macos/Runner/MainFlutterWindow.swift` |
| User configuration | Resolved (no fix needed) | — |
| Can't close Collections/Documents columns | Fixed | `lib/database_columns.dart`, `lib/app_provider.dart` |
| UI can be sized too small | Fixed | `macos/Runner/MainFlutterWindow.swift` |
| Right-click on a Database opens a dialog | Fixed | `lib/database_columns.dart` |
| Creating an index | Fixed | `lib/app_provider.dart`, `lib/secondary_index_sheet.dart` |
| Dumping a database doesn't write a file | Fixed | `lib/database_info_sheet.dart` |
| Can't cancel the database restore warning dialog | Fixed | `lib/import_export_dialogs.dart` |

# Error when attempting to find a Document by ID

Status: Fixed

I'm running the Flutter app (`kmdb_ui`) and I get try to find a Document by ID.
I provide the ID ('019db411398374d0a4c7e9880c4a5110') and then click "Find". The
UI goes to an error screen.

I see this in the terminal:

```
Another exception was thrown: A TextEditingController was used after being disposed.
Another exception was thrown: 'package:flutter/src/widgets/framework.dart': Failed assertion: line 6268 pos 12: '_dependents.isEmpty': is not true.
Another exception was thrown: Tried to build dirty widget in the wrong build scope.
```

## Fix

Inside the "Find" button handler, `appProvider.selectDocument(doc)` called
`notifyListeners()` while the dialog was still open. This scheduled a rebuild of
`_DocumentContentColumnState` (and other AppProvider watchers) mid-dialog,
causing in-flight rebuilds for widgets that were being dismissed simultaneously.

Fix: In `database_columns.dart` `_showFindByIdDialog`, reverse the order —
call `Navigator.pop(context)` _before_ `appProvider.selectDocument(doc)` in
both the `onSubmitted` and `onPressed` handlers so the dialog is fully removed
before the notification fires.

# App name

Status: Fixed

The title bar currently has `kmdb_ui` as the application name. Please change
this to `KMDB`.

## Fix

The macOS window/dock name comes from `CFBundleName` in `macos/Runner/Info.plist`,
which resolved to `$(PRODUCT_NAME)` = `$(TARGET_NAME)` = `kmdb_ui`.

Fix: Hardcode `CFBundleName` to `KMDB` in `Info.plist`, and update
`MaterialApp(title:)` and the `PlatformMenu(label:)` in `main.dart` to `KMDB`
to match.

# Database-level functionality

Status: Fixed

The "Sync & remotes" and "Database Info and Maintenance" icons are placed at the
top of the database listing. It's not overly obvious that the functions relate
to the currently-selected database. Consider providing these functions next to
each database name in the listing (relating the functionality to that database,
of course).

## Fix

Move the Sync and Info `IconButton`s from the `DatabaseHistoryColumn` header
into each database `ListTile` as trailing action buttons. The buttons are only
shown for the currently selected database, and the actions operate on that
specific database path.

# Tab bar

Status: Fixed

Under the "View" menu, there's a "Show/Hide Tab" but there's only ever one tab.
I'd suggest we remove this feature but let me know what you think.

## Fix

The "Show/Hide Tab" item is injected by macOS automatically when
`NSWindow.allowsAutomaticWindowTabbing` is `true` (the default). Flutter's
`PlatformMenuBar` does not suppress it.

Fix: In `macos/Runner/MainFlutterWindow.swift`, add
`NSWindow.allowsAutomaticWindowTabbing = false` in `awakeFromNib()` before
the `super.awakeFromNib()` call.

# User configuration

Status: Resolved (no fix needed)

Does the UI store the user configuration? If so, where?

If not, perhaps we need to set up a plan for this. Basic settings such as
dark/light mode would be a useful start.

## Fix

Theme mode is already persisted via `SharedPreferences` (macOS: UserDefaults),
using the key `theme_mode` in `AppProvider`. The View > Mode menu (Light / Dark
/ System) is the current UI for it — the selection survives app restarts.

If additional preferences are needed in the future (default column widths,
font size, etc.), a small plan can be created to extend the existing
SharedPreferences storage.

# Can't close Collections listing or Collection Documents columns

Status: Fixed

When the UI is narrow and only 1 column is displayed, it's not possible to close
the Collections listing or Collection Documents columns and get back to the
database listing.

## Fix

The narrow layout in `_buildNarrowLayout` had no back navigation. Each column's
`AppBar` now shows a leading back `IconButton` when the layout is narrow,
calling the appropriate `appProvider.select*(null)` method to step back one
level.

# UI can be sized too small

Status: Fixed

The UI width and height can be shrunk to a size that causes RenderFlex
overflows. Perhaps we should have a minimum size for the desktop UI?

## Fix

Set a minimum window size in `macos/Runner/MainFlutterWindow.swift` by adding
`self.minSize = NSSize(width: 700, height: 500)` in `awakeFromNib()`.

# Right-click on a Database opens a dialog

Status: Fixed

Right-clicking on a database opens a small dialog that displays the path of the
DB. We likely no longer need this now that we have the Database-level
functionality in the Databases column.

## Fix

Remove the `GestureDetector(onSecondaryTap: ...)` wrapper and its `showDialog`
call from the database `ListTile` in `database_columns.dart`. The path
information is accessible via the Database Info sheet.

# Creating an index

Status: Fixed

I tried to create a secondary index on a collection. In the dialog box I set
'title' as the field and clicked "Create". An error was raised - I've put the
terminal output below:

```
flutter: Could not persist secondary index to config: FormatException: Failed to read config file "/Users/gonk/tmp/demodb/local/config.json": Cannot open file
flutter: Error reopening database at /Users/gonk/tmp/demodb: StorageException(/Users/gonk/tmp/demodb/LOCK): Cannot open file
flutter: #0      StorageAdapterNative.acquireLock (package:kmdb/src/engine/platform/storage_adapter_native.dart:192:7)
flutter: <asynchronous suspension>
flutter: #1      CrashRecovery.open (package:kmdb/src/engine/kvstore/crash_recovery.dart:72:5)
flutter: <asynchronous suspension>
flutter: #2      KvStoreImpl.open (package:kmdb/src/engine/kvstore/kv_store_impl.dart:102:38)
flutter: <asynchronous suspension>
flutter: #3      KmdbDatabase.open (package:kmdb/src/query/kmdb_database.dart:259:33)
flutter: <asynchronous suspension>
flutter: #4      AppProvider._reopenDatabase (package:kmdb_ui/app_provider.dart:967:19)
flutter: <asynchronous suspension>
flutter: #5      AppProvider.createSecondaryIndex (package:kmdb_ui/app_provider.dart:470:5)
flutter: <asynchronous suspension>
flutter: #6      AppProvider.runBusy (package:kmdb_ui/app_provider.dart:1047:14)
flutter: <asynchronous suspension>
flutter: #7      _SecondaryIndexContent._submit (package:kmdb_ui/secondary_index_sheet.dart:232:7)
flutter: <asynchronous suspension>
```

Two bugs:

1. Config file not found: `KmdbConfig.forDatabase()` fails for new databases
   that have no `local/config.json` yet (no remotes have been added). The error
   is caught and printed — the in-memory index definition is still applied.

2. LOCK error (the real bug): `_reopenDatabase()` called `_closeCurrentDatabase()`
   which invoked macOS `stopAccessing`, releasing the security-scoped bookmark for
   the database directory. It then called `KmdbDatabase.open()` without first
   calling `startAccessing` again. The database directory was no longer
   sandbox-accessible, so acquiring the LOCK file failed. Compare with
   `selectDatabase()` which correctly calls `startAccessing` before `open()`.

   Additionally, the same pattern in `_submit` (in `secondary_index_sheet.dart`)
   where `runBusy` calls `notifyListeners()` while the dialog was still open
   caused the secondary TextEditingController / wrong-build-scope errors.

## Fix

1. In `app_provider.dart` `_reopenDatabase()`, add a `startAccessing` call
   (mirroring `selectDatabase()`) after `_closeCurrentDatabase()` and before
   `KmdbDatabase.open()`.

2. In `secondary_index_sheet.dart` `_submit()`, call `Navigator.pop(context)`
   synchronously before the `await appProvider.runBusy(...)` call so the dialog
   is gone before any `notifyListeners()` fires. Errors from the async operation
   are surfaced via `ScaffoldMessenger` instead of in-dialog error text.

# Dumping a database doesn't seem to write out a file

Status: Fixed

No file appears to be written when a database is dumped.

## Fix

The Dump button called `Navigator.pop(context)` to close the info sheet, then
immediately called `showDumpDialog(context, appProvider)` with the same
now-unmounted context. By the time `FilePicker.saveFile()` returned,
`context.mounted` was `false`, so the early-exit guard fired and nothing was
written.

Fix: Remove the pre-emptive `Navigator.pop(context)` from the Dump and Restore
button callbacks in `database_info_sheet.dart`. Instead, await the dialog
function and close the sheet afterwards:
`await showDumpDialog(context, appProvider); if (context.mounted) Navigator.pop(context)`.

# Can't cancel the database restore warning dialog

Status: Fixed

When selecting the Restore function for a database, I am unable to Cancel the
warning dialog - though I can click off the dialog and it closes. Error message
is below:

```
Another exception was thrown: Null check operator used on a null value
```

## Fix

The `builder` in `showRestoreDialog` discarded the dialog's context
(`builder: (_) => ...`) and used the outer `context` (from the already-popped
bottom sheet) for `Navigator.pop(context, false/true)`. Since that context was
from a dismissed widget, `Navigator.of(context)` returned null, causing the
null-check crash.

Fix: Rename `_` to `dialogContext` in the builder and use
`Navigator.pop(dialogContext, false/true)` for both Cancel and Continue buttons
in `import_export_dialogs.dart`.

# KMDB Browser

A sleek, modern Flutter desktop application for browsing and managing
[KMDB](https://github.com/bettongia/kmdb) database stores.

The KMDB Browser provides a powerful, multi-column interface designed for deep
exploration of KMDB databases, featuring a "master-detail-detail-detail" layout
familiar to macOS users.

![KMDB Browser Concept](https://images.unsplash.com/photo-1558494949-ef010cbdcc31?auto=format&fit=crop&q=80&w=2000)

## Features

- **Multi-Column Navigation**: A resizable, four-column layout for seamless
  navigation:
  - **Databases**: Manage your recently opened and pinned KMDB stores.
  - **Collections**: Browse all collections within a database with live document
    counts.
  - **Documents**: Filter and search through documents in a specific collection.
  - **Details**: Inspect full JSON document details with syntax highlighting.
- **Database Operations**: Create new KMDB stores or open existing ones from
  your filesystem.
- **Data Management**: Add new collections and documents directly from the UI.
- **JSON Exploration**: Rich, collapsible JSON view for complex documents with
  one-click copy-to-clipboard.
- **Native Experience**: Full support for macOS menu bars, keyboard shortcuts
  (⌘N, ⌘O), and system theme synchronization.
- **Aesthetic Design**: Clean, modern UI built with Inter typography and a
  curated color palette supporting both Light and Dark modes.

## Technical Stack

- **Framework**: [Flutter](https://flutter.dev)
- **State Management**: [Provider](https://pub.dev/packages/provider)
- **Persistence**: `shared_preferences` for database history and session state.
- **Typography**:
  [Google Fonts (Inter)](https://fonts.google.com/specimen/Inter)
- **Core Engine**: `kmdb` (Dart FFI bindings to the KMDB engine)

## Getting Started

### Prerequisites

- Flutter SDK (latest stable)
- KMDB engine dependencies (ensure `kmdb` package is properly configured for
  your platform)

### Running the App

```bash
# From the packages/kmdb_ui directory
flutter run -d macos
```

## Project Structure

- `lib/main.dart`: App entry point and layout orchestration.
- `lib/database_columns.dart`: Implementation of the multi-column browsing
  interface.
- `lib/database_provider.dart`: Global state management for database
  connections.
- `lib/collection_provider.dart`: State management for the currently selected
  collection.
- `lib/*_dialog.dart`: Various modals for creating and adding data.

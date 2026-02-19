# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a thin wrapper around the `matrix` Dart SDK that adds Sliding Sync (MSC4186) support. The library should leverage existing Matrix SDK code as much as possible - minimize custom implementations and prefer delegating to SDK methods for room state management, event handling, database operations, and protocol types.

**Design Principle**: When implementing features, always check if the Matrix SDK already provides the functionality before writing custom code.

## Commit Style

Use single-line conventional commits: `type: description`

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

## Build & Development Commands

```bash
# Get dependencies (run from project root)
dart pub get

# Run analysis
dart analyze

# Format code
dart format .

# Run example app (Flutter)
cd example && flutter run
```

## Architecture

### Core Components

**SlidingSync** (`lib/src/sliding_sync.dart`)
- Main controller managing the sync loop, position tracking, and response processing
- Uses builder pattern for configuration: `SlidingSync.builder(id: 'main', client: client)`
- Room subscriptions are sent on every request (MSC4186 has no server-side sticky state)
- Handles M_UNKNOWN_POS errors by resetting session and continuing
- Caches position and list state to database for session persistence

**SlidingSyncList** (`lib/src/sliding_sync_list.dart`)
- Manages individual room lists with different sync modes
- Factory constructors for common patterns: `allRoomsMinimal()`, `activeRooms()`, `space()`
- Applies list operations (SYNC, INSERT, DELETE, INVALIDATE) from server responses
- Tracks loading state: notLoaded → preloaded → partiallyLoaded → fullyLoaded

**SlidingSyncOnlyClient** (`lib/src/sliding_sync_only_client.dart`)
- Custom Matrix `Client` subclass that disables traditional sync
- Override `sync()` to return empty `SyncUpdate`, preventing SDK from making regular sync requests
- Use this when you want sliding sync to be the only sync mechanism

### Sync Modes (SyncMode enum)

- **selective**: Client specifies exact ranges to fetch
- **paging**: Sequential pagination (0-19 → 20-39 → 40-59...)
- **growing**: Expanding window from start (0-19 → 0-39 → 0-59...)

### Models

- **SlidingSyncExtensions**: Enable protocol extensions (toDevice, e2ee, accountData, receipts, typing, presence)
- **RequiredStateRequest**: Specify which room state events to include (minimal vs full)
- **SlidingRoomFilter**: Filter rooms by type, DM status, encryption, spaces, tags

### Integration with matrix-dart-sdk

This library is a wrapper - always prefer Matrix SDK methods over custom implementations:
- API requests: `client.slidingSync()`
- Room state: `room.setState()`, `client.handleSync()`
- Persistence: `client.database.storeAccountData()`, `client.database.storeRoomUpdate()`
- Events: `client.onTimelineEvent`, `client.onToDeviceEvent`, `client.onSync`
- Types: Use SDK types (`MatrixEvent`, `Room`, `BasicEvent`, `StrippedStateEvent`, etc.)

## Key Implementation Details

- Timeline events arrive newest-first from the server
- The library tracks `_latestEventIds` per room to detect new messages (server's numLive is unreliable)
- `_emittedEventIds` set prevents duplicate event processing
- `_initializedRooms` set tracks which rooms have been seen to handle repeated `initial=true` flags
- Position token changes on every response even without content changes - always save after processing

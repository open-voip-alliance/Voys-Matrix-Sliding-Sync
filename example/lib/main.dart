// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:voys_matrix_sliding_sync/voys_matrix_sliding_sync.dart';
import 'package:voys_matrix_sliding_sync_example/logging_http_client.dart';

Future<void> _loadEnv() async {
  final env = Platform.environment;
  _LoginPageState._lastUsername = env['MATRIX_USER'] ?? '';
  _LoginPageState._lastPassword = env['MATRIX_PASS'] ?? '';
  _LoginPageState._lastToken = env['VG_API'] ?? '';
}

// Matches the real event type/state key/content shape used by the
// production Voys conversations app (co.voys.assigned_to).
const String assignedToEventType = 'co.voys.assigned_to';
const String assignedToStateKey = 'true';
// One `co.voys.responded` state event per responder, keyed by the
// responder's identifier (same identifier namespace as `assignedTo`).
const String respondedEventType = 'co.voys.responded';
const List<String> assignableUsers = ['foo', 'baz'];

String? getAssignedTo(Room room) =>
    room
            .getState(assignedToEventType, assignedToStateKey)
            ?.content['assigned_to']
        as String?;

Set<String> getResponded(Room room) =>
    room.states[respondedEventType]?.keys.toSet() ?? const {};

/// Preview text for the room list's last-message line. `co.voys.assigned_to`
/// is included in the sliding sync preview event types (see `_initSync`) so
/// reassignment-only rooms still sort by recency, but it has no `body` field,
/// so the SDK's generic `Event.body` would otherwise show
/// 'Unknown message format of type "co.voys.assigned_to"'.
String lastEventPreview(Event? event) {
  if (event == null) return 'No messages';
  if (event.type == assignedToEventType) {
    final assignedTo = event.content['assigned_to'] as String?;
    return assignedTo == null
        ? 'Room unassigned'
        : 'Room assigned to $assignedTo';
  }
  return event.body;
}

/// Builds the server-side filter for the room list's `assigned_to`/`responded`/
/// `involving`/`unread` selections (see [_allFilterValue]/[_unassignedFilterValue]
/// in [_RoomListPageState]).
SlidingRoomFilter? roomListFilterFor({
  required String assignedToFilter,
  required String respondedFilter,
  required String involvingFilter,
  required bool unreadFilter,
}) {
  List<String?>? assignedTo;
  if (assignedToFilter == _unassignedFilterValue) {
    assignedTo = const [null];
  } else if (assignedToFilter != _allFilterValue) {
    assignedTo = [assignedToFilter];
  }

  final responded = respondedFilter == _allFilterValue
      ? null
      : [respondedFilter];

  final involving = involvingFilter == _allFilterValue
      ? null
      : [involvingFilter];

  final unread = unreadFilter ? true : null;

  if (assignedTo == null &&
      responded == null &&
      involving == null &&
      unread == null) {
    return null;
  }
  return SlidingRoomFilter(
    assignedTo: assignedTo,
    responded: responded,
    involving: involving,
    unread: unread,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadEnv();
  runApp(ProviderScope(child: MatrixExampleChat()));
}

final clientProvider = FutureProvider((_) async {
  final client = SlidingSyncOnlyClient(
    'Matrix Example Chat',
    database: await MatrixSdkDatabase.init(
      'my_name',
      database: await sqlite.openDatabase('database.sqlite'),
    ),
    enableDehydratedDevices: false,
    httpClient: createLoggingHttpClient(),
  );

  // Disable background sync to prevent sync loop
  client.backgroundSync = false;

  // Order `client.rooms` purely by recency, same as the production
  // Voys conversations app -- `latestEventReceivedTime` falls back to the
  // room's creation time (or now, for invites) when there's no cached
  // `lastEvent` yet, so rooms never get stranded with a null sort key.
  client.setCustomRoomSorter(
    (a, b) => b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
  );

  // Initialize - our custom client will intercept any sync() calls and return empty responses
  await client.init(
    waitForFirstSync: false,
    waitUntilLoadCompletedLoaded: false,
  );

  return client;
});

class MatrixExampleChat extends ConsumerWidget {
  const MatrixExampleChat({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);

    return MaterialApp(
      title: 'Matrix Example Chat',
      debugShowCheckedModeBanner: false,
      home: client.when(
        data: (Client client) =>
            client.isLogged() ? const RoomListPage() : const LoginPage(),
        error: (Object error, StackTrace stackTrace) => Text(error.toString()),
        loading: () => Text('loading'),
      ),
    );
  }
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  // Store last entered values to persist across widget recreations
  static String _lastHomeserver = 'https://matrix.org';
  static String _lastUsername = '';
  static String _lastPassword = '';
  static String _lastToken = '';
  static bool _lastUseTokenAuth = false;

  late final TextEditingController _homeserverTextField = TextEditingController(
    text: _lastHomeserver,
  );
  late final TextEditingController _usernameTextField = TextEditingController(
    text: _lastUsername,
  );
  late final TextEditingController _passwordTextField = TextEditingController(
    text: _lastPassword,
  );
  late final TextEditingController _tokenTextField = TextEditingController(
    text: _lastToken,
  );

  bool _loading = false;
  late bool _useTokenAuth = _lastUseTokenAuth;

  void _login() async {
    if (_loading) return;

    setState(() {
      _loading = true;
    });

    try {
      final client = await ref.read(clientProvider.future);
      await client.checkHomeserver(Uri.parse(_homeserverTextField.text.trim()));

      if (_useTokenAuth) {
        await client.login(
          'nl.voys.single_user',
          token: _tokenTextField.text.trim(),
          identifier: AuthenticationUserIdentifier(user: 'a user'),
        );
      } else {
        await client.login(
          LoginType.mLoginPassword,
          password: _passwordTextField.text,
          identifier: AuthenticationUserIdentifier(
            user: _usernameTextField.text,
          ),
        );
      }

      // Save the current values before navigating away
      _saveValues();

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const RoomListPage()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        if (kDebugMode) print(e);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
      setState(() {
        _loading = false;
      });
    }
  }

  void _clearDatabase() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(clientProvider).value;
      await client?.dispose();
      final dbPath = await sqlite.getDatabasesPath();
      final path = '$dbPath/database.sqlite';
      await sqlite.deleteDatabase(path);
      ref.invalidate(clientProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Database cleared')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error clearing database: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _saveValues() {
    _lastHomeserver = _homeserverTextField.text;
    _lastUsername = _usernameTextField.text;
    _lastPassword = _passwordTextField.text;
    _lastToken = _tokenTextField.text;
    _lastUseTokenAuth = _useTokenAuth;
  }

  @override
  void dispose() {
    _saveValues();
    _homeserverTextField.dispose();
    _usernameTextField.dispose();
    _passwordTextField.dispose();
    _tokenTextField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _homeserverTextField,
              readOnly: _loading,
              autocorrect: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Homeserver',
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Use VG User Token Authentication'),
              value: _useTokenAuth,
              onChanged: _loading
                  ? null
                  : (value) {
                      setState(() {
                        _useTokenAuth = value;
                        if (value) {
                          _homeserverTextField.text =
                              'https://matrix.eu-production.holodeck.voys.nl';
                        } else {
                          _homeserverTextField.text = 'https://matrix.org';
                        }
                      });
                    },
            ),
            const SizedBox(height: 16),
            if (_useTokenAuth)
              TextField(
                controller: _tokenTextField,
                readOnly: _loading,
                autocorrect: false,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Token',
                ),
                onSubmitted: (_) => _login(),
              )
            else ...[
              TextField(
                controller: _usernameTextField,
                readOnly: _loading,
                autocorrect: false,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Username',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordTextField,
                readOnly: _loading,
                autocorrect: false,
                obscureText: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Password',
                ),
                onSubmitted: (_) => _login(),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _login,
                child: _loading
                    ? const LinearProgressIndicator()
                    : const Text('Login'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _loading ? null : _clearDatabase,
                child: const Text('Clear Database'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RoomListPage extends ConsumerStatefulWidget {
  const RoomListPage({super.key});

  @override
  _RoomListPageState createState() => _RoomListPageState();
}

// PopupMenuButton treats a selected item's `value` of `null` as "menu
// dismissed" (calls onCanceled, not onSelected), so a real `null` can
// never be a selectable value -- sentinel strings stand in for it.
const String _allFilterValue = ' all';
const String _unassignedFilterValue = ' unassigned';
const String _unassignValue = ' unassign';

class _RoomListPageState extends ConsumerState<RoomListPage> {
  SlidingSync? _slidingSync;
  bool _isInitializing = true;
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;
  StreamSubscription? _timelineSubscription;
  String _filterAssignedTo = _allFilterValue;
  String _filterResponded = _allFilterValue;
  String _filterInvolving = _allFilterValue;
  bool _filterUnread = false;
  bool _sortOldestFirst = false;

  @override
  void initState() {
    super.initState();
    _initSlidingSync();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final list = _slidingSync?.list;

    if (list == null ||
        list.isFullyLoaded ||
        list.state == SlidingSyncListLoadingState.preloaded) {
      return;
    }

    // Don't trigger if already loading
    if (_isLoadingMore) {
      return;
    }

    // Load more if user scrolled near the bottom (within 200 pixels)
    final isNearBottom = position.maxScrollExtent - position.pixels <= 200.0;

    if (isNearBottom) {
      if (kDebugMode) {
        print('User scrolled near bottom, loading more rooms');
      }
      setState(() {
        _isLoadingMore = true;
      });
      list.loadMore();
    }
  }

  Future<void> _initSlidingSync() async {
    try {
      final client = await ref.read(clientProvider.future);

      // Don't recreate if already initialized
      if (_slidingSync != null) {
        if (kDebugMode) print('Sliding sync already initialized, skipping...');
        setState(() {
          _isInitializing = false;
        });
        return;
      }

      if (kDebugMode) {
        print('Initializing sliding sync for client: ${client.userID}');
      }

      _slidingSync = SlidingSync.builder(client: client)
          .withExtensions(SlidingSyncExtensions.all())
          // A room whose only activity is state changes (e.g. reassignment,
          // with no chat messages ever sent) has no event in the SDK's
          // default previewable set, so it never gets a `lastEvent` and
          // sorts to the bottom regardless of how recently it was touched.
          // Matches the production Voys conversations app's preview types.
          .withPreviewEventTypes({
            ...client.roomPreviewLastEvents,
            assignedToEventType,
          })
          .addList(
            SlidingSyncList(
              syncMode: SyncMode.growing,
              // Fetch enough events per room that a previewable event is
              // almost always in-window, matching the production Voys
              // conversations app's list timeline_limit.
              timelineLimit: 10,
              requiredState: RequiredStateRequest(
                include: [
                  ['m.room.name', ''],
                  ['m.room.avatar', ''],
                  [assignedToEventType, assignedToStateKey],
                  [respondedEventType, '*'],
                ],
              ),
              // Use 1 to see the rooms loading one-by-one in action.
              batchSize: 10,
            ),
          )
          .build();

      if (kDebugMode) print('Sliding sync created, starting sync...');

      // Rebuild when a local event is added (e.g. just-sent message) so the
      // room list reflects the new lastEvent without waiting for the next sync.
      _timelineSubscription = client.onTimelineEvent.stream.listen((_) {
        if (mounted) setState(() {});
      });

      // Listen to updates and trigger rebuilds
      _slidingSync!.updateStream.listen((update) {
        if (kDebugMode) {
          print(
            'Sliding sync update: rooms=${update.rooms.length}, lists=${update.lists.length}',
          );
          for (final entry in update.lists.entries) {
            print('  List ${entry.key}: ops=${entry.value.ops?.length ?? 0}');
          }
        }

        // Check if we should load more after this update
        final list = _slidingSync?.list;
        final loadedRoomCount =
            list?.roomIds.where((id) => id.isNotEmpty).length ?? 0;

        if (list != null &&
            !list.isFullyLoaded &&
            list.state != SlidingSyncListLoadingState.preloaded) {
          // Load more if we haven't reached minimum
          if (loadedRoomCount < 10) {
            if (kDebugMode) {
              print(
                'Loading more rooms to reach minimum (loaded: $loadedRoomCount)',
              );
            }
            _isLoadingMore = true;
            list.loadMore();
          } else {
            // Reached minimum, stop loading and allow scroll-based loading
            _isLoadingMore = false;
          }
        } else {
          // Fully loaded or preloaded
          _isLoadingMore = false;
        }

        if (mounted) {
          setState(() {
            // Trigger rebuild when new data arrives
          });
        }
      });

      // Start syncing (don't await - it runs continuously in background)
      unawaited(_slidingSync!.startSync());

      if (kDebugMode) print('Sliding sync started');

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error initializing sliding sync: $e');
        print('Stack trace: $stackTrace');
      }
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _timelineSubscription?.cancel();
    // Dispose the sliding sync object (which stops sync and closes streams)
    _slidingSync?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _logout() async {
    final client = await ref.read(clientProvider.future);

    // Navigate immediately to login screen
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }

    // Clean up in the background (don't await - fire and forget)
    _slidingSync?.dispose();
    _slidingSync = null;

    // Logout without blocking (fire and forget)
    unawaited(client.logout());
  }

  SlidingRoomFilter? _buildFilters() => roomListFilterFor(
    assignedToFilter: _filterAssignedTo,
    respondedFilter: _filterResponded,
    involvingFilter: _filterInvolving,
    unreadFilter: _filterUnread,
  );

  void _applyPreset({
    required String involving,
    required bool unread,
    required bool oldestFirst,
  }) {
    setState(() {
      _filterAssignedTo = _allFilterValue;
      _filterResponded = _allFilterValue;
      _filterInvolving = involving;
      _filterUnread = unread;
      _sortOldestFirst = oldestFirst;
    });
    _slidingSync?.list?.setFilters(_buildFilters());
    _slidingSync?.list?.setOldestActivityFirst(
      oldestActivityFirst: oldestFirst,
    );
  }

  void _assignRoom(Room room, String? username) async {
    try {
      await room.client.setRoomStateWithKey(
        room.id,
        assignedToEventType,
        assignedToStateKey,
        {'assigned_to': username},
      );
      _slidingSync?.wakeSyncLoop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error assigning room: $e')));
      }
    }
  }

  void _join(Room room) async {
    if (room.membership != Membership.join) {
      await room.join();
    }

    // Subscribe to get full room state and more timeline events
    if (kDebugMode) print('Subscribing to room ${room.id}');
    _slidingSync?.subscribeToRooms({
      room.id: RoomSubscription(
        timelineLimit: 10,
        requiredState: RequiredStateRequest.full(),
        includeHeroes: true,
      ),
    });

    if (mounted) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => RoomPage(room: room)));
      if (kDebugMode) print('Unsubscribing from room ${room.id}');
      _slidingSync?.unsubscribeFromRooms([room.id]);
    }
  }

  void _showGoToRoomDialog() {
    final TextEditingController roomIdController = TextEditingController(
      text: '!hEIsMjankdsnERiyrL:conversations.voys.nl',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to Room'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: roomIdController,
              decoration: const InputDecoration(
                labelText: 'Room ID',
                hintText: '!roomId:server.com',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onSubmitted: (value) {
                if (value.isNotEmpty) {
                  Navigator.of(context).pop();
                  _goToRoom(value.trim());
                }
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter a Matrix room ID (starts with !)',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final roomId = roomIdController.text.trim();
              if (roomId.isEmpty) {
                return;
              }
              if (!roomId.startsWith('!') || !roomId.contains(':')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invalid room ID format'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              Navigator.of(context).pop();
              _goToRoom(roomId);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }

  void _goToRoom(String roomId) async {
    final client = ref.read(clientProvider).value!;

    if (kDebugMode) {
      print('Going to room: $roomId');
    }

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Loading room $roomId...'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // Subscribe to the room using sliding sync
    _slidingSync!.subscribeToRooms({
      roomId: RoomSubscription(
        timelineLimit: 50,
        requiredState: RequiredStateRequest.full(),
        includeHeroes: true,
      ),
    });

    // Wait for room data to arrive (listen to update stream)
    try {
      await _waitForRoom(roomId, client);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading room: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _waitForRoom(String roomId, Client client) async {
    // Check if room already exists
    final existingRoom = client.getRoomById(roomId);
    if (kDebugMode) {
      print('Checking for room: $roomId');
      print('Total rooms in client: ${client.rooms.length}');
      print('Room found: ${existingRoom != null}');
    }

    if (existingRoom != null) {
      if (kDebugMode) {
        print('Room already exists, navigating immediately');
      }
      if (mounted) {
        _join(existingRoom);
      }
      return;
    }

    if (kDebugMode) {
      print('Waiting for room data to arrive from sync...');
      print('Room subscription added, next sync will include it');
    }

    // Wait for room to appear in sync updates
    final completer = Completer<Room>();
    late StreamSubscription<SlidingSyncUpdate> subscription;

    subscription = _slidingSync!.updateStream.listen((update) {
      if (kDebugMode) {
        print('Received sync update with ${update.rooms.length} rooms');
        print('Looking for room: $roomId');
        print('Update contains our room: ${update.rooms.containsKey(roomId)}');
      }

      final room = client.getRoomById(roomId);
      if (kDebugMode) {
        print('Room found in client: ${room != null}');
      }

      if (room != null) {
        if (kDebugMode) {
          print('✓ Room found! Navigating...');
        }
        subscription.cancel();
        if (!completer.isCompleted) {
          completer.complete(room);
        }
      }
    });

    // Add timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        subscription.cancel();
        completer.completeError('Timeout waiting for room data');
      }
    });

    final room = await completer.future;

    // Navigate to the room
    if (mounted) {
      _join(room);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(clientProvider).value!;

    // Get the current room count for the title
    final list = _slidingSync?.list;
    final roomCount = (list?.roomIds ?? []).where((id) => id.isNotEmpty).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _filterUnread && _sortOldestFirst
              ? 'Urgent ($roomCount)'
              : _filterInvolving == 'foo'
              ? 'My chats ($roomCount)'
              : 'Chats ($roomCount)',
        ),
        actions: [
          TextButton(
            onPressed: () => _applyPreset(
              involving: _allFilterValue,
              unread: false,
              oldestFirst: false,
            ),
            child: const Text('All'),
          ),
          TextButton(
            onPressed: () => _applyPreset(
              involving: 'foo',
              unread: false,
              oldestFirst: false,
            ),
            child: const Text('My chats'),
          ),
          TextButton(
            onPressed: () => _applyPreset(
              involving: _allFilterValue,
              unread: true,
              oldestFirst: true,
            ),
            child: const Text('Urgent'),
          ),
          const VerticalDivider(),
          PopupMenuButton<String>(
            icon: Icon(
              _filterAssignedTo == _allFilterValue
                  ? Icons.filter_list
                  : Icons.filter_list_alt,
            ),
            tooltip: 'Filter by assignee',
            onSelected: (value) {
              setState(() => _filterAssignedTo = value);
              _slidingSync?.list?.setFilters(_buildFilters());
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: _allFilterValue,
                checked: _filterAssignedTo == _allFilterValue,
                child: const Text('All'),
              ),
              CheckedPopupMenuItem(
                value: _unassignedFilterValue,
                checked: _filterAssignedTo == _unassignedFilterValue,
                child: const Text('Unassigned'),
              ),
              for (final username in assignableUsers)
                CheckedPopupMenuItem(
                  value: username,
                  checked: _filterAssignedTo == username,
                  child: Text(username),
                ),
            ],
          ),
          PopupMenuButton<String>(
            icon: Icon(
              _filterResponded == _allFilterValue
                  ? Icons.forum_outlined
                  : Icons.forum,
            ),
            tooltip: 'Filter by responded',
            onSelected: (value) {
              setState(() => _filterResponded = value);
              _slidingSync?.list?.setFilters(_buildFilters());
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: _allFilterValue,
                checked: _filterResponded == _allFilterValue,
                child: const Text('All'),
              ),
              for (final username in assignableUsers)
                CheckedPopupMenuItem(
                  value: username,
                  checked: _filterResponded == username,
                  child: Text(username),
                ),
            ],
          ),
          PopupMenuButton<String>(
            icon: Icon(
              _filterInvolving == _allFilterValue
                  ? Icons.person_search_outlined
                  : Icons.person_search,
            ),
            tooltip: 'Filter: involving (assigned to OR responded)',
            onSelected: (value) {
              setState(() => _filterInvolving = value);
              _slidingSync?.list?.setFilters(_buildFilters());
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: _allFilterValue,
                checked: _filterInvolving == _allFilterValue,
                child: const Text('All'),
              ),
              for (final username in assignableUsers)
                CheckedPopupMenuItem(
                  value: username,
                  checked: _filterInvolving == username,
                  child: Text(username),
                ),
            ],
          ),
          IconButton(
            icon: Icon(
              _filterUnread
                  ? Icons.mark_chat_unread
                  : Icons.mark_chat_unread_outlined,
            ),
            tooltip: 'Filter: unread only',
            onPressed: () {
              setState(() => _filterUnread = !_filterUnread);
              _slidingSync?.list?.setFilters(_buildFilters());
            },
          ),
          IconButton(
            icon: Icon(_sortOldestFirst ? Icons.north : Icons.south),
            tooltip: 'Sort: oldest activity first',
            onPressed: () {
              setState(() => _sortOldestFirst = !_sortOldestFirst);
              _slidingSync?.list?.setOldestActivityFirst(
                oldestActivityFirst: _sortOldestFirst,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.meeting_room),
            onPressed: _showGoToRoomDialog,
            tooltip: 'Go to Room',
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: _isInitializing || _slidingSync == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<SlidingSyncUpdate>(
              stream: _slidingSync!.updateStream,
              builder: (context, snapshot) {
                // Check if sliding sync is still available (not disposed)
                if (_slidingSync == null) {
                  return const Center(child: CircularProgressIndicator());
                }

                final list = _slidingSync!.list;
                List<String> roomIds;
                if (_sortOldestFirst) {
                  // The server always sorts (never skips it via the
                  // full-range optimization) for `oldest_activity_first`, so
                  // its order is reliable here -- unlike the default
                  // recency sort below, `client.rooms` can't reproduce
                  // "oldest first" since its own sorter is fixed to recency.
                  roomIds = (list?.roomIds ?? [])
                      .where((id) => id.isNotEmpty)
                      .toList();
                } else {
                  // Order from `client.rooms` (kept sorted by `customRoomSorter`,
                  // see clientProvider) rather than the server's op order or a
                  // manual re-sort -- the server can skip its recency sort when a
                  // filtered list's range covers its whole result set, and
                  // `client.rooms` degrades gracefully (via
                  // `latestEventReceivedTime`) when a room has no cached
                  // `lastEvent` yet. `list.roomIds` still scopes membership to
                  // the current filter/window.
                  final listRoomIdSet = (list?.roomIds ?? [])
                      .where((id) => id.isNotEmpty)
                      .toSet();
                  roomIds = client.rooms
                      .where((room) => listRoomIdSet.contains(room.id))
                      .map((room) => room.id)
                      .toList();
                }

                // Filter changes reset the list to `notLoaded` until the
                // server confirms the new result set, so treat that state
                // like "still loading" rather than "confirmed empty" --
                // otherwise switching filters flashes a false "no rooms"
                // message before the real (filtered) rooms arrive.
                final isAwaitingFreshData =
                    list?.state == SlidingSyncListLoadingState.notLoaded;

                if (roomIds.isEmpty &&
                    (!snapshot.hasData || isAwaitingFreshData)) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Loading rooms...'),
                      ],
                    ),
                  );
                }

                if (roomIds.isEmpty) {
                  final hasActiveFilter =
                      _filterAssignedTo != _allFilterValue ||
                      _filterResponded != _allFilterValue ||
                      _filterInvolving != _allFilterValue ||
                      _filterUnread;
                  return Center(
                    child: Text(
                      hasActiveFilter
                          ? 'No rooms match this filter'
                          : 'No rooms found',
                    ),
                  );
                }

                return Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: roomIds.length,
                        itemBuilder: (context, i) {
                          final roomId = roomIds[i];
                          final room = client.getRoomById(roomId);

                          if (room == null) {
                            return const ListTile(
                              leading: CircleAvatar(),
                              title: Text('Loading...'),
                            );
                          }

                          final assignedTo = getAssignedTo(room);
                          final responded = getResponded(room);
                          final hasUnread = room.notificationCount > 0;

                          return ListTile(
                            leading: room.avatar == null
                                ? const CircleAvatar()
                                : FutureBuilder<Uri>(
                                    future: room.avatar!.getThumbnailUri(
                                      client,
                                      width: 56,
                                      height: 56,
                                    ),
                                    builder: (context, snapshot) {
                                      if (!snapshot.hasData) {
                                        return const CircleAvatar();
                                      }
                                      return CircleAvatar(
                                        foregroundImage: NetworkImage(
                                          snapshot.data!.toString(),
                                          headers: {
                                            'Authorization':
                                                'Bearer ${client.accessToken}',
                                          },
                                        ),
                                      );
                                    },
                                  ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    room.getLocalizedDisplayname(),
                                    style: TextStyle(
                                      fontWeight: hasUnread
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (room.notificationCount > 0)
                                  Material(
                                    borderRadius: BorderRadius.circular(99),
                                    color: Colors.red,
                                    child: Padding(
                                      padding: const EdgeInsets.all(2.0),
                                      child: Text(
                                        room.notificationCount.toString(),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        lastEventPreview(room.lastEvent),
                                        maxLines: 1,
                                        style: TextStyle(
                                          fontWeight: hasUnread
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                    if (room.lastEvent?.originServerTs != null)
                                      Text(
                                        room.lastEvent!.originServerTs
                                            .toIso8601String(),
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                  ],
                                ),
                                assignedTo == null
                                    ? const Text(
                                        'Unassigned',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      )
                                    : Text.rich(
                                        TextSpan(
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontStyle: FontStyle.italic,
                                          ),
                                          children: [
                                            const TextSpan(
                                              text: 'Assigned to: ',
                                            ),
                                            TextSpan(
                                              text: assignedTo,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                if (responded.isNotEmpty)
                                  Text(
                                    'Responded: ${responded.join(', ')}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.person_add_alt_1),
                              tooltip: 'Assign room',
                              onSelected: (username) => _assignRoom(
                                room,
                                username == _unassignValue ? null : username,
                              ),
                              itemBuilder: (context) => [
                                for (final username in assignableUsers)
                                  PopupMenuItem(
                                    value: username,
                                    child: Text(username),
                                  ),
                                const PopupMenuItem(
                                  value: _unassignValue,
                                  child: Text('Unassign'),
                                ),
                              ],
                            ),
                            onTap: () => _join(room),
                          );
                        },
                      ),
                    ),
                    // Loading indicator at the bottom - show when actively loading
                    if (_isLoadingMore && !(list?.isFullyLoaded ?? true))
                      Container(
                        padding: const EdgeInsets.all(16.0),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 200),
                          border: Border(
                            top: BorderSide(
                              color: Theme.of(context).dividerColor,
                              width: 1,
                            ),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('Loading more rooms...'),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class RoomPage extends StatefulWidget {
  final Room room;
  const RoomPage({required this.room, super.key});

  @override
  _RoomPageState createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  late final Future<Timeline> _timelineFuture;
  Timeline? _timeline;
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;
  late String? _assignedTo = getAssignedTo(widget.room);
  // Which identifier `co.voys.responded` gets recorded under when sending a
  // message, since the demo's assignable identifiers aren't tied to the
  // real logged-in Matrix account.
  String _respondingAs = assignableUsers.first;

  void _recordResponse() async {
    if (getResponded(widget.room).contains(_respondingAs)) return;

    try {
      await widget.room.client.setRoomStateWithKey(
        widget.room.id,
        respondedEventType,
        _respondingAs,
        {},
      );
    } catch (e) {
      if (kDebugMode) print('Error recording response: $e');
    }
  }

  void _assignRoom(String? username) async {
    try {
      await widget.room.client.setRoomStateWithKey(
        widget.room.id,
        assignedToEventType,
        assignedToStateKey,
        {'assigned_to': username},
      );
      if (mounted) setState(() => _assignedTo = username);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error assigning room: $e')));
      }
    }
  }

  @override
  void initState() {
    _timelineFuture = widget.room
        .getTimeline(
          onChange: (_) {
            if (mounted) setState(() {});
          },
          onInsert: (_) {
            if (mounted) setState(() {});
          },
          onRemove: (_) {
            if (mounted) setState(() {});
          },
          limit: Room.defaultHistoryCount,
        )
        .then((timeline) async {
          _timeline = timeline;
          final hasRoomCreate = timeline.events.any(
            (e) => e.type == EventTypes.RoomCreate,
          );
          if (!hasRoomCreate &&
              timeline.events.length < Room.defaultHistoryCount) {
            await timeline.requestHistory(
              historyCount: Room.defaultHistoryCount,
            );
          }
          // Mark the room as read so `notificationCount` clears -- events
          // arrive newest-first, so the first event is the latest.
          final latestEventId = timeline.events.firstOrNull?.eventId;
          if (latestEventId != null) {
            unawaited(
              widget.room.setReadMarker(latestEventId, mRead: latestEventId),
            );
          }
          if (mounted) setState(() {});
          return timeline;
        });
    _scrollController.addListener(_onScroll);
    super.initState();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isLoadingMore) return;
    final timeline = _timeline;
    if (timeline == null) return;

    // With reverse:true the beginning of history is at maxScrollExtent.
    final isNearTop =
        _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200.0;

    if (isNearTop) {
      final hasRoomCreate = timeline.events.any(
        (e) => e.type == EventTypes.RoomCreate,
      );
      if (hasRoomCreate) return;

      setState(() => _isLoadingMore = true);
      timeline.requestHistory().whenComplete(() {
        if (mounted) setState(() => _isLoadingMore = false);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _timeline?.cancelSubscriptions();
    super.dispose();
  }

  final TextEditingController _sendController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  void _send() {
    widget.room.sendTextEvent(_sendController.text.trim());
    _sendController.clear();
    _focusNode.requestFocus();
    _recordResponse();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight + 10,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.room.getLocalizedDisplayname()),
            FutureBuilder<Timeline>(
              future: _timelineFuture,
              builder: (context, snapshot) => Text(
                '${snapshot.data?.events.length ?? 0} messages loaded',
                style: const TextStyle(fontSize: 14),
              ),
            ),
            Text(
              _assignedTo == null ? 'Unassigned' : 'Assigned to: $_assignedTo',
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: 'Assign room',
            onSelected: (username) =>
                _assignRoom(username == _unassignValue ? null : username),
            itemBuilder: (context) => [
              for (final username in assignableUsers)
                PopupMenuItem(value: username, child: Text(username)),
              const PopupMenuItem(
                value: _unassignValue,
                child: Text('Unassign'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: FutureBuilder<Timeline>(
                future: _timelineFuture,
                builder: (context, snapshot) {
                  final timeline = snapshot.data;
                  if (timeline == null) {
                    return const Center(
                      child: CircularProgressIndicator.adaptive(),
                    );
                  }
                  // Sort newest-first so reverse:true ListView shows oldest
                  // at the top and newest at the bottom (standard chat UX).
                  // Explicit sort is needed because sliding sync can deliver
                  // events out of order across sync batches.
                  final sortedEvents = timeline.events.toList()
                    ..sort(
                      (a, b) => b.originServerTs.compareTo(a.originServerTs),
                    );
                  return Column(
                    children: [
                      if (_isLoadingMore)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text('Loading more messages...'),
                            ],
                          ),
                        ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          itemCount: sortedEvents.length,
                          itemBuilder: (context, i) {
                            final event = sortedEvents[i];
                            if (event.relationshipEventId != null) {
                              return const SizedBox.shrink();
                            }
                            return Opacity(
                              opacity: event.status.isSent ? 1 : 0.25,
                              child: Message(event, timeline, widget.room),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  DropdownButton<String>(
                    value: _respondingAs,
                    items: [
                      for (final username in assignableUsers)
                        DropdownMenuItem(
                          value: username,
                          child: Text(username),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _respondingAs = value);
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _sendController,
                      focusNode: _focusNode,
                      decoration: const InputDecoration(
                        hintText: 'Send message',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_outlined),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Message extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final Room room;

  const Message(this.event, this.timeline, this.room, {super.key});

  @override
  Widget build(BuildContext context) {
    final avatarUrl = event.senderFromMemoryOrFallback.avatarUrl;
    return ListTile(
      leading: avatarUrl == null
          ? const CircleAvatar()
          : FutureBuilder<Uri>(
              future: avatarUrl.getThumbnailUri(
                room.client,
                width: 56,
                height: 56,
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircleAvatar();
                }
                return CircleAvatar(
                  foregroundImage: NetworkImage(
                    snapshot.data!.toString(),
                    headers: {
                      'Authorization': 'Bearer ${room.client.accessToken}',
                    },
                  ),
                );
              },
            ),
      title: Row(
        children: [
          Expanded(
            child: Text(event.senderFromMemoryOrFallback.calcDisplayname()),
          ),
          Text(
            event.originServerTs.toIso8601String(),
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
      subtitle: Text(event.getDisplayEvent(timeline).body),
    );
  }
}

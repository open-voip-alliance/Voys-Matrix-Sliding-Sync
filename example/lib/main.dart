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
      final client = ref.read(clientProvider).valueOrNull;
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

class _RoomListPageState extends ConsumerState<RoomListPage> {
  SlidingSync? _slidingSync;
  bool _isInitializing = true;
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;
  StreamSubscription? _timelineSubscription;

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

      _slidingSync = client
          .createSlidingSyncBuilder('main')
          .withExtensions(SlidingSyncExtensions.all())
          .addList(
            SlidingSyncList(
              syncMode: SyncMode.growing,
              timelineLimit: 1,
              requiredState: RequiredStateRequest(
                include: [
                  ['m.room.name', ''],
                  ['m.room.avatar', ''],
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
        title: Text('Chats ($roomCount)'),
        actions: [
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
                // Filter out placeholder room IDs (empty strings)
                var roomIds = (list?.roomIds ?? [])
                    .where((id) => id.isNotEmpty)
                    .toList();

                // Sort rooms by last event timestamp (most recent first)
                roomIds.sort((a, b) {
                  final roomA = client.getRoomById(a);
                  final roomB = client.getRoomById(b);

                  final timeA = roomA?.lastEvent?.originServerTs ?? DateTime(0);
                  final timeB = roomB?.lastEvent?.originServerTs ?? DateTime(0);

                  return timeB.compareTo(
                    timeA,
                  ); // Descending order (newest first)
                });

                if (roomIds.isEmpty && !snapshot.hasData) {
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

                if (roomIds.isEmpty && snapshot.hasData) {
                  return const Center(child: Text('No rooms found'));
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
                                  child: Text(room.getLocalizedDisplayname()),
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
                            subtitle: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    room.lastEvent?.body ?? 'No messages',
                                    maxLines: 1,
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
          ],
        ),
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

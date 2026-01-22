import 'dart:io';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:voys_matrix_sliding_sync/voys_matrix_sliding_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize FFI for desktop platforms
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const SlidingSyncExampleApp());
}

class SlidingSyncExampleApp extends StatelessWidget {
  const SlidingSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sliding Sync Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _homeserverController = TextEditingController(text: 'matrix.org');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Create database using sqflite
      final db = await databaseFactory.openDatabase('sliding_sync_example.db');
      final database = await MatrixSdkDatabase.init(
        'sliding_sync_example',
        database: db,
      );

      // Use SlidingSyncOnlyClient to disable normal sync
      final client = SlidingSyncOnlyClient(
        'SlidingSyncExample',
        database: database,
      );

      // Disable background sync
      client.backgroundSync = false;

      await client.init(
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: false,
      );

      final homeserver = Uri.https(_homeserverController.text, '');
      await client.checkHomeserver(homeserver);

      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: _usernameController.text),
        password: _passwordController.text,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => RoomListPage(client: client),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sliding Sync Example'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _homeserverController,
              decoration: const InputDecoration(
                labelText: 'Homeserver',
                hintText: 'matrix.org',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
              ),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ElevatedButton(
              onPressed: _isLoading ? null : _login,
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Login'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _homeserverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}

class RoomListPage extends StatefulWidget {
  final Client client;

  const RoomListPage({super.key, required this.client});

  @override
  State<RoomListPage> createState() => _RoomListPageState();
}

class _RoomListPageState extends State<RoomListPage> {
  late SlidingSync _slidingSync;
  List<String> _roomIds = [];
  int? _totalRooms;

  @override
  void initState() {
    super.initState();
    _setupSlidingSync();
  }

  void _setupSlidingSync() {
    // Create sliding sync using the builder pattern (same as conversations app)
    _slidingSync = SlidingSync.builder(id: 'main', client: widget.client)
        .withExtensions(SlidingSyncExtensions.essential())
        .addList(
          SlidingSyncList(
            name: 'all_rooms',
            syncMode: SyncMode.growing,
            timelineLimit: 1,
            requiredState: RequiredStateRequest.minimal(),
            batchSize: 20,
            includeHeroes: true,
          ),
        )
        .build();

    // Listen for updates
    _slidingSync.updateStream.listen((update) {
      final list = _slidingSync.getList('all_rooms');
      if (list != null) {
        setState(() {
          _roomIds = list.roomIds.where((id) => id.isNotEmpty).toList();
          _totalRooms = list.totalRoomCount;
        });
      }
    });

    // Start syncing
    _slidingSync.startSync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Rooms (${_roomIds.length}${_totalRooms != null ? '/$_totalRooms' : ''})',
        ),
      ),
      body: ListView.builder(
        itemCount: _roomIds.length,
        itemBuilder: (context, index) {
          final roomId = _roomIds[index];
          final room = widget.client.getRoomById(roomId);

          final displayName = room?.getLocalizedDisplayname() ?? roomId;
          return ListTile(
            leading: CircleAvatar(
              child: Text(
                displayName.isNotEmpty ? displayName.substring(0, 1).toUpperCase() : '?',
              ),
            ),
            title: Text(displayName),
            subtitle: Text(
              room?.lastEvent?.body ?? 'No messages',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: room != null && room.notificationCount > 0
                ? Badge(
                    label: Text('${room.notificationCount}'),
                  )
                : null,
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final list = _slidingSync.getList('all_rooms');
          if (list != null && !list.isFullyLoaded) {
            list.loadMore();
          }
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }

  @override
  void dispose() {
    _slidingSync.dispose();
    widget.client.logout();
    super.dispose();
  }
}

// lib/main.dart
// P2P Parking with Supabase backend + Google Maps navigation
// Enhanced profile: editable full name, date of birth, profile photo upload.

import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Platform, File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// NEW: image picker for profile photo
import 'package:image_picker/image_picker.dart';

const SUPABASE_URL = 'https://xoiogluvrwtcdoirqvhu.supabase.co';
const SUPABASE_ANON =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhvaW9nbHV2cnd0Y2RvaXJxdmh1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTYwNjgxNjksImV4cCI6MjA3MTY0NDE2OX0._oWD6WUP7xLtHZkMPBpWiP6iQAgDhC838CIn7H9sULU';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: SUPABASE_URL, anonKey: SUPABASE_ANON);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ParkingApp());
}

class ParkingApp extends StatelessWidget {
  const ParkingApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFFFFEF00); // yellow #FFEF00
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'P2P Parking',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.black),
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: Colors.black,
          displayColor: Colors.black,
        ),
        iconTheme: const IconThemeData(color: Colors.black),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: seedColor,
            foregroundColor: Colors.black,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: seedColor,
            foregroundColor: Colors.black,
          ),
        ),
      ),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/home': (_) => const HomePage(),
        '/profile': (_) => const ProfilePage(),
        '/post': (_) => const PostSpacePage(),
        // NEW route for edit profile
        '/profile_edit': (_) => const EditProfilePage(),
      },
    );
  }
}

// --------------------------- Models & Utilities ---------------------------

enum CoverType { open, covered }

class ParkingSpace {
  final String id;
  String title;
  final String ownerUserId;
  double pricePerHour; // Rs/hr
  LatLng location;
  String dimensions;
  bool gated;
  bool guarded;
  CoverType coverType;
  List<String> allowedTypes; // '2w','3w','4w'
  String contactPhone; // poster's phone number
  bool isBooked; // optional denormalized flag

  ParkingSpace({
    required this.id,
    required this.title,
    required this.ownerUserId,
    required this.pricePerHour,
    required this.location,
    required this.dimensions,
    required this.gated,
    required this.guarded,
    required this.coverType,
    required this.allowedTypes,
    required this.contactPhone,
    this.isBooked = false,
  });

  factory ParkingSpace.fromMap(Map<String, dynamic> m) => ParkingSpace(
    id: m['id'] as String,
    title: m['title'] as String,
    ownerUserId: m['owner_user_id'] as String,
    pricePerHour: (m['price_per_hour'] as num).toDouble(),
    location: LatLng(
      (m['lat'] as num).toDouble(),
      (m['lng'] as num).toDouble(),
    ),
    dimensions: (m['dimensions'] ?? '') as String,
    gated: (m['gated'] ?? false) as bool,
    guarded: (m['guarded'] ?? false) as bool,
    coverType:
        ((m['cover_type'] ?? 'covered') == 'covered')
            ? CoverType.covered
            : CoverType.open,
    allowedTypes: List<String>.from(m['allowed_types'] ?? ['2w', '3w', '4w']),
    contactPhone: (m['contact_phone'] ?? '') as String,
    isBooked: (m['is_booked'] ?? false) as bool,
  );

  Map<String, dynamic> toInsert() => {
    'title': title,
    'owner_user_id': ownerUserId,
    'price_per_hour': pricePerHour,
    'lat': location.latitude,
    'lng': location.longitude,
    'dimensions': dimensions,
    'gated': gated,
    'guarded': guarded,
    'cover_type': coverType == CoverType.covered ? 'covered' : 'open',
    'allowed_types': allowedTypes,
    'contact_phone': contactPhone,
    'is_booked': isBooked,
  };
}

class Booking {
  final String id;
  final String spaceId;
  final String bookerUserId;
  final String vehicleType; // '2w'|'3w'|'4w'
  final String status; // confirmed, etc.

  Booking({
    required this.id,
    required this.spaceId,
    required this.bookerUserId,
    required this.vehicleType,
    required this.status,
  });

  factory Booking.fromMap(Map<String, dynamic> m) => Booking(
    id: m['id'] as String,
    spaceId: m['space_id'] as String,
    bookerUserId: m['booker_user_id'] as String,
    vehicleType: m['vehicle_type'] as String,
    status: m['status'] as String,
  );
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r"\s+"));
  if (parts.isEmpty) return '?';
  String i1 = parts.first.isNotEmpty ? parts.first[0] : '';
  String i2 = parts.length > 1 && parts.last.isNotEmpty ? parts.last[0] : '';
  return (i1 + i2).toUpperCase();
}

// ------------------------------ Supabase API ------------------------------

class Db {
  static final c = Supabase.instance.client;

  static Future<User?> sessionUser() async {
    final sess = c.auth.currentSession;
    return sess?.user;
  }

  static Future<void> saveProfileIfNeeded(User u) async {
    await c.from('profiles').upsert({
      'id': u.id,
      'email': u.email,
      'name': u.userMetadata?['name'] ?? u.email?.split('@').first,
      'avatar_url': u.userMetadata?['avatar_url'],
    });
  }

  // Nearby with simple bounding box (approx)
  static Future<List<ParkingSpace>> nearby(
    LatLng center, {
    double maxKm = 3,
  }) async {
    // bounding box approximation (1 deg ~ 111km)
    final dLat = maxKm / 111.0;
    final dLng = maxKm / (111.0 * math.cos(center.latitude * math.pi / 180.0));
    final minLat = center.latitude - dLat;
    final maxLat = center.latitude + dLat;
    final minLng = center.longitude - dLng;
    final maxLng = center.longitude + dLng;

    final rows = await c
        .from('spaces')
        .select()
        .gte('lat', minLat)
        .lte('lat', maxLat)
        .gte('lng', minLng)
        .lte('lng', maxLng);
    final list =
        (rows as List)
            .map((e) => ParkingSpace.fromMap(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => a.pricePerHour.compareTo(b.pricePerHour));
    return list;
  }

  static Future<List<ParkingSpace>> spacesByOwner(String userId) async {
    final rows = await c.from('spaces').select().eq('owner_user_id', userId);
    return (rows as List)
        .map((e) => ParkingSpace.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> insertSpace(ParkingSpace s) async {
    await c.from('spaces').insert(s.toInsert());
  }

  // new: update an existing space
  static Future<void> updateSpace(ParkingSpace s) async {
    await c.from('spaces').update(s.toInsert()).eq('id', s.id);
  }

  // new: delete a space by id
  static Future<void> deleteSpace(String id) async {
    await c.from('spaces').delete().eq('id', id);
  }

  static Future<Booking> createBooking({
    required String spaceId,
    required String vehicleType,
  }) async {
    final uid = c.auth.currentUser!.id;
    final row =
        await c
            .from('bookings')
            .insert({
              'space_id': spaceId,
              'booker_user_id': uid,
              'vehicle_type': vehicleType,
              'status': 'confirmed',
            })
            .select()
            .single();
    return Booking.fromMap(row);
  }

  // ---------------- Profile helpers ----------------

  /// Fetch profile record for current user (includes full_name, dob, avatar_url)
  static Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    final rows =
        await c.from('profiles').select().eq('id', userId).maybeSingle();
    if (rows == null) return null;
    return rows as Map<String, dynamic>;
  }

  /// Update profile fields (partial update)
  static Future<void> updateProfile(
    String userId,
    Map<String, dynamic> values,
  ) async {
    await c.from('profiles').update(values).eq('id', userId);
  }

  /// Upload avatar bytes to storage bucket 'avatars' and return public URL
  /// Upload avatar bytes to storage bucket 'avatars' and return public URL
  static Future<String?> uploadAvatar(String userId, Uint8List bytes) async {
    try {
      final key =
          'avatars/${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Upload image bytes to Supabase storage
      await c.storage.from('avatars').uploadBinary(key, bytes);

      // Get public URL — handle multiple SDK return types
      final dynamic publicUrlResp = c.storage.from('avatars').getPublicUrl(key);

      // Case 1: plain String (newer SDKs)
      if (publicUrlResp is String) return publicUrlResp;

      // Case 2: SupabaseFileObject or similar map
      if (publicUrlResp is Map<String, dynamic>) {
        final url = publicUrlResp['publicUrl'] ?? publicUrlResp['data'];
        if (url is String) return url;
      }

      // Case 3: dynamic object with fields like `.data` or `.publicUrl`
      try {
        final dyn = publicUrlResp as dynamic;
        if (dyn.publicUrl is String) return dyn.publicUrl as String;
        if (dyn.data is String) return dyn.data as String;
      } catch (_) {
        // ignore if no matching field
      }

      debugPrint('Unexpected getPublicUrl response: $publicUrlResp');
      return null;
    } catch (e) {
      debugPrint('Avatar upload failed: $e');
      return null;
    }
  }
}

// -------------------------------- Login UI --------------------------------

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  void initState() {
    super.initState();
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushReplacementNamed(context, '/home');
      });
    }
  }

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pwd = TextEditingController();
  bool _isLogin = true;
  bool _busy = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      if (_isLogin) {
        await Supabase.instance.client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _pwd.text.trim(),
        );
      } else {
        // Create account
        await Supabase.instance.client.auth.signUp(
          email: _email.text.trim(),
          password: _pwd.text.trim(),
          data: {'name': _email.text.trim().split('@').first},
        );
        // IMPORTANT: sign in immediately to guarantee a session
        await Supabase.instance.client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _pwd.text.trim(),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } on AuthException catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.local_parking,
                    size: 64,
                    color: Colors.black,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'P2P Parking',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _email,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                              ),
                              keyboardType: TextInputType.emailAddress,
                              validator:
                                  (v) =>
                                      (v == null || !v.contains('@'))
                                          ? 'Enter a valid email'
                                          : null,
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _pwd,
                              decoration: const InputDecoration(
                                labelText: 'Password',
                              ),
                              obscureText: true,
                              validator:
                                  (v) =>
                                      (v == null || v.length < 6)
                                          ? 'Min 6 characters'
                                          : null,
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _busy ? null : _submit,
                                child:
                                    _busy
                                        ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : Text(
                                          _isLogin ? 'Login' : 'Create account',
                                        ),
                              ),
                            ),
                            TextButton(
                              onPressed:
                                  () => setState(() => _isLogin = !_isLogin),
                              child: Text(
                                _isLogin
                                    ? "New here? Register"
                                    : "Have an account? Login",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------- Home Page --------------------------------
// (unchanged from previous working file; omitted comments for brevity)

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _mapController = MapController();
  LatLng? _current;
  bool _locating = true;
  bool _showNearby = false;
  List<ParkingSpace> _nearby = [];
  String _vehicleType = '2w';

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Future<void> _initLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        _current = const LatLng(12.9716, 77.5946); // fallback: Bengaluru
      } else {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        _current = LatLng(pos.latitude, pos.longitude);
      }
      await _fetchNearby();
    } catch (_) {
      _current = const LatLng(12.9716, 77.5946);
      await _fetchNearby();
    }
    if (!mounted) return;
    setState(() => _locating = false);
  }

  Future<void> _fetchNearby() async {
    if (_current == null) return;
    final list = await Db.nearby(_current!, maxKm: 3);
    setState(() => _nearby = list);
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      // Session expired or sign-up without session
      Future.microtask(
        () =>
            Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false),
      );
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body:
          _locating || _current == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _current!,
                      initialZoom: 15,
                      interactionOptions: const InteractionOptions(
                        flags: ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c'],
                        userAgentPackageName: 'com.example.p2p_parking',
                      ),
                      MarkerLayer(markers: _buildMarkers()),
                    ],
                  ),

                  // Profile button
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12, right: 12),
                        child: PopupMenuButton(
                          offset: const Offset(0, 50),
                          itemBuilder:
                              (ctx) => [
                                const PopupMenuItem(
                                  value: 'profile',
                                  child: Text('Profile'),
                                ),
                                const PopupMenuItem(
                                  value: 'logout',
                                  child: Text('Logout'),
                                ),
                              ],
                          onSelected: (value) async {
                            if (value == 'profile') {
                              await Navigator.of(context).pushNamed('/profile');
                              setState(() {});
                            } else if (value == 'logout') {
                              await Supabase.instance.client.auth.signOut();
                              if (!mounted) return;
                              Navigator.of(
                                context,
                              ).pushNamedAndRemoveUntil('/login', (_) => false);
                            }
                          },
                          child: CircleAvatar(
                            radius: 24,
                            child: Text(_initials(user.email ?? 'U')),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bottom overlay card
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Card(
                        elevation: 6,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.map, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Home — ${_showNearby ? 'Showing nearby spaces' : 'Ready'}',
                                      style:
                                          Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () async {
                                        setState(() => _showNearby = true);
                                        _mapController.move(_current!, 16);
                                        await _fetchNearby();
                                      },
                                      icon: const Icon(
                                        Icons.directions_car,
                                        color: Colors.black,
                                      ),
                                      label: const Text('Park'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          () => Navigator.of(context)
                                              .push(
                                                MaterialPageRoute(
                                                  builder:
                                                      (_) =>
                                                          const PostSpacePage(),
                                                ),
                                              )
                                              .then((_) async {
                                                await _fetchNearby();
                                                setState(() {});
                                              }),
                                      icon: const Icon(
                                        Icons.add_location_alt,
                                        color: Colors.black,
                                      ),
                                      label: const Text('Post'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // Vehicle type selector
                              if (_showNearby)
                                Row(
                                  children: [
                                    const Text('Vehicle:'),
                                    const SizedBox(width: 8),
                                    DropdownButton<String>(
                                      value: _vehicleType,
                                      items: const [
                                        DropdownMenuItem(
                                          value: '2w',
                                          child: Text('2-wheeler'),
                                        ),
                                        DropdownMenuItem(
                                          value: '3w',
                                          child: Text('3-wheeler'),
                                        ),
                                        DropdownMenuItem(
                                          value: '4w',
                                          child: Text('4-wheeler'),
                                        ),
                                      ],
                                      onChanged:
                                          (v) => setState(
                                            () => _vehicleType = v ?? '2w',
                                          ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
    );
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    if (_current != null) {
      markers.add(
        Marker(
          point: _current!,
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: const Icon(
            Icons.my_location,
            size: 30,
            color: Colors.blueAccent,
          ),
        ),
      );
    }
    if (_showNearby && _current != null) {
      for (final s in _nearby.where(
        (s) => s.allowedTypes.contains(_vehicleType),
      )) {
        markers.add(
          Marker(
            point: s.location,
            width: 120,
            height: 80,
            child: _PriceMarker(space: s, vehicleType: _vehicleType),
          ),
        );
      }
    }
    return markers;
  }
}

class _PriceMarker extends StatelessWidget {
  final ParkingSpace space;
  final String vehicleType;
  const _PriceMarker({required this.space, required this.vehicleType});

  @override
  Widget build(BuildContext context) {
    final rs = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (_) => _SpaceSheet(space: space, vehicleType: vehicleType),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${rs.format(space.pricePerHour)}/hr',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const Icon(Icons.location_on, size: 32, color: Colors.redAccent),
        ],
      ),
    );
  }
}

class _SpaceSheet extends StatefulWidget {
  final ParkingSpace space;
  final String vehicleType;
  const _SpaceSheet({required this.space, required this.vehicleType});
  @override
  State<_SpaceSheet> createState() => _SpaceSheetState();
}

class _SpaceSheetState extends State<_SpaceSheet> {
  bool _booking = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.space;
    final chips = <Widget>[
      _InfoChip(
        label: s.coverType == CoverType.covered ? 'Covered' : 'Open',
        icon: Icons.roofing,
      ),
      if (s.gated) const _InfoChip(label: 'Gated', icon: Icons.fence),
      if (s.guarded) const _InfoChip(label: 'Guarded', icon: Icons.shield),
      _InfoChip(label: s.dimensions, icon: Icons.straighten),
      _InfoChip(
        label: 'Allows: ${s.allowedTypes.join(', ')}',
        icon: Icons.directions_car,
      ),
    ];
    final rs = NumberFormat.currency(locale: 'en_IN', symbol: '₹');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_parking),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (s.isBooked)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Booked',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Text(
                '${rs.format(s.pricePerHour)}/hr',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Vehicle:'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: widget.vehicleType,
                items: const [
                  DropdownMenuItem(value: '2w', child: Text('2-wheeler')),
                  DropdownMenuItem(value: '3w', child: Text('3-wheeler')),
                  DropdownMenuItem(value: '4w', child: Text('4-wheeler')),
                ],
                onChanged: (_) {}, // just display here
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Replaced single button with Book & Navigate + Contact button
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      _booking
                          ? null
                          : () async {
                            setState(() => _booking = true);
                            try {
                              final b = await Db.createBooking(
                                spaceId: s.id,
                                vehicleType: widget.vehicleType,
                              );
                              if (!mounted) return;
                              Navigator.pop(context);
                              _showNavSheet(context, s.location);
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Booking failed: $e')),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _booking = false);
                            }
                          },
                  icon: const Icon(Icons.check_circle, color: Colors.black),
                  label: Text(_booking ? 'Booking...' : 'Book & Navigate'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    final phone = s.contactPhone.trim();
                    if (phone.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Owner has not provided a phone number',
                          ),
                        ),
                      );
                      return;
                    }
                    _dialOwner(phone);
                  },
                  icon: const Icon(Icons.call, color: Colors.black),
                  label: const Text('Contact'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _dialOwner(String phone) async {
    var normalized = phone.trim();
    if (normalized.isEmpty) return;

    if (!normalized.startsWith('+')) {
      normalized = normalized.replaceAll(RegExp(r'\D'), '');
    } else {
      normalized = '+' + normalized.substring(1).replaceAll(RegExp(r'\D'), '');
    }

    final uri = Uri.parse('tel:$normalized');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot open dialer on this device')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to open dialer: $e')));
    }
  }
}

void _showNavSheet(BuildContext context, LatLng dest) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder:
        (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Booking confirmed!'),
              const SizedBox(height: 8),
              const Text('Open navigation to the space:'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openGoogleMaps(dest),
                      icon: const Icon(Icons.navigation, color: Colors.black),
                      label: const Text('Open in Google Maps'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
  );
}

Future<void> _openGoogleMaps(LatLng dest) async {
  final lat = dest.latitude;
  final lng = dest.longitude;

  // Prefer native apps
  final androidUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng'); // Android
  final iosUri = Uri.parse(
    'comgooglemaps://?daddr=$lat,$lng&directionsmode=driving',
  ); // iOS
  // Fallback to web (opens browser if app not available)
  final webUri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
  );

  try {
    if (Platform.isAndroid && await canLaunchUrl(androidUri)) {
      await launchUrl(androidUri, mode: LaunchMode.externalApplication);
      return;
    }
    if (Platform.isIOS && await canLaunchUrl(iosUri)) {
      await launchUrl(iosUri, mode: LaunchMode.externalApplication);
      return;
    }
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Could not launch maps: $e');
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _InfoChip({required this.label, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

// ------------------------------ Post Space ---------------------------------

class PostSpacePage extends StatefulWidget {
  final ParkingSpace? existing;
  const PostSpacePage({this.existing, super.key});
  @override
  State<PostSpacePage> createState() => _PostSpacePageState();
}

class _PostSpacePageState extends State<PostSpacePage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController(text: 'My Spare Spot');
  final _dimensions = TextEditingController(text: '5.0m x 2.5m');
  final _price = TextEditingController(text: '50');
  final _phone = TextEditingController(); // NEW: contact phone input
  bool _gated = true;
  bool _guarded = false;
  CoverType _cover = CoverType.covered;
  LatLng? _useLocation;
  bool _saving = false;
  final Set<String> _allowed = {'2w', '3w', '4w'};

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _title.text = e.title;
      _dimensions.text = e.dimensions;
      _price.text = e.pricePerHour.toStringAsFixed(0);
      _gated = e.gated;
      _guarded = e.guarded;
      _cover = e.coverType;
      _useLocation = e.location;
      _allowed
        ..clear()
        ..addAll(e.allowedTypes);
      _phone.text = e.contactPhone; // load existing phone when editing
    }
  }

  Future<void> _getCurrent() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() => _useLocation = LatLng(p.latitude, p.longitude));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to get location')));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_useLocation == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please set location')));
      return;
    }
    setState(() => _saving = true);
    try {
      final uid = Supabase.instance.client.auth.currentUser!.id;
      final space = ParkingSpace(
        id: widget.existing?.id ?? 'temp',
        title: _title.text.trim(),
        ownerUserId: uid,
        pricePerHour: double.tryParse(_price.text.trim()) ?? 50,
        location: _useLocation!,
        dimensions: _dimensions.text.trim(),
        gated: _gated,
        guarded: _guarded,
        coverType: _cover,
        allowedTypes: _allowed.toList(),
        contactPhone: _phone.text.trim(), // NEW: save contact phone
      );

      if (widget.existing == null) {
        await Db.insertSpace(space);
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Space posted!')));
      } else {
        await Db.updateSpace(space);
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Space updated!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to post: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Post a Space' : 'Edit Space'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Title'),
                  validator:
                      (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Enter a title'
                              : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _dimensions,
                  decoration: const InputDecoration(
                    labelText: 'Dimensions (e.g., 5.0m x 2.5m)',
                  ),
                  validator:
                      (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Enter dimensions'
                              : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _price,
                  decoration: const InputDecoration(
                    labelText: 'Price (Rs./hr)',
                  ),
                  keyboardType: TextInputType.number,
                  validator:
                      (v) =>
                          (v == null || double.tryParse(v) == null)
                              ? 'Enter price'
                              : null,
                ),
                const SizedBox(height: 8),
                // NEW: contact phone field (mandatory)
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(
                    labelText: 'Contact phone (owner)',
                    hintText: 'e.g. 9876543210',
                  ),
                  keyboardType: TextInputType.phone,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty)
                      return 'Enter contact phone';
                    final digits = v.replaceAll(RegExp(r'\D'), '');
                    if (digits.length < 10) return 'Enter a valid phone number';
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<CoverType>(
                  value: _cover,
                  decoration: const InputDecoration(labelText: 'Cover Type'),
                  items: const [
                    DropdownMenuItem(
                      value: CoverType.covered,
                      child: Text('Covered'),
                    ),
                    DropdownMenuItem(
                      value: CoverType.open,
                      child: Text('Open'),
                    ),
                  ],
                  onChanged:
                      (v) => setState(() => _cover = v ?? CoverType.covered),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: _gated,
                  onChanged: (v) => setState(() => _gated = v),
                  title: const Text('Gated'),
                ),
                SwitchListTile(
                  value: _guarded,
                  onChanged: (v) => setState(() => _guarded = v),
                  title: const Text('Guarded'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('2-wheeler'),
                      selected: _allowed.contains('2w'),
                      onSelected:
                          (v) => setState(
                            () =>
                                v ? _allowed.add('2w') : _allowed.remove('2w'),
                          ),
                    ),
                    FilterChip(
                      label: const Text('3-wheeler'),
                      selected: _allowed.contains('3w'),
                      onSelected:
                          (v) => setState(
                            () =>
                                v ? _allowed.add('3w') : _allowed.remove('3w'),
                          ),
                    ),
                    FilterChip(
                      label: const Text('4-wheeler'),
                      selected: _allowed.contains('4w'),
                      onSelected:
                          (v) => setState(
                            () =>
                                v ? _allowed.add('4w') : _allowed.remove('4w'),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Location'),
                  subtitle: Text(
                    _useLocation == null
                        ? 'Not set'
                        : 'Lat: ${_useLocation!.latitude.toStringAsFixed(5)}, Lng: ${_useLocation!.longitude.toStringAsFixed(5)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _getCurrent,
                        icon: const Icon(
                          Icons.my_location,
                          color: Colors.black,
                        ),
                        label: const Text('Use Current'),
                      ),
                      const SizedBox(width: 8),
                      // Select on Map button kept from previous enhancement
                      OutlinedButton.icon(
                        onPressed: () async {
                          LatLng center =
                              _useLocation ??
                              (await _getFallbackCenter()) ??
                              const LatLng(12.9716, 77.5946);
                          final picked = await Navigator.of(
                            context,
                          ).push<LatLng?>(
                            MaterialPageRoute(
                              builder: (_) => MapPickerPage(initial: center),
                            ),
                          );
                          if (picked != null) {
                            setState(() => _useLocation = picked);
                          }
                        },
                        icon: const Icon(Icons.map, color: Colors.black),
                        label: const Text('Select on Map'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.upload, color: Colors.black),
                    label:
                        _saving
                            ? const Text('Posting...')
                            : Text(
                              widget.existing == null
                                  ? 'Post Space'
                                  : 'Save Changes',
                            ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // helper to get a fallback center by trying device location; returns null on failure
  Future<LatLng?> _getFallbackCenter() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }
}

// --------------------------- Map Picker Page ---------------------------

class MapPickerPage extends StatefulWidget {
  final LatLng initial;
  const MapPickerPage({required this.initial, super.key});
  @override
  State<MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<MapPickerPage> {
  late final MapController _mapCtrl;
  late LatLng _picked; // center pin position

  @override
  void initState() {
    super.initState();
    _mapCtrl = MapController();
    _picked = widget.initial;
  }

  // Helper to return the picked location and close page
  void _confirmAndPop() {
    Navigator.of(context).pop(_picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select location'),
        actions: [
          // Confirm button restored
          TextButton(
            onPressed: _confirmAndPop,
            child: const Text('Confirm', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: _picked,
              initialZoom: 16,
              // Update _picked ONLY on user gesture (prevents programmatic jumps)
              onPositionChanged: (mapPosition, hasGesture) {
                final center = mapPosition.center;
                if (center != null && hasGesture == true) {
                  if (center.latitude != _picked.latitude ||
                      center.longitude != _picked.longitude) {
                    setState(() => _picked = center);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.example.p2p_parking',
              ),
            ],
          ),

          // Fixed center pin overlay (ignore pointer so map gestures work)
          const IgnorePointer(
            ignoring: true,
            child: Center(
              child: Icon(Icons.location_on, size: 48, color: Colors.redAccent),
            ),
          ),

          // small card at top showing coordinates (optional helpful feedback)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  'Lat: ${_picked.latitude.toStringAsFixed(6)}, Lng: ${_picked.longitude.toStringAsFixed(6)}',
                  style: const TextStyle(fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _confirmAndPop, // returns current _picked
        label: const Text('Use this location'),
        icon: const Icon(Icons.check),
      ),
    );
  }
}

// ------------------------------ Profile Page (ENHANCED) ------------------------------

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  List<ParkingSpace> _mine = [];
  Map<String, dynamic>? _profile;
  bool _loadingProfile = true;

  Future<void> _load() async {
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final list = await Db.spacesByOwner(uid);
    final profile = await Db.fetchProfile(uid);
    setState(() {
      _mine = list;
      _profile = profile;
      _loadingProfile = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Widget _avatarWidget(String? url, String initials) {
    if (url != null && url.isNotEmpty) {
      return CircleAvatar(radius: 32, backgroundImage: NetworkImage(url));
    }
    return CircleAvatar(
      radius: 32,
      child: Text(
        initials,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = Supabase.instance.client.auth.currentUser!;
    final initials = _initials(
      _profile?['full_name'] as String? ?? u.email ?? 'U',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          // open edit profile screen and refresh on return
          await Navigator.of(context).pushNamed('/profile_edit');
          await _load();
        },
        child: const Icon(Icons.edit),
      ),
      body: SafeArea(
        child:
            _loadingProfile
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        _avatarWidget(
                          _profile?['avatar_url'] as String?,
                          initials,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _profile?['full_name'] as String? ??
                                    (u.email ?? 'Unknown'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(u.email ?? 'No email'),
                              const SizedBox(height: 6),
                              Text(
                                _profile?['dob'] != null &&
                                        (_profile!['dob'] as String).isNotEmpty
                                    ? 'DOB: ${_formatDob(_profile!['dob'] as String)}'
                                    : 'DOB: Not set',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Your Posted Spaces',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (_mine.isEmpty)
                      const Text("You haven't posted any spaces yet.")
                    else
                      ..._mine.map(
                        (s) => _SpaceListTile(
                          space: s,
                          onDeleted: () async {
                            await _load();
                          },
                          onEdited: () async {
                            await _load();
                          },
                        ),
                      ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () async {
                        // quick refresh manually
                        await _load();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Profile refreshed')),
                          );
                        }
                      },
                      child: const Text('Refresh Profile'),
                    ),
                  ],
                ),
      ),
    );
  }

  String _formatDob(String iso) {
    try {
      final d = DateTime.parse(iso);
      return DateFormat.yMMMd().format(d);
    } catch (_) {
      return iso;
    }
  }
}

// ------------------------------ Edit Profile Page ------------------------------

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});
  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _fullName = TextEditingController();
  DateTime? _dob;
  String? _avatarUrl;
  bool _saving = false;
  bool _loading = true;
  final ImagePicker _picker = ImagePicker();
  Uint8List? _pickedBytes;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final p = await Db.fetchProfile(uid);
    if (p != null) {
      _fullName.text = (p['full_name'] as String?) ?? '';
      final dobVal = p['dob'] as String?;
      if (dobVal != null && dobVal.isNotEmpty) {
        try {
          _dob = DateTime.parse(dobVal);
        } catch (_) {
          _dob = null;
        }
      }
      _avatarUrl = p['avatar_url'] as String?;
    }
    setState(() => _loading = false);
  }

  Future<void> _pickImage(ImageSource src) async {
    try {
      final XFile? file = await _picker.pickImage(
        source: src,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() {
        _pickedBytes = bytes;
        // show preview from memory, avatarUrl kept until upload
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Image pick failed: $e')));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final uid = Supabase.instance.client.auth.currentUser!.id;

    try {
      String? uploadedUrl = _avatarUrl;
      if (_pickedBytes != null) {
        final res = await Db.uploadAvatar(uid, _pickedBytes!);
        if (res != null) uploadedUrl = res;
      }

      final updateMap = <String, dynamic>{
        'full_name': _fullName.text.trim(),
        'avatar_url': uploadedUrl,
      };
      if (_dob != null) updateMap['dob'] = _dob!.toIso8601String();

      await Db.updateProfile(uid, updateMap);

      if (!mounted) return;
      Navigator.of(context).pop(); // return to profile page
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _avatarPreview() {
    if (_pickedBytes != null) {
      return CircleAvatar(
        radius: 48,
        backgroundImage: MemoryImage(_pickedBytes!),
      );
    }
    if (_avatarUrl != null && _avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 48,
        backgroundImage: NetworkImage(_avatarUrl!),
      );
    }
    final initials = _initials(
      _fullName.text.isNotEmpty
          ? _fullName.text
          : (Supabase.instance.client.auth.currentUser!.email ?? 'U'),
    );
    return CircleAvatar(
      radius: 48,
      child: Text(initials, style: const TextStyle(fontSize: 24)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      children: [
                        Center(child: _avatarPreview()),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: () => _pickImage(ImageSource.gallery),
                              icon: const Icon(Icons.photo_library),
                              label: const Text('Gallery'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () => _pickImage(ImageSource.camera),
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Camera'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _fullName,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                          ),
                          validator:
                              (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Enter your name'
                                      : null,
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Date of Birth'),
                          subtitle: Text(
                            _dob == null
                                ? 'Not set'
                                : DateFormat.yMMM().add_d().format(_dob!),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.calendar_today),
                            onPressed: () async {
                              final now = DateTime.now();
                              final initial =
                                  _dob ??
                                  DateTime(now.year - 25, now.month, now.day);
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: initial,
                                firstDate: DateTime(1900),
                                lastDate: DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                ),
                              );
                              if (picked != null) setState(() => _dob = picked);
                            },
                          ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child:
                              _saving
                                  ? const CircularProgressIndicator()
                                  : const Text('Save Profile'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
    );
  }
}

// ------------------------------ Profile helper widgets reused ------------------------------

class _SpaceListTile extends StatelessWidget {
  final ParkingSpace space;
  final VoidCallback? onDeleted;
  final VoidCallback? onEdited;
  const _SpaceListTile({required this.space, this.onDeleted, this.onEdited});

  @override
  Widget build(BuildContext context) {
    final rs = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    return Card(
      child: ListTile(
        leading: const Icon(Icons.local_parking, color: Colors.black),
        title: Text(space.title),
        subtitle: Text(
          '${space.dimensions} • ${space.coverType == CoverType.covered ? 'Covered' : 'Open'}\n'
          '${space.gated ? 'Gated' : 'Not gated'} • ${space.guarded ? 'Guarded' : 'Un-guarded'}\n'
          'Allows: ${space.allowedTypes.join(', ')}',
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${rs.format(space.pricePerHour)}/hr',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              onSelected: (v) async {
                if (v == 'delete') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder:
                        (ctx) => AlertDialog(
                          title: const Text('Delete post'),
                          content: const Text(
                            'Are you sure you want to delete this space?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                  );
                  if (ok == true) {
                    try {
                      await Db.deleteSpace(space.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Post deleted')),
                      );
                      onDeleted?.call();
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Delete failed: $e')),
                      );
                    }
                  }
                } else if (v == 'edit') {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PostSpacePage(existing: space),
                    ),
                  );
                  onEdited?.call();
                }
              },
              itemBuilder:
                  (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
              child: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Icon(Icons.more_vert, color: Colors.black),
              ),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}

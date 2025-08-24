// main.dart — P2P Parking with Supabase backend + Google Maps navigation
// ---------------------------------------------------------------------
// What’s included (single file demo):
// - Free login with Supabase (email + password) and session persistence
// - Spaces stored in Supabase (post, list nearby, view details)
// - Book a space (simple immediate-confirm flow)
// - One-tap navigation using Google Maps (via URL scheme) to the booked spot
// - Map UI uses OpenStreetMap tiles via flutter_map (no API key needed)
//
// ----------------------------- Dependencies ------------------------------
// In pubspec.yaml under dependencies:
//   flutter:
//     sdk: flutter
//   cupertino_icons: ^1.0.2
//   flutter_map: ^7.0.2
//   latlong2: ^0.9.1
//   geolocator: ^13.0.1
//   intl: ^0.19.0
//   uuid: ^4.4.2
//   supabase_flutter: ^2.5.0
//   url_launcher: ^6.3.0
//
// Android permissions:
//   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
// iOS Info.plist:
//   NSLocationWhenInUseUsageDescription = "This app needs location to find and post parking spaces."
//
// ----------------------------- Supabase Setup -----------------------------
// 1) Create a Supabase project (https://supabase.com)
// 2) Get your Project URL and anon key; paste into SUPABASE_URL and SUPABASE_ANON below.
// 3) Run the SQL in your Supabase SQL editor:
//   -- tables
//   create table if not exists profiles (
//     id uuid primary key references auth.users on delete cascade,
//     name text,
//     email text unique,
//     avatar_url text,
//     created_at timestamp with time zone default now()
//   );
//   create table if not exists spaces (
//     id uuid primary key default gen_random_uuid(),
//     owner_user_id uuid references auth.users(id) on delete cascade,
//     title text not null,
//     price_per_hour numeric not null,
//     lat double precision not null,
//     lng double precision not null,
//     dimensions text,
//     gated boolean default false,
//     guarded boolean default false,
//     cover_type text check (cover_type in ('open','covered')) default 'covered',
//     allowed_types text[] default array['2w','3w','4w'],
//     created_at timestamp with time zone default now()
//   );
//   create table if not exists bookings (
//     id uuid primary key default gen_random_uuid(),
//     space_id uuid references spaces(id) on delete cascade,
//     booker_user_id uuid references auth.users(id) on delete cascade,
//     vehicle_type text check (vehicle_type in ('2w','3w','4w')) not null,
//     status text check (status in ('pending','confirmed','completed','cancelled')) default 'confirmed',
//     start_time timestamp with time zone default now(),
//     end_time timestamp with time zone,
//     created_at timestamp with time zone default now()
//   );
//
//   -- RLS
//   alter table profiles enable row level security;
//   alter table spaces enable row level security;
//   alter table bookings enable row level security;
//
//   -- Policies
//   create policy "profiles self access" on profiles
//     for select using (auth.uid() = id);
//   create policy "profiles upsert self" on profiles
//     for insert with check (auth.uid() = id);
//
//   create policy "spaces readable to all" on spaces for select using (true);
//   create policy "spaces insert by auth" on spaces for insert with check (auth.role() = 'authenticated');
//   create policy "spaces owner update" on spaces for update using (auth.uid() = owner_user_id);
//
//   create policy "bookings select own or owner" on bookings for select using (
//     auth.uid() = booker_user_id or auth.uid() in (select owner_user_id from spaces where spaces.id = bookings.space_id)
//   );
//   create policy "bookings insert by auth" on bookings for insert with check (auth.role() = 'authenticated');
//   create policy "bookings update own" on bookings for update using (auth.uid() = booker_user_id);
//
// --------------------------- End of setup notes ---------------------------

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'P2P Parking',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/home': (_) => const HomePage(),
        '/profile': (_) => const ProfilePage(),
        '/post': (_) => const PostSpacePage(),
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
    return Booking.fromMap(row as Map<String, dynamic>);
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
                  const Icon(Icons.local_parking, size: 64),
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
                                      icon: const Icon(Icons.directions_car),
                                      label: const Text('Park'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          () => Navigator.of(
                                            context,
                                          ).pushNamed('/post').then((_) async {
                                            await _fetchNearby();
                                            setState(() {});
                                          }),
                                      icon: const Icon(Icons.add_location_alt),
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
          SizedBox(
            width: double.infinity,
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
              icon: const Icon(Icons.check_circle),
              label: Text(_booking ? 'Booking...' : 'Book & Navigate'),
            ),
          ),
        ],
      ),
    );
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
                      icon: const Icon(Icons.navigation),
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
  final uri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=${dest.latitude},${dest.longitude}&travelmode=driving',
  );
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
  const PostSpacePage({super.key});
  @override
  State<PostSpacePage> createState() => _PostSpacePageState();
}

class _PostSpacePageState extends State<PostSpacePage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController(text: 'My Spare Spot');
  final _dimensions = TextEditingController(text: '5.0m x 2.5m');
  final _price = TextEditingController(text: '50');
  bool _gated = true;
  bool _guarded = false;
  CoverType _cover = CoverType.covered;
  LatLng? _useLocation;
  bool _saving = false;
  final Set<String> _allowed = {'2w', '3w', '4w'};

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
        id: 'temp',
        title: _title.text.trim(),
        ownerUserId: uid,
        pricePerHour: double.tryParse(_price.text.trim()) ?? 50,
        location: _useLocation!,
        dimensions: _dimensions.text.trim(),
        gated: _gated,
        guarded: _guarded,
        coverType: _cover,
        allowedTypes: _allowed.toList(),
      );
      await Db.insertSpace(space);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Space posted!')));
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
      appBar: AppBar(title: const Text('Post a Space')),
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
                  trailing: OutlinedButton.icon(
                    onPressed: _getCurrent,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Use Current'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.upload),
                    label:
                        _saving
                            ? const Text('Posting...')
                            : const Text('Post Space'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------ Profile Page ------------------------------

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  List<ParkingSpace> _mine = [];

  Future<void> _load() async {
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final list = await Db.spacesByOwner(uid);
    setState(() => _mine = list);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final u = Supabase.instance.client.auth.currentUser!;
    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  child: Text(
                    _initials(u.email ?? 'U'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.email ?? 'Unknown',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text('Authenticated via Supabase'),
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
              ..._mine.map((s) => _SpaceListTile(space: s)),
          ],
        ),
      ),
    );
  }
}

class _SpaceListTile extends StatelessWidget {
  final ParkingSpace space;
  const _SpaceListTile({required this.space});
  @override
  Widget build(BuildContext context) {
    final rs = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    return Card(
      child: ListTile(
        leading: const Icon(Icons.local_parking),
        title: Text(space.title),
        subtitle: Text(
          '${space.dimensions} • ${space.coverType == CoverType.covered ? 'Covered' : 'Open'}\n'
          '${space.gated ? 'Gated' : 'Not gated'} • ${space.guarded ? 'Guarded' : 'Un-guarded'}\n'
          'Allows: ${space.allowedTypes.join(', ')}',
        ),
        trailing: Text('${rs.format(space.pricePerHour)}/hr'),
        isThreeLine: true,
      ),
    );
  }
}

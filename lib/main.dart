import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// NOTIFICATIONS
// ---------------------------------------------------------------------------

final FlutterLocalNotificationsPlugin notificationsPlugin =
FlutterLocalNotificationsPlugin();

// Sets up notifications and asks the user for permission.
Future<void> initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notificationsPlugin.initialize(
    settings: const InitializationSettings(android: androidSettings),
  );
  final android = notificationsPlugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
}

// Shows a notification when a report changes status.
Future<void> showStatusNotification(Report report) async {
  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'report_status',
      'Report status updates',
      channelDescription: 'Tells you when your report changes status',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );
  final message = report.status == 'Fixed'
      ? 'Good news! "${report.title}" has been fixed.'
      : 'Your report "${report.title}" is now ${report.status}.';
  await notificationsPlugin.show(
    id: report.title.hashCode & 0x7FFFFFFF,
    title: 'Community Fix-It',
    body: message,
    notificationDetails: details,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  try {
    await initNotifications();
  } catch (e) {
    debugPrint('Notifications could not start: $e');
  }

  runApp(const FixItApp());
}


// ---------------------------------------------------------------------------
// USERS (two demo accounts: a citizen and a municipality officer)
// ---------------------------------------------------------------------------

class AppUser {
  final String username;
  final String password;
  final String displayName;
  final String role; // 'citizen' or 'municipality'

  const AppUser(this.username, this.password, this.displayName, this.role);

  bool get isMunicipality => role == 'municipality';
  String get roleLabel => isMunicipality ? 'Municipality' : 'Citizen';
}

const List<AppUser> demoUsers = [
  AppUser('citizen', 'citizen123', 'Community Resident', 'citizen'),
  AppUser('municipality', 'council123', 'Municipality Officer', 'municipality'),
];

// Finds a person's display name from their username.
String nameFor(String username) {
  for (final u in demoUsers) {
    if (u.username == username) return u.displayName;
  }
  return username;
}
Future<AppUser> appUserFromFirebase(User user) async {
  var role = 'citizen';

  try {
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get(const GetOptions(source: Source.server));

    if (profile.data()?['role'] == 'municipality') {
      role = 'municipality';
    }
  } on FirebaseException catch (error) {
    debugPrint('Could not read Firestore role: ${error.code}');
  }

  return AppUser(
    user.email!,
    '',
    user.displayName ??
        (role == 'municipality' ? 'Municipality Officer' : 'Community Resident'),
    role,
  );
}
// ---------------------------------------------------------------------------
// APP ROOT
// ---------------------------------------------------------------------------

class FixItApp extends StatelessWidget {
  const FixItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Community Fix-It',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          backgroundColor: Colors.teal,
          foregroundColor: Colors.white,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// Decides which screen to show: login, or the home screen for the user.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AppUser? _user;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restoreUser();
  }

  // If someone was logged in last time, log them in again.
  Future<void> _restoreUser() async {
    final user = await FirebaseAuth.instance.authStateChanges().first;
    final restoredUser =
    user == null || user.email == null ? null : await appUserFromFirebase(user);

    if (!mounted) return;
    setState(() {
      _user = restoredUser;
      _loading = false;
    });
  }

  Future<void> _login(AppUser user) async {
    if (!mounted) return;
    setState(() => _user = user);
  }
  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('currentUser');

    if (!mounted) return;
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_user == null) {
      return LoginScreen(onLogin: _login);
    }
    return HomeScreen(
      key: ValueKey(_user!.username),
      user: _user!,
      onLogout: _logout,
    );
  }
}

// ---------------------------------------------------------------------------
// DATA
// ---------------------------------------------------------------------------

// A blueprint for one report.
class Report {
  final String title;
  final String category;
  final String description;
  final String? photoPath;
  final double? latitude;
  final double? longitude;
  final String reporter; // username of the citizen who made it
  String status;
  String? note; // the municipality's response

  Report(this.title, this.category, this.description, this.status,
      {this.photoPath,
        this.latitude,
        this.longitude,
        this.reporter = 'citizen',
        this.note});

  Map<String, dynamic> toJson() => {
    'title': title,
    'category': category,
    'description': description,
    'status': status,
    'photoPath': photoPath,
    'latitude': latitude,
    'longitude': longitude,
    'reporter': reporter,
    'note': note,
  };

  factory Report.fromJson(Map<String, dynamic> json) => Report(
    json['title'] as String,
    json['category'] as String,
    json['description'] as String,
    json['status'] as String,
    photoPath: json['photoPath'] as String?,
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    // Older saved reports have no reporter, so they belong to the citizen.
    reporter: json['reporter'] as String? ?? 'citizen',
    note: json['note'] as String?,
  );
}

// The three stages a report moves through.
const List<String> statusSteps = ['Reported', 'In progress', 'Fixed'];

// Sample reports, shown only the very first time the app is opened.
List<Report> sampleReports() => [
  Report('Large pothole on Main Road', 'Pothole',
      'Deep hole near the taxi rank.', 'Reported'),
  Report('Streetlight not working', 'Streetlight',
      'Dark since last week.', 'In progress',
      note: 'An electrician has been booked for this week.'),
  Report('Illegal dumping near the park', 'Dumping',
      'Rubbish has been piling up.', 'Fixed'),
];

IconData categoryIcon(String category) {
  switch (category) {
    case 'Pothole':
      return Icons.add_road;
    case 'Streetlight':
      return Icons.lightbulb;
    case 'Water leak':
      return Icons.water_drop;
    case 'Dumping':
      return Icons.delete;
    default:
      return Icons.report_problem;
  }
}

Color statusColor(String status) {
  switch (status) {
    case 'In progress':
      return Colors.orange;
    case 'Fixed':
      return Colors.green;
    default:
      return Colors.red;
  }
}

// ---------------------------------------------------------------------------
// LOGIN SCREEN
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
  final Future<void> Function(AppUser) onLogin;

  const LoginScreen({super.key, required this.onLogin});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _hidePassword = true;
  String? _error;

  Future<void> submit() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _usernameController.text.trim();
    final password = _passwordController.text;

    setState(() => _error = null);

    UserCredential credential;
    try {
      credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.code == 'network-request-failed'
            ? 'Check your internet connection and try again.'
            : 'Sign-in failed (${e.code}). Check your email and password.';
      });
      return;
    }

    if (!mounted) return;
    final user = credential.user;
    if (user == null) return;

    final appUser = await appUserFromFirebase(user);
    if (!mounted) return;
    await widget.onLogin(appUser);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  const Icon(Icons.location_city, size: 72, color: Colors.teal),
                  const SizedBox(height: 8),
                  const Text(
                    'Community Fix-It',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('Report problems. Track the fix.'),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your Email'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_hidePassword
                            ? Icons.visibility
                            : Icons.visibility_off),
                        onPressed: () =>
                            setState(() => _hidePassword = !_hidePassword),
                      ),
                    ),
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your password'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: submit,
                      icon: const Icon(Icons.login),
                      label: const Text('Log in'),
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Demo accounts (tap one to fill in the details).
                  Card(
                    color: Colors.teal.shade50,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Text(
                            'Demo accounts (tap to fill in)',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        for (final u in demoUsers)
                          ListTile(
                            dense: true,
                            leading: Icon(u.isMunicipality
                                ? Icons.admin_panel_settings
                                : Icons.person),
                            title: Text(u.roleLabel),
                            subtitle:
                            Text('${u.username} / ${u.password}'),

                          ),
                      ],
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

// ---------------------------------------------------------------------------
// HOME SCREEN
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  final AppUser user;
  final Future<void> Function() onLogout;

  const HomeScreen({super.key, required this.user, required this.onLogout});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Report> reports = []; // ALL reports (both users share one list)
  bool _loading = true;
  String _filter = 'All';
  String _search = '';

  final List<String> filters = ['All', ...statusSteps];

  @override
  void initState() {
    super.initState();
    loadReports();
  }

  Future<void> loadReports() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('reports');
    List<Report> loaded;
    if (saved == null) {
      loaded = sampleReports();
    } else {
      final list = jsonDecode(saved) as List;
      loaded = list
          .map((item) => Report.fromJson(item as Map<String, dynamic>))
          .toList();
    }
    if (!mounted) return;
    setState(() {
      reports = loaded;
      _loading = false;
    });
  }

  Future<void> saveReports() async {
    final prefs = await SharedPreferences.getInstance();
    final text = jsonEncode(reports.map((r) => r.toJson()).toList());
    await prefs.setString('reports', text);
  }

  // The reports this user is allowed to see:
  // the municipality sees everything, a citizen only sees their own.
  List<Report> get myReports {
    if (widget.user.isMunicipality) return reports;
    return reports.where((r) => r.reporter == widget.user.username).toList();
  }

  // Then apply the chosen chip and the search text.
  List<Report> get visibleReports {
    return myReports.where((r) {
      final matchesStatus = _filter == 'All' || r.status == _filter;
      final matchesSearch =
      r.title.toLowerCase().contains(_search.toLowerCase());
      return matchesStatus && matchesSearch;
    }).toList();
  }

  int countFor(String filter) {
    if (filter == 'All') return myReports.length;
    return myReports.where((r) => r.status == filter).length;
  }

  Future<void> openNewReportForm() async {
    final newReport = await Navigator.push<Report>(
      context,
      MaterialPageRoute(
        builder: (context) => NewReportScreen(user: widget.user),
      ),
    );
    if (newReport != null) {
      setState(() {
        reports.insert(0, newReport);
      });
      await saveReports();
    }
  }

  Future<void> openDetails(Report report) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => ReportDetailsScreen(
          report: report,
          user: widget.user,
          onChanged: saveReports,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      if (deleted == true) {
        reports.remove(report);
      }
    });
    await saveReports();
  }

  @override
  Widget build(BuildContext context) {
    final shown = visibleReports;
    final user = widget.user;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Community Fix-It'),
        actions: [
          IconButton(
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          // Who is logged in
          Container(
            width: double.infinity,
            color: Colors.teal.shade50,
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  user.isMunicipality
                      ? Icons.admin_panel_settings
                      : Icons.person,
                  color: Colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${user.displayName} · ${user.roleLabel}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          // Search box
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              onChanged: (value) => setState(() => _search = value),
              decoration: const InputDecoration(
                hintText: 'Search reports',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          // Status filter chips
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: filters.map((f) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('$f (${countFor(f)})'),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                );
              }).toList(),
            ),
          ),
          // The list
          Expanded(
            child: shown.isEmpty
                ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.inbox,
                      size: 64, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(
                    myReports.isEmpty
                        ? (user.isMunicipality
                        ? 'No reports have been submitted yet'
                        : 'No reports yet. Tap "New report".')
                        : 'No reports match your search',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 80),
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final report = shown[index];
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: ListTile(
                    onTap: () => openDetails(report),
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primaryContainer,
                      child: Icon(categoryIcon(report.category)),
                    ),
                    title: Text(
                      report.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      user.isMunicipality
                          ? '${report.category} · by ${nameFor(report.reporter)}'
                          : report.category,
                    ),
                    trailing: Chip(
                      label: Text(
                        report.status,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12),
                      ),
                      backgroundColor: statusColor(report.status),
                      side: BorderSide.none,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      // Only citizens can create reports.
      floatingActionButton: user.isMunicipality
          ? null
          : FloatingActionButton.extended(
        onPressed: openNewReportForm,
        icon: const Icon(Icons.add),
        label: const Text('New report'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// REPORT DETAILS SCREEN
// ---------------------------------------------------------------------------

class ReportDetailsScreen extends StatefulWidget {
  final Report report;
  final AppUser user;
  final VoidCallback onChanged; // tells the home screen to save

  const ReportDetailsScreen({
    super.key,
    required this.report,
    required this.user,
    required this.onChanged,
  });

  @override
  State<ReportDetailsScreen> createState() => _ReportDetailsScreenState();
}

class _ReportDetailsScreenState extends State<ReportDetailsScreen> {
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.report.note ?? '');
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // Asks "are you sure?" before deleting.
  Future<void> confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete report?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  // Municipality only: move the report to its next stage.
  Future<void> moveToNextStatus(int currentStep) async {
    setState(() {
      widget.report.status = statusSteps[currentStep + 1];
    });
    widget.onChanged();
    try {
      await showStatusNotification(widget.report);
    } catch (e) {
      debugPrint('Could not show notification: $e');
    }
  }

  // Municipality only: save the response for the citizen.
  void saveNote() {
    final text = _noteController.text.trim();
    setState(() {
      widget.report.note = text.isEmpty ? null : text;
    });
    widget.onChanged();
    showMessage('Response saved');
  }

  Future<void> openInMaps(double lat, double lng) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      final opened =
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        showMessage('Could not open Maps.');
      }
    } catch (e) {
      if (!mounted) return;
      showMessage('Could not open Maps.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final user = widget.user;
    final currentStep = statusSteps.indexOf(report.status);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Details'),
        actions: [
          // Only the citizen can delete a report.
          if (!user.isMunicipality)
            IconButton(
              onPressed: confirmDelete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete report',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (report.photoPath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(report.photoPath!),
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                  const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(categoryIcon(report.category)),
                ),
                const SizedBox(width: 12),
                Text(report.category, style: const TextStyle(fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              report.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Reported by ${nameFor(report.reporter)}',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Text(report.description, style: const TextStyle(fontSize: 16)),
            if (report.latitude != null && report.longitude != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Location: ${report.latitude!.toStringAsFixed(5)}, '
                          '${report.longitude!.toStringAsFixed(5)}',
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    openInMaps(report.latitude!, report.longitude!),
                icon: const Icon(Icons.map),
                label: const Text('Open in Maps'),
              ),
            ],
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            const Text(
              'Progress',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: List.generate(statusSteps.length, (i) {
                final reached = i <= currentStep;
                return Expanded(
                  child: Column(
                    children: [
                      CircleAvatar(
                        backgroundColor: reached
                            ? statusColor(statusSteps[i])
                            : Colors.grey.shade300,
                        child: Icon(
                          reached ? Icons.check : Icons.circle_outlined,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        statusSteps[i],
                        style: TextStyle(
                          fontWeight:
                          i == currentStep ? FontWeight.bold : null,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),

            // ---- What the CITIZEN sees ----
            if (!user.isMunicipality) ...[
              if (report.note != null)
                Card(
                  color: Colors.teal.shade50,
                  child: ListTile(
                    leading:
                    const Icon(Icons.support_agent, color: Colors.teal),
                    title: const Text('Municipality response'),
                    subtitle: Text(report.note!),
                  ),
                ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  report.status == 'Fixed'
                      ? 'This issue has been fixed. Thank you!'
                      : 'The municipality will update the status of your report.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: report.status == 'Fixed'
                        ? Colors.green
                        : Colors.grey.shade700,
                  ),
                ),
              ),
            ],

            // ---- What the MUNICIPALITY sees ----
            if (user.isMunicipality) ...[
              TextField(
                controller: _noteController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Response to the citizen',
                  hintText: 'e.g. Crew scheduled for Friday',
                  prefixIcon: Icon(Icons.edit_note),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: saveNote,
                icon: const Icon(Icons.save),
                label: const Text('Save response'),
              ),
              const SizedBox(height: 24),
              if (currentStep < statusSteps.length - 1)
                FilledButton.icon(
                  onPressed: () => moveToNextStatus(currentStep),
                  icon: const Icon(Icons.arrow_forward),
                  label: Text('Mark as ${statusSteps[currentStep + 1]}'),
                )
              else
                const Center(
                  child: Text(
                    'This issue has been fixed.',
                    style: TextStyle(fontSize: 16, color: Colors.green),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NEW REPORT SCREEN (citizens only)
// ---------------------------------------------------------------------------

class NewReportScreen extends StatefulWidget {
  final AppUser user;

  const NewReportScreen({super.key, required this.user});

  @override
  State<NewReportScreen> createState() => _NewReportScreenState();
}

class _NewReportScreenState extends State<NewReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _picker = ImagePicker();
  String _category = 'Pothole';
  String? _photoPath;
  double? _latitude;
  double? _longitude;
  bool _gettingLocation = false;

  final List<String> categories = [
    'Pothole',
    'Streetlight',
    'Water leak',
    'Dumping',
    'Other',
  ];

  void showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> pickPhoto(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        imageQuality: 80,
      );
      if (picked != null) {
        final folder = await getApplicationDocumentsDirectory();
        final newPath =
            '${folder.path}/report_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(picked.path).copy(newPath);
        if (!mounted) return;
        setState(() {
          _photoPath = newPath;
        });
      }
    } catch (e) {
      if (!mounted) return;
      showMessage('Could not open the camera or gallery.');
    }
  }

  Future<void> getLocation() async {
    setState(() => _gettingLocation = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        if (!mounted) return;
        showMessage('Please turn on Location in your phone settings.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        showMessage('Location permission was not given.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });
    } catch (e) {
      if (!mounted) return;
      showMessage('Could not get your location. Try again outside.');
    } finally {
      if (mounted) {
        setState(() => _gettingLocation = false);
      }
    }
  }

  void submit() {
    if (_formKey.currentState!.validate()) {
      final report = Report(
        _titleController.text,
        _category,
        _descriptionController.text,
        'Reported',
        photoPath: _photoPath,
        latitude: _latitude,
        longitude: _longitude,
        reporter: widget.user.username, // remember who made it
      );
      Navigator.pop(context, report);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Report')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  prefixIcon: Icon(Icons.title),
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                (value == null || value.isEmpty) ? 'Enter a title' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category),
                  border: OutlineInputBorder(),
                ),
                items: categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (value) => setState(() => _category = value!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descriptionController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  prefixIcon: Icon(Icons.description),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Describe the problem'
                    : null,
              ),
              const SizedBox(height: 16),
              if (_photoPath != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_photoPath!),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pickPhoto(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Take photo'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pickPhoto(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_latitude != null && _longitude != null)
                Card(
                  color: Colors.teal.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.location_on, color: Colors.red),
                    title: const Text('Location added'),
                    subtitle: Text(
                      '${_latitude!.toStringAsFixed(5)}, '
                          '${_longitude!.toStringAsFixed(5)}',
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: _gettingLocation ? null : getLocation,
                icon: _gettingLocation
                    ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Icon(Icons.my_location),
                label: Text(_gettingLocation
                    ? 'Finding location...'
                    : (_latitude == null
                    ? 'Add my location'
                    : 'Update my location')),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: submit,
                icon: const Icon(Icons.send),
                label: const Text('Submit report'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
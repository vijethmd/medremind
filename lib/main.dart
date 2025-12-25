import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initializationSettingsAndroid));
  
  // --- ANDROID 14 PERMISSION REQUESTS ---
  await _requestPermissions();
  
  runApp(const MedMinderApp());
}

Future<void> _requestPermissions() async {
  final androidPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  // Request Notification permission (Android 13+)
  await androidPlugin?.requestNotificationsPermission();
  // Request Exact Alarm permission (Android 14+)
  await androidPlugin?.requestExactAlarmsPermission();
}

class MedMinderApp extends StatelessWidget {
  const MedMinderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true, 
        colorSchemeSeed: Colors.indigoAccent, 
        textTheme: GoogleFonts.plusJakartaSansTextTheme()
      ),
      home: const DashboardHome(),
    );
  }
}

// --- LOCAL DATABASE HELPER ---
class DBHelper {
  static Future<Database> db() async {
    return openDatabase(
      p.join(await getDatabasesPath(), 'meds_v5.db'),
      version: 1,
      onCreate: (db, version) {
        return db.execute("CREATE TABLE medications(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, pattern TEXT, relation TEXT)");
      },
    );
  }

  static Future<int> createMed(String name, String pattern, String relation) async {
    final db = await DBHelper.db();
    return await db.insert('medications', {'name': name, 'pattern': pattern, 'relation': relation});
  }

  static Future<List<Map<String, dynamic>>> getMeds() async {
    final db = await DBHelper.db();
    return db.query('medications', orderBy: "id DESC");
  }

  static Future<void> deleteMed(int id) async {
    final db = await DBHelper.db();
    await db.delete('medications', where: "id = ?", whereArgs: [id]);
  }
}

// --- 1. DASHBOARD HOME ---
class DashboardHome extends StatelessWidget {
  const DashboardHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),
              Text("MedMinder", style: GoogleFonts.plusJakartaSans(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.indigo.shade900)),
              Text("Your Smart Health Partner", style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
              const SizedBox(height: 50),
              Text("Explore", style: GoogleFonts.plusJakartaSans(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2, crossAxisSpacing: 20, mainAxisSpacing: 20,
                children: [
                  _menuCard(context, "My Meds", Icons.medical_services_outlined, const Color(0xFF4E81EE), const MedListScreen(isEditMode: false)),
                  _menuCard(context, "Add Med", Icons.add_task_outlined, const Color(0xFF27AE60), const AddMedScreen()),
                  _menuCard(context, "Edit & Delete", Icons.auto_fix_high_outlined, const Color(0xFFF2994A), const MedListScreen(isEditMode: true)),
                  _menuCard(context, "Meal Times", Icons.schedule_outlined, const Color(0xFFEB5757), const MealSettingsScreen()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuCard(BuildContext context, String title, IconData icon, Color color, Widget screen) {
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => screen)),
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(32), boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 25)]),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: color, size: 36), const SizedBox(height: 12), Text(title, style: const TextStyle(fontWeight: FontWeight.bold))]),
      ),
    );
  }
}

// --- 2. ADD MEDICINE SCREEN ---
class AddMedScreen extends StatefulWidget {
  const AddMedScreen({super.key});
  @override
  State<AddMedScreen> createState() => _AddMedScreenState();
}

class _AddMedScreenState extends State<AddMedScreen> {
  final _name = TextEditingController();
  final _m = TextEditingController(); final _n = TextEditingController(); final _e = TextEditingController();
  final _f1 = FocusNode(); final _f2 = FocusNode(); final _f3 = FocusNode();
  bool _isAfter = true;

  // --- UPDATED SCHEDULING LOGIC WITH MEAL OFFSETS ---
  Future<void> _scheduleMeds(String name, String pattern, bool isAfter) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> dosages = pattern.split('-'); // e.g., ["1", "0", "1"]
    
    // Meal Keys: b (Breakfast), l (Lunch), d (Dinner)
    List<String> mealKeys = ['b', 'l', 'd'];
    List<String> mealNames = ['Morning', 'Afternoon', 'Night'];

    for (int i = 0; i < dosages.length; i++) {
      if (dosages[i] == '0') continue;

      int hour = prefs.getInt('${mealKeys[i]}H') ?? (i == 0 ? 8 : (i == 1 ? 13 : 20));
      int minute = prefs.getInt('${mealKeys[i]}M') ?? 0;

      // Apply Offsets: Before (-20m), After (+40m)
      DateTime mealTime = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, hour, minute);
      DateTime scheduledTime = isAfter ? mealTime.add(const Duration(minutes: 40)) : mealTime.subtract(const Duration(minutes: 20));

      final tz.TZDateTime tzScheduled = tz.TZDateTime.from(scheduledTime, tz.local);

      const android = AndroidNotificationDetails(
        'med_channel_v5', 'Medication Alarms',
        importance: Importance.max, priority: Priority.high,
        sound: RawResourceAndroidNotificationSound('med_alarm'), playSound: true,
      );

      await flutterLocalNotificationsPlugin.zonedSchedule(
        DateTime.now().millisecond + i, // Unique ID per dose
        'Medication Reminder',
        'Time for your ${mealNames[i]} dose: $name',
        tzScheduled.isBefore(tz.TZDateTime.now(tz.local)) ? tzScheduled.add(const Duration(days: 1)) : tzScheduled,
        const NotificationDetails(android: android),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text("New Prescription")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Medicine Name", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: "e.g. Dolo 650",
                hintStyle: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.w400),
                filled: true, fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 35),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _box("Morn", _m, _f1, _f2), _box("Noon", _n, _f2, _f3), _box("Night", _e, _f3, null),
            ]),
            const SizedBox(height: 35),
            Row(children: [
              Expanded(child: _foodBtn("Before Food", !_isAfter, () => setState(() => _isAfter = false))),
              const SizedBox(width: 15),
              Expanded(child: _foodBtn("After Food", _isAfter, () => setState(() => _isAfter = true))),
            ]),
            const SizedBox(height: 50),
            ElevatedButton(
              onPressed: () async {
                if (_name.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Name cannot be empty"), backgroundColor: Colors.redAccent));
                  return;
                }
                String pattern = "${_m.text.isEmpty?'0':_m.text}-${_n.text.isEmpty?'0':_n.text}-${_e.text.isEmpty?'0':_e.text}";
                await DBHelper.createMed(_name.text, pattern, _isAfter ? "After Food" : "Before Food");
                await _scheduleMeds(_name.text, pattern, _isAfter);
                if (mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 65), backgroundColor: Colors.indigoAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
              child: const Text("Save & Schedule", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box(String l, TextEditingController c, FocusNode cur, FocusNode? nxt) => Column(children: [
    Text(l, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)),
    const SizedBox(height: 10),
    SizedBox(width: 65, child: TextField(
      controller: c, focusNode: cur, textAlign: TextAlign.center, maxLength: 1, 
      onChanged: (v) => (v.isNotEmpty && nxt != null) ? FocusScope.of(context).requestFocus(nxt) : null,
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      decoration: InputDecoration(counterText: "", hintText: "0", hintStyle: TextStyle(color: Colors.grey.shade300), border: OutlineInputBorder(borderRadius: BorderRadius.circular(15))),
    ))
  ]);

  Widget _foodBtn(String l, bool a, VoidCallback t) => ElevatedButton(
    onPressed: t, style: ElevatedButton.styleFrom(backgroundColor: a ? Colors.indigoAccent : Colors.grey.shade100, foregroundColor: a ? Colors.white : Colors.black54, padding: const EdgeInsets.symmetric(vertical: 18)),
    child: Text(l, style: const TextStyle(fontWeight: FontWeight.bold)),
  );
}

// --- 3. MEAL TIMINGS SCREEN ---
class MealSettingsScreen extends StatefulWidget {
  const MealSettingsScreen({super.key});
  @override
  State<MealSettingsScreen> createState() => _MealSettingsScreenState();
}

class _MealSettingsScreenState extends State<MealSettingsScreen> {
  Map<String, TimeOfDay> _times = {'b': const TimeOfDay(hour: 8, minute: 0), 'l': const TimeOfDay(hour: 13, minute: 0), 'd': const TimeOfDay(hour: 20, minute: 0)};

  @override
  void initState() { super.initState(); _load(); }

  _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _times['b'] = TimeOfDay(hour: prefs.getInt('bH') ?? 8, minute: prefs.getInt('bM') ?? 0);
      _times['l'] = TimeOfDay(hour: prefs.getInt('lH') ?? 13, minute: prefs.getInt('lM') ?? 0);
      _times['d'] = TimeOfDay(hour: prefs.getInt('dH') ?? 20, minute: prefs.getInt('dM') ?? 0);
    });
  }

  _pick(String k) async {
    TimeOfDay? p = await showTimePicker(context: context, initialTime: _times[k]!);
    if (p != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${k}H', p.hour); await prefs.setInt('${k}M', p.minute);
      setState(() => _times[k] = p);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      appBar: AppBar(title: const Text("Meal Timings")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            _tile("Breakfast", 'b', Colors.orange),
            _tile("Lunch", 'l', Colors.blue),
            _tile("Dinner", 'd', Colors.indigo),
            const SizedBox(height: 30),
            
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.indigo.withOpacity(0.05),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.indigo.withOpacity(0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.info_outline, color: Colors.indigo, size: 20),
                    const SizedBox(width: 10),
                    Text("Reminder Settings", style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.bold, color: Colors.indigo)),
                  ]),
                  const SizedBox(height: 15),
                  _infoText("Before Food", "You will be notified 20 minutes before your set meal time."),
                  const Divider(height: 25, thickness: 0.5),
                  _infoText("After Food", "You will be notified 40 minutes after your set meal time."),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoText(String title, String desc) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)),
      Text(desc, style: const TextStyle(fontSize: 13, color: Colors.black54)),
    ],
  );

  Widget _tile(String title, String k, Color color) => Container(
    margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: color.withOpacity(0.05), blurRadius: 20)]),
    child: Row(children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        Text(_times[k]!.format(context), style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 22)),
      ]),
      const Spacer(),
      IconButton(onPressed: () => _pick(k), icon: const Icon(Icons.edit_calendar_outlined, size: 28), color: color)
    ]),
  );
}

// --- 4. LIST SCREEN ---
class MedListScreen extends StatefulWidget {
  final bool isEditMode;
  const MedListScreen({super.key, required this.isEditMode});
  @override
  State<MedListScreen> createState() => _MedListScreenState();
}

class _MedListScreenState extends State<MedListScreen> {
  List<Map<String, dynamic>> _meds = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _refresh(); }

  _refresh() async {
    final data = await DBHelper.getMeds();
    setState(() { _meds = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFF),
      appBar: AppBar(title: Text(widget.isEditMode ? "Edit & Delete" : "My Meds")),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _meds.isEmpty 
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.inventory_2_outlined, size: 80, color: Colors.indigo.withOpacity(0.1)),
              const SizedBox(height: 15),
              const Text("No Medications Scheduled", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
              const Text("Please add a medicine to get started.", style: TextStyle(color: Colors.grey)),
            ])) 
          : ListView.builder(
              padding: const EdgeInsets.all(24),
              itemCount: _meds.length,
              itemBuilder: (c, i) => Container(
                margin: const EdgeInsets.only(bottom: 15),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: ListTile(
                  title: Text(_meds[i]['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  subtitle: Text("${_meds[i]['relation']} (${_meds[i]['pattern']})"),
                  trailing: widget.isEditMode ? IconButton(icon: const Icon(Icons.delete_sweep, color: Colors.redAccent), onPressed: () async {
                    await DBHelper.deleteMed(_meds[i]['id']); _refresh();
                  }) : null,
                ),
              ),
            ),
    );
  }
}


// import 'package:flutter/material.dart';
// import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// import 'package:timezone/data/latest.dart' as tz;
// import 'package:timezone/timezone.dart' as tz;
// import 'package:shared_preferences/shared_preferences.dart';
// import 'package:google_fonts/google_fonts.dart';
// import 'package:sqflite/sqflite.dart';
// import 'package:path/path.dart' as p;

// final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   tz.initializeTimeZones();
  
//   const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
//   await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initializationSettingsAndroid));
  
//   runApp(const MedMinderApp());
// }

// class MedMinderApp extends StatelessWidget {
//   const MedMinderApp({super.key});
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       debugShowCheckedModeBanner: false,
//       theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigoAccent),
//       home: const DashboardHome(),
//     );
//   }
// }

// // --- DATABASE HELPER ---
// class DBHelper {
//   static Future<Database> db() async => openDatabase(
//     p.join(await getDatabasesPath(), 'medminder_final_fix.db'), 
//     version: 1, 
//     onCreate: (db, v) => db.execute("CREATE TABLE medications(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, pattern TEXT, relation TEXT)")
//   );
//   static Future<int> createMed(String n, String p, String r) async => (await DBHelper.db()).insert('medications', {'name': n, 'pattern': p, 'relation': r});
//   static Future<List<Map<String, dynamic>>> getMeds() async => (await DBHelper.db()).query('medications', orderBy: "id DESC");
//   static Future<void> deleteMed(int id) async => (await DBHelper.db()).delete('medications', where: "id = ?", whereArgs: [id]);
// }

// // --- DASHBOARD ---
// class DashboardHome extends StatelessWidget {
//   const DashboardHome({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: const Text("MedMinder")),
//       body: Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             ElevatedButton(
//               style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
//               onPressed: () async {
//                 final androidPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
//                 await androidPlugin?.requestNotificationsPermission();
//                 await androidPlugin?.requestExactAlarmsPermission();
//                 ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Permissions Requested")));
//               },
//               child: const Text("STEP 1: ENABLE PERMISSIONS"),
//             ),
//             const SizedBox(height: 20),
//             ElevatedButton(
//               onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const AddMedScreen())),
//               child: const Text("STEP 2: ADD MEDICINE"),
//             ),
//             const SizedBox(height: 20),
//             ElevatedButton(
//               onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const MealSettingsScreen())),
//               child: const Text("STEP 3: SET MEAL TIMES"),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }

// // --- ADD MEDICINE ---
// class AddMedScreen extends StatefulWidget {
//   const AddMedScreen({super.key});
//   @override State<AddMedScreen> createState() => _AddMedScreenState();
// }

// class _AddMedScreenState extends State<AddMedScreen> {
//   final _name = TextEditingController();
//   final _m = TextEditingController(); final _n = TextEditingController(); final _e = TextEditingController();
//   bool _isAfter = true;

//   Future<void> _schedule(String name, String pattern, bool after) async {
//     final prefs = await SharedPreferences.getInstance();
//     List<String> doses = pattern.split('-');
//     List<String> keys = ['b', 'l', 'd'];

//     for (int i = 0; i < doses.length; i++) {
//       if (doses[i] == '0' || doses[i].isEmpty) continue;

//       int h = prefs.getInt('${keys[i]}H') ?? (i == 0 ? 8 : (i == 1 ? 13 : 20));
//       int m = prefs.getInt('${keys[i]}M') ?? 0;

//       DateTime meal = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, h, m);
//       // MATH: -20m if Before, +40m if After
//       DateTime scheduled = after ? meal.add(const Duration(minutes: 40)) : meal.subtract(const Duration(minutes: 20));

//       if (scheduled.isBefore(DateTime.now())) scheduled = scheduled.add(const Duration(days: 1));

//       // NEW CHANNEL ID TO RESET SAMSUNG SETTINGS
//       const android = AndroidNotificationDetails(
//         'urgent_med_v100', 'URGENT ALARMS',
//         channelDescription: 'Medicine reminders that override silence',
//         importance: Importance.max,
//         priority: Priority.max,
//         playSound: true,
//         enableVibration: true,
//         sound: RawResourceAndroidNotificationSound('med_alarm'),
//       );

//       await flutterLocalNotificationsPlugin.zonedSchedule(
//         name.hashCode + i,
//         'MEDICINE REMINDER',
//         'Take $name now',
//         tz.TZDateTime.from(scheduled, tz.local),
//         const NotificationDetails(android: android),
//         androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
//         uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
//         matchDateTimeComponents: DateTimeComponents.time,
//       );
//     }
//   }

//   @override
//   Widget build(BuildContext context) => Scaffold(
//     appBar: AppBar(title: const Text("New Medicine")),
//     body: Padding(
//       padding: const EdgeInsets.all(20),
//       child: Column(children: [
//         TextField(controller: _name, decoration: const InputDecoration(labelText: "Name")),
//         const SizedBox(height: 20),
//         Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
//           _input("Morn", _m), _input("Noon", _n), _input("Night", _e),
//         ]),
//         const SizedBox(height: 20),
//         Row(children: [
//           Expanded(child: ElevatedButton(onPressed: () => setState(() => _isAfter = false), child: const Text("Before"))),
//           const SizedBox(width: 10),
//           Expanded(child: ElevatedButton(onPressed: () => setState(() => _isAfter = true), child: const Text("After"))),
//         ]),
//         const Spacer(),
//         ElevatedButton(
//           style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
//           onPressed: () async {
//             if (_name.text.isEmpty) return;
//             String p = "${_m.text}-${_n.text}-${_e.text}";
//             await DBHelper.createMed(_name.text, p, _isAfter ? "After" : "Before");
//             await _schedule(_name.text, p, _isAfter);
//             Navigator.pop(context);
//           }, 
//           child: const Text("SAVE MEDICINE"),
//         )
//       ]),
//     ),
//   );

//   Widget _input(String l, TextEditingController c) => Column(children: [Text(l), SizedBox(width: 40, child: TextField(controller: c, textAlign: TextAlign.center))]);
// }

// // --- MEAL SETTINGS ---
// class MealSettingsScreen extends StatefulWidget {
//   const MealSettingsScreen({super.key});
//   @override State<MealSettingsScreen> createState() => _MealSettingsScreenState();
// }

// class _MealSettingsScreenState extends State<MealSettingsScreen> {
//   _pick(String k) async {
//     TimeOfDay? p = await showTimePicker(context: context, initialTime: TimeOfDay.now());
//     if (p != null) {
//       final prefs = await SharedPreferences.getInstance();
//       await prefs.setInt('${k}H', p.hour); await prefs.setInt('${k}M', p.minute);
//       setState(() {});
//     }
//   }
//   @override
//   Widget build(BuildContext context) => Scaffold(
//     appBar: AppBar(title: const Text("Meal Times")),
//     body: ListView(children: [
//       ListTile(title: const Text("Breakfast"), subtitle: const Text("Notifies -20m if 'Before'"), trailing: const Icon(Icons.edit), onTap: () => _pick('b')),
//       ListTile(title: const Text("Lunch"), trailing: const Icon(Icons.edit), onTap: () => _pick('l')),
//       ListTile(title: const Text("Dinner"), subtitle: const Text("Notifies +40m if 'After'"), trailing: const Icon(Icons.edit), onTap: () => _pick('d')),
//     ]),
//   );
// }

// class MedListScreen extends StatelessWidget {
//   final bool isEditMode;
//   const MedListScreen({super.key, required this.isEditMode});
//   @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text("List")));
// }
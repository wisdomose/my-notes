import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Reminder notifications, scheduled with the system alarm manager so
/// they fire even when the app isn't running (and again after a reboot).
/// The notification id is the note id.
class Reminders {
  Reminders._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<void>? _ready;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Reminders',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
  );

  /// [onTap] gets the note id of a tapped reminder (UI isolate only).
  static Future<void> init({void Function(int noteId)? onTap}) =>
      _ready ??= () async {
        tzdata.initializeTimeZones();
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
          onDidReceiveNotificationResponse: (r) {
            final id = int.tryParse(r.payload ?? '');
            if (id != null) onTap?.call(id);
          },
        );
      }();

  static AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// The note id of the reminder that launched the app, if any.
  static Future<int?> launchedFrom() async {
    await init();
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (d == null || !d.didNotificationLaunchApp) return null;
    return int.tryParse(d.notificationResponse?.payload ?? '');
  }

  /// Whether reminders can fire at the exact minute (Android 12+ asks the
  /// user for this); otherwise Android may deliver them a little late.
  static Future<bool> exactAllowed() async {
    await init();
    return await _android?.canScheduleExactNotifications() ?? true;
  }

  static Future<void> requestExact() async {
    await init();
    await _android?.requestExactAlarmsPermission();
  }

  /// Returns whether it was scheduled exactly.
  static Future<bool> schedule(int noteId, DateTime at, String what) async {
    await init();
    final exact = await exactAllowed();
    await _plugin.zonedSchedule(
      id: noteId,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: _details,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      title: what,
      payload: '$noteId',
    );
    return exact;
  }

  static Future<void> cancel(int noteId) async {
    await init();
    await _plugin.cancel(id: noteId);
  }
}

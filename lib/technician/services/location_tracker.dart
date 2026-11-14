import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';

/// Sends the technician's live GPS position to the backend while a job is
/// active (accepted / on_the_way / work_in_progress):
///   POST /technician/jobs/{jobId}/location  {latitude, longitude}
/// every [interval]. On Android a foreground notification keeps updates coming
/// when the app is in the background or the screen is off.
class LocationTracker {
  LocationTracker(this.api);

  final TechnicianApi api;
  static const interval = Duration(seconds: 10);
  static const _jobRefresh = Duration(seconds: 60);
  static const _activeStatuses = {
    'accepted',
    'on_the_way',
    'reached_location',
    'inspection_started',
    'work_in_progress',
  };

  Timer? _timer;
  StreamSubscription<Position>? _stream;
  Position? _last;
  bool _busy = false;
  List<String> _ids = const [];
  bool _sharingOff = false;
  DateTime? _refreshedAt;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => _tick());
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _stopStream();
  }

  void _stopStream() {
    _stream?.cancel();
    _stream = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      if (api.isPendingApproval) {
        _stopStream();
        return;
      }
      // Jobs / sharing switch are re-read once a minute, not on every ping.
      final due = _refreshedAt == null ||
          DateTime.now().difference(_refreshedAt!) >= _jobRefresh;
      if (due) {
        final jobs = await api.jobs();
        _ids = <String>[
          for (final j in jobs)
            if (j is Map &&
                _activeStatuses.contains(_normalize(j['status'])) &&
                j['id'] != null)
              j['id'].toString(),
        ];
        _sharingOff = false;
        if (_ids.isNotEmpty) {
          try {
            final profile = await api.getProfile();
            _sharingOff = profile['locationSharing'] == false;
          } catch (_) {}
        }
        _refreshedAt = DateTime.now();
      }
      final ids = _ids;
      if (ids.isEmpty || _sharingOff) {
        _stopStream();
        return;
      }

      if (!await _ensurePermission()) return;
      _ensureStream();

      Position? pos = _last;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 8)),
        );
        _last = pos;
      } catch (_) {}
      if (pos == null) return;

      for (final id in ids) {
        try {
          await api.updateLocation(id, pos.latitude, pos.longitude,
              accuracy: pos.accuracy);
        } catch (e) {
          debugPrint('Location ping failed for job $id: $e');
        }
      }
    } catch (e) {
      debugPrint('Location tracker: $e');
    } finally {
      _busy = false;
    }
  }

  String _normalize(dynamic s) =>
      (s ?? '').toString().trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  /// Android: a position stream with a foreground notification keeps the app
  /// process alive in the background so the timer keeps sending.
  void _ensureStream() {
    if (_stream != null) return;
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: interval,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'SignFix is sharing your location',
              notificationText: 'Your live location is shared during active jobs.',
              enableWakeLock: true,
            ),
          )
        : const LocationSettings(accuracy: LocationAccuracy.high);
    _stream = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) => _last = p,
      onError: (_) => _stopStream(),
    );
  }
}

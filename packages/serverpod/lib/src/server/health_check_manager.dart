import 'dart:async';
import 'dart:io';

import 'package:serverpod/protocol.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod/src/server/health_check.dart';
import 'package:system_resources/system_resources.dart';

/// Performs health checks on the server once a minute, typically this class
/// is managed internally by Serverpod. Writes results to the database.
/// The [HealthCheckManager] is also responsible for periodically read and update
/// the server configuration.
class HealthCheckManager {
  final Serverpod _pod;
  bool _running = false;
  Timer? _timer;

  /// Creates a new [HealthCheckManager].
  HealthCheckManager(this._pod);

  /// Starts the health check manager.
  Future<void> start() async {
    _running = true;
    try {
      await SystemResources.init();
    } catch (e) {
      stderr.writeln(
        'CPU and memory usage metrics are not supported on this platform.',
      );
    }
    _scheduleNextCheck();
  }

  /// Stops the health check manager.
  void stop() {
    _running = false;
    _timer?.cancel();
  }

  void _performHealthCheck() async {
    var session = await _pod.createSession(enableLogging: false);

    try {
      var result = await performHealthChecks(_pod);

      for (var metric in result.metrics) {
        await ServerHealthMetric.insert(session, metric);
      }

      for (var connectionInfo in result.connectionInfos) {
        await ServerHealthConnectionInfo.insert(session, connectionInfo);
      }
    } catch (e) {
      // TODO: Sometimes serverpod attempts to write duplicate health checks for
      // the same time. Doesn't cause any harm, but would be nice to fix.
    }

    await session.close();

    await _pod.reloadRuntimeSettings();

    await _cleanUpClosedSessions();

    _scheduleNextCheck();
  }

  void _scheduleNextCheck() {
    _timer?.cancel();
    if (!_running) {
      return;
    }
    _timer = Timer(_timeUntilNextMinute(), _performHealthCheck);
  }

  Future<void> _cleanUpClosedSessions() async {
    var session = await _pod.createSession(enableLogging: false);

    try {
      var encoder = DatabasePoolManager.encoder;

      var now = encoder.convert(DateTime.now().toUtc());
      var threeMinutesAgo = encoder.convert(
        DateTime.now().subtract(const Duration(minutes: 3)).toUtc(),
      );
      var serverStartTime = encoder.convert(_pod.startedTime);
      var serverId = encoder.convert(_pod.serverId);

      // Touch all sessions that have been opened by this server.
      var touchQuery =
          'UPDATE serverpod_session_log SET touched = $now WHERE "serverId" = $serverId AND "isOpen" = TRUE AND "time" > $serverStartTime';
      await session.db.query(touchQuery);

      // Close sessions that haven't been touched in 3 minutes.
      var closeQuery =
          'UPDATE serverpod_session_log SET "isOpen" = FALSE WHERE "isOpen" = TRUE AND "touched" < $threeMinutesAgo';
      await session.db.query(closeQuery);
    } catch (e, stackTrace) {
      stderr.writeln('Failed to cleanup closed sessions: $e');
      stderr.write('$stackTrace');
    }
  }
}

Duration _timeUntilNextMinute() {
  // Add a second to make sure we don't end up on the same minute.
  var now = DateTime.now().toUtc().add(const Duration(seconds: 2));
  var next =
      DateTime.utc(now.year, now.month, now.day, now.hour, now.minute).add(
    const Duration(minutes: 1),
  );

  return next.difference(now);
}

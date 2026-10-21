import 'package:flutter/foundation.dart';

import '../attendance_models.dart';
import 'session_history.dart';

final class SessionHistoryController extends ChangeNotifier {
  SessionHistoryController(this.repository, {DateTime Function()? now})
    : window = HistoryWindow.sixMonths((now ?? DateTime.now)());
  final SessionHistoryRepository repository;
  final HistoryWindow window;
  final _sessions = <WorkSession>[];
  bool _disposed = false;
  bool _loading = false;
  bool _loaded = false;
  HistoryFailure? _failure;
  HistoryCursor? _next;
  bool get isCurrent => !_disposed && repository.isCurrent;
  List<WorkSession> get sessions =>
      isCurrent ? List.unmodifiable(_sessions) : const [];
  bool get loading => isCurrent && _loading;
  bool get loaded => isCurrent && _loaded;
  bool get hasMore => isCurrent && _next != null;
  HistoryFailure? get failure => isCurrent ? _failure : const HistoryFailure();

  Future<void> loadMore() async {
    if (!isCurrent || _loading || (_loaded && _next == null)) return;
    _loading = true;
    _failure = null;
    notifyListeners();
    try {
      final page = await repository.load(window, before: _next);
      if (!isCurrent) return;
      _sessions.addAll(page.sessions);
      _next = page.next;
      _loaded = true;
    } catch (_) {
      if (isCurrent) _failure = const HistoryFailure();
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sessions.clear();
    super.dispose();
  }
}

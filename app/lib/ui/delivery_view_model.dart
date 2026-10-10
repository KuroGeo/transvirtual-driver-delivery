import 'package:flutter/foundation.dart';

import '../data/delivery/delivery_repository.dart';
import '../data/delivery/sync_coordinator.dart';
import '../models/delivery.dart';
import 'delivery/query/workbench_query.dart';
import 'delivery/query/workbench_session.dart';

export 'delivery/query/workbench_query.dart';
export 'delivery/query/workbench_session.dart';

class DeliveryViewModel extends ChangeNotifier {
  DeliveryViewModel({required this.repository, required this.syncCoordinator});

  final DeliveryRepository repository;
  final SyncCoordinator syncCoordinator;

  List<Stop> _stops = const [];
  List<PendingUpdate> _queue = const [];
  WorkbenchQuery _query = const WorkbenchQuery();
  WorkbenchResult _result = const WorkbenchQuery().evaluate(
    stops: const [],
    queue: const [],
  );
  WorkbenchPanel _panel = WorkbenchPanel.map;
  ListSessionContext _listSession = const ListSessionContext();
  DetailContext? _detailContext;
  bool _closed = false;
  Future<void>? _loading;
  Future<bool>? _saving;
  Future<void>? _syncing;
  Future<void>? _closing;
  bool isLoading = false;
  bool isSaving = false;
  bool isSyncing = false;
  String? loadError;
  String? saveError;
  String? syncMessage;

  List<Stop> get stops => List.unmodifiable(_stops);
  int get queueCount => _queue.length;
  int get pendingCount =>
      _stops.where((stop) => stop.status == DeliveryStatus.pending).length;
  WorkbenchQuery get query => _query;
  WorkbenchResult get result => _result;
  WorkbenchPanel get panel => _panel;
  ListSessionContext get listSession => _listSession;
  DetailContext? get detailContext => _detailContext;
  Stop? get selectedStop =>
      _detailContext == null ? null : stopById(_detailContext!.stopId);

  void setSearch(String search) => _setQuery(
    WorkbenchQuery(
      search: search,
      status: _query.status,
      waitingOnly: _query.waitingOnly,
    ),
  );

  void setStatus(DeliveryStatus? status) => _setQuery(
    WorkbenchQuery(
      search: _query.search,
      status: status,
      waitingOnly: _query.waitingOnly,
    ),
  );

  void setWaitingOnly(bool waitingOnly) => _setQuery(
    WorkbenchQuery(
      search: _query.search,
      status: _query.status,
      waitingOnly: waitingOnly,
    ),
  );

  void resetQuery() => _setQuery(const WorkbenchQuery());

  void _setQuery(WorkbenchQuery query) {
    if (_closed || _query == query) return;
    _query = query;
    _deriveResult();
    _notify();
  }

  void _deriveResult() {
    _result = _query.evaluate(stops: _stops, queue: _queue);
  }

  /// Controllers report session context without rebuilding the workbench.
  void rememberListSession({
    required double scrollOffset,
    String? focusedReference,
  }) {
    if (_closed || !scrollOffset.isFinite) return;
    _listSession = ListSessionContext(
      scrollOffset: scrollOffset < 0 ? 0 : scrollOffset,
      focusedReference: focusedReference ?? _listSession.focusedReference,
    );
  }

  void openList() {
    if (_closed) return;
    _detailContext = null;
    _panel = WorkbenchPanel.list;
    _notify();
  }

  void closeList() {
    if (_closed) return;
    _detailContext = null;
    _panel = WorkbenchPanel.map;
    _notify();
  }

  void openDetail(String stopId, {required DetailOrigin origin}) {
    if (_closed || stopById(stopId) == null) return;
    _detailContext = DetailContext(
      stopId: stopId,
      origin: origin,
      listSession: origin == DetailOrigin.list ? _listSession : null,
    );
    _panel = WorkbenchPanel.detail;
    saveError = null;
    _notify();
  }

  void closeDetail() {
    if (_closed || _detailContext == null) return;
    final context = _detailContext!;
    _panel = context.origin == DetailOrigin.list
        ? WorkbenchPanel.list
        : WorkbenchPanel.map;
    if (context.listSession != null) _listSession = context.listSession!;
    _detailContext = null;
    saveError = null;
    _notify();
  }

  Stop? stopById(String id) {
    for (final stop in _stops) {
      if (stop.id == id) return stop;
    }
    return null;
  }

  bool awaitsService(Stop stop) =>
      _queue.any((update) => update.stopId == stop.id);

  Future<void> load() {
    if (_closed) return Future<void>.value();
    final loading = _loading;
    if (loading != null) return loading;
    final future = Future<void>.microtask(
      _load,
    ).whenComplete(() => _loading = null);
    _loading = future;
    return future;
  }

  Future<void> _load() async {
    if (_closed) return;
    isLoading = true;
    loadError = null;
    _notify();
    try {
      if (_closed) return;
      await repository.initialize();
      await _refresh();
    } catch (_) {
      loadError = '配送数据无法加载，请重试。';
    } finally {
      isLoading = false;
      _notify();
    }
  }

  Future<bool> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) {
    if (_saving != null || _closed) return Future<bool>.value(false);
    final future = Future<bool>.microtask(
      () => _submit(stopId, status, reason: reason, note: note),
    ).whenComplete(() => _saving = null);
    _saving = future;
    return future;
  }

  Future<bool> _submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    if (_closed) return false;
    isSaving = true;
    saveError = null;
    _notify();
    var saved = false;
    try {
      if (_closed) return false;
      await repository.submit(stopId, status, reason: reason, note: note);
      saved = true;
      syncMessage = '已保存到本机，等待服务连接。';
      try {
        await _refresh();
      } catch (_) {
        loadError = '记录已保存，但列表刷新失败，请重试加载。';
      }
    } catch (_) {
      saveError = '保存失败，请重试。输入内容已保留。';
    } finally {
      isSaving = false;
      _notify();
    }
    return saved;
  }

  void clearSaveError() {
    if (_closed || saveError == null) return;
    saveError = null;
    _notify();
  }

  Future<void> sync() {
    if (_saving != null || _loading != null || _closed) {
      return Future<void>.value();
    }
    final syncing = _syncing;
    if (syncing != null) return syncing;
    final future = Future<void>.microtask(
      _sync,
    ).whenComplete(() => _syncing = null);
    _syncing = future;
    return future;
  }

  Future<void> _sync() async {
    if (_closed) return;
    isSyncing = true;
    syncMessage = null;
    _notify();
    try {
      if (_closed) return;
      await syncCoordinator.sync();
      syncMessage = '本机待同步记录已确认。';
    } catch (_) {
      syncMessage = '同步未完成。更新仍保存在本机，请稍后重试。';
    } finally {
      try {
        await _refresh();
      } catch (_) {
        loadError = '同步后列表刷新失败，请重试加载。';
      }
      isSyncing = false;
      _notify();
    }
  }

  Future<void> _refresh() async {
    if (_closed) return;
    final stops = await repository.loadStops();
    if (_closed) return;
    final queue = await repository.pendingUpdates();
    if (_closed) return;
    _stops = stops;
    _queue = queue;
    _deriveResult();
    loadError = null;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    // Register before pause/disposal callbacks so all callers join one close.
    final future = Future<void>.microtask(_finishClose);
    _closing = future;
    syncCoordinator.pause();
    return future;
  }

  Future<void> _finishClose() async {
    try {
      await Future.wait<void>([
        ?_loading,
        ?_saving?.then<void>((_) {}),
        ?_syncing,
      ]);
    } finally {
      super.dispose();
      await repository.close();
    }
  }
}

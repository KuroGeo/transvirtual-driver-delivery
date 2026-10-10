import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/delivery/delivery_repository.dart';
import '../data/delivery/delivery_settings_store.dart';
import '../data/delivery/sync_coordinator.dart';
import '../models/delivery.dart';
import '../models/workbench.dart';
import 'delivery/feedback/workbench_notice.dart';
import 'delivery/query/workbench_query.dart';
import 'delivery/query/workbench_session.dart';

export 'delivery/query/workbench_query.dart';
export 'delivery/query/workbench_session.dart';

class DeliveryViewModel extends ChangeNotifier {
  DeliveryViewModel({
    required this.repository,
    required this.syncCoordinator,
    this.settingsStore,
    this.mode = ClientMode.localClient,
    this.automaticSync = false,
  }) {
    syncCoordinator.addListener(_onProgress);
  }

  final DeliveryRepository repository;
  final SyncCoordinator syncCoordinator;
  final DeliverySettingsStore? settingsStore;
  final ClientMode mode;
  // Standalone components are manual. The formal factory explicitly enables it.
  final bool automaticSync;
  final notice = ValueNotifier<WorkbenchNotice?>(null);
  final syncProgress = ValueNotifier<SyncProgress?>(null);
  DeliverySettings? _settings;
  Future<void> _settingsTail = Future<void>.value();
  Future<void> _refreshTail = Future<void>.value();
  final _syncRuns = <Future<void>>{};
  Future<void>? _coordinatorRun;
  final _unrefreshed = <String, Stop>{};
  MapViewport? _pendingViewport;
  bool? _pendingOnline;
  int _snapshotVersion = 0;
  int _noticeId = 0;
  int _progressRun = 0;
  bool _hasLoaded = false;
  bool isChangingOnline = false;
  String? _onlineError;
  String? _viewportError;
  String? get settingsError => _onlineError ?? _viewportError;

  DeliverySettings? get settings => _settings;
  bool get online => _settings?.online ?? true;
  bool get canRecord =>
      !_closed && !isLoading && !isSaving && loadError == null;
  bool hasUnrefreshedResult(String stopId) => _unrefreshed.containsKey(stopId);
  String? get syncMessage => notice.value?.message;

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
    final known = _unrefreshed[id];
    if (known != null) return known;
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
    _notify();
    var loaded = false;
    try {
      if (_closed) return;
      await repository.initialize();
      if (_closed) return;
      await _settingsTail;
      if (_closed) return;
      final store = settingsStore;
      if (store != null) _settings = await store.loadSettings();
      if (_closed) return;
      await _refresh();
      _settings ??= DeliverySettings(
        datasetId: _queue.isEmpty
            ? 'component-session'
            : _queue.first.datasetId,
      );
      loaded = true;
    } catch (_) {
      loadError = 'Could not load deliveries. Reload to try again.';
    } finally {
      isLoading = false;
      _notify();
    }
    if (loaded && automaticSync && online && _queue.isNotEmpty && !_closed) {
      unawaited(_requestSync(manual: false));
    }
  }

  Future<bool> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) {
    if (_saving != null || _closed || loadError != null || isLoading) {
      return Future<bool>.value(false);
    }
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
      final before = stopById(stopId);
      await repository.submit(stopId, status, reason: reason, note: note);
      saved = true;
      _snapshotVersion++;
      if (before != null) {
        // These are known committed facts, not an invented repository snapshot.
        _unrefreshed[stopId] = Stop(
          id: before.id,
          reference: before.reference,
          customerName: before.customerName,
          address: before.address,
          latitude: before.latitude,
          longitude: before.longitude,
          status: status,
          timeWindow: before.timeWindow,
          reason: status == DeliveryStatus.failed ? reason?.trim() : null,
          note:
              status == DeliveryStatus.failed &&
                  note != null &&
                  note.trim().isNotEmpty
              ? note.trim()
              : null,
        );
      }
      showNotice(
        online ? 'Delivery saved locally.' : 'Saved locally · waiting to sync.',
        kind: NoticeKind.saved,
      );
      try {
        await _refresh();
      } catch (_) {
        loadError = 'Saved locally. Reload to update the delivery view.';
      }
    } catch (_) {
      saveError = 'Could not save. Your input is still here. Try again.';
    } finally {
      isSaving = false;
      _notify();
    }
    // A committed addition must wake the drain even if a view refresh failed.
    if (saved && automaticSync && online && !_closed) {
      unawaited(_requestSync(manual: false));
    }
    return saved;
  }

  void clearSaveError() {
    if (_closed || saveError == null) return;
    saveError = null;
    _notify();
  }

  Future<void> sync() => _requestSync(manual: true);

  Future<void> _requestSync({required bool manual}) {
    if (_closed || isLoading || !_hasLoaded) return Future<void>.value();
    if (!online) {
      showNotice(
        loadError != null
            ? 'Offline · updates stay saved on this device.'
            : _queue.isEmpty
            ? 'Offline · connect to check for updates.'
            : 'Offline · ${_queue.length} saved update${_queue.length == 1 ? '' : 's'} waiting.',
        kind: NoticeKind.information,
      );
      return Future<void>.value();
    }
    if (manual &&
        _queue.isEmpty &&
        loadError == null &&
        !syncCoordinator.isRunning) {
      showNotice('No saved updates to sync.', kind: NoticeKind.complete);
      return Future<void>.value();
    }
    if (!isSyncing) {
      isSyncing = true;
      _notify();
    }
    if (_closed) return Future<void>.value();
    // Always request a queue reread before joining the UI's existing Future.
    final raw = syncCoordinator.sync();
    if (identical(raw, _coordinatorRun)) return _syncing!;
    _coordinatorRun = raw;
    late final Future<void> observed;
    observed = raw
        .then<void>(
          (_) => _afterSync(raw, null),
          onError: (Object error, StackTrace stack) => _afterSync(raw, error),
        )
        .whenComplete(() {
          _syncRuns.remove(observed);
          if (identical(_syncing, observed)) {
            _syncing = null;
            _coordinatorRun = null;
            isSyncing = false;
            _notify();
          }
        });
    _syncing = observed;
    _syncRuns.add(observed);
    return observed;
  }

  Future<void> _afterSync(Future<void> raw, Object? error) async {
    final terminal = syncCoordinator.progress;
    try {
      await _refresh();
    } catch (_) {
      loadError =
          'Updates are saved. Reload to check their confirmation state.';
    }
    if (_closed || !identical(_coordinatorRun, raw)) return;
    final count = terminal?.confirmedCount ?? 0;
    final simulated = mode == ClientMode.demo ? 'Demo · ' : '';
    if (loadError != null) {
      showNotice(
        'Updates are saved. Reload to check their state.',
        kind: NoticeKind.information,
      );
    } else if (error != null) {
      showNotice(
        '$simulated${count > 0 ? '$count confirmed · ' : ''}'
        '${mode == ClientMode.localClient ? 'Service unavailable' : 'Could not sync'} · '
        '${_queue.length} update${_queue.length == 1 ? '' : 's'} still saved. Try again.',
        kind: NoticeKind.error,
      );
    } else if (!online && _queue.isNotEmpty) {
      showNotice(
        'Offline · $count confirmed; ${_queue.length} still saved.',
        kind: NoticeKind.information,
      );
    } else {
      showNotice(
        count == 0
            ? 'No saved updates to sync.'
            : '$simulated$count update${count == 1 ? '' : 's'} confirmed.',
        kind: NoticeKind.complete,
      );
    }
    _notify();
  }

  void _onProgress(SyncProgress progress) {
    if (_closed || progress.runId < _progressRun) return;
    _progressRun = progress.runId;
    syncProgress.value = progress;
    switch (progress.stage) {
      case SyncStage.started:
      case SyncStage.sending:
      case SyncStage.acknowledged:
        showNotice(
          online
              ? '${mode == ClientMode.demo ? 'Demo · ' : ''}Syncing · ${progress.confirmedCount} confirmed…'
              : 'Offline · ${progress.confirmedCount} confirmed; remaining updates stay saved.',
          kind: online ? NoticeKind.syncing : NoticeKind.information,
          persistent: online,
        );
        if (progress.stage == SyncStage.acknowledged) {
          _snapshotVersion++;
          unawaited(_refreshAfterAcknowledgement());
        }
      case SyncStage.paused:
        if (!online) {
          showNotice(
            'Offline · updates stay saved on this device.',
            kind: NoticeKind.information,
          );
        }
      case SyncStage.failed:
      case SyncStage.finished:
        // Final feedback waits for the persisted snapshot in _afterSync.
        break;
    }
  }

  Future<void> _refreshAfterAcknowledgement() async {
    try {
      await _refresh();
    } catch (_) {
      loadError =
          'Updates are saved. Reload to check their confirmation state.';
    }
    _notify();
  }

  Future<bool> setOnline(bool value) async {
    if (_closed || !_hasLoaded || isLoading || isChangingOnline) return false;
    if (value == online) return true;
    isChangingOnline = true;
    _notify();
    try {
      if (_closed) return false;
      _pendingOnline = value;
      return await _writeSettings(
        () async {
          await settingsStore?.saveOnline(value);
          if (_closed) return;
          _settings = DeliverySettings(
            datasetId: _settings!.datasetId,
            online: value,
            viewport: _settings!.viewport,
          );
          _pendingOnline = null;
          _onlineError = null;
          if (!value) {
            syncCoordinator.pause();
            showNotice(
              'Offline · updates stay saved on this device.',
              kind: NoticeKind.information,
            );
          } else if (automaticSync) {
            unawaited(_requestSync(manual: false));
          }
          _notify();
        },
        'Could not save the connection setting. Try again.',
        connection: true,
      );
    } finally {
      isChangingOnline = false;
      _notify();
    }
  }

  Future<bool> saveViewport(MapViewport viewport) {
    if (_closed ||
        !_hasLoaded ||
        isLoading ||
        viewport.datasetId != _settings?.datasetId) {
      return Future<bool>.value(false);
    }
    _pendingViewport = viewport;
    return _writeSettings(
      () async {
        await settingsStore?.saveViewport(viewport);
        if (_closed) return;
        _settings = DeliverySettings(
          datasetId: _settings!.datasetId,
          online: online,
          viewport: viewport,
        );
        if (identical(_pendingViewport, viewport)) _pendingViewport = null;
        final hadError = _viewportError != null;
        _viewportError = null;
        if (hadError) _notify();
      },
      'Could not save the map position. Try again.',
      connection: false,
    );
  }

  Future<bool> retrySettings() {
    final onlineValue = _pendingOnline;
    if (onlineValue != null) return setOnline(onlineValue);
    final viewport = _pendingViewport;
    return viewport == null
        ? Future<bool>.value(false)
        : saveViewport(viewport);
  }

  Future<bool> _writeSettings(
    Future<void> Function() write,
    String errorMessage, {
    required bool connection,
  }) {
    final future = _settingsTail.then<bool>((_) async {
      if (_closed) return false;
      try {
        await write();
        return true;
      } catch (_) {
        if (connection) {
          _onlineError = errorMessage;
        } else {
          _viewportError = errorMessage;
        }
        showNotice(errorMessage, kind: NoticeKind.error);
        _notify();
        return false;
      }
    });
    _settingsTail = future.then<void>((_) {});
    return future;
  }

  Future<void> _refresh() {
    final future = _refreshTail.then<void>((_) async {
      while (!_closed) {
        final version = _snapshotVersion;
        final stops = await repository.loadStops();
        if (_closed) return;
        final queue = await repository.pendingUpdates();
        if (_closed) return;
        if (version != _snapshotVersion) continue;
        _stops = stops;
        _queue = queue;
        _unrefreshed.clear();
        _deriveResult();
        loadError = null;
        _hasLoaded = true;
        return;
      }
    });
    _refreshTail = future.catchError((Object error) {});
    return future;
  }

  void showNotice(
    String message, {
    required NoticeKind kind,
    bool persistent = false,
  }) {
    if (_closed) return;
    notice.value = WorkbenchNotice(
      id: ++_noticeId,
      message: message,
      kind: kind,
      persistent: persistent,
    );
  }

  void clearNotice(int id) {
    if (!_closed && notice.value?.id == id) notice.value = null;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    final future = Future<void>.microtask(_finishClose);
    _closing = future;
    syncCoordinator.removeListener(_onProgress);
    syncCoordinator.pause();
    return future;
  }

  Future<void> _finishClose() async {
    try {
      await Future.wait<void>([
        ?_loading,
        ?_saving?.then<void>((_) {}),
        ..._syncRuns,
        _settingsTail,
        _refreshTail,
      ]);
    } finally {
      notice.dispose();
      syncProgress.dispose();
      super.dispose();
      await repository.close();
    }
  }
}

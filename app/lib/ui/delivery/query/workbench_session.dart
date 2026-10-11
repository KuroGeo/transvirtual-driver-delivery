enum WorkbenchPanel { map, list, detail }

enum DetailOrigin { list, map, nearest }

/// Ephemeral session state. It is deliberately never written to settings.
class ListSessionContext {
  const ListSessionContext({this.scrollOffset = 0, this.focusedReference});

  final double scrollOffset;
  final String? focusedReference;
}

/// The entry origin is explicit, even if a list happens to be open underneath.
class DetailContext {
  const DetailContext({
    required this.stopId,
    required this.origin,
    this.listSession,
  });

  final String stopId;
  final DetailOrigin origin;
  final ListSessionContext? listSession;
}

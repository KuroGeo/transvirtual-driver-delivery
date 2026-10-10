enum NoticeKind { saved, syncing, complete, information, error }

class WorkbenchNotice {
  const WorkbenchNotice({
    required this.id,
    required this.message,
    required this.kind,
    this.persistent = false,
  });

  final int id;
  final String message;
  final NoticeKind kind;
  final bool persistent;
}

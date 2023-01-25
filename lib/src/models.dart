import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus {
  /// Task is enqueued on the native platform and waiting to start
  ///
  /// It may wait for resources, or for an appropriate network to become
  /// available before starting the actual download and changing state to
  /// `running`.
  enqueued,

  /// Task is running, i.e. actively downloading
  running,

  /// Task has completed successfully and the file is available
  ///
  /// This is a final state
  complete,

  /// Task has completed because the url was not found (Http status code 404)
  ///
  /// This is a final state
  notFound,

  /// Task has failed to download due to an error
  ///
  /// This is a final state
  failed,

  /// Task has been canceled by the user or the system
  ///
  /// This is a final state
  canceled,

  /// Task failed, and is now waiting to retry
  ///
  /// The task is held in this state until the exponential backoff time for
  /// this retry has passed, and will then be rescheduled on the native
  /// platform, switching state to `enqueued` and then `running`
  waitingToRetry;

  /// True if this state is one of the 'final' states, meaning no more
  /// state changes are possible
  bool get isFinalState {
    switch (this) {
      case DownloadTaskStatus.complete:
      case DownloadTaskStatus.notFound:
      case DownloadTaskStatus.failed:
      case DownloadTaskStatus.canceled:
        return true;

      case DownloadTaskStatus.enqueued:
      case DownloadTaskStatus.running:
      case DownloadTaskStatus.waitingToRetry:
        return false;
    }
  }

  /// True if this state is not a 'final' state, meaning more
  /// state changes are possible
  bool get isNotFinalState => !isFinalState;
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory {
  /// As returned by getApplicationDocumentsDirectory()
  applicationDocuments,

  /// As returned by getTemporaryDirectory()
  temporary,

  /// As returned by getApplicationSupportDirectory() - iOS only
  applicationSupport
}

/// Type of download updates requested for a group of downloads
enum DownloadTaskProgressUpdates {
  /// no status change or progress updates
  none,

  /// only status changes
  statusChange,

  /// only progress updates while downloading, no status change updates
  progressUpdates,

  /// Status change updates and progress updates while downloading
  statusChangeAndProgressUpdates,
}

/// A server Request
///
/// An equality test on a [Request] is an equality test on the [url]
class Request {
  /// String representation of the url, urlEncoded
  final String url;

  /// potential additional headers to send with the request
  final Map<String, String> headers;

  /// Set [post] to make the request using POST instead of GET.
  /// Post must be one of the following:
  /// - a String: POST request with [post] as the body, encoded in utf8 and
  ///   default content-type 'text/plain'
  /// - a List of bytes: POST request with [post] as the body
  final Object? post;

  /// Maximum number of retries the downloader should attempt
  ///
  /// Defaults to 0, meaning no retry will be attempted
  final int retries;

  /// Number of retries remaining
  int _retriesRemaining;

  /// Creates a [Request]
  ///
  /// [url] must not be encoded and can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url]
  /// [headers] an optional map of HTTP request headers
  /// [post] if set, uses POST instead of GET. Post must be one of the
  /// following:
  /// - a String: POST request with [post] as the body, encoded in utf8 and
  ///   default content-type 'text/plain'
  /// - a List of bytes: POST request with [post] as the body
  ///
  /// [retries] if >0 will retry a failed download this many times
  Request(
      {required String url,
      Map<String, String>? urlQueryParameters,
      this.headers = const {},
      this.post,
      this.retries = 0})
      : _retriesRemaining = retries,
        url = _urlWithQueryParameters(url, urlQueryParameters) {
    if (retries < 0 || retries > 10) {
      throw ArgumentError('Number of retries must be in range 1 through 10');
    }
    if (!(post == null || post is String || post is Uint8List)) {
      print(post.runtimeType);
      throw ArgumentError(
          'Field post must be a String or a Uint8List');
    }
  }

  /// Creates object from JsonMap
  Request.fromJsonMap(Map<String, dynamic> jsonMap)
      : url = jsonMap['url'],
        headers = Map<String, String>.from(jsonMap['headers']),
        post = jsonMap['post'],
        retries = jsonMap['retries'],
        _retriesRemaining = jsonMap['retriesRemaining'];

  /// Creates JSON map of this object
  Map toJsonMap() => {
        'url': url,
        'headers': headers,
        'post': post,
        'retries': retries,
        'retriesRemaining': _retriesRemaining,
      };

  /// Decrease [_retriesRemaining] by one
  void decreaseRetriesRemaining() => _retriesRemaining--;

  /// Number of retries remaining
  int get retriesRemaining => _retriesRemaining;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Request && runtimeType == other.runtimeType && url == other.url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() {
    return 'Request{url: $url, headers: $headers, post: ${post == null ? "null" : "not null"}, '
        'retries: $retries, retriesRemaining: $_retriesRemaining}';
  }
}

/// Information related to a download task
///
/// An equality test on a [BackgroundDownloadTask] is a test on the [taskId]
/// only - all other fields are ignored in that test
class BackgroundDownloadTask extends Request {
  /// Identifier for the task - auto generated if omitted
  final String taskId;

  /// Filename of the file to store
  final String filename;

  /// Optional directory, relative to the base directory
  final String directory;

  /// Base directory
  final BaseDirectory baseDirectory;

  /// Group that this task belongs to
  final String group;

  /// Type of progress updates desired
  final DownloadTaskProgressUpdates progressUpdates;

  /// If true, will not download over cellular (metered) network
  final bool requiresWiFi;

  /// User-defined metadata
  final String metaData;

  /// Creates a [BackgroundDownloadTask]
  ///
  /// [taskId] must be unique. A unique id will be generated if omitted
  /// [url] must not be encoded and can include query parameters
  /// [urlQueryParameters] may be added and will be appended to the [url]
  /// [filename] of the file to save. If omitted, a random filename will be
  /// generated
  /// [headers] an optional map of HTTP request headers
  /// [post] if set, uses POST instead of GET. Post must be one of the
  /// following:
  /// - true: POST request without a body
  /// - a String: POST request with [post] as the body, encoded in utf8 and
  ///   content-type 'text/plain'
  /// - a List of bytes: POST request with [post] as the body
  /// - a Map: POST request with [post] as form fields, encoded in utf8 and
  ///   content-type 'application/x-www-form-urlencoded'
  ///
  /// [directory] optional directory name, precedes [filename]
  /// [baseDirectory] one of the base directories, precedes [directory]
  /// [group] if set allows different callbacks or processing for different
  /// groups
  /// [progressUpdates] the kind of progress updates requested
  /// [requiresWiFi] if set, will not start download until WiFi is available.
  /// If not set may start download over cellular network
  /// [retries] if >0 will retry a failed download this many times
  /// [metaData] user data
  BackgroundDownloadTask(
      {String? taskId,
      required super.url,
      super.urlQueryParameters,
      String? filename,
      super.headers,
      super.post,
      this.directory = '',
      this.baseDirectory = BaseDirectory.applicationDocuments,
      this.group = 'default',
      this.progressUpdates = DownloadTaskProgressUpdates.statusChange,
      this.requiresWiFi = false,
      super.retries,
      this.metaData = ''})
      : taskId = taskId ?? Random().nextInt(1 << 32).toString(),
        filename = filename ?? Random().nextInt(1 << 32).toString() {
    if (filename?.isEmpty == true) {
      throw ArgumentError('Filename cannot be empty');
    }
    if (filename?.contains(Platform.pathSeparator) == true) {
      throw ArgumentError('Filename cannot contain path separators');
    }
    if (directory.startsWith(Platform.pathSeparator)) {
      throw ArgumentError(
          'Directory must be relative to the baseDirectory specified in the baseDirectory argument');
    }
  }

  /// Returns a copy of the [BackgroundDownloadTask] with optional changes to
  /// specific fields
  BackgroundDownloadTask copyWith(
          {String? taskId,
          String? url,
          String? filename,
          Map<String, String>? headers,
          Object? post,
          String? directory,
          BaseDirectory? baseDirectory,
          String? group,
          DownloadTaskProgressUpdates? progressUpdates,
          bool? requiresWiFi,
          int? retries,
          int? retriesRemaining,
          String? metaData}) =>
      BackgroundDownloadTask(
          taskId: taskId ?? this.taskId,
          url: url ?? this.url,
          filename: filename ?? this.filename,
          headers: headers ?? this.headers,
          post: post ?? this.post,
          directory: directory ?? this.directory,
          baseDirectory: baseDirectory ?? this.baseDirectory,
          group: group ?? this.group,
          progressUpdates: progressUpdates ?? this.progressUpdates,
          requiresWiFi: requiresWiFi ?? this.requiresWiFi,
          retries: retries ?? this.retries,
          metaData: metaData ?? this.metaData)
        .._retriesRemaining = retriesRemaining ?? this._retriesRemaining;

  /// Creates object from JsonMap
  BackgroundDownloadTask.fromJsonMap(Map<String, dynamic> jsonMap)
      : taskId = jsonMap['taskId'],
        filename = jsonMap['filename'],
        directory = jsonMap['directory'],
        baseDirectory = BaseDirectory.values[jsonMap['baseDirectory']],
        group = jsonMap['group'],
        progressUpdates =
            DownloadTaskProgressUpdates.values[jsonMap['progressUpdates']],
        requiresWiFi = jsonMap['requiresWiFi'],
        metaData = jsonMap['metaData'],
        super.fromJsonMap(jsonMap);

  /// Creates JSON map of this object
  @override
  Map toJsonMap() => {
        ...super.toJsonMap(),
        'taskId': taskId,
        'filename': filename,
        'directory': directory,
        'baseDirectory': baseDirectory.index, // stored as int
        'group': group,
        'progressUpdates': progressUpdates.index, // stored as int
        'requiresWiFi': requiresWiFi,
        'metaData': metaData
      };

  /// If true, task expects progress updates
  bool get providesProgressUpdates =>
      progressUpdates == DownloadTaskProgressUpdates.progressUpdates ||
      progressUpdates ==
          DownloadTaskProgressUpdates.statusChangeAndProgressUpdates;

  /// If true, task expects status updates
  bool get providesStatusUpdates =>
      progressUpdates == DownloadTaskProgressUpdates.statusChange ||
      progressUpdates ==
          DownloadTaskProgressUpdates.statusChangeAndProgressUpdates;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundDownloadTask &&
          runtimeType == other.runtimeType &&
          taskId == other.taskId;

  @override
  int get hashCode => taskId.hashCode;

  @override
  String toString() {
    return 'BackgroundDownloadTask{taskId: $taskId, url: $url, filename: $filename, headers: $headers, directory: $directory, baseDirectory: $baseDirectory, group: $group, progressUpdates: $progressUpdates, requiresWiFi: $requiresWiFi, retries: $retries, retriesRemaining: $_retriesRemaining, metaData: $metaData}';
  }
}

/// Return fully encoded url String composed of the [url] and the
/// [urlQueryParameters], if given
///
/// Note the assumption is that the original [url] is not encoded
String _urlWithQueryParameters(
    String url, Map<String, String>? urlQueryParameters) {
  if (urlQueryParameters == null || urlQueryParameters.isEmpty) {
    return Uri.encodeFull(url);
  }
  final separator = url.contains('?') ? '&' : '?';
  return Uri.encodeFull(
      '$url$separator${urlQueryParameters.entries.map((e) => '${e.key}=${e.value}').join('&')}');
}

/// Signature for a function you can provide to the [downloadBatch] method
/// that will be called upon completion of each file download in the batch.
///
/// [succeeded] will count the number of successful downloads, and
/// [failed] counts the number of failed downloads (for any reason).
typedef BatchDownloadProgressCallback = void Function(
    int succeeded, int failed);

/// Contains tasks and results related to a batch of downloads
class BackgroundDownloadBatch {
  final List<BackgroundDownloadTask> tasks;
  final BatchDownloadProgressCallback? batchDownloadProgressCallback;
  final results = <BackgroundDownloadTask, DownloadTaskStatus>{};

  BackgroundDownloadBatch(this.tasks, this.batchDownloadProgressCallback);

  /// Returns an Iterable with successful downloads in this batch
  Iterable<BackgroundDownloadTask> get succeeded => results.entries
      .where((entry) => entry.value == DownloadTaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of successful downloads in this batch
  int get numSucceeded => results.values
      .where((result) => result == DownloadTaskStatus.complete)
      .length;

  /// Returns an Iterable with failed downloads in this batch
  Iterable<BackgroundDownloadTask> get failed => results.entries
      .where((entry) => entry.value != DownloadTaskStatus.complete)
      .map((e) => e.key);

  /// Returns the number of failed downloads in this batch
  int get numFailed => results.values.length - numSucceeded;
}

/// Base class for events related to [task]. Actual events are
/// either a status update or a progress update.
///
/// When receiving an event, test if the event is a
/// [BackgroundDownloadStatusEvent] or a [BackgroundDownloadProgressEvent]
/// and treat the event accordingly
class BackgroundDownloadEvent {
  final BackgroundDownloadTask task;

  BackgroundDownloadEvent(this.task);
}

/// A status update event
class BackgroundDownloadStatusEvent extends BackgroundDownloadEvent {
  final DownloadTaskStatus status;

  BackgroundDownloadStatusEvent(super.task, this.status);
}

/// A progress update event
///
/// A successfully downloaded task will always finish with progress 1.0
/// [DownloadTaskStatus.failed] results in progress -1.0
/// [DownloadTaskStatus.canceled] results in progress -2.0
/// [DownloadTaskStatus.notFound] results in progress -3.0
/// [DownloadTaskStatus.waitingToRetry] results in progress -4.0
class BackgroundDownloadProgressEvent extends BackgroundDownloadEvent {
  final double progress;

  BackgroundDownloadProgressEvent(super.task, this.progress);
}

// Progress values representing a status
const progressComplete = 1.0;
const progressFailed = -1.0;
const progressCanceled = -2.0;
const progressNotFound = -3.0;
const progressWaitingToRetry = -4.0;

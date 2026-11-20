/// Central tuning knobs for the FarmGuard camera detection pipeline.
///
/// Every tunable used by the detection event engine and the upload queue
/// lives here so behavior is adjusted in exactly one place. All defaults are
/// `const` and services accept a [DetectionConfig] so tests can tighten the
/// values without touching production code.
class DetectionConfig {
  const DetectionConfig({
    this.personClassName = 'person',
    this.confidenceThreshold = 0.50,
    this.confirmationWindow = 5,
    this.confirmationMinimum = 3,
    this.cooldown = defaultCooldown,
    this.maxBoundingBoxes = 5,
    this.uploadMaxAttempts = 8,
    this.uploadBackoffBase = defaultBackoffBase,
    this.uploadBackoffMultiplier = 2.0,
    this.uploadBackoffJitter = 0.5,
    this.uploadMaxBackoff = defaultMaxBackoff,
  });

  /// Default cooldown between two confirmed presence events.
  static const Duration defaultCooldown = Duration(seconds: 30);

  /// Default base delay for the first upload retry.
  static const Duration defaultBackoffBase = Duration(milliseconds: 1500);

  /// Default upper bound for any single retry delay.
  static const Duration defaultMaxBackoff = Duration(seconds: 60);

  /// Only this COCO class counts as human presence. The system detects
  /// presence only — it never identifies a person.
  final String personClassName;

  /// Minimum model confidence for a detection to count as person-present.
  final double confidenceThreshold;

  /// Length of the rolling window of processed frames (in frames).
  final int confirmationWindow;

  /// Person-present frames required inside the window to confirm an event.
  final int confirmationMinimum;

  /// Time that must pass after a confirmed event before the next one can
  /// confirm — continuous presence must not spam events.
  final Duration cooldown;

  /// Maximum number of person detections considered per frame (the
  /// highest-confidence ones are kept).
  final int maxBoundingBoxes;

  // ---- Upload queue tuning ----

  /// Total attempts allowed per event before it is marked permanently
  /// failed (the event is kept, never deleted silently).
  final int uploadMaxAttempts;

  /// Delay before the first retry.
  final Duration uploadBackoffBase;

  /// Multiplier applied to the delay after each further failure.
  final double uploadBackoffMultiplier;

  /// Maximum fraction of the computed delay added as random jitter
  /// (actual jitter = this * random() in [0, 1)).
  final double uploadBackoffJitter;

  /// Upper bound for any computed retry delay (before jitter).
  final Duration uploadMaxBackoff;
}

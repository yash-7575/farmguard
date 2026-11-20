# FarmGuard Camera

Smart farm surveillance on Android: live camera monitoring with on-device
YOLO person detection.

## Phases

| Phase | Scope | Status |
| ----- | ----- | ------ |
| 1 | Flutter foundation, light-green themed home screen | Done |
| 2 | Live camera preview (official `camera` plugin), permission handling, Start/Stop Monitoring | Superseded by Phase 3 |
| 3 | On-device YOLO26s person detection via the official Ultralytics Flutter plugin | This phase |

From Phase 3 the detection pipeline is owned by `YOLOView` (Ultralytics
plugin, native CameraX). The Phase 2 `camera`-plugin pipeline was retired
with it, so only one camera stack ships in the app.

## Model

- Official Ultralytics asset `yolo26s_w8a32.tflite` (YOLO26s detection,
  COCO pretrained, 640×640 input).
- Quantization: W8A32 — int8 weights, FP32 activations (dynamic-range).
  This is the official verified Android LiteRT format. Full-INT8 (A8W8)
  exports are NOT used: Ultralytics documents that they destroy detection
  scores in this pipeline.
- Source (pinned release):
  https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.7.0/yolo26s_w8a32.tflite
- Size: 10,086,793 bytes (~9.6 MB)
- SHA-256: `ad2b2332f130c12470191835865d49b1a0d474570a964eef798bf7387e4ae510`
- The model is downloaded once on first use by `YOLOModelResolver`, cached
  in the app's documents directory (`mobile-standard-v2/`), and never
  bundled in the APK. Interrupted downloads land in a `.download` temp file
  and are retried safely. No fallback to other model sizes (e.g. `yolo26n`)
  is performed.
- For the offline demonstration: run the app once with network access so
  the model is downloaded and cached; after that, monitoring works offline.

## Detection

- Only the COCO `person` class is counted by the app logic.
- Bounding boxes, `Person` labels and confidence scores are rendered
  natively by `YOLOView`.
- Statistics (people count, FPS, processing ms) are tracked in
  `lib/services/detection_stats.dart` (pure Dart, unit-tested).
- Streaming is capped at 15 results/sec (`YOLOStreamingConfig.throttled`).
- No identity recognition, no event history, no storage, no backend.

## Third-party licenses & notices (AGPL-3.0)

The YOLO integration used by this project is the **official Ultralytics
Flutter plugin** (`ultralytics_yolo`, https://github.com/ultralytics/yolo-flutter-app)
and the model family **Ultralytics YOLO26**. Both are licensed under
**AGPL-3.0** (with an Ultralytics Enterprise License option).

What this means for this project:

- This is a college (academic) project used for research and coursework;
  AGPL-3.0 is fully satisfied by keeping the project open source under the
  same license. Preserve the Ultralytics license notice above and the
  plugin's copyright notices.
- If this app (or a derivative of it) is ever distributed or offered as a
  service, the **complete corresponding source** must be provided to users
  under AGPL-3.0, including the app code that links the plugin and any
  modified plugin/model code.
- "Offered as a service" includes network use (AGPL §13): e.g. streaming
  detection results to a remote dashboard would make the app's source
  disclosable to the users of that service.
- AGPL-3.0 does **not** require disclosing the farm's video footage or
  detection events — only the source code of the software.
- For proprietary/closed-source commercial distribution, an Ultralytics
  Enterprise License would need to be purchased instead
  (https://www.ultralytics.com/license).

LiteRT (the Android inference runtime used by the plugin) is licensed
under Apache-2.0 by Google and carries no copyleft obligation.

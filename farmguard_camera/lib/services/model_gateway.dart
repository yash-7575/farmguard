import 'package:ultralytics_yolo/core/yolo_model_resolver.dart';

/// Access to the official Ultralytics model artifacts (availability check
/// and resolution/download), injectable so widget tests can run without
/// touching the platform channels the real resolver depends on.
abstract class ModelGateway {
  /// Whether the official [modelId] artifact is already cached locally.
  Future<bool> isModelAvailableLocally(String modelId);

  /// Resolves (and on first use downloads) the official [modelId] artifact,
  /// returning the local file path ready for inference. Downloads emit
  /// progress on [YOLOModelManager.downloadProgress] (pure Dart stream).
  Future<String> resolveModel(String modelId);
}

/// Production gateway delegating to the plugin's official model resolver.
class UltralyticsModelGateway implements ModelGateway {
  const UltralyticsModelGateway();

  @override
  Future<bool> isModelAvailableLocally(String modelId) =>
      YOLOModelResolver.isOfficialModelAvailableLocally(modelId);

  @override
  Future<String> resolveModel(String modelId) async {
    final resolved = await YOLOModelResolver.resolve(modelPath: modelId);
    return resolved.modelPath;
  }
}

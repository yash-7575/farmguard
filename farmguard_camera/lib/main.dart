import 'package:material_ui/material_ui.dart';

import 'screens/home_screen.dart';
import 'services/cloud_services.dart';
import 'services/model_gateway.dart';

void main() {
  runApp(const FarmGuardApp());
}

class FarmGuardApp extends StatelessWidget {
  const FarmGuardApp({super.key, this.modelGateway, this.cloudServices});

  /// Injectable model-asset gateway for tests; defaults to the real one.
  final ModelGateway? modelGateway;

  /// Injectable cloud bundle for tests; defaults to the production one
  /// (which is inert under `flutter test` so widget tests never touch a
  /// platform channel).
  final CloudServices? cloudServices;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FarmGuard Camera',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: HomeScreen(
        modelGateway: modelGateway,
        cloudServices: cloudServices,
      ),
    );
  }
}

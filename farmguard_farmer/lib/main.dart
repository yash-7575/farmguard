import 'package:material_ui/material_ui.dart';

import 'screens/auth_gate.dart';
import 'services/app_services.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(FarmGuardApp(services: AppServices.production()));
}

class FarmGuardApp extends StatelessWidget {
  /// Injected backend dependencies (the app's idiom). Production builds
  /// use [AppServices.production]; tests inject a fake-based bundle so no
  /// platform channel is ever touched.
  final AppServices services;

  const FarmGuardApp({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FarmGuard Farmer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: AuthGate(services: services),
    );
  }
}

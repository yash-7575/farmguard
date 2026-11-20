import 'package:material_ui/material_ui.dart';

import '../widgets/fg_card.dart';
import '../widgets/section_header.dart';

/// Settings: farmer profile placeholder, notification preferences, the
/// signed-in account (from the auth session) and app information.
class SettingsScreen extends StatefulWidget {
  /// Signed-in farmer from the auth session (shown in the Account section).
  final String farmerName;
  final String farmerEmail;

  /// Clears the session and returns to the login screen.
  final VoidCallback onLogout;

  const SettingsScreen({
    super.key,
    required this.farmerName,
    required this.farmerEmail,
    required this.onLogout,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _personAlerts = true;
  bool _offlineAlerts = true;
  bool _dailySummary = false;
  bool _quietHours = false;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: <Widget>[
          Text('Settings', style: textTheme.headlineMedium),
          const SizedBox(height: 20),
          _profileCard(context),
          const SizedBox(height: 24),
          SectionHeader(title: 'Account'),
          _accountCard(context),
          const SizedBox(height: 24),
          SectionHeader(title: 'Notifications'),
          FgCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                _SwitchRow(
                  icon: Icons.notifications_active,
                  title: 'Person detection alerts',
                  subtitle: 'Notify me when a person is detected on any camera',
                  value: _personAlerts,
                  onChanged: (bool v) => setState(() => _personAlerts = v),
                ),
                Divider(color: scheme.outlineVariant, indent: 60),
                _SwitchRow(
                  icon: Icons.wifi_off,
                  title: 'Camera offline alerts',
                  subtitle: 'Notify me when a camera loses connection',
                  value: _offlineAlerts,
                  onChanged: (bool v) => setState(() => _offlineAlerts = v),
                ),
                Divider(color: scheme.outlineVariant, indent: 60),
                _SwitchRow(
                  icon: Icons.summarize,
                  title: 'Daily activity summary',
                  subtitle: 'One summary of today\'s detections each evening',
                  value: _dailySummary,
                  onChanged: (bool v) => setState(() => _dailySummary = v),
                ),
                Divider(color: scheme.outlineVariant, indent: 60),
                _SwitchRow(
                  icon: Icons.bedtime,
                  title: 'Quiet hours',
                  subtitle: 'Mute non-critical alerts from 10 PM to 6 AM',
                  value: _quietHours,
                  onChanged: (bool v) => setState(() => _quietHours = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SectionHeader(title: 'App information'),
          FgCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                _InfoRow(title: 'App', value: 'FarmGuard Farmer'),
                Divider(color: scheme.outlineVariant, indent: 60),
                _InfoRow(title: 'Version', value: '1.0.0 (build 1)'),
                Divider(color: scheme.outlineVariant, indent: 60),
                _InfoRow(title: 'Detection engine', value: 'Person detection v2'),
                Divider(color: scheme.outlineVariant, indent: 60),
                _InfoRow(title: 'Data', value: 'Demo events + live data'),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: Text(
              'FarmGuard keeps watch, so you can rest.',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Account section: signed-in farmer from the auth session + logout.
  Widget _accountCard(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String name = widget.farmerName;
    final String initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return FgCard(
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials.isEmpty ? '?' : initials,
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(name, style: textTheme.titleSmall),
                      if (widget.farmerEmail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          widget.farmerEmail,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: scheme.outlineVariant),
          InkWell(
            onTap: widget.onLogout,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.logout,
                      size: 19,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Log out',
                      style: textTheme.titleSmall,
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileCard(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return FgCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              'RK',
              style: textTheme.titleMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Ravi Kumar', style: textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Farm owner · +91 98••• ••4301',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit profile',
            icon: Icon(
              Icons.edit_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return MergeSemantics(
      child: ListTile(
        minVerticalPadding: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: scheme.onSurfaceVariant),
        ),
        title: Text(title, style: textTheme.titleSmall),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            subtitle,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ),
        isThreeLine: true,
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String title;
  final String value;

  const _InfoRow({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: textTheme.bodyMedium)),
          Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

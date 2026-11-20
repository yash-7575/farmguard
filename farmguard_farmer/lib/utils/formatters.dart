/// Small date/time formatting helpers.
///
/// Intentionally dependency-free (no `intl`) to keep the dependency set
/// minimal for Phase 1.
library;

const List<String> _monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool isYesterday(DateTime reference, DateTime value) => isSameDay(
      reference.subtract(const Duration(days: 1)),
      value,
    );

/// "6:42 PM" style time-of-day string.
String formatTime(DateTime dt) {
  final int hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final String minute = dt.minute.toString().padLeft(2, '0');
  final String suffix = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $suffix';
}

/// "Today, 6:42 PM" / "Yesterday, 8:14 PM" / "14 Nov, 3:05 PM".
String formatEventTime(DateTime value, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  if (isSameDay(reference, value)) return 'Today, ${formatTime(value)}';
  if (isYesterday(reference, value)) return 'Yesterday, ${formatTime(value)}';
  final String day = value.day.toString().padLeft(2, '0');
  return '$day ${_monthNames[value.month - 1]}, ${formatTime(value)}';
}

/// Human-friendly recency: "Just now", "35 min ago", "2 h ago", "Yesterday".
String timeAgo(DateTime value, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  final Duration difference = reference.difference(value);
  if (difference.inMinutes < 1) return 'Just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
  if (difference.inHours < 24) return '${difference.inHours} h ago';
  if (difference.inDays < 2) return 'Yesterday';
  return '${difference.inDays} days ago';
}

/// "Good morning / afternoon / evening" based on device time.
String greeting({DateTime? now}) {
  final int hour = (now ?? DateTime.now()).hour;
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

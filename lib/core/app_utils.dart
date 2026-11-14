import 'package:intl/intl.dart';

String humanize(String value) => value
    .replaceAll('_', ' ')
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

/// Whether a notification has been read. The API returns a `readAt` time stamp
/// (null while unread), not a `read` flag, so check both.
bool notificationIsRead(Map<dynamic, dynamic> n) =>
    n['read'] == true ||
    n['isRead'] == true ||
    (n['readAt'] != null && n['readAt'].toString().isNotEmpty);

/// Turns any error into a message that is safe to show a customer.
///
/// API errors already carry a readable message and pass through unchanged
/// (minus a leading "Exception:"). Anything technical - Dart/Flutter errors,
/// stack traces, socket/TLS errors, "setState() callback..." - is replaced by
/// a plain sentence so developer text never reaches the screen.
String userMessage(Object? error,
    {String fallback = 'Something went wrong. Please try again.'}) {
  var s = (error ?? '').toString().trim();
  // "Exception: x", "ApiException: x", "FirebaseAuthException(...): x"
  s = s.replaceFirst(
      RegExp(r'^(?:[A-Za-z]*Exception|[A-Za-z]*Error)(?:\([^)]*\))?:\s*'), '');
  // "[firebase_auth/invalid-phone-number] The phone number is invalid."
  s = s.replaceFirst(RegExp(r'^\[[\w\-/]+\]\s*'), '').trim();
  final lower = s.toLowerCase();

  const network = [
    'socketexception',
    'failed host lookup',
    'handshakeexception',
    'clientexception',
    'connection refused',
    'connection reset',
    'connection closed',
    'network is unreachable',
    'xmlhttprequest',
  ];
  if (network.any(lower.contains)) {
    return 'Could not connect. Please check your internet connection and try again.';
  }
  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return 'The request took too long. Please try again.';
  }

  const technical = [
    'setstate',
    'renderflex',
    'package:',
    'dart:',
    'null check',
    'is not a subtype',
    'nosuchmethod',
    "type '",
    'instance of',
    'unhandled exception',
    'stack trace',
    'platformexception',
    'unexpected character',
    'unexpected token',
    'not valid json',
    'json',
    'unexpected end of input',
    'formatexception',
    'rangeerror',
    'range error',
    'index out of',
    'bad state',
    'assertion',
    'lateinitialization',
    'flutter',
    'widget',
    'null is not',
    'cannot be null',
    'the method ',
    'the getter ',
  ];
  if (s.isEmpty || s.length > 220 || technical.any(lower.contains)) {
    return fallback;
  }
  return s;
}

String money(dynamic value, {String symbol = '₹'}) {
  final amount =
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  final decimals = amount == amount.roundToDouble() ? 0 : 2;
  return NumberFormat.currency(
    locale: 'en_IN',
    symbol: symbol,
    decimalDigits: decimals,
  ).format(amount);
}

double orderMinimumShortfall(num total, {num minimum = 2500}) =>
    (minimum - total).clamp(0, double.infinity).toDouble();

bool requiresPromotionalOrderMinimum(String? bannerId) =>
    const {'home_banner_2', 'home_banner_3'}.contains(bannerId);

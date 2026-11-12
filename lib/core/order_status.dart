import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'app_utils.dart';

/// Display info for one order status coming from the API.
class OrderStatusInfo {
  const OrderStatusInfo(this.key, this.label, this.color, this.icon);
  final String key;
  final String label;
  final Color color;
  final IconData icon;
}

/// The 9 order statuses the API can return, in lifecycle order
/// (cancelled is terminal and sits outside the progress flow).
const List<OrderStatusInfo> kOrderStatuses = [
  OrderStatusInfo('payment_pending', 'Payment Pending', AppColors.warning,
      Icons.hourglass_top_rounded),
  OrderStatusInfo('under_review', 'Under Review', AppColors.info,
      Icons.fact_check_outlined),
  OrderStatusInfo('quotation', 'Quotation in Progress', Color(0xFF7B5CD6),
      Icons.request_quote_outlined),
  OrderStatusInfo(
      'approved', 'Approved', AppColors.success, Icons.thumb_up_alt_outlined),
  OrderStatusInfo('production', 'In Production', AppColors.goldDark,
      Icons.precision_manufacturing_outlined),
  OrderStatusInfo('ready', 'Ready for Dispatch', Color(0xFF0E9AA7),
      Icons.inventory_2_outlined),
  OrderStatusInfo('installation', 'Installation in Progress',
      Color(0xFFE8590C), Icons.construction_rounded),
  OrderStatusInfo('completed', 'Completed', AppColors.success,
      Icons.check_circle_rounded),
  OrderStatusInfo(
      'cancelled', 'Cancelled', AppColors.danger, Icons.cancel_outlined),
];

/// Order statuses shown as steps in the order-detail progress tracker.
final List<OrderStatusInfo> kOrderFlow =
    kOrderStatuses.where((s) => s.key != 'cancelled').toList();

// Spellings the backend also uses for the same state.
const Map<String, String> _aliases = {
  'in_production': 'production',
  'inproduction': 'production',
  'paymentpending': 'payment_pending',
  'underreview': 'under_review',
  'in_installation': 'installation',
  'canceled': 'cancelled',
};

String normalizeOrderStatus(dynamic raw) {
  final s = (raw ?? '')
      .toString()
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-]+'), '_');
  return _aliases[s] ?? s;
}

/// Status display for an order. A status outside the 9 known ones is shown
/// as-is (humanized) instead of being relabelled as something else.
OrderStatusInfo orderStatusInfo(dynamic raw) {
  final key = normalizeOrderStatus(raw);
  for (final s in kOrderStatuses) {
    if (s.key == key) return s;
  }
  return OrderStatusInfo(
    key,
    key.isEmpty ? 'Status Unavailable' : humanize(key),
    AppColors.textMuted,
    Icons.info_outline_rounded,
  );
}

/// True when the API flagged the order's last payment as failed.
bool orderPaymentFailed(Map<dynamic, dynamic> order) {
  bool flag(dynamic v) => v == true || v?.toString().toLowerCase() == 'true';
  if (flag(order['paymentFailed'])) return true;
  final payment = order['payment'];
  return payment is Map && flag(payment['paymentFailed']);
}

/// Id of the payment to retry, when the API provides one.
String? orderPaymentId(Map<dynamic, dynamic> order) {
  final payment = order['payment'];
  final id = order['paymentId'] ??
      order['failedPaymentId'] ??
      order['lastPaymentId'] ??
      (payment is Map ? payment['id'] : null);
  final text = id?.toString() ?? '';
  return text.isEmpty ? null : text;
}

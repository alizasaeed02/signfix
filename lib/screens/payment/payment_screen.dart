import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import '../../core/app_theme.dart';
import '../../services/api_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  PaymentScreen — Full Razorpay checkout with dark SignFix theme
// ────────────────────────────────────────────────────────────────────────────

/// Opens Razorpay checkout for a freshly created order (Design Studio /
/// Power Supply). Returns true only when the backend confirmed the payment.
/// Razorpay checkout options exactly as payment_api_guide.pdf (Step 2):
/// base options + the method-specific keys at the top level.
///  - qr          -> method upi, upi.flow = qr        (Case A)
///  - upi + ID    -> method upi, vpa = <ID>           (Case B: collect request)
///  - upi, no ID  -> method upi, upi.flow = intent    (Case C: installed apps)
///  - card / netbanking / emi -> method                (Cases D, E, G)
///  - wallet      -> method wallet, wallet = <name>   (Case F)
Map<String, dynamic> razorpayCheckoutOptions({
  required String key,
  required int amountInPaise,
  required String currency,
  required String name,
  required String description,
  String? providerOrderId,
  required String customerName,
  required String customerEmail,
  required String customerPhone,
  required String method,
  String? upiId,
  String? bank,
  String? wallet,
}) {
  final vpa = (upiId ?? '').trim();
  final prefill = <String, dynamic>{
    'name': customerName,
    'email': customerEmail,
    'contact': customerPhone,
  };
  final methodOptions = <String, dynamic>{};
  switch (method) {
    case 'qr':
      methodOptions['method'] = 'upi';
      methodOptions['upi'] = {'flow': 'qr'};
    case 'upi':
      methodOptions['method'] = 'upi';
      if (vpa.isNotEmpty) {
        methodOptions['vpa'] = vpa;
        prefill['method'] = 'upi'; // SDK copy of the same hints
        prefill['vpa'] = vpa;
      } else {
        methodOptions['upi'] = {'flow': 'intent'};
      }
    case 'card' || 'netbanking' || 'emi':
      methodOptions['method'] = method;
      prefill['method'] = method;
      if (method == 'netbanking' && bank != null) prefill['bank'] = bank;
    case 'wallet':
      methodOptions['method'] = 'wallet';
      prefill['method'] = 'wallet';
      if (wallet != null && wallet.isNotEmpty) methodOptions['wallet'] = wallet;
  }
  return <String, dynamic>{
    'key': key,
    'amount': amountInPaise,
    'currency': currency,
    'name': name,
    'description': description,
    if (providerOrderId != null && providerOrderId.startsWith('order_'))
      'order_id': providerOrderId,
    'prefill': prefill,
    'theme': {'color': '#F59E0B'},
    ...methodOptions,
  };
}

/// What the customer picked in the inline [PaymentOptionsPanel].
class PaymentChoice {
  const PaymentChoice(this.method, this.type,
      {this.upiId, this.bank, this.wallet});
  final String method; // upi | card | netbanking | wallet | emi
  final String type; // full | advance
  final String? upiId, bank, wallet;
}

/// If [choice] is given (picked inline before submitting) Razorpay opens
/// straight away; otherwise the payment options page is shown.
Future<bool> payForOrder(
  BuildContext context,
  ApiClient api, {
  required String orderNo,
  required double amount,
  required String description,
  PaymentChoice? choice,
  String? retryPaymentId,
  String paymentType = 'full',
}) async {
  Map<String, dynamic> profile = const {};
  try {
    profile = Map<String, dynamic>.from(await api.getProfile());
  } catch (_) {
    // Prefill is optional; never block payment because the profile failed.
  }
  if (!context.mounted) return false;
  final result = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => PaymentScreen(
        api: api,
        orderId: orderNo,
        quotationNo: '',
        paymentType: choice?.type ?? paymentType,
        retryPaymentId: retryPaymentId,
        amount: amount,
        customerName: profile['name']?.toString() ?? 'Customer',
        customerEmail: profile['email']?.toString() ?? '',
        customerPhone: (profile['mobile'] ?? profile['phone'])?.toString() ?? '',
        description: description,
        payOrderDirectly: true,
        initialChoice: choice,
        onSuccess: (_) {},
        onFailure: (_) {},
      ),
    ),
  );
  return result == true;
}

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({
    super.key,
    required this.api,
    required this.orderId,
    required this.quotationNo,
    required this.paymentType,
    required this.amount,
    required this.customerName,
    required this.customerEmail,
    required this.customerPhone,
    required this.description,
    required this.onSuccess,
    required this.onFailure,
    this.payOrderDirectly = false,
    this.initialChoice,
    this.retryPaymentId,
  });

  /// Pre-selected method/type: opens Razorpay immediately on first build.
  final PaymentChoice? initialChoice;

  /// Id of a failed payment: the session is created with
  /// POST /customer/payments/:id/retry instead of a new intent.
  final String? retryPaymentId;

  /// false (default): pay an approved quotation (existing behaviour).
  /// true: pay an order's server-side estimate via /payments/order-intents.
  final bool payOrderDirectly;

  final ApiClient api;
  final String orderId;
  final String quotationNo;
  final String paymentType;
  final double amount; // INR (Rupees)
  final String customerName;
  final String customerEmail;
  final String customerPhone;
  final String description;
  final void Function(String paymentId) onSuccess;
  final void Function(String reason) onFailure;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late final Razorpay _razorpay;
  bool _launched = false;
  bool _processing = false;
  String? _resultMessage;
  bool _isSuccess = false;
  bool _isPending = false;
  bool _canRetry = true;
  String? _paymentIntentId;
  String? _activeRetryId;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _onSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _onError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _onWallet);
    final choice = widget.initialChoice;
    if (choice != null) {
      _processing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_launch(
            method: choice.method,
            upiId: choice.upiId,
            type: choice.type,
            bank: choice.bank,
            wallet: choice.wallet));
      });
    }
  }

  @override
  void dispose() {
    _razorpay.clear();
    super.dispose();
  }

  /// Creates the payment session for the order. The server allows only one
  /// open payment per order: if an earlier attempt (e.g. a cancelled Full
  /// payment) is still open under the other type, continue that one instead
  /// of failing with "Another payment for this order is still in progress".
  Future<Map<String, dynamic>> _createOrderIntent(
      String type, String idempotencyKey) async {
    Map<String, dynamic> body(String t, String key) =>
        {'orderNo': widget.orderId, 'type': t, 'idempotencyKey': key};
    try {
      return await widget.api.createOrderPaymentIntent(body(type, idempotencyKey));
    } on ApiException catch (e) {
      final inProgress = e.statusCode == 409 &&
          e.message.toLowerCase().contains('in progress');
      if (!inProgress) rethrow;
      final other = type == 'full' ? 'advance' : 'full';
      final intent = await widget.api.createOrderPaymentIntent(
          body(other, '$idempotencyKey-$other'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Continuing your earlier ${other == 'advance' ? 'advance' : 'full'} payment for this order.')));
      }
      return intent;
    }
  }

  String _friendlySetupError(Object e) {
    final raw = e is ApiException
        ? e.message
        : e.toString().replaceFirst(RegExp(r'^(Exception|ApiException):\s*'), '');
    final lower = raw.toLowerCase();
    if (lower.contains('cannot connect') ||
        lower.contains('timed out') ||
        lower.contains('closed unexpectedly') ||
        lower.contains('could not be reached')) {
      return 'Could not reach the payment server. Check your internet connection and tap Try Again. Your order is saved and you have not been charged.';
    }
    return raw;
  }

  Future<void> _launch(
      {String method = 'upi',
      String? upiId,
      String? type,
      String? bank,
      String? wallet}) async {
    final payType = type ?? widget.paymentType;
    setState(() {
      _launched = true;
      _processing = true;
      _isPending = false;
      _paymentIntentId = null;
    });

    try {
      // 1. Backend se payment intent mango
      final idempotencyKey =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      final retryId = _activeRetryId ?? widget.retryPaymentId;
      Future<Map<String, dynamic>> freshIntent() => widget.payOrderDirectly
          ? _createOrderIntent(payType, idempotencyKey)
          : widget.api.createPaymentIntent({
              'quotationNo': widget.quotationNo,
              'type': payType,
              'amount': widget.amount,
              'idempotencyKey': idempotencyKey,
            });
      final intent = retryId != null
          // Retry: ask the backend for a fresh Razorpay order first
          // (POST /payments/order-intents). Fall back to /payments/:id/retry.
          ? await (widget.payOrderDirectly
              ? freshIntent().catchError((Object _) =>
                  widget.api.retryPayment(retryId))
              : widget.api.retryPayment(retryId)
                  .catchError((Object _) => freshIntent()))
          : widget.payOrderDirectly
          ? await _createOrderIntent(payType, idempotencyKey)
          : await widget.api.createPaymentIntent({
              'quotationNo': widget.quotationNo,
              'type': payType,
              'amount': widget.amount,
              'idempotencyKey': idempotencyKey,
            });

      final paymentIntentId = intent['id']?.toString();
      final checkoutValue = intent['checkout'];

      if (paymentIntentId == null ||
          paymentIntentId.isEmpty ||
          checkoutValue is! Map) {
        throw Exception('The payment could not be started. Please try again.');
      }

      final checkout = Map<String, dynamic>.from(checkoutValue);
      final keyId = checkout['keyId']?.toString();
      final providerOrderId = checkout['orderId']?.toString();

      // Amount ko safe tarike se handle karna (Int ya Double dono handle honge)
      final dynamic rawAmount = checkout['amount'];
      final int amountInPaise;
      if (rawAmount is num) {
        amountInPaise = rawAmount.round();
      } else if (rawAmount is String && num.tryParse(rawAmount) != null) {
        amountInPaise = num.parse(rawAmount).round();
      } else {
        throw Exception('The payment could not be started. Please try again.');
      }

      final currency = checkout['currency']?.toString() ?? 'INR';

      // 2. STRICT CHECKS (Yahan se pata chalega masla kya hai)
      final effectiveKey = (keyId != null && keyId.startsWith('rzp_'))
          ? keyId
          : 'rzp_live_TZRwgnPCEkDeu4';

      if (amountInPaise <= 0) {
        throw Exception('This order has no payable amount.');
      }

      _paymentIntentId = paymentIntentId;
      // A further retry must target the replacement payment just created.
      if (retryId != null) _activeRetryId = paymentIntentId;

      debugPrint('🔑 Key ID: $effectiveKey');
      debugPrint(' Razorpay Order ID: $providerOrderId');
      debugPrint('💰 Amount Backend se (Paise): $amountInPaise');
      debugPrint('💵 Rupees mein: ₹${amountInPaise / 100}');

      // 4. Open Razorpay (options built per payment_api_guide.pdf, Step 2)
      final options = razorpayCheckoutOptions(
        key: effectiveKey,
        amountInPaise: amountInPaise,
        currency: currency,
        name: checkout['name']?.toString() ?? 'SignFix',
        description:
            checkout['description']?.toString() ?? widget.description,
        providerOrderId: providerOrderId,
        customerName: widget.customerName,
        customerEmail: widget.customerEmail,
        customerPhone: widget.customerPhone,
        method: method,
        upiId: upiId,
        bank: bank,
        wallet: wallet,
      );

      debugPrint('📋 Razorpay Options: $options');

      try {
        _razorpay.open(options);
        debugPrint('✅ _razorpay.open() called successfully');
      } catch (sdkError) {
        debugPrint('❌ RAZORPAY SDK ERROR: $sdkError');
        rethrow;
      }
    } catch (e) {
      debugPrint('❌ PAYMENT SETUP ERROR: $e');
      if (!mounted) return;
      setState(() {
        _processing = false;
        _resultMessage = 'Payment could not be started.\n${_friendlySetupError(e)}';
        _isSuccess = false;
        _isPending = false;
        _canRetry = true;
      });
    }
  }

  void _onSuccess(PaymentSuccessResponse resp) {
    unawaited(_verifyAndComplete(resp));
  }

  Future<void> _verifyAndComplete(PaymentSuccessResponse resp) async {
    final paymentIntentId = _paymentIntentId;
    final paymentId = resp.paymentId;
    final providerOrderId = resp.orderId;
    final signature = resp.signature;

    if (paymentId == null || paymentId.isEmpty) {
      _showPending(
        'Razorpay did not return a payment ID. Please contact support.',
      );
      return;
    }

    setState(() {
      _processing = true;
      _resultMessage = null;
      _canRetry = false;
    });

    if (paymentIntentId != null &&
        providerOrderId != null &&
        signature != null) {
      try {
        final verified = await widget.api.verifyPayment(paymentIntentId, {
          'razorpayPaymentId': paymentId,
          'razorpayOrderId': providerOrderId,
          'razorpaySignature': signature,
        });
        debugPrint(
            'Quotation payment verification result: status=${verified['status']}');
        final status = (verified['status'] ?? '').toString().toLowerCase();
        if (status == 'captured' || status == 'authorized') {
          if (!mounted) return;
          setState(() {
            _processing = false;
            _isSuccess = true;
            _isPending = false;
            _resultMessage = paymentId;
          });
          widget.onSuccess(paymentId);
          return;
        } else if (status == 'failed') {
          throw Exception('Payment was rejected or failed at provider.');
        } else {
          _showPending(
              'Payment is pending gateway confirmation. Current status: $status');
          return;
        }
      } catch (e) {
        debugPrint('Verification endpoint error: $e');
        _showPending(
            'Payment was received by gateway but could not be verified by backend: $e. Please do not pay again.');
        return;
      }
    } else {
      _showPending(
          'Payment session missing signature or intent. Reference: $paymentId');
      return;
    }
  }

  void _showPending(String message) {
    if (!mounted) return;
    setState(() {
      _processing = false;
      _isSuccess = false;
      _isPending = true;
      _canRetry = false;
      _resultMessage = message;
    });
  }

  void _onError(PaymentFailureResponse resp) {
    unawaited(_reportFailure(resp));
  }

  String _friendlyError(PaymentFailureResponse resp) {
    final code = resp.code ?? 0;
    final raw = (resp.message ?? '').toLowerCase();

    if (code == Razorpay.PAYMENT_CANCELLED ||
        raw.contains('cancel') ||
        raw.contains('dismiss')) {
      return 'You cancelled the payment. You can try again whenever you\'re ready.';
    }
    if (code == Razorpay.NETWORK_ERROR ||
        raw.contains('network') ||
        raw.contains('internet') ||
        raw.contains('connect') ||
        raw.contains('timeout')) {
      return 'Unable to connect to the payment service. Please check your internet connection and try again.';
    }
    if (raw.contains('insufficient') ||
        raw.contains('low balance') ||
        raw.contains('not enough')) {
      return 'Your account has insufficient funds. Please use another payment method.';
    }
    if (raw.contains('declined') ||
        raw.contains('do not honour') ||
        raw.contains('card blocked')) {
      return 'Your payment was declined by the bank. Please try another payment method.';
    }

    final cleanMsg = resp.message
            ?.replaceAll(RegExp(r'Exception:?\s*'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim() ??
        '';
    if (cleanMsg.isNotEmpty && cleanMsg.length < 120) return cleanMsg;

    return 'Payment could not be completed. Please try a different payment method or contact support.';
  }

  Future<void> _reportFailure(PaymentFailureResponse resp) async {
    final paymentIntentId = _paymentIntentId;
    final message = _friendlyError(resp);

    if (paymentIntentId != null) {
      try {
        await widget.api.reportPaymentFailure(paymentIntentId, {
          if (resp.code != null) 'code': resp.code.toString(),
          'description': resp.message ?? 'Razorpay payment failed',
          'source': 'razorpay',
          'step': 'checkout',
        });
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _processing = false;
      _isSuccess = false;
      _isPending = false;
      _canRetry = true;
      _resultMessage = message;
    });
    widget.onFailure(message);
  }

  void _onWallet(ExternalWalletResponse resp) {
    _showPending(
      'The ${resp.walletName} payment was started, but has not been confirmed by SignFix yet. Check your payment status before trying again.',
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.softGray,
        appBar: AppBar(
          backgroundColor: AppColors.white,
          elevation: 0,
          title: const Row(children: [
            Icon(Icons.payment_rounded, color: AppColors.gold, size: 22),
            SizedBox(width: 8),
            Text('Secure Payment',
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: AppColors.navy)),
          ]),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.gold),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: _resultMessage != null
            ? _ResultView(
                isSuccess: _isSuccess,
                isPending: _isPending,
                message: _resultMessage!,
                orderId: widget.orderId,
                onDone: () => Navigator.pop(context, _isSuccess),
                onRetry: !_canRetry || _isSuccess
                    ? null
                    : () => setState(() {
                          _resultMessage = null;
                          _launched = false;
                          _isPending = false;
                          _paymentIntentId = null;
                        }),
              )
            : _processing
                ? const Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(color: AppColors.gold),
                      SizedBox(height: 16),
                      Text('Opening payment gateway…',
                          style: TextStyle(color: AppColors.textLight)),
                    ]),
                  )
                : PaymentOptionsPanel(
                    orderId: widget.orderId,
                    paymentType: widget.paymentType,
                    amount: widget.amount,
                    description: widget.description,
                    customerName: widget.customerName,
                    onPay: (method, upiId, type, {bank, wallet}) => _launch(
                        method: method,
                        upiId: upiId,
                        type: type,
                        bank: bank,
                        wallet: wallet),
                    launched: _launched,
                    allowTypeChoice: widget.payOrderDirectly &&
                        widget.retryPaymentId == null,
                  ),
      );
}

// ── Payment Summary Page (same look as the Order wizard payment step) ───────
/// Payment type + method chooser. Used full-screen after an order exists
/// ([PaymentScreen]) and inline (`embedded: true`) on the Design Studio and
/// Power Supply pages, before the order is submitted.
class PaymentOptionsPanel extends StatefulWidget {
  const PaymentOptionsPanel({
    super.key,
    this.orderId = '',
    this.paymentType = 'full',
    required this.amount,
    this.description = '',
    this.customerName = '',
    required this.onPay,
    this.launched = false,
    this.allowTypeChoice = false,
    this.embedded = false,
    this.enabled = true,
    this.buttonLabel,
  });
  final String orderId, paymentType, description, customerName;
  final double amount;
  final void Function(String method, String? upiId, String type,
      {String? bank, String? wallet}) onPay;
  final bool launched;
  final bool allowTypeChoice;

  /// Inline mode: no order summary card, no own scrolling.
  final bool embedded;

  /// When false the Submit & Pay button is disabled (e.g. price not ready).
  final bool enabled;

  /// Overrides the default "Submit & Pay ₹x" label.
  final String? buttonLabel;

  @override
  State<PaymentOptionsPanel> createState() => _PaymentSummaryState();
}

class _PaymentSummaryState extends State<PaymentOptionsPanel> {
  String _selectedMethod = 'upi';
  final TextEditingController _upiController = TextEditingController();
  String? _upiError;
  String? _error;
  String? _bank;
  String? _wallet;
  int? _emiMonths;
  late String _type = widget.paymentType;

  static final _upiRegex = RegExp(r'^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,}$');
  static const _banks = {
    'SBI': 'SBIN',
    'HDFC Bank': 'HDFC',
    'ICICI Bank': 'ICIC',
    'Axis Bank': 'UTIB',
    'Kotak Mahindra': 'KKBK',
    'Punjab National Bank': 'PUNB_R',
    'Bank of Baroda': 'BARB_R',
    'Canara Bank': 'CNRB',
    'Yes Bank': 'YESB',
    'IDBI Bank': 'IBKL',
  };
  static const _wallets = ['Paytm', 'PhonePe', 'Mobikwik'];

  double get _payAmount =>
      _type == 'advance' ? widget.amount * 0.25 : widget.amount;
  String _money(double v) => '₹${v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}';

  @override
  void dispose() {
    _upiController.dispose();
    super.dispose();
  }

  void _select(String id) => setState(() {
        _selectedMethod = id;
        _error = null;
        _upiError = null;
      });

  void _pay() {
    if (widget.launched) return;
    final upiId = _upiController.text.trim();
    if (_selectedMethod == 'upi' &&
        upiId.isNotEmpty &&
        !_upiRegex.hasMatch(upiId)) {
      setState(() => _upiError = 'Enter a valid UPI ID (e.g. username@bank)');
      return;
    }
    if (_selectedMethod == 'netbanking' && _bank == null) {
      setState(() => _error =
          'Please select a bank. You will enter your banking details securely in Razorpay.');
      return;
    }
    if (_selectedMethod == 'wallet' && _wallet == null) {
      setState(() => _error =
          'Please select a wallet. You will authorize it securely in Razorpay.');
      return;
    }
    if (_selectedMethod == 'emi' && _emiMonths == null) {
      setState(() => _error = 'Please select an EMI plan.');
      return;
    }
    setState(() {
      _error = null;
      _upiError = null;
    });
    widget.onPay(
      _selectedMethod,
      _selectedMethod == 'upi' ? upiId : null,
      _type,
      bank: _bank == null ? null : _banks[_bank],
      wallet: _wallet?.toLowerCase(),
    );
  }

  /// Guide case A: "Pay via QR Code" opens Razorpay's UPI QR directly.
  void _payQr() {
    if (widget.launched || !widget.enabled) return;
    setState(() {
      _error = null;
      _upiError = null;
    });
    widget.onPay('qr', null, _type);
  }

  Widget _typeCard(String type, String title, String sub) {
    final selected = _type == type;
    final amount = type == 'advance' ? widget.amount * 0.25 : widget.amount;
    return Expanded(
      child: GestureDetector(
        onTap: widget.launched ? null : () => setState(() => _type = type),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                selected ? AppColors.gold.withValues(alpha: .15) : AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? AppColors.gold : AppColors.cardBorder,
                width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: selected ? AppColors.gold : AppColors.navy,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
            const SizedBox(height: 4),
            Text(_money(amount),
                style: TextStyle(
                    color: selected ? AppColors.gold : AppColors.textMuted,
                    fontWeight: FontWeight.w900,
                    fontSize: 18)),
            const SizedBox(height: 2),
            Text(sub,
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _infoBox(IconData icon, Color color, String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style:
                      const TextStyle(color: AppColors.textLight, fontSize: 12))),
        ]),
      );

  List<Widget> _methodFields() {
    switch (_selectedMethod) {
      case 'upi':
        return [
          TextField(
            controller: _upiController,
            keyboardType: TextInputType.text,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            style: const TextStyle(color: AppColors.charcoal),
            decoration: InputDecoration(
              labelText: 'UPI ID (optional)',
              hintText: 'e.g. username@bank',
              prefixIcon:
                  const Icon(Icons.alternate_email, color: AppColors.gold),
              errorText: _upiError,
            ),
            onChanged: (_) {
              if (_upiError != null) setState(() => _upiError = null);
            },
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: (widget.launched || !widget.enabled) ? null : _payQr,
            child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: const Row(children: [
              Icon(Icons.qr_code_2_rounded, color: AppColors.gold, size: 48),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pay via QR Code',
                        style: TextStyle(
                            color: AppColors.navy,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    SizedBox(height: 4),
                    Text('Scan using any UPI app (GPay, PhonePe, Paytm)',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  ],
                ),
              ),
            ]),
            ),
          ),
        ];
      case 'card':
        return [
          _infoBox(Icons.lock_outline_rounded, AppColors.success,
              'Enter your card details and any verification code in the secure Razorpay checkout screen.'),
        ];
      case 'netbanking':
        return [
          DropdownButtonFormField<String>(
            initialValue: _bank,
            decoration: const InputDecoration(
              labelText: 'Select Bank',
              prefixIcon: Icon(Icons.account_balance_outlined,
                  color: AppColors.success),
            ),
            dropdownColor: AppColors.white,
            style: const TextStyle(color: AppColors.charcoal),
            items: _banks.keys
                .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                .toList(),
            onChanged: (v) => setState(() {
              _bank = v;
              _error = null;
            }),
          ),
        ];
      case 'wallet':
        return [
          Row(
            children: [
              for (var i = 0; i < _wallets.length; i++)
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _wallet = _wallets[i];
                      _error = null;
                    }),
                    child: Container(
                      height: 70,
                      margin: EdgeInsets.only(
                          right: i < _wallets.length - 1 ? 10 : 0),
                      decoration: BoxDecoration(
                        color: _wallet == _wallets[i]
                            ? AppColors.gold.withValues(alpha: .15)
                            : AppColors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _wallet == _wallets[i]
                              ? AppColors.gold
                              : AppColors.cardBorder,
                          width: _wallet == _wallets[i] ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(_wallets[i],
                          style: const TextStyle(
                              color: AppColors.navy,
                              fontWeight: FontWeight.w700,
                              fontSize: 12)),
                    ),
                  ),
                ),
            ],
          ),
        ];
      case 'emi':
        return [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [3, 6, 9, 12].map((months) {
              final selected = _emiMonths == months;
              return GestureDetector(
                onTap: () => setState(() {
                  _emiMonths = months;
                  _error = null;
                }),
                child: Container(
                  width: (MediaQuery.of(context).size.width - 50) / 2,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.gold.withValues(alpha: .15)
                        : AppColors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: selected ? AppColors.gold : AppColors.cardBorder,
                        width: selected ? 2 : 1),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$months months',
                            style: TextStyle(
                                color:
                                    selected ? AppColors.gold : AppColors.navy,
                                fontWeight: FontWeight.w800,
                                fontSize: 15)),
                        const SizedBox(height: 6),
                        Text('${_money(_payAmount / months)}/month',
                            style: const TextStyle(
                                color: AppColors.textMuted,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        const SizedBox(height: 4),
                        Text('${_money(_payAmount)} total',
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 11)),
                      ]),
                ),
              );
            }).toList(),
          ),
        ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final children = _buildChildren();
    if (widget.embedded) {
      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }
    return ListView(padding: const EdgeInsets.all(18), children: children);
  }

  List<Widget> _buildChildren() => [
          if (!widget.embedded) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(children: [
                _SummaryRow('Order', widget.orderId),
                if (widget.customerName.isNotEmpty)
                  _SummaryRow('Customer', widget.customerName),
                _SummaryRow('Description', widget.description),
              ]),
            ),
            const SizedBox(height: 20),
          ],
          const Text('Payment Type',
              style: TextStyle(
                  color: AppColors.textLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 14)),
          const SizedBox(height: 10),
          if (widget.allowTypeChoice)
            Row(children: [
              _typeCard('full', 'Full Payment', 'Pay entire amount'),
              const SizedBox(width: 12),
              _typeCard('advance', 'Advance (25%)', 'Pay 25% now'),
            ])
          else
            Row(children: [
              _typeCard(widget.paymentType,
                  widget.paymentType == 'advance' ? 'Advance (25%)' : 'Full Payment',
                  widget.paymentType == 'advance' ? 'Pay 25% now' : 'Pay entire amount'),
            ]),
          const SizedBox(height: 20),
          const Text('Select a Payment Method',
              style: TextStyle(
                  color: AppColors.textLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 14)),
          const SizedBox(height: 6),
          const Text(
              'Choose the available payment method in Razorpay secure checkout.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(height: 12),
          Row(children: [
            _PayMethod(Icons.account_balance_wallet_outlined, 'UPI / GPay',
                AppColors.gold,
                selected: _selectedMethod == 'upi', onTap: () => _select('upi')),
            const SizedBox(width: 10),
            _PayMethod(
                Icons.credit_card_outlined, 'Credit / Debit', AppColors.info,
                selected: _selectedMethod == 'card',
                onTap: () => _select('card')),
            const SizedBox(width: 10),
            _PayMethod(Icons.account_balance_outlined, 'Net Banking',
                AppColors.success,
                selected: _selectedMethod == 'netbanking',
                onTap: () => _select('netbanking')),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _PayMethod(
                Icons.phone_android_outlined, 'Wallets', AppColors.warning,
                selected: _selectedMethod == 'wallet',
                onTap: () => _select('wallet')),
            const SizedBox(width: 10),
            _PayMethod(
                Icons.currency_rupee_outlined, 'EMI', AppColors.textLight,
                selected: _selectedMethod == 'emi', onTap: () => _select('emi')),
          ]),
          const SizedBox(height: 16),
          ..._methodFields(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.danger),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.error_outline_rounded,
                    color: AppColors.danger, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_error!,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 13))),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.softGray,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: const Row(children: [
              Icon(Icons.lock_rounded, color: AppColors.success, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '100% Secure · Powered by Razorpay · Card details, bank credentials and OTP are entered only in Razorpay Checkout.',
                  style: TextStyle(color: AppColors.textLight, fontSize: 12),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: (widget.launched || !widget.enabled) ? null : _pay,
            child: Opacity(
              opacity: widget.enabled ? 1 : .5,
              child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.gold, AppColors.goldDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.gold.withValues(alpha: .35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.lock_rounded,
                    color: AppColors.navyDeep, size: 18),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    widget.buttonLabel ?? 'Submit & Pay ${_money(_payAmount)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.navyDeep,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ]),
            ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Card, bank, wallet details and OTP are entered securely in Razorpay Checkout.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        ];
}

// ── Result View ───────────────────────────────────────────────────────────────
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.isSuccess,
    required this.isPending,
    required this.message,
    required this.orderId,
    required this.onDone,
    required this.onRetry,
  });
  final bool isSuccess;
  final bool isPending;
  final String message, orderId;
  final VoidCallback onDone;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final statusColor = isSuccess
        ? AppColors.success
        : (isPending ? AppColors.warning : AppColors.danger);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: .12),
              shape: BoxShape.circle,
              border: Border.all(color: statusColor, width: 2),
            ),
            child: Icon(
              isSuccess
                  ? Icons.check_circle_rounded
                  : (isPending
                      ? Icons.hourglass_top_rounded
                      : Icons.cancel_rounded),
              color: statusColor,
              size: 52,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            isSuccess
                ? 'Payment Successful!'
                : (isPending ? 'Payment Status Pending' : 'Payment Failed'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Text(
              isSuccess ? 'Payment ID: $message' : message,
              style: const TextStyle(color: AppColors.textLight, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
          if (isSuccess) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: AppColors.success.withValues(alpha: .3)),
              ),
              child: Text(
                'Payment recorded for order $orderId',
                style: const TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                    fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onDone,
              child: Text(isSuccess ? 'View My Orders' : 'Back to Order'),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try Again'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────────────────────────
class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(
              child: Text(value,
                  style: const TextStyle(
                      color: AppColors.navy,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  textAlign: TextAlign.end)),
        ]),
      );
}

class _PayMethod extends StatelessWidget {
  const _PayMethod(this.icon, this.label, this.color,
      {this.selected = false, this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.softGray : AppColors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? AppColors.gold : AppColors.cardBorder,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 5),
              Text(label,
                  style: const TextStyle(
                      color: AppColors.navy,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              if (selected)
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.gold,
                    shape: BoxShape.circle,
                  ),
                ),
            ]),
          ),
        ),
      );
}

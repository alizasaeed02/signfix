import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import '../services/api_client.dart';
import '../core/app_utils.dart';

/// "Order & Create: AI Storefront Preview" card shared by the three home
/// banner flows (Order wizard, Design Studio, Power Supply).
///
/// * Generates a preview automatically once the selections settle
///   ([autoDelay] after the last change) as long as [ready] is true.
/// * If the selections change afterwards the image is marked out of date and
///   the customer can regenerate it.
/// * [onChanged] reports the image / prompt / "use this design" state so the
///   host screen can attach it to the order.
class _CachedPreview {
  _CachedPreview(this.selectionKey, this.url, this.prompt, this.confirmed);
  final String selectionKey;
  final String url;
  final String? prompt;
  bool confirmed;
}

class AiPreviewCard extends StatefulWidget {
  /// Last generated preview per screen ([cacheScope]). Survives the card
  /// being rebuilt (rotation, navigating away and back) so the image is only
  /// regenerated when the customer changes a selection.
  static final Map<String, _CachedPreview> _cache = {};

  /// Forget the saved preview (call after an order is placed / reset).
  static void clearCache(String cacheScope) => _cache.remove(cacheScope);

  const AiPreviewCard({
    super.key,
    required this.api,
    required this.cacheScope,
    required this.selectionKey,
    required this.ready,
    required this.buildRequest,
    required this.promptSummary,
    this.designSummary,
    this.onChanged,
    this.autoGenerate = true,
    this.autoDelay = const Duration(seconds: 2),
    this.title = 'Order & Create: AI Storefront Preview',
    this.notReadyMessage = 'Complete your selections to see the AI preview.',
  });

  final ApiClient api;

  /// Identifies the screen this card belongs to (e.g. 'wizard', 'signage').
  final String cacheScope;

  /// Changes whenever any customer selection that affects the design changes.
  final String selectionKey;

  /// Enough information is available to generate a preview.
  final bool ready;

  /// Body for POST /customer/designs/preview (may be async, e.g. to capture
  /// a reference image).
  final FutureOr<Map<String, dynamic>> Function() buildRequest;

  /// Text saved on the order as `aiPrompt`.
  final String Function() promptSummary;

  /// Short "what the customer designed" line shown above "AI used", so the
  /// two can be compared at a glance.
  final String Function()? designSummary;

  final void Function(String? imageUrl, String? prompt, bool confirmed)?
      onChanged;
  final bool autoGenerate;
  final Duration autoDelay;
  final String title;
  final String notReadyMessage;

  @override
  State<AiPreviewCard> createState() => _AiPreviewCardState();
}

class _AiPreviewCardState extends State<AiPreviewCard> {
  String? _url;
  String? _prompt;
  String? _specs; // what the server says it generated (from `specifications`)
  bool _loading = false;
  bool _confirmed = false;
  bool _stale = false;
  String? _error;
  Timer? _timer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // Rebuilt with the same selections (rotation, came back to this screen):
    // show the preview that was already generated instead of making a new one.
    final saved = AiPreviewCard._cache[widget.cacheScope];
    if (saved != null && saved.selectionKey == widget.selectionKey) {
      _url = saved.url;
      _prompt = saved.prompt;
      _confirmed = saved.confirmed;
      // Tell the host after the first frame (it may not be built yet).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _notify();
      });
    } else {
      _maybeSchedule();
    }
  }

  @override
  void didUpdateWidget(AiPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.selectionKey != widget.selectionKey) {
      // A selection changed: the old image no longer matches -> update it.
      if (_url != null && !_stale) {
        _stale = true;
        _confirmed = false;
        AiPreviewCard._cache.remove(widget.cacheScope);
        _notify();
      }
      _maybeSchedule();
    } else if (!old.ready && widget.ready) {
      _maybeSchedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Leaving the screen (e.g. back to edit selections) drops the old image
    // so it can't be attached to an order it no longer matches.
    widget.onChanged?.call(null, null, false);
    super.dispose();
  }

  void _notify() =>
      widget.onChanged?.call(_stale ? null : _url, _prompt, _confirmed);

  // Automatic: the first preview, and again whenever a selection changes
  // (the previous image is out of date). Rotation / navigation never trigger
  // a new generation.
  void _maybeSchedule() {
    _timer?.cancel();
    final needsPreview = _url == null || _stale;
    if (!widget.autoGenerate || !widget.ready || !needsPreview || _loading) {
      return;
    }
    _timer = Timer(widget.autoDelay, () {
      if (mounted &&
          widget.ready &&
          !_loading &&
          (_url == null || _stale)) {
        _generate();
      }
    });
  }

  Future<void> _generate() async {
    if (!widget.ready) {
      setState(() => _error = widget.notReadyMessage);
      return;
    }
    final run = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _confirmed = false;
    });
    try {
      final body = await widget.buildRequest();
      final res = await widget.api.generateDesignPreview(body);
      final url = res['imageUrl']?.toString();
      if (url == null || url.trim().isEmpty) {
        throw const ApiException(
            'AI image generation is not available right now. Please try again shortly.');
      }
      if (!mounted || run != _generation) return;
      final s = res['specifications'];
      String? specs;
      if (s is Map) {
        String? t(String k) {
          final v = s[k]?.toString().trim();
          return (v == null || v.isEmpty) ? null : v;
        }

        final size = (t('width') != null && t('height') != null)
            ? '${t('width')} × ${t('height')} ${t('unit') ?? 'ft'}'
            : null;
        specs = [t('color'), t('material'), size]
            .whereType<String>()
            .join(' · ');
      }
      setState(() {
        _url = url;
        _prompt = widget.promptSummary();
        _specs = (specs == null || specs.isEmpty) ? null : specs;
        _stale = false;
      });
      AiPreviewCard._cache[widget.cacheScope] =
          _CachedPreview(widget.selectionKey, url, _prompt, false);
      _notify();
    } catch (e) {
      if (!mounted || run != _generation) return;
      setState(() => _error = userMessage(e));
    } finally {
      if (mounted && run == _generation) setState(() => _loading = false);
    }
  }

  Widget _image(String url,
      {double? height, double? width, BoxFit fit = BoxFit.cover}) {
    if (url.startsWith('data:')) {
      try {
        final Uint8List bytes =
            base64Decode(url.substring(url.indexOf(',') + 1));
        return Image.memory(bytes, height: height, width: width, fit: fit);
      } catch (_) {
        return const SizedBox.shrink();
      }
    }
    return Image.network(
      url,
      height: height,
      width: width,
      fit: fit,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : SizedBox(
              height: height ?? 200,
              child: const Center(
                  child: CircularProgressIndicator(color: AppColors.gold))),
      errorBuilder: (_, __, ___) => SizedBox(
        height: height ?? 200,
        child: const Center(
            child: Text('Preview image could not be loaded.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12))),
      ),
    );
  }

  void _openFullScreen() => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.zero,
          child: Stack(children: [
            InteractiveViewer(child: _image(_url!, fit: BoxFit.contain)),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasImage = _url != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.auto_awesome, color: AppColors.gold, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.title,
                  style: const TextStyle(
                      color: AppColors.navy,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
            ),
          ]),
          const SizedBox(height: 6),
          const Text(
              'A photorealistic AI visualization of your selections installed on a storefront, before you pay.',
              style: TextStyle(
                  color: AppColors.textBody, fontSize: 11, height: 1.3)),
          const SizedBox(height: 14),
          if (_loading)
            Container(
              height: 160,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.softGray,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.gold),
                  SizedBox(height: 12),
                  Text('Generating your AI preview…',
                      style:
                          TextStyle(color: AppColors.textLight, fontSize: 12)),
                ],
              ),
            )
          else if (hasImage) ...[
            GestureDetector(
              onTap: _openFullScreen,
              child: Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _image(_url!, height: 200, width: double.infinity),
                ),
                if (_stale)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .35),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: const Text('Selections changed',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            const Text('Tap the image to view it full screen',
                style: TextStyle(color: AppColors.textMuted, fontSize: 10)),
            if (widget.designSummary != null) ...[
              const SizedBox(height: 4),
              Text('Your design: ${widget.designSummary!()}',
                  style: const TextStyle(
                      color: AppColors.navy,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ],
            if (_specs != null) ...[
              const SizedBox(height: 4),
              Text('AI used: $_specs',
                  style: const TextStyle(
                      color: AppColors.textLight,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 10),
            if (_stale)
              const Text(
                  'Your selections changed - the preview will update shortly (or tap Regenerate).',
                  style: TextStyle(
                      color: AppColors.warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w700))
            else if (_confirmed)
              const Row(children: [
                Icon(Icons.check_circle, color: AppColors.success, size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'Design selected - it will be attached to your order',
                      style: TextStyle(
                          color: AppColors.success,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ])
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    setState(() => _confirmed = true);
                    AiPreviewCard._cache[widget.cacheScope]?.confirmed = true;
                    _notify();
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Use this design'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.navyDeep,
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ] else if (_error != null) ...[
            Text(_error!,
                style: const TextStyle(color: AppColors.warning, fontSize: 12)),
            const SizedBox(height: 10),
          ] else if (!widget.ready) ...[
            Text(widget.notReadyMessage,
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _loading ? null : _generate,
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: Text(hasImage || _error != null
                  ? 'Regenerate AI Preview'
                  : 'Generate AI Preview'),
            ),
          ),
        ],
      ),
    );
  }
}

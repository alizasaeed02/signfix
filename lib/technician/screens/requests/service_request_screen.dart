import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../../../core/app_utils.dart' show humanize;
import '../../core/app_theme.dart';
import '../../services/api_client.dart';
import '../../widgets/common.dart';

/// Service request raised by the technician from the field: when they go to a
/// place to handle an issue they upload photos, the problem, the location and
/// the on-site contact number. Same form as the customer's request page.
class TechnicianServiceRequestScreen extends StatefulWidget {
  const TechnicianServiceRequestScreen({super.key, required this.api});
  final TechnicianApi api;
  @override
  State<TechnicianServiceRequestScreen> createState() =>
      _TechnicianServiceRequestScreenState();
}

class _TechnicianServiceRequestScreenState
    extends State<TechnicianServiceRequestScreen> {
  final _desc = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _contactName = TextEditingController();
  String _category = 'LED Problem';
  final _photos = <File>[];
  Position? _position;
  bool _loading = false;
  bool _gpsLoading = false;

  late Future<List<dynamic>> _mine;

  static const _categories = [
    'LED Problem',
    'Electrical Issue',
    'Physical Damage',
    'Sign Board Repair',
    'Replacement',
    'Installation',
    'Cleaning',
    'Maintenance',
    'Inspection',
    'Emergency',
    'Other',
  ];

  static final _phoneRegex = RegExp(r'^\+?[0-9][0-9\s-]{6,17}$');

  @override
  void initState() {
    super.initState();
    _mine = widget.api.siteRequests();
  }

  @override
  void dispose() {
    _desc.dispose();
    _address.dispose();
    _phone.dispose();
    _contactName.dispose();
    super.dispose();
  }

  void _reloadMine() => setState(() => _mine = widget.api.siteRequests());

  Future<void> _pick(ImageSource source) async {
    final file =
        await ImagePicker().pickImage(source: source, imageQuality: 78);
    if (file != null && mounted) setState(() => _photos.add(File(file.path)));
  }

  /// GPS coordinates + reverse-geocoded address (same as the customer page).
  Future<void> _captureLocation() async {
    setState(() => _gpsLoading = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) showAppError(context, 'Location permission is required.');
        return;
      }
      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              forceLocationManager: false,
              timeLimit: const Duration(seconds: 15),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15),
            );
      final pos = await Geolocator.getCurrentPosition(locationSettings: settings);
      final addressText = await _reverseGeocode(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _position = pos;
        if (addressText.isNotEmpty) _address.text = addressText;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(addressText.isNotEmpty
            ? 'Location captured: $addressText'
            : 'GPS location captured (${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)})'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (mounted) showAppError(context, e);
    } finally {
      if (mounted) setState(() => _gpsLoading = false);
    }
  }

  Future<String> _reverseGeocode(double lat, double lon) async {
    try {
      final res = await http.get(
        Uri.parse(
            'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&addressdetails=1'),
        headers: {
          'User-Agent': 'SignFix/1.0 (signfix@app.com)',
          'Accept-Language': 'en',
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final addr = (jsonDecode(res.body) as Map<String, dynamic>)['address']
                as Map<String, dynamic>? ??
            {};
        String s(String k) => addr[k]?.toString() ?? '';
        final road = s('road').isNotEmpty ? s('road') : s('pedestrian');
        final suburb = s('suburb').isNotEmpty ? s('suburb') : s('neighbourhood');
        final city = s('city').isNotEmpty
            ? s('city')
            : s('town').isNotEmpty
                ? s('town')
                : s('village');
        return [
          if (road.isNotEmpty)
            s('house_number').isNotEmpty ? '${s('house_number')} $road' : road,
          suburb,
          city,
          s('state'),
          s('postcode'),
          s('country'),
        ].where((p) => p.isNotEmpty).join(', ');
      }
    } catch (_) {
      // offline / rate-limited: the technician can type the address instead
    }
    return '';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final desc = _desc.text.trim();
    final phone = _phone.text.trim();
    if (desc.isEmpty) {
      showAppError(context, 'Please describe the problem at the site.');
      return;
    }
    if (desc.length < 10) {
      showAppError(context, 'Description must be at least 10 characters.');
      return;
    }
    if (phone.isEmpty) {
      showAppError(context, 'Please enter the contact number for this site.');
      return;
    }
    if (!_phoneRegex.hasMatch(phone)) {
      showAppError(context, 'Enter a valid contact number (7-15 digits).');
      return;
    }
    if (_address.text.trim().isEmpty) {
      showAppError(
          context, 'Please enter the site address or use GPS location.');
      return;
    }
    if (_photos.isEmpty) {
      showAppError(context, 'Please add at least 1 photo of the problem.');
      return;
    }

    setState(() => _loading = true);
    try {
      final urls = <String>[];
      for (final file in _photos) {
        final result = await widget.api.upload(file, 'service-request', 'site');
        if (result['url'] != null) urls.add(result['url'].toString());
      }
      if (urls.isEmpty) {
        throw const ApiException('Photos could not be uploaded. Try again.');
      }
      final result = await widget.api.createSiteRequest({
        'category': _category,
        'description': desc,
        'address': _address.text.trim(),
        'contactNumber': phone,
        if (_contactName.text.trim().isNotEmpty)
          'contactName': _contactName.text.trim(),
        if (_position != null) 'latitude': _position!.latitude,
        if (_position != null) 'longitude': _position!.longitude,
        'photos': urls,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.navyDark,
          icon: const Icon(Icons.check_circle_rounded,
              color: AppColors.success, size: 52),
          title: const Text('Request Submitted!',
              style: TextStyle(color: AppColors.white)),
          content: Text(
            '${result['message'] ?? 'Your request has been received.'}\n\nReference: ${result['id'] ?? ''}',
            style: const TextStyle(color: AppColors.textLight),
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'))
          ],
        ),
      );
      if (mounted) {
        _desc.clear();
        _address.clear();
        _phone.clear();
        _contactName.clear();
        setState(() {
          _photos.clear();
          _position = null;
        });
        _reloadMine();
      }
    } catch (e) {
      if (mounted) showAppError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        color: AppColors.gold,
        onRefresh: () async {
          _reloadMine();
          await _mine.then<void>((_) {}, onError: (Object _) {});
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(18),
          children: [
            const Text('Request a service',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy)),
            const SizedBox(height: 4),
            const Text(
                'At a site? Photo → problem → contact number → location → submit',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            const SizedBox(height: 20),

            // Photos
            Row(children: [
              Expanded(
                  child: OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Camera'),
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
              )),
            ]),
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 80,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(_photos[i],
                          width: 80, height: 80, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () => setState(() => _photos.removeAt(i)),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                              color: AppColors.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.close,
                              size: 12, color: AppColors.white),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 14),

            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(
                labelText: 'Problem category',
                prefixIcon: Icon(Icons.category_outlined),
              ),
              dropdownColor: AppColors.white,
              style: const TextStyle(color: AppColors.navy),
              items: _categories
                  .map((x) => DropdownMenuItem(
                        value: x,
                        child: Text(x,
                            style: const TextStyle(color: AppColors.navy)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v!),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _desc,
              maxLines: 4,
              style: const TextStyle(color: AppColors.charcoal),
              decoration: const InputDecoration(
                labelText: 'Describe the problem *',
                hintText: 'e.g. LED panel flickering, sign board broken...',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.description_outlined),
              ),
            ),
            const SizedBox(height: 12),

            // Contact number at the site
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              style: const TextStyle(color: AppColors.charcoal),
              decoration: const InputDecoration(
                labelText: 'Contact number *',
                hintText: 'Phone number of the person at the site',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contactName,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: AppColors.charcoal),
              decoration: const InputDecoration(
                labelText: 'Contact person (optional)',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),

            // Address — editable, auto-filled by GPS
            TextField(
              controller: _address,
              maxLines: 2,
              style: const TextStyle(color: AppColors.charcoal),
              decoration: InputDecoration(
                labelText: 'Site address *',
                hintText: 'Enter address or use GPS below',
                prefixIcon: const Icon(Icons.location_on_outlined),
                suffixIcon: _address.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear,
                            color: AppColors.textMuted, size: 18),
                        onPressed: () => setState(() {
                          _address.clear();
                          _position = null;
                        }),
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _gpsLoading ? null : _captureLocation,
                icon: _gpsLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.gold))
                    : Icon(
                        _position == null
                            ? Icons.my_location_rounded
                            : Icons.check_circle_outline_rounded,
                        color: _position == null
                            ? AppColors.gold
                            : AppColors.success,
                      ),
                label: Text(
                  _gpsLoading
                      ? 'Getting location…'
                      : _position == null
                          ? 'Use GPS location'
                          : 'GPS location captured  (tap to refresh)',
                  style: TextStyle(
                    color:
                        _position == null ? AppColors.gold : AppColors.success,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: _position == null
                        ? AppColors.gold.withValues(alpha: .5)
                        : AppColors.success.withValues(alpha: .5),
                  ),
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
            if (_position != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.gps_fixed, size: 13, color: AppColors.success),
                const SizedBox(width: 6),
                Text(
                  'GPS: ${_position!.latitude.toStringAsFixed(5)}, ${_position!.longitude.toStringAsFixed(5)}',
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.success),
                ),
              ]),
            ],
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: LoadingButton(
                loading: _loading,
                onPressed: _submit,
                child: const Text('Submit service request'),
              ),
            ),
            const SizedBox(height: 28),

            // Previously submitted requests
            const Text('My submitted requests',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy)),
            const SizedBox(height: 10),
            FutureBuilder<List<dynamic>>(
              future: _mine,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                        child:
                            CircularProgressIndicator(color: AppColors.gold)),
                  );
                }
                if (snap.hasError) {
                  return Row(children: [
                    const Expanded(
                        child: Text('Could not load your requests.',
                            style: TextStyle(color: AppColors.textMuted))),
                    TextButton(
                        onPressed: _reloadMine, child: const Text('Retry')),
                  ]);
                }
                final items = snap.data ?? [];
                if (items.isEmpty) {
                  return const Text('No requests submitted yet.',
                      style: TextStyle(color: AppColors.textMuted));
                }
                return Column(
                  children: items
                      .whereType<Map>()
                      .map((r) => _RequestCard(request: r))
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      );
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request});
  final Map request;

  @override
  Widget build(BuildContext context) {
    final status = request['status']?.toString() ?? 'submitted';
    final done = status == 'completed' || status == 'closed';
    final color = done ? AppColors.success : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(request['id']?.toString() ?? '',
                style: const TextStyle(
                    color: AppColors.gold,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: .3)),
            ),
            child: Text(humanize(status),
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(request['category']?.toString() ?? '',
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: AppColors.charcoal)),
        const SizedBox(height: 4),
        Text(request['description']?.toString() ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textLight, fontSize: 12)),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.phone_outlined,
              size: 14, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text(request['contactNumber']?.toString() ?? '',
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textLight)),
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.location_on_outlined,
              size: 14, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Expanded(
            child: Text(request['address']?.toString() ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textLight)),
          ),
        ]),
      ]),
    );
  }
}

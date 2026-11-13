import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../services/api_client.dart';
import '../../widgets/common.dart';
import '../../../core/app_utils.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.api, required this.onLogout});
  final TechnicianApi api;
  final VoidCallback onLogout;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<Map<String, dynamic>> _future;
  bool _editing = false;
  bool _saving = false;
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emergencyCtrl = TextEditingController();
  final _skillsCtrl = TextEditingController();
  bool _locationSharing = true;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getProfile();
  }

  void _handleAuthError() async {
    await widget.api.logout();
    if (mounted) widget.onLogout();
  }

  void _reload() {
    final future = widget.api.getProfile();
    setState(() {
      _future = future;
    });
  }

  Future<void> _pullToRefresh() async {
    final future = widget.api.getProfile();
    setState(() {
      _future = future;
    });
    await future.then<void>((_) {}, onError: (Object _) {});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emergencyCtrl.dispose();
    _skillsCtrl.dispose();
    super.dispose();
  }

  void _startEdit(Map<String, dynamic> p) {
    _nameCtrl.text = p['name'] ?? '';
    _phoneCtrl.text = (p['mobile'] ?? p['phone'])?.toString() ?? '';
    _emergencyCtrl.text = p['emergencyContact']?.toString() ?? '';
    _skillsCtrl.text = (p['skills'] as List? ?? []).join(', ');
    _locationSharing = p['locationSharing'] == true;
    setState(() => _editing = true);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final skills = _skillsCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      await widget.api.updateProfile({
        'name': _nameCtrl.text.trim(),
        'mobile': _phoneCtrl.text.trim(),
        'emergencyContact': _emergencyCtrl.text.trim(),
        'skills': skills,
        'locationSharing': _locationSharing,
      });
      if (mounted) {
        setState(() {
          _editing = false;
          _future = widget.api.getProfile();
        });
      }
    } catch (e) {
      if (mounted) showAppError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Sign out', style: TextStyle(color: AppColors.navy)),
        content: const Text('Are you sure you want to sign out?',
            style: TextStyle(color: AppColors.midGray)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.logout();
      widget.onLogout();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.softGray,
        appBar: AppBar(
          backgroundColor: AppColors.appBar,
          foregroundColor: AppColors.navy,
          automaticallyImplyLeading: false,
          title: const Text('My Profile',
              style: TextStyle(
                  color: AppColors.navy, fontWeight: FontWeight.w800)),
        ),
        body: Container(
          color: AppColors.softGray,
          child: FutureBuilder<Map<String, dynamic>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(
                    child: CircularProgressIndicator(color: AppColors.gold));
              }
              if (snap.hasError) {
                final errMsg = snap.error.toString();
                final isAuthError =
                    errMsg.toLowerCase().contains('authentication') ||
                        errMsg.toLowerCase().contains('unauthorized') ||
                        errMsg.toLowerCase().contains('401');
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: isAuthError
                              ? AppColors.warning.withValues(alpha: .1)
                              : AppColors.danger.withValues(alpha: .1),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: isAuthError
                                  ? AppColors.warning
                                  : AppColors.danger,
                              width: 2),
                        ),
                        child: Icon(
                            isAuthError
                                ? Icons.lock_outline_rounded
                                : Icons.error_outline_rounded,
                            color: isAuthError
                                ? AppColors.warning
                                : AppColors.danger,
                            size: 40),
                      ),
                      const SizedBox(height: 20),
                      Text(
                          isAuthError
                              ? 'Session Expired'
                              : 'Could Not Load Profile',
                          style: const TextStyle(
                              color: AppColors.navy,
                              fontSize: 18,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Text(
                          isAuthError
                              ? 'Your session has expired. Please sign in again.'
                              : 'Unable to load data. Please try again.',
                          style: const TextStyle(
                              color: AppColors.midGray, fontSize: 13),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: isAuthError
                            ? FilledButton.icon(
                                onPressed: _handleAuthError,
                                icon: const Icon(Icons.login_rounded),
                                label: const Text('Sign In Again'))
                            : OutlinedButton(
                                onPressed: _reload,
                                child: const Text('Try Again')),
                      ),
                    ]),
                  ),
                );
              }
              final p = snap.data!;
              final skills = List<String>.from(p['skills'] as List? ?? []);

              return RefreshIndicator(
                color: AppColors.gold,
                backgroundColor: AppColors.white,
                onRefresh: _pullToRefresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(18),
                  children: [
                    // ── Avatar & Name ──────────────────────────────────────────────
                    Center(
                        child: Column(children: [
                      Text(
                          p['name']?.toString().isNotEmpty == true
                              ? p['name'].toString()
                              : 'Technician',
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: AppColors.navy)),
                      const SizedBox(height: 4),
                      Text(p['email'] ?? '',
                          style: const TextStyle(
                              color: AppColors.midGray, fontSize: 13)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.gold.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: AppColors.gold.withValues(alpha: .3)),
                        ),
                        child: Text(
                            p['employeeId']?.toString().isNotEmpty == true
                                ? 'EMP ID: ${p['employeeId']}'
                                : 'ID: ${p['technicianId'] ?? '—'}',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.gold)),
                      ),
                    ])),
                    const SizedBox(height: 20),

                    // ── Complete your profile (pending approval / missing details) ──
                    ValueListenableBuilder<String>(
                      valueListenable: widget.api.accountStatus,
                      builder: (context, status, _) {
                        final areas = p['serviceAreas'];
                        final missing = (areas is List
                                ? areas.isEmpty
                                : (p['workLocation'] ?? '')
                                    .toString()
                                    .trim()
                                    .isEmpty) ||
                            skills.isEmpty;
                        if (status != 'pending_approval' && !missing) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: _CompleteProfileCard(
                            api: widget.api,
                            profile: p,
                            pending: status == 'pending_approval',
                            onSaved: _pullToRefresh,
                          ),
                        );
                      },
                    ),

                    // ── Performance ────────────────────────────────────────────────
                    Row(children: [
                      _PerfCard('${p['totalJobsCompleted'] ?? 0}', 'Jobs Done',
                          Icons.check_circle_outline, AppColors.success),
                      const SizedBox(width: 12),
                      _PerfCard('${p['rating'] ?? '—'}', 'Rating',
                          Icons.star_rounded, AppColors.warning),
                    ]),
                    const SizedBox(height: 16),

                    // ── Profile Details ────────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: AppColors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Text('Profile Details',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.navy)),
                              const Spacer(),
                              if (!_editing)
                                GestureDetector(
                                  onTap: () => _startEdit(p),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color:
                                          AppColors.gold.withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                          color: AppColors.gold
                                              .withValues(alpha: .3)),
                                    ),
                                    child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.edit_outlined,
                                              size: 14, color: AppColors.gold),
                                          SizedBox(width: 4),
                                          Text('Edit',
                                              style: TextStyle(
                                                  color: AppColors.gold,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12)),
                                        ]),
                                  ),
                                ),
                            ]),
                            const SizedBox(height: 14),
                            if (_editing) ...[
                              _Field(
                                  _nameCtrl, 'Full name', Icons.person_outline),
                              const SizedBox(height: 10),
                              _Field(_phoneCtrl, 'Phone', Icons.phone_outlined,
                                  type: TextInputType.phone),
                              const SizedBox(height: 10),
                              _Field(_emergencyCtrl, 'Emergency contact',
                                  Icons.emergency_outlined,
                                  type: TextInputType.phone),
                              const SizedBox(height: 10),
                              _Field(_skillsCtrl, 'Skills (comma separated)',
                                  Icons.build_outlined,
                                  hint: 'e.g. LED Wiring, ACP Fabrication'),
                              const SizedBox(height: 10),
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: AppColors.cardBorder),
                                ),
                                child: Material(
                                  color: AppColors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  child: SwitchListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 14),
                                    value: _locationSharing,
                                    onChanged: (v) =>
                                        setState(() => _locationSharing = v),
                                    title: const Text('Location sharing',
                                        style: TextStyle(
                                            color: AppColors.navy,
                                            fontWeight: FontWeight.w600)),
                                    subtitle: const Text(
                                        'Allow admin to track your location during jobs',
                                        style: TextStyle(
                                            color: AppColors.midGray,
                                            fontSize: 12)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(children: [
                                Expanded(
                                    child: OutlinedButton(
                                        onPressed: () =>
                                            setState(() => _editing = false),
                                        child: const Text('Cancel'))),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: LoadingButton(
                                        loading: _saving,
                                        onPressed: _save,
                                        child: const Text('Save'))),
                              ]),
                            ] else ...[
                              _InfoRow(
                                  Icons.phone_outlined,
                                  'Phone',
                                  (p['mobile'] ?? p['phone'])
                                              ?.toString()
                                              .isNotEmpty ==
                                          true
                                      ? (p['mobile'] ?? p['phone']).toString()
                                      : 'Not set'),
                              const SizedBox(height: 10),
                              _InfoRow(
                                  Icons.emergency_outlined,
                                  'Emergency contact',
                                  p['emergencyContact']
                                              ?.toString()
                                              .isNotEmpty ==
                                          true
                                      ? p['emergencyContact'].toString()
                                      : 'Not set'),
                              const SizedBox(height: 10),
                              if (p['employeeId'] != null &&
                                  p['employeeId'].toString().isNotEmpty) ...[
                                _InfoRow(Icons.badge_outlined, 'Employee ID',
                                    p['employeeId'].toString()),
                                const SizedBox(height: 10),
                              ],
                              if (p['dateOfJoining'] != null &&
                                  p['dateOfJoining'].toString().isNotEmpty) ...[
                                _InfoRow(
                                    Icons.calendar_today_outlined,
                                    'Date of Joining',
                                    p['dateOfJoining'].toString()),
                                const SizedBox(height: 10),
                              ],
                              if ((p['serviceAreas'] as List?)?.isNotEmpty ==
                                  true) ...[
                                _InfoRow(
                                    Icons.location_city_outlined,
                                    'Work Location',
                                    (p['serviceAreas'] as List).join(', ')),
                                const SizedBox(height: 10),
                              ],
                              _InfoRow(
                                p['locationSharing'] == true
                                    ? Icons.location_on_outlined
                                    : Icons.location_off_outlined,
                                'Location sharing',
                                p['locationSharing'] == true
                                    ? 'Enabled'
                                    : 'Disabled',
                                valueColor: p['locationSharing'] == true
                                    ? AppColors.success
                                    : AppColors.midGray,
                              ),
                            ],
                          ]),
                    ),
                    const SizedBox(height: 14),

                    // ── Skills ─────────────────────────────────────────────────────
                    if (skills.isNotEmpty && !_editing)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Skills',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.navy)),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: skills
                                    .map((s) => Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: AppColors.gold
                                                .withValues(alpha: .1),
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            border: Border.all(
                                                color: AppColors.gold
                                                    .withValues(alpha: .3)),
                                          ),
                                          child: Text(s,
                                              style: const TextStyle(
                                                  color: AppColors.gold,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12)),
                                        ))
                                    .toList(),
                              ),
                            ]),
                      ),
                    const SizedBox(height: 20),

                    // ── Sign out ───────────────────────────────────────────────────
                    GestureDetector(
                      onTap: _confirmLogout,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.danger.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: AppColors.danger.withValues(alpha: .4)),
                        ),
                        child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.logout_rounded,
                                  color: AppColors.danger, size: 20),
                              SizedBox(width: 8),
                              Text('Sign Out',
                                  style: TextStyle(
                                      color: AppColors.danger,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15)),
                            ]),
                      ),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              );
            },
          ),
        ),
      );
}

// ── Widgets ────────────────────────────────────────────────────────────────────
class _PerfCard extends StatelessWidget {
  const _PerfCard(this.value, this.label, this.icon, this.color);
  final String value, label;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: .3)),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800, color: color)),
              Text(label,
                  style:
                      const TextStyle(fontSize: 12, color: AppColors.midGray)),
            ]),
          ]),
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field(this.ctrl, this.label, this.icon,
      {this.type = TextInputType.text, this.hint});
  final TextEditingController ctrl;
  final String label;
  final IconData icon;
  final TextInputType type;
  final String? hint;
  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl,
        keyboardType: type,
        style: const TextStyle(color: AppColors.charcoal),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.label, this.value, {this.valueColor});
  final IconData icon;
  final String label, value;
  final Color? valueColor;
  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.midGray)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: valueColor ?? AppColors.charcoal)),
              ])),
        ],
      );
}

// ── Complete profile card (work location, skills, mobile) ────────────────────
// Option A of the approval workflow: the technician fills in their own details.
// (Option B: an admin can enter the same details from the Admin Panel.)
class _CompleteProfileCard extends StatefulWidget {
  const _CompleteProfileCard({
    required this.api,
    required this.profile,
    required this.pending,
    required this.onSaved,
  });
  final TechnicianApi api;
  final Map<String, dynamic> profile;
  final bool pending;
  final Future<void> Function() onSaved;

  @override
  State<_CompleteProfileCard> createState() => _CompleteProfileCardState();
}

class _CompleteProfileCardState extends State<_CompleteProfileCard> {
  late final TextEditingController _city;
  late final TextEditingController _skills;
  late final TextEditingController _mobile;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    // Work location / city = the technician's service areas (guide: serviceAreas[]).
    final areas = p['serviceAreas'];
    _city = TextEditingController(
        text: areas is List
            ? areas.join(', ')
            : (p['workLocation']?.toString() ?? ''));
    _skills = TextEditingController(
        text: (p['skills'] as List? ?? const []).join(', '));
    _mobile = TextEditingController(
        text: (p['mobile'] ?? p['phone'])?.toString() ?? '');
  }

  @override
  void dispose() {
    _city.dispose();
    _skills.dispose();
    _mobile.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final city = _city.text.trim();
    final skills = _skills.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final mobile = _mobile.text.trim();
    final digits = mobile.replaceAll(RegExp(r'[^0-9]'), '');
    String? err;
    if (city.length < 2) {
      err = 'Please enter your work location / city.';
    } else if (skills.isEmpty) {
      err = 'Please enter at least one skill (separate with commas).';
    } else if (digits.length < 8) {
      err = 'Please enter a valid mobile number.';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.api.updateProfile({
        'serviceAreas': city
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        'skills': skills,
        'mobile': mobile,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(widget.pending
            ? 'Profile submitted. An admin will review and approve your account.'
            : 'Profile saved.'),
        backgroundColor: AppColors.success,
      ));
      await widget.onSaved();
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gold.withValues(alpha: .5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.assignment_ind_outlined,
                color: AppColors.gold, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  widget.pending
                      ? 'Complete your profile'
                      : 'Add your work details',
                  style: const TextStyle(
                      color: AppColors.navy,
                      fontWeight: FontWeight.w800,
                      fontSize: 15)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
              widget.pending
                  ? 'Submit your details so an admin can review and approve your account. You can also ask an admin to fill them in for you.'
                  : 'Your work location and skills help us assign the right jobs.',
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 12, height: 1.3)),
          const SizedBox(height: 14),
          TextField(
            controller: _city,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: AppColors.charcoal),
            decoration: const InputDecoration(
              labelText: 'Work location / city *',
              hintText: 'e.g. Noida Sector 62, East Delhi',
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _skills,
            style: const TextStyle(color: AppColors.charcoal),
            decoration: const InputDecoration(
              labelText: 'Skills *',
              hintText: 'e.g. LED repair, installation, wiring',
              prefixIcon: Icon(Icons.build_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _mobile,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: AppColors.charcoal),
            decoration: const InputDecoration(
              labelText: 'Mobile number *',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: LoadingButton(
              loading: _saving,
              onPressed: _submit,
              child: const Text('Submit'),
            ),
          ),
        ]),
      );
}

import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import '../core/app_utils.dart' show userMessage;

/// "Delete account" tile + confirmation flow (App Store guideline 5.1.1(v):
/// apps that let users create an account must let them delete it in the app).
///
/// The user must type DELETE to confirm. [onDelete] calls the server; when it
/// succeeds [onDeleted] runs (sign out and return to the login screen).
class DeleteAccountButton extends StatelessWidget {
  const DeleteAccountButton({
    super.key,
    required this.onDelete,
    required this.onDeleted,
  });

  final Future<void> Function() onDelete;
  final VoidCallback onDeleted;

  Future<void> _start(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await onDelete();
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(const SnackBar(
        content: Text('Your account has been deleted.'),
        backgroundColor: AppColors.success,
      ));
      onDeleted();
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(
        content: Text(userMessage(e,
            fallback: 'Could not delete your account. Please try again.')),
        backgroundColor: AppColors.danger,
      ));
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => _start(context),
        icon: const Icon(Icons.delete_forever_outlined,
            color: AppColors.danger, size: 20),
        label: const Text('Delete account',
            style: TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w700,
                fontSize: 14)),
      );
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _text = TextEditingController();
  bool _ok = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.white,
        title: const Text('Delete your account?',
            style: TextStyle(color: AppColors.navy)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently deletes your account and removes your '
              'personal details (name, email, phone number and saved '
              'addresses). You will not be able to sign in again with it. '
              'This cannot be undone.',
              style: TextStyle(color: AppColors.charcoal, height: 1.35),
            ),
            const SizedBox(height: 14),
            const Text('Type DELETE to confirm:',
                style: TextStyle(
                    color: AppColors.charcoal, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: _text,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              onChanged: (v) =>
                  setState(() => _ok = v.trim().toUpperCase() == 'DELETE'),
              decoration: const InputDecoration(hintText: 'DELETE'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: _ok ? () => Navigator.pop(context, true) : null,
              child: const Text('Delete account')),
        ],
      );
}

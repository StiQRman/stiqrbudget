import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/budgets_provider.dart';
import '../providers/pb_provider.dart';
import '../services/pocketbase_service.dart';
import '../utils/app_theme.dart';

class CollaboratorsModal extends ConsumerStatefulWidget {
  const CollaboratorsModal({super.key});

  @override
  ConsumerState<CollaboratorsModal> createState() => _CollaboratorsModalState();
}

class _CollaboratorsModalState extends ConsumerState<CollaboratorsModal> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _labelController = TextEditingController();
  String _selectedRole = 'edit'; // 'edit' or 'view'
  bool _isSubmitting = false;
  bool _showManualKeyInput = false;

  @override
  void dispose() {
    _keyController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  String _shortKey(String key) {
    if (key.length <= 20) return key;
    return '${key.substring(0, 10)}...${key.substring(key.length - 8)}';
  }

  Future<void> _grantAccess(String rawPayload) async {
    final activeBudgetId = ref.read(activeBudgetIdProvider);
    final pbService = ref.read(pbServiceProvider);

    setState(() {
      _isSubmitting = true;
    });

    try {
      await pbService.addCollaboratorToBudget(
        localBudgetId: activeBudgetId,
        qrOrPubKeyInput: rawPayload,
        role: _selectedRole,
        label: _labelController.text.trim(),
      );

      if (!mounted) return;
      _keyController.clear();
      _labelController.clear();
      setState(() {
        _showManualKeyInput = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Collaborator added (${_selectedRole == 'edit' ? 'Full Edit' : 'View-Only'})!',
          ),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _openQrScanner() async {
    final scannedRaw = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => const _QrScannerScreen(),
      ),
    );
    if (scannedRaw != null && scannedRaw.trim().isNotEmpty && mounted) {
      await _grantAccess(scannedRaw.trim());
    }
  }

  Future<void> _changeRole(BudgetCollaborator entry, String newRole) async {
    final activeBudgetId = ref.read(activeBudgetIdProvider);
    final pbService = ref.read(pbServiceProvider);
    setState(() {
      _isSubmitting = true;
    });
    try {
      await pbService.updateCollaboratorRole(
        localBudgetId: activeBudgetId,
        collaboratorPubAddress: entry.pubAddress,
        newRole: newRole,
      );
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Updated permission to ${newRole == 'edit' ? 'Full Edit' : 'View-Only'}',
          ),
          backgroundColor: const Color(0xFF06B6D4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _removeCollaborator(BudgetCollaborator entry) async {
    final activeBudgetId = ref.read(activeBudgetIdProvider);
    final pbService = ref.read(pbServiceProvider);
    setState(() {
      _isSubmitting = true;
    });
    try {
      await pbService.removeCollaboratorFromBudget(
        localBudgetId: activeBudgetId,
        collaboratorPubAddress: entry.pubAddress,
      );
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Collaborator removed.'),
          backgroundColor: Colors.teal,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to remove collaborator: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final pbService = ref.watch(pbServiceProvider);
    final budgets = ref.watch(budgetsListProvider);
    final activeBudgetId = ref.watch(activeBudgetIdProvider);
    final activeBudget = budgets.firstWhere(
      (b) => b.id == activeBudgetId,
      orElse: () => Budget(id: 'budget_1', name: 'My Budget'),
    );

    final qrPayload = pbService.currentUserQrPayload;
    final pubKey = pbService.currentUserId ?? '';
    final desc = pbService.getBudgetDescriptor(activeBudgetId);
    final isOwner = desc == null || desc.isOwner;
    final role = desc?.role ?? 'owner';
    final collaborators = pbService.getCollaboratorsForBudget(activeBudgetId);

    return Container(
      decoration: BoxDecoration(
        color: colors.modalBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              20,
              14,
              20,
              MediaQuery.of(context).viewInsets.bottom + 28,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: colors.isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF06B6D4).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.qr_code_2_rounded,
                        color: Color(0xFF06B6D4),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Public Key & Budget Sharing',
                            style: GoogleFonts.outfit(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                          ),
                          Text(
                            'Share "${activeBudget.name}" securely via StiQRcloud',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // --- MY PUBLIC KEY QR CARD ---
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: colors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: colors.border),
                  ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.verified_user_outlined, color: Color(0xFF10B981), size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'YOUR PUBLIC KEY QR CODE',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF10B981),
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Have a friend scan this QR code to invite you to their budget. Your email & password are never shared.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (qrPayload.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: QrImageView(
                          data: qrPayload,
                          version: QrVersions.auto,
                          size: 170,
                          backgroundColor: Colors.white,
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          'Not logged in',
                          style: TextStyle(color: colors.textMuted),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: colors.cardBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.vpn_key_outlined, color: Color(0xFF06B6D4), size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _shortKey(pubKey),
                              style: GoogleFonts.robotoMono(
                                fontSize: 11,
                                color: colors.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: qrPayload.isEmpty
                                ? null
                                : () {
                                    Clipboard.setData(ClipboardData(text: qrPayload));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Invite key copied to clipboard!'),
                                        backgroundColor: Color(0xFF06B6D4),
                                      ),
                                    );
                                  },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.copy_rounded, color: Color(0xFF06B6D4), size: 15),
                                const SizedBox(width: 4),
                                Text(
                                  'Copy Key',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF06B6D4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // --- ACTIVE BUDGET COLLABORATORS ---
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'BUDGET ACCESS: ${activeBudget.name.toUpperCase()}',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: colors.textMuted,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isOwner
                          ? const Color(0xFF6366F1).withValues(alpha: 0.2)
                          : (role == 'edit'
                              ? const Color(0xFF10B981).withValues(alpha: 0.2)
                              : const Color(0xFFF59E0B).withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isOwner
                          ? 'OWNER'
                          : (role == 'edit' ? 'SHARED • FULL EDIT' : 'SHARED • VIEW-ONLY'),
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isOwner
                            ? const Color(0xFF818CF8)
                            : (role == 'edit' ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (!isOwner) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            role == 'edit' ? Icons.edit_note_rounded : Icons.visibility_outlined,
                            color: role == 'edit' ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              role == 'edit'
                                  ? 'You have Full Edit access to this shared budget.'
                                  : 'You have View-Only access to this shared budget.',
                              style: GoogleFonts.outfit(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Owner Key: ${_shortKey(desc.ownerPubAddress)}',
                        style: GoogleFonts.robotoMono(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Owner controls: Add Collaborator
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Add Collaborator to "${activeBudget.name}"',
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Only this budget is shared. Your other budgets remain completely private.',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Nickname / Label field
                      TextField(
                        controller: _labelController,
                        style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Collaborator Nickname (Optional)',
                          hintText: 'e.g. Partner, Spouse, Roommate',
                          labelStyle: GoogleFonts.inter(color: colors.textSecondary, fontSize: 12),
                          hintStyle: GoogleFonts.inter(color: colors.textMuted, fontSize: 12),
                          prefixIcon: Icon(Icons.badge_outlined, color: colors.iconMuted, size: 18),
                          isDense: true,
                          filled: true,
                          fillColor: colors.inputFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Role Selector: Full Edit vs View-Only
                      Text(
                        'Permission Level',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedRole = 'edit'),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: _selectedRole == 'edit'
                                      ? const Color(0xFF6366F1).withValues(alpha: 0.15)
                                      : colors.cardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _selectedRole == 'edit'
                                        ? const Color(0xFF6366F1)
                                        : colors.border,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.edit_outlined,
                                          size: 15,
                                          color: _selectedRole == 'edit'
                                              ? (colors.isDark ? const Color(0xFF818CF8) : const Color(0xFF4F46E5))
                                              : colors.textSecondary,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Full Edit',
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: _selectedRole == 'edit'
                                                ? (colors.isDark ? Colors.white : const Color(0xFF4338CA))
                                                : colors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Can log & allocate',
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedRole = 'view'),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: _selectedRole == 'view'
                                      ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                                      : colors.cardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _selectedRole == 'view'
                                        ? const Color(0xFFF59E0B)
                                        : colors.border,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.visibility_outlined,
                                          size: 15,
                                          color: _selectedRole == 'view'
                                              ? const Color(0xFFF59E0B)
                                              : colors.textSecondary,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'View-Only',
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: _selectedRole == 'view'
                                                ? (colors.isDark ? Colors.white : const Color(0xFFB45309))
                                                : colors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Read-only access',
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Scan QR Button + Paste Key Toggle
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isSubmitting ? null : _openQrScanner,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF06B6D4),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                              label: Text(
                                'Scan QR Code',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: _isSubmitting
                                ? null
                                : () {
                                    setState(() {
                                      _showManualKeyInput = !_showManualKeyInput;
                                    });
                                  },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colors.textPrimary,
                              side: BorderSide(color: colors.border),
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.paste_rounded, size: 16),
                            label: Text(
                              'Paste Key',
                              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),

                      if (_showManualKeyInput) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _keyController,
                          style: GoogleFonts.robotoMono(color: colors.textPrimary, fontSize: 11),
                          decoration: InputDecoration(
                            hintText: 'Paste stiqrbudget:user:... or public key',
                            hintStyle: GoogleFonts.inter(color: colors.textMuted, fontSize: 11),
                            isDense: true,
                            filled: true,
                            fillColor: colors.inputFill,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: colors.border),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: colors.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                            ),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF06B6D4), size: 18),
                              onPressed: () async {
                                final data = await Clipboard.getData(Clipboard.kTextPlain);
                                if (data?.text != null) {
                                  _keyController.text = data!.text!.trim();
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: _isSubmitting
                              ? null
                              : () {
                                  if (_keyController.text.trim().isNotEmpty) {
                                    _grantAccess(_keyController.text.trim());
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isSubmitting
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : Text(
                                  'Grant Budget Access',
                                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Existing Collaborators List
                if (collaborators.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.surfaceSecondary,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline_rounded, color: colors.iconMuted, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'No collaborators on "${activeBudget.name}" yet. Only you can decrypt this budget.',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'CURRENT COLLABORATORS (${collaborators.length})',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colors.textMuted,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...collaborators.map((c) {
                        final isEdit = c.role == 'edit';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: colors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: colors.border),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: isEdit
                                    ? const Color(0xFF6366F1).withValues(alpha: 0.2)
                                    : const Color(0xFFF59E0B).withValues(alpha: 0.2),
                                child: Icon(
                                  isEdit ? Icons.edit_outlined : Icons.visibility_outlined,
                                  size: 16,
                                  color: isEdit ? const Color(0xFF818CF8) : const Color(0xFFF59E0B),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      c.label.isNotEmpty ? c.label : c.shortPubKey,
                                      style: GoogleFonts.outfit(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      c.shortPubKey,
                                      style: GoogleFonts.robotoMono(
                                        fontSize: 10,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              DropdownButton<String>(
                                value: c.role == 'edit' ? 'edit' : 'view',
                                dropdownColor: colors.cardBg,
                                underline: const SizedBox.shrink(),
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'edit',
                                    child: Text('Full Edit'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'view',
                                    child: Text('View-Only'),
                                  ),
                                ],
                                onChanged: _isSubmitting
                                    ? null
                                    : (val) {
                                        if (val != null && val != c.role) {
                                          _changeRole(c, val);
                                        }
                                      },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.person_remove_outlined,
                                  color: Colors.redAccent,
                                  size: 18,
                                ),
                                tooltip: 'Remove collaborator',
                                onPressed: _isSubmitting ? null : () => _removeCollaborator(c),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
  }
}

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  bool _hasScanned = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: colors.scaffoldBg,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        title: Text(
          'Scan Collaborator QR Code',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: colors.textPrimary),
        ),
      ),
      body: Stack(
        children: [
          ReaderWidget(
            codeFormat: Format.qrCode,
            showFlashlight: true,
            showToggleCamera: true,
            showGallery: false,
            onScan: (Code result) {
              if (_hasScanned) return;
              final raw = result.text?.trim();
              if (result.isValid && raw != null && raw.isNotEmpty) {
                _hasScanned = true;
                Navigator.pop(context, raw);
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF06B6D4), width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.cardBg.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.border),
              ),
              child: Text(
                'Point your camera at another user\'s StiQRbudget QR code in their Settings -> Public Key QR & Budget Collaborators.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: colors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

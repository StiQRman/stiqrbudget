import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../providers/auth_provider.dart';
import '../providers/budgets_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/releases_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/csv_export_service.dart';
import '../utils/app_theme.dart';
import '../utils/responsive_layout.dart';
import 'apk_downloads_view.dart';
import 'collaborators_modal.dart';
import 'privacy_policy_view.dart';
import 'spending_report_view.dart';
import 'transaction_ledger_view.dart';

typedef SettingsPage = SettingsView;

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  Future<void> _exportCsvData(BuildContext context, WidgetRef ref) async {
    final categories = ref.read(categoriesProvider);
    final transactions = ref.read(transactionsProvider);
    final budgets = ref.read(budgetsListProvider);
    final activeBudgetId = ref.read(activeBudgetIdProvider);
    final activeBudget = budgets.firstWhere(
      (b) => b.id == activeBudgetId,
      orElse: () => Budget(id: 'budget_1', name: 'My Budget'),
    );

    final csvContent = CsvExportService.generateBudgetCsv(
      budgetName: activeBudget.name,
      categories: categories,
      transactions: transactions,
    );

    final sanitizedName = activeBudget.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .toLowerCase();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final fileName = 'stiqrbudget_${sanitizedName}_$timestamp.csv';

    String? savedPath;
    File? exportFile;

    // Try saving to Downloads directory on Android if accessible
    try {
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        final f = File('${downloadDir.path}/$fileName');
        await f.writeAsString(csvContent);
        savedPath = f.path;
        exportFile = f;
      }
    } catch (_) {}

    // Always also write to temporary directory for reliable Share sheet access
    try {
      final tempDir = await getTemporaryDirectory();
      final f = File('${tempDir.path}/$fileName');
      await f.writeAsString(csvContent);
      exportFile = f;
      savedPath ??= f.path;
    } catch (_) {
      final f = File('${Directory.systemTemp.path}/$fileName');
      await f.writeAsString(csvContent);
      exportFile = f;
      savedPath ??= f.path;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('CSV exported: $savedPath'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }

    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(exportFile.path, mimeType: 'text/csv')],
          subject: 'StiQRbudget Export - ${activeBudget.name}',
          text: 'StiQRbudget CSV export for ${activeBudget.name}',
        ),
      );
    } catch (_) {}
  }

  void _showAddBudgetDialog(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colors.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Create New Budget',
            style: GoogleFonts.outfit(color: colors.textPrimary, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: controller,
            style: GoogleFonts.inter(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Enter budget name (e.g. Savings)',
              hintStyle: TextStyle(color: colors.textMuted),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel', style: GoogleFonts.inter(color: colors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  final newBudget = await ref.read(budgetsListProvider.notifier).addBudget(name);
                  await ref.read(activeBudgetIdProvider.notifier).setActiveBudget(newBudget.id);
                  if (context.mounted) {
                    Navigator.pop(dialogContext);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Switched to new budget: $name'),
                        backgroundColor: Colors.teal,
                      ),
                    );
                  }
                }
              },
              child: Text('Create', style: GoogleFonts.inter(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showUndoConfirmDialog(BuildContext context, WidgetRef ref, String actionDescription) {
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) {
        bool isUndoing = false;
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              backgroundColor: colors.cardBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
                  const SizedBox(width: 8),
                  Text(
                    'Undo Action?',
                    style: GoogleFonts.outfit(color: colors.textPrimary, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Text(
                'Are you sure you want to undo the last action: "$actionDescription"?\n\nThis will delete any created transactions and revert envelope balances to their previous state.',
                style: GoogleFonts.inter(color: colors.textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: isUndoing ? null : () => Navigator.pop(dialogContext),
                  child: Text('Cancel', style: GoogleFonts.inter(color: colors.textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: isUndoing ? null : () async {
                    setState(() {
                      isUndoing = true;
                    });
                    try {
                      final success = await ref.read(transactionsProvider.notifier).undoLastAction();
                      if (context.mounted) {
                        Navigator.pop(dialogContext); // Close dialog
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(success
                                ? 'Action successfully undone!'
                                : 'Failed to undo action.'),
                            backgroundColor: success ? Colors.teal : Colors.redAccent,
                          ),
                        );
                      }
                    } catch (e) {
                      print("Error during undo: $e");
                    } finally {
                      if (dialogContext.mounted) {
                        setState(() {
                          isUndoing = false;
                        });
                      }
                    }
                  },
                  child: isUndoing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text('Yes, Undo', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsState = ref.watch(settingsProvider);
    final isDark = settingsState.themeMode == ThemeMode.dark ||
        (settingsState.themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final effectiveTheme = isDark ? AppTheme.darkTheme : AppTheme.lightTheme;

    return Theme(
      data: effectiveTheme,
      child: Builder(
        builder: (pageContext) {
          final settingsNotifier = ref.read(settingsProvider.notifier);
          final latestRelease = ref.watch(latestReleaseProvider);
          final hasUpdate = ref.watch(hasUpdateProvider);
          final currentVersionAsync = ref.watch(currentAppVersionProvider);
          final currentVersion = currentVersionAsync.value ?? AppConfig.appVersion;
          final colors = AppColors.of(pageContext);

          // Watch transactionsProvider to trigger rebuild when lastUndoAction changes
          ref.watch(transactionsProvider);
          final lastAction = ref.read(transactionsProvider.notifier).lastUndoAction;

          return Scaffold(
            backgroundColor: colors.scaffoldBg,
            appBar: AppBar(
              backgroundColor: colors.scaffoldBg,
              elevation: 0,
              leading: IconButton(
                icon: Icon(Icons.arrow_back, color: colors.iconPrimary),
                tooltip: 'Back',
                onPressed: () => Navigator.pop(pageContext),
              ),
              title: Text(
                'Settings',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  color: colors.textPrimary,
                ),
              ),
            ),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.symmetric(
                      horizontal: isNarrow ? 12 : 20,
                      vertical: 16,
                    ),
                    child: ResponsiveCenter(
                      maxWidth: 720,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                    Text(
                      'Customize your StiqrBudget experience.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Appearance / Theme Mode Card
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  settingsState.themeMode == ThemeMode.light
                                      ? Icons.light_mode_outlined
                                      : (settingsState.themeMode == ThemeMode.dark
                                          ? Icons.dark_mode_outlined
                                          : Icons.brightness_auto_outlined),
                                  color: const Color(0xFF6366F1),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Appearance',
                                      style: GoogleFonts.outfit(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      'Choose app display theme',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<ThemeMode>(
                              showSelectedIcon: !isNarrow,
                              segments: [
                                ButtonSegment(
                                  value: ThemeMode.system,
                                  label: const Text('System', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  icon: isNarrow ? null : const Icon(Icons.brightness_auto, size: 16),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.dark,
                                  label: const Text('Dark', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  icon: isNarrow ? null : const Icon(Icons.dark_mode, size: 16),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.light,
                                  label: const Text('Light', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  icon: isNarrow ? null : const Icon(Icons.light_mode, size: 16),
                                ),
                              ],
                              selected: {settingsState.themeMode},
                              onSelectionChanged: (Set<ThemeMode> newSelection) {
                                ref.read(settingsProvider.notifier).setThemeMode(newSelection.first);
                              },
                              style: SegmentedButton.styleFrom(
                                textStyle: GoogleFonts.inter(
                                  fontSize: isNarrow ? 11 : 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Spending Report Tile
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.analytics_outlined, color: Color(0xFF6366F1), size: 20),
                          ),
                          title: Text(
                            'Spending Report',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'Analyze envelope spending, paycheck allocations & transfers.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted, size: 20),
                          onTap: () {
                            Navigator.push(
                              pageContext,
                              MaterialPageRoute(builder: (_) => const SpendingReportView()),
                            );
                          },
                        ),
                      ),
                    ),

                    // Transaction History Tile
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF06B6D4).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.history_outlined, color: Color(0xFF06B6D4), size: 20),
                          ),
                          title: Text(
                            'Transaction History',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'View and search all past expenses, income, and transfers.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted, size: 20),
                          onTap: () {
                            Navigator.push(
                              pageContext,
                              MaterialPageRoute(builder: (_) => const TransactionLedgerView()),
                            );
                          },
                        ),
                      ),
                    ),

                    // Export Data to CSV (Free) Tile
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.file_download_outlined, color: Color(0xFF10B981), size: 20),
                          ),
                          title: Text(
                            'Export Data to CSV (Free)',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'Export all envelopes and transaction history to a spreadsheet',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted, size: 20),
                          onTap: () => _exportCsvData(pageContext, ref),
                        ),
                      ),
                    ),

                    // Biometrics Switch Card
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: SwitchListTile(
                          value: settingsState.useBiometrics,
                          onChanged: settingsState.isBiometricsSupported
                              ? (val) async {
                                  final success = await settingsNotifier.toggleBiometrics(val);
                                  if (!success && pageContext.mounted) {
                                    ScaffoldMessenger.of(pageContext).showSnackBar(
                                      const SnackBar(
                                        content: Text('Failed to update biometric settings.'),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                }
                              : null,
                          title: Text(
                            'Fingerprint Log In',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            settingsState.isBiometricsSupported
                                ? 'Require fingerprint to unlock the app on launch.'
                                : 'Biometrics are not supported on this device.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          activeColor: const Color(0xFF06B6D4),
                          inactiveTrackColor: colors.cardBg,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Budgets Section Title
                    Text(
                      'BUDGETS & COLLABORATION',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: colors.textMuted,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Public Key QR & Collaborators Button
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.qr_code_2_rounded, color: Color(0xFF10B981), size: 20),
                          ),
                          title: Text(
                            'Public Key QR & Budget Collaborators',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'Show your QR code or scan a user\'s QR to share the active budget.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted),
                          onTap: () {
                            showModalBottomSheet(
                              context: pageContext,
                              isScrollControlled: true,
                              backgroundColor: colors.modalBg,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                              ),
                              builder: (context) => const CollaboratorsModal(),
                            );
                          },
                        ),
                      ),
                    ),

                    // Manage Budgets Button
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF8B5CF6), size: 20),
                          ),
                          title: Text(
                            'Manage Budgets',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'Switch, rename, or delete budgets on this account.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted),
                          onTap: () => _showManageBudgetsModal(pageContext, ref),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Undo Last Action Button
                    Text(
                      'TRANSACTION ACTIONS',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: colors.textMuted,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),

                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: lastAction != null ? const Color(0xFFEF4444).withOpacity(0.5) : colors.border,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: lastAction != null
                                  ? const Color(0xFFEF4444).withOpacity(0.12)
                                  : const Color(0xFF475569).withOpacity(0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.undo,
                              color: lastAction != null ? const Color(0xFFEF4444) : colors.textSecondary,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            'Undo Last Action',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: lastAction != null ? colors.textPrimary : colors.textSecondary,
                            ),
                          ),
                          subtitle: Text(
                            lastAction != null
                                ? 'Revert: "${lastAction.description}"'
                                : 'No action to undo.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: lastAction != null
                              ? Icon(Icons.chevron_right, color: colors.iconMuted)
                              : null,
                          onTap: lastAction != null
                              ? () => _showUndoConfirmDialog(pageContext, ref, lastAction.description)
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // App Releases & APK Downloads (Hidden in Play Store build)
                    if (!AppConfig.isPlayStore) ...[
                      Text(
                        'APP UPDATES & RELEASES',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colors.textMuted,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),

                      Container(
                        decoration: BoxDecoration(
                          color: colors.surfaceSecondary,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: hasUpdate ? const Color(0xFFEF4444).withValues(alpha: 0.6) : colors.border,
                          ),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.asset(
                                  'assets/icons/app_icon.png',
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            title: Text(
                              'Download APK & Versions',
                              style: GoogleFonts.outfit(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              latestRelease != null
                                  ? 'Latest: ${latestRelease.version} • All versions available'
                                  : 'Download Android app and view release history',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: colors.textSecondary,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hasUpdate)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEF4444),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'NEW',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                Icon(Icons.chevron_right, color: colors.iconMuted),
                              ],
                            ),
                            onTap: () {
                              Navigator.push(
                                pageContext,
                                MaterialPageRoute(builder: (context) => const ApkDownloadsView()),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // Privacy Policy Tile
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF06B6D4).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.privacy_tip_outlined,
                              color: Color(0xFF06B6D4),
                              size: 20,
                            ),
                          ),
                          title: Text(
                            'Privacy Policy',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            'Zero-Knowledge E2EE & Post-Quantum privacy details.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: colors.iconMuted, size: 20),
                          onTap: () => _openPrivacyPolicy(pageContext),
                        ),
                      ),
                    ),

                    // StiQRcloud connection info
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.lock_outline_rounded, color: Color(0xFF6366F1), size: 20),
                      ),
                      title: Text(
                        'StiQRcloud E2EE Sync',
                        style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        'stiqrcloud.stiqrnotes.com • Zero-Knowledge Encrypted',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Log Out Tile
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.logout_outlined, color: Colors.redAccent, size: 20),
                          ),
                          title: Text(
                            'Log Out',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.redAccent,
                            ),
                          ),
                          subtitle: Text(
                            'Sign out of your account on this device.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right, color: Colors.redAccent, size: 20),
                          onTap: () {
                            ref.read(authProvider.notifier).logout();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Delete Account Tile (consistent across Android, iOS, and Web)
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.55),
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.delete_forever_outlined,
                              color: Color(0xFFEF4444),
                              size: 20,
                            ),
                          ),
                          title: Text(
                            'Delete Account',
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFEF4444),
                            ),
                          ),
                          subtitle: Text(
                            'Permanently erase your account, budgets, and synced data.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: Color(0xFFEF4444),
                            size: 20,
                          ),
                          onTap: () => _showDeleteAccountDialog(pageContext, ref),
                        ),
                      ),
                    ),
                    Divider(color: colors.divider, height: 32),

                    // Footer
                    Center(
                      child: Text(
                        'StiqrBudget v$currentVersion',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  void _handleAddBudgetTap(BuildContext context, WidgetRef ref) {
    // Phase 1 Google Play launch is 100% free with no paywall gates.
    if (AppConfig.isPlayStore) {
      _showAddBudgetDialog(context, ref);
      return;
    }
    final subState = ref.read(subscriptionProvider);
    final canAdd = ref.read(budgetsListProvider.notifier).canAddBudget(subState.isMultiBudgetUnlocked);
    if (!canAdd) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.of(context).modalBg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetCtx) => MultiBudgetPaywallModal(
          onUnlocked: () {
            Navigator.pop(sheetCtx);
            _showAddBudgetDialog(context, ref);
          },
        ),
      );
      return;
    }
    _showAddBudgetDialog(context, ref);
  }

  void _showManageBudgetsModal(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.modalBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => Consumer(
        builder: (ctx, modalRef, _) {
          final budgets = modalRef.watch(budgetsListProvider);
          final activeId = modalRef.watch(activeBudgetIdProvider);
          final canDelete = budgets.length > 1;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Manage Budgets',
                        style: GoogleFonts.outfit(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _handleAddBudgetTap(context, ref);
                        },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: budgets.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) {
                        final b = budgets[index];
                        final isActive = b.id == activeId;
                        return Container(
                          decoration: BoxDecoration(
                            color: colors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isActive ? const Color(0xFF10B981) : colors.border,
                              width: isActive ? 1.5 : 1,
                            ),
                          ),
                          child: ListTile(
                            onTap: () async {
                              await modalRef.read(activeBudgetIdProvider.notifier).setActiveBudget(b.id);
                              if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                            },
                            leading: Icon(
                              isActive ? Icons.check_circle_rounded : Icons.account_balance_wallet_outlined,
                              color: isActive ? const Color(0xFF10B981) : colors.iconMuted,
                            ),
                            title: Text(
                              b.name,
                              style: GoogleFonts.outfit(
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                            subtitle: isActive
                                ? Text(
                                    'Active Budget',
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: const Color(0xFF10B981),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit_outlined, size: 20, color: colors.textSecondary),
                                  tooltip: 'Rename',
                                  onPressed: () => _showRenameBudgetDialog(ctx, modalRef, b.id, b.name),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                    color: canDelete ? const Color(0xFFEF4444) : colors.textMuted,
                                  ),
                                  tooltip: canDelete ? 'Delete' : 'At least 1 budget required',
                                  onPressed: canDelete
                                      ? () => _confirmDeleteBudgetDialog(ctx, modalRef, b.id, b.name)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showRenameBudgetDialog(BuildContext context, WidgetRef ref, String id, String currentName) {
    final controller = TextEditingController(text: currentName);
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: colors.modalBg,
        title: Text('Rename Budget', style: GoogleFonts.outfit(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: colors.textPrimary),
          decoration: const InputDecoration(hintText: 'Budget name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final next = controller.text.trim();
              if (next.isNotEmpty) {
                await ref.read(budgetsListProvider.notifier).renameBudget(id, next);
              }
              if (dlgCtx.mounted) Navigator.pop(dlgCtx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPrivacyPolicy(BuildContext context) async {
    if (kIsWeb) {
      await launchUrl(
        Uri.parse('https://stiqrbudget.com/privacy'),
        webOnlyWindowName: '_blank',
      );
      return;
    }
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PrivacyPolicyView()),
    );
  }

  void _showDeleteAccountDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeleteAccountDialog(parentContext: context),
    );
  }

  void _confirmDeleteBudgetDialog(BuildContext context, WidgetRef ref, String id, String name) {
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: colors.modalBg,
        title: Text('Delete "$name"?', style: GoogleFonts.outfit(color: colors.textPrimary)),
        content: Text(
          'This will permanently remove this budget, its categories, and its transactions.',
          style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () {
              Navigator.of(dlgCtx).pop();
              ref.read(budgetsListProvider.notifier).deleteBudget(id);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class MultiBudgetPaywallModal extends ConsumerWidget {
  final VoidCallback onUnlocked;

  const MultiBudgetPaywallModal({super.key, required this.onUnlocked});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Unlock Multiple Budgets',
              style: GoogleFonts.outfit(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Free accounts include 1 budget. Upgrade to manage unlimited budgets across personal, family, or business accounts.',
              style: GoogleFonts.inter(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 18),
            _buildPlanCard(
              colors: colors,
              title: 'Multi-Budget Add-On',
              price: '\$1/mo or \$10/yr',
              subtitle: 'Unlimited budgets on this account',
              accent: const Color(0xFF06B6D4),
            ),
            const SizedBox(height: 10),
            _buildPlanCard(
              colors: colors,
              title: 'All-Access Bundle',
              price: '\$2.49/mo or \$19.99/yr',
              subtitle: 'Multi-Budget + all upcoming Pro features',
              accent: const Color(0xFF8B5CF6),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                await ref.read(subscriptionProvider.notifier).upgradeTo(SubscriptionTier.allAccessBundle);
                onUnlocked();
              },
              child: Text(
                'Simulate Upgrade (Testing Mode)',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlanCard({
    required AppColors colors,
    required String title,
    required String price,
    required String subtitle,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.workspace_premium_rounded, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(fontSize: 11, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          Text(
            price,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteAccountDialog extends ConsumerStatefulWidget {
  final BuildContext parentContext;

  const _DeleteAccountDialog({required this.parentContext});

  @override
  ConsumerState<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final TextEditingController _confirmController = TextEditingController();
  bool _isDeleting = false;

  bool get _isConfirmed => _confirmController.text.trim() == 'DELETE';

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleDelete() async {
    if (!_isConfirmed || _isDeleting) return;
    setState(() => _isDeleting = true);

    final messenger = ScaffoldMessenger.maybeOf(widget.parentContext);
    final navigator = Navigator.of(widget.parentContext);

    try {
      await ref.read(authProvider.notifier).deleteAccount();
      navigator.popUntil((route) => route.isFirst);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Your account and all data have been permanently deleted.'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Failed to delete account: $e'),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return AlertDialog(
      backgroundColor: colors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Delete Account?',
              style: GoogleFonts.outfit(
                color: colors.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This action is permanent and cannot be undone. Deleting your account will permanently erase all local and cloud-synced budgets, envelopes, and transactions.',
            style: GoogleFonts.inter(
              color: colors.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Type DELETE to confirm:',
            style: GoogleFonts.inter(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            enabled: !_isDeleting,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: GoogleFonts.inter(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'DELETE',
              hintStyle: TextStyle(color: colors.textMuted),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isDeleting ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(color: colors.textSecondary),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFEF4444),
            disabledBackgroundColor: const Color(0xFFEF4444).withValues(alpha: 0.3),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: (_isConfirmed && !_isDeleting) ? _handleDelete : null,
          child: _isDeleting
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text(
                  'Delete Account',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ],
    );
  }
}

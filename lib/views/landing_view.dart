import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_theme.dart';
import '../utils/responsive_layout.dart';
import 'auth_view.dart';

class LandingView extends StatelessWidget {
  const LandingView({super.key});

  // TODO: Replace with your live Bitcoin / Lightning address or donation URL.
  static const String _supportPlaceholderAddress =
      'bc1q-your-btc-address-here';

  void _openAuth(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthView()),
    );
  }

  void _showSupportDialog(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: colors.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colors.border),
          ),
          title: Row(
            children: [
              Icon(Icons.favorite_rounded, color: accent, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Support StiQRbudget',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'StiQRbudget is 100% free, zero-knowledge, and ad-free. We never sell your data, run ads, or lock basic features behind paywalls.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Bitcoin / Lightning Support',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _supportPlaceholderAddress,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Copy address',
                        icon: Icon(Icons.copy_rounded, size: 18, color: accent),
                        onPressed: () {
                          Clipboard.setData(
                            const ClipboardData(
                              text: _supportPlaceholderAddress,
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Support address copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Questions or feedback? Reach us at stiqrapps@gmail.com',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                'Close',
                style: TextStyle(color: accent, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showPrivacyPolicy(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.78,
          minChildSize: 0.5,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, color: accent, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Privacy Policy',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: colors.textSecondary),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(color: colors.border, height: 1),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(24),
                    children: [
                      _policySection(
                        colors,
                        'Zero-Knowledge Architecture',
                        'Your financial data belongs exclusively to you. All budgets, envelopes, transaction descriptions, amounts, and balances are encrypted directly on your device before they ever touch the network. We cannot read your financial records, and we cannot sell your data.',
                      ),
                      _policySection(
                        colors,
                        'Post-Quantum Hybrid Cryptography',
                        'Protected by Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519 + AES-256-GCM), PBKDF2-SHA256 local key derivation, and Ed25519 digital signatures for private collaboration. Your decryption keys never leave your device unencrypted.',
                      ),
                      _policySection(
                        colors,
                        'No Tracking, No Ads, No Bank Scrapers',
                        'We never ask for your bank login, account numbers, or routing numbers. We do not embed ad SDKs, tracking pixels, or third-party analytics.',
                      ),
                      _policySection(
                        colors,
                        'Encrypted Cloud Sync',
                        'When multi-device sync is active, StiQRcloud stores only encrypted ciphertexts (tc:enc:v1:...) that are unreadable without your local keys.',
                      ),
                      _policySection(
                        colors,
                        'Data Sovereignty & Free CSV Export',
                        'Export your unencrypted budgets, envelopes, and transaction history to CSV at any time at zero cost, or delete your account and encrypted blobs whenever you choose.',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Contact: stiqrapps@gmail.com • https://stiqrbudget.com',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _policySection(AppColors colors, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    final features = [
      (
        Icons.lock_outline_rounded,
        'Post-Quantum Hybrid Encrypted',
        'Zero-Knowledge ML-KEM-768 + X25519 + AES-256-GCM: nobody—not Google, your bank, or us—can see your spending.',
      ),
      (
        Icons.tune_rounded,
        'Smart Envelope Rules',
        'Automate allocations with % of Check, \$ Per Check, and Monthly Target rules.',
      ),
      (
        Icons.qr_code_2_rounded,
        'Private QR Collaboration',
        'Share specific budgets with family or partners without sharing bank logins.',
      ),
      (
        Icons.download_done_rounded,
        'Free CSV Export & Offline-First',
        'Your data works offline anytime and exports cleanly to CSV at zero cost.',
      ),
    ];

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
            final isWide = ResponsiveBreakpoints.isWide(constraints.maxWidth);

            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isNarrow ? 16 : 24,
                  vertical: isNarrow ? 20 : 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: EdgeInsets.all(isNarrow ? 14 : 16),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Icon(
                          Icons.account_balance_wallet_rounded,
                          size: isNarrow ? 38 : 44,
                          color: accent,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'StiQRbudget',
                          style: theme.textTheme.headlineLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Zero-Knowledge Envelope Budgeting. Your Money, Your Keys.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: isWide ? 280 : double.infinity,
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: () => _openAuth(context),
                          icon: const Icon(Icons.login_rounded),
                          label: const Text(
                            'Sign In / Get Started',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: features.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: isWide ? 2 : 1,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                          mainAxisExtent: isNarrow ? 176 : (isWide ? 154 : 148),
                        ),
                        itemBuilder: (context, index) {
                          final (icon, title, desc) = features[index];
                          return Container(
                            padding: EdgeInsets.all(isNarrow ? 14 : 18),
                            decoration: BoxDecoration(
                              color: colors.cardBg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: colors.border),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(icon, color: accent, size: 22),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        desc,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          height: 1.4,
                                          color: colors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 32),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: () => _showPrivacyPolicy(context),
                            icon: Icon(
                              Icons.privacy_tip_outlined,
                              size: 18,
                              color: colors.textSecondary,
                            ),
                            label: Text(
                              'Privacy Policy',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ),
                          if (kIsWeb)
                            TextButton.icon(
                              onPressed: () => _showSupportDialog(context),
                              icon: Icon(
                                Icons.favorite_outline_rounded,
                                size: 18,
                                color: accent,
                              ),
                              label: Text(
                                'Support StiQRbudget',
                                style: TextStyle(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

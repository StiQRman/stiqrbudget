import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/app_theme.dart';
import '../utils/responsive_layout.dart';

class PrivacyPolicyView extends StatelessWidget {
  const PrivacyPolicyView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: colors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: colors.scaffoldBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.iconPrimary),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Privacy Policy',
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
                horizontal: isNarrow ? 16 : 24,
                vertical: 16,
              ),
              child: ResponsiveCenter(
                maxWidth: 720,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: colors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.shield_outlined, color: accent, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'StiQRbudget Privacy Policy',
                                  style: GoogleFonts.outfit(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Effective Date: November 19, 2026 • stiqrbudget.com',
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
                    ),
                    _buildSection(
                      colors,
                      '1. Zero-Knowledge Architecture',
                      'At StiQRbudget, your financial data belongs exclusively to you. We do not want, collect, track, or sell your personal or financial information. All budgets, envelopes, transaction descriptions, amounts, and category balances are encrypted directly on your device before they ever touch the network. We cannot read your financial records because we do not have the keys to decrypt them.',
                    ),
                    _buildSection(
                      colors,
                      '2. Post-Quantum Hybrid Cryptography',
                      'Your financial data is protected by Post-Quantum Hybrid Encryption (ML-KEM-768 + X25519 + AES-256-GCM) end-to-end client-side cryptography:\n'
                          '• AES-256-GCM (Authenticated Encryption) encrypts all transactions, envelopes, notes, and balances on your device.\n'
                          '• PBKDF2-SHA256 (60,000 rounds) & NIST FIPS 203 ML-KEM-768 derive your master keys locally and deterministically.\n'
                          '• Ed25519 Digital Signatures authenticate cloud requests without revealing plaintext payloads.\n'
                          '• Hybrid ML-KEM-768 + X25519 Key Exchange secures shared budget collaboration with automatic zero-action upgrades.\n'
                          '• Client-Isolated Keys: Your private decryption keys never leave your device unencrypted.',
                    ),
                    _buildSection(
                      colors,
                      '3. What We Never Collect',
                      '• No Bank Account Credentials: We never ask for your bank login, account numbers, or routing numbers, and we do not use third-party bank scrapers (e.g., Plaid, Yodlee, MX).\n'
                          '• No Financial Details: We cannot view your income, balances, spending habits, or transaction history.\n'
                          '• No Ad Tracking or Device Profiling: We do not embed ad SDKs, tracking pixels, or cross-app tracking beacons.',
                    ),
                    _buildSection(
                      colors,
                      '4. Minimal Encrypted Metadata',
                      '• Account Identifier: Your normalized, hashed email is used solely for account identification.\n'
                          '• Encrypted Blobs: When sync is active, StiQRcloud stores only encrypted ciphertexts (tc:enc:v1:...) that are unreadable without your local keys.\n'
                          '• Basic Crash Diagnostics: If enabled by your OS (e.g., Google Play crash reports), non-identifying technical diagnostics may be received to fix bugs.',
                    ),
                    _buildSection(
                      colors,
                      '5. Data Sovereignty & Free CSV Export',
                      'You have full ownership of your data at all times. Export your unencrypted budgets, envelopes, and transaction history to CSV at zero cost whenever you want, or permanently delete your account and encrypted cloud blobs directly from Settings.',
                    ),
                    _buildSection(
                      colors,
                      '6. Children\'s Privacy & Disclaimers',
                      'StiQRbudget is not directed to individuals under the age of 13. StiQRbudget is a personal budgeting tool and does not provide financial, legal, or tax advice. Because StiQRbudget is zero-knowledge, if you lose your account password, we cannot reset it or recover your encrypted data.',
                    ),
                    _buildSection(
                      colors,
                      '7. Contact Us',
                      'If you have questions, feedback, or concerns regarding your privacy or this policy, please contact us at:\n'
                          '• Email: stiqrapps@gmail.com\n'
                          '• Website: https://stiqrbudget.com',
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSection(AppColors colors, String title, String body) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.outfit(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: GoogleFonts.inter(
              fontSize: 13,
              height: 1.5,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

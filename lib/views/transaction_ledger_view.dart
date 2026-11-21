import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hexcolor/hexcolor.dart';
import 'package:intl/intl.dart';
import '../providers/transactions_provider.dart';
import '../providers/categories_provider.dart';
import '../models/transaction_model.dart';
import '../models/category.dart';
import '../utils/app_theme.dart';
import 'spending_report_view.dart';

class TransactionLedgerView extends ConsumerWidget {
  final String? filterCategoryId;

  const TransactionLedgerView({super.key, this.filterCategoryId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    var transactions = ref.watch(transactionsProvider);
    final categories = ref.watch(categoriesProvider);
    final currencyFormat = NumberFormat.simpleCurrency();
    final dateFormat = DateFormat('MMM d, y • h:mm a');

    // Filter transactions if filterCategoryId is provided
    if (filterCategoryId != null) {
      transactions = transactions.where((tx) {
        return tx.category == filterCategoryId ||
            tx.sourceCategory == filterCategoryId ||
            tx.destinationCategory == filterCategoryId;
      }).toList();
    }

    // Helper to find category name/color by ID
    String getCategoryName(String? id) {
      if (id == null) return 'Unknown';
      final cat = categories.where((c) => c.id == id);
      return cat.isNotEmpty ? cat.first.name : 'Category Deleted';
    }

    Color getCategoryColor(String? id) {
      if (id == null) return const Color(0xFF64748B);
      final cat = categories.where((c) => c.id == id);
      return cat.isNotEmpty ? HexColor(cat.first.colorHex) : const Color(0xFF64748B);
    }

    String ledgerTitle = 'Transactions';
    if (filterCategoryId != null) {
      final cat = categories.where((c) => c.id == filterCategoryId);
      if (cat.isNotEmpty) {
        ledgerTitle = '${cat.first.name} History';
      }
    }

    return Scaffold(
      backgroundColor: colors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: colors.scaffoldBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.iconPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          ledgerTitle,
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 22,
            color: colors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.analytics_outlined, color: colors.iconPrimary),
            tooltip: 'Spending Report',
            onPressed: () {
              Category? matchedCategory;
              if (filterCategoryId != null) {
                final match = categories.where((c) => c.id == filterCategoryId);
                if (match.isNotEmpty) {
                  matchedCategory = match.first;
                }
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SpendingReportView(initialCategory: matchedCategory),
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(transactionsProvider.notifier).loadTransactions();
          await ref.read(categoriesProvider.notifier).loadCategories();
        },
        color: colors.primary,
        backgroundColor: colors.cardBg,
        child: transactions.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.receipt_long, size: 64, color: colors.textMuted),
                      const SizedBox(height: 16),
                      Text(
                        'No transactions recorded.',
                        style: GoogleFonts.outfit(color: colors.textSecondary, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16.0),
                itemCount: transactions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final tx = transactions[index];
                  final isIncome = tx.type == TransactionType.income;
                  final isTransfer = tx.type == TransactionType.transfer;

                  // Define styling based on transaction type
                  Color amountColor;
                  String prefix;
                  IconData icon;
                  Color iconBg;
                  Color iconColor;
                  Widget detailWidget;

                  if (isIncome) {
                    amountColor = const Color(0xFF10B981); // Emerald
                    prefix = '+';
                    icon = Icons.south_west_outlined;
                    iconBg = const Color(0xFF10B981).withOpacity(0.12);
                    iconColor = const Color(0xFF10B981);
                    detailWidget = Text(
                      'Deposited into ${getCategoryName(tx.category)}',
                      style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 12),
                    );
                  } else if (isTransfer) {
                    amountColor = const Color(0xFF6366F1); // Indigo
                    prefix = '';
                    icon = Icons.swap_horiz_outlined;
                    iconBg = const Color(0xFF6366F1).withOpacity(0.12);
                    iconColor = const Color(0xFF6366F1);
                    detailWidget = Row(
                      children: [
                        Text(
                          getCategoryName(tx.sourceCategory),
                          style: GoogleFonts.inter(
                            color: getCategoryColor(tx.sourceCategory),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4.0),
                          child: Icon(Icons.arrow_right_alt, color: colors.textSecondary, size: 14),
                        ),
                        Text(
                          getCategoryName(tx.destinationCategory),
                          style: GoogleFonts.inter(
                            color: getCategoryColor(tx.destinationCategory),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    );
                  } else {
                    amountColor = const Color(0xFFEF4444); // Red
                    prefix = '-';
                    icon = Icons.north_east_outlined;
                    iconBg = const Color(0xFFEF4444).withOpacity(0.12);
                    iconColor = const Color(0xFFEF4444);
                    detailWidget = Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: getCategoryColor(tx.category),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          getCategoryName(tx.category),
                          style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 12),
                        ),
                      ],
                    );
                  }

                  return Container(
                    decoration: BoxDecoration(
                      color: colors.cardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colors.border,
                      ),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        // Icon Type
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: iconBg,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            color: iconColor,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 16),

                        // Details
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tx.description,
                                style: GoogleFonts.outfit(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              detailWidget,
                              const SizedBox(height: 6),
                              Text(
                                dateFormat.format(tx.date),
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  color: colors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Amount
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$prefix${currencyFormat.format(tx.amount.abs())}',
                              style: GoogleFonts.outfit(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: amountColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

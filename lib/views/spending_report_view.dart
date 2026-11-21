import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hexcolor/hexcolor.dart';
import 'package:intl/intl.dart';
import '../models/category.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../services/spending_report_engine.dart';
import '../utils/app_theme.dart';
import '../utils/icon_mapper.dart';
import '../utils/responsive_layout.dart';

enum DateRangePreset {
  thisMonth,
  last30Days,
  lastMonth,
  thisYear,
  custom,
}

class SpendingReportView extends ConsumerStatefulWidget {
  final Category? initialCategory;
  final String? initialDescription;

  const SpendingReportView({
    super.key,
    this.initialCategory,
    this.initialDescription,
  });

  @override
  ConsumerState<SpendingReportView> createState() => _SpendingReportViewState();
}

class _SpendingReportViewState extends ConsumerState<SpendingReportView>
    with SingleTickerProviderStateMixin {
  late DateTime _startDate;
  late DateTime _endDate;
  DateRangePreset _selectedPreset = DateRangePreset.thisMonth;

  Category? _selectedCategory;
  final TextEditingController _descriptionController = TextEditingController();

  late TabController _tabController;
  final currencyFormat = NumberFormat.simpleCurrency();
  final dateFormat = DateFormat('MMM d, y');
  final dateTimeFormat = DateFormat('MMM d, y • h:mm a');

  @override
  void initState() {
    super.initState();
    _applyPreset(DateRangePreset.thisMonth, shouldSetState: false);
    _selectedCategory = widget.initialCategory;
    if (widget.initialDescription != null) {
      _descriptionController.text = widget.initialDescription!;
    }
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _applyPreset(DateRangePreset preset, {bool shouldSetState = true}) {
    final now = DateTime.now();
    DateTime start;
    DateTime end;

    switch (preset) {
      case DateRangePreset.thisMonth:
        start = DateTime(now.year, now.month, 1);
        end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
        break;
      case DateRangePreset.last30Days:
        start = now.subtract(const Duration(days: 30));
        end = now;
        break;
      case DateRangePreset.lastMonth:
        start = DateTime(now.year, now.month - 1, 1);
        end = DateTime(now.year, now.month, 0, 23, 59, 59);
        break;
      case DateRangePreset.thisYear:
        start = DateTime(now.year, 1, 1);
        end = DateTime(now.year, 12, 31, 23, 59, 59);
        break;
      case DateRangePreset.custom:
        return;
    }

    if (shouldSetState) {
      setState(() {
        _selectedPreset = preset;
        _startDate = start;
        _endDate = end;
      });
    } else {
      _selectedPreset = preset;
      _startDate = start;
      _endDate = end;
    }
  }

  Future<void> _pickCustomDateRange() async {
    final colors = AppColors.of(context);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: colors.primary,
              onPrimary: Colors.white,
              surface: colors.cardBg,
              onSurface: colors.textPrimary,
            ),
            scaffoldBackgroundColor: colors.scaffoldBg,
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedPreset = DateRangePreset.custom;
        _startDate = picked.start;
        _endDate = DateTime(
          picked.end.year,
          picked.end.month,
          picked.end.day,
          23,
          59,
          59,
        );
      });
    }
  }

  void _resetFilters() {
    setState(() {
      _applyPreset(DateRangePreset.thisMonth, shouldSetState: false);
      _selectedCategory = null;
      _descriptionController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final allCategories = ref.watch(categoriesProvider);
    final allTransactions = ref.watch(transactionsProvider);

    // Filter categories to only exclude the system unallocated envelope from dropdown
    final selectableCategories =
        allCategories.where((c) => !c.isUnallocated).toList();

    final isValid = SpendingReportEngine.isValidFilter(
      startDate: _startDate,
      endDate: _endDate,
      category: _selectedCategory,
      description: _descriptionController.text,
    );

    SpendingReportResult? reportResult;
    if (isValid) {
      reportResult = SpendingReportEngine.generateReport(
        startDate: _startDate,
        endDate: _endDate,
        filterCategory: _selectedCategory,
        filterDescription: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        allCategories: allCategories,
        allTransactions: allTransactions,
      );
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
          'Spending Report',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 22,
            color: colors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: colors.iconSecondary),
            tooltip: 'Reset Filters',
            onPressed: _resetFilters,
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 12.0 : 16.0,
                vertical: 12.0,
              ),
              child: ResponsiveCenter(
                maxWidth: 920,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // --- FILTERS CARD ---
                    _buildFilterCard(selectableCategories),
                    const SizedBox(height: 16),

                    // --- VALIDATION BANNER OR REPORT CONTENT ---
                    if (!isValid) ...[
                      _buildValidationMessage(),
                    ] else if (reportResult != null) ...[
                      _buildReportContent(reportResult),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // --- FILTER CARD ---
  Widget _buildFilterCard(List<Category> categories) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.filter_list_rounded,
                  color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Report Options',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Date Range Required',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 1. Date Range Picker Selector
          InkWell(
            onTap: _pickCustomDateRange,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colors.inputFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_outlined,
                      color: colors.secondary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Date Range (Required)',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${dateFormat.format(_startDate)} – ${dateFormat.format(_endDate)}',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.edit_calendar_outlined,
                      color: colors.iconSecondary, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Preset Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPresetChip('This Month', DateRangePreset.thisMonth),
                const SizedBox(width: 8),
                _buildPresetChip('Last 30 Days', DateRangePreset.last30Days),
                const SizedBox(width: 8),
                _buildPresetChip('Last Month', DateRangePreset.lastMonth),
                const SizedBox(width: 8),
                _buildPresetChip('This Year', DateRangePreset.thisYear),
                const SizedBox(width: 8),
                _buildPresetChip('Custom...', DateRangePreset.custom,
                    onTap: _pickCustomDateRange),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Category Dropdown
          DropdownButtonFormField<String?>(
            // ignore: deprecated_member_use
            value: _selectedCategory?.id,
            isExpanded: true,
            dropdownColor: colors.cardBg,
            style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Envelope / Category',
              helperText: 'Select an envelope, or enter a description keyword below',
              helperStyle: GoogleFonts.inter(fontSize: 11, color: colors.textMuted),
              labelStyle: GoogleFonts.inter(color: colors.textSecondary),
              prefixIcon: Icon(Icons.folder_outlined, color: colors.textSecondary),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colors.primary, width: 1.5),
              ),
              filled: true,
              fillColor: colors.inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Row(
                  children: [
                    Icon(Icons.all_inclusive, color: colors.textSecondary, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'All Envelopes (Requires Description)',
                      style: GoogleFonts.inter(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              ...categories.map((cat) {
                final catColor = HexColor(cat.colorHex);
                return DropdownMenuItem<String?>(
                  value: cat.id,
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: catColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        IconMapper.getIcon(cat.iconName),
                        size: 16,
                        color: catColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          cat.name,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(color: colors.textPrimary),
                        ),
                      ),
                      Text(
                        currencyFormat.format(cat.balance),
                        style: GoogleFonts.inter(
                          color: colors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            onChanged: (catId) {
              setState(() {
                if (catId == null) {
                  _selectedCategory = null;
                } else {
                  _selectedCategory = categories.firstWhere((c) => c.id == catId);
                }
              });
            },
          ),
          const SizedBox(height: 14),

          // 3. Description Keyword Field
          TextFormField(
            controller: _descriptionController,
            style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Description Keyword',
              labelStyle: GoogleFonts.inter(color: colors.textSecondary),
              hintText: 'e.g. Costco, Rent, Dining, Gas',
              hintStyle: GoogleFonts.inter(color: colors.textMuted),
              prefixIcon: Icon(Icons.search_rounded, color: colors.textSecondary),
              suffixIcon: _descriptionController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, color: colors.iconSecondary, size: 18),
                      onPressed: () {
                        setState(() {
                          _descriptionController.clear();
                        });
                      },
                    )
                  : null,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colors.primary, width: 1.5),
              ),
              filled: true,
              fillColor: colors.inputFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onChanged: (_) {
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChip(String label, DateRangePreset preset, {VoidCallback? onTap}) {
    final colors = AppColors.of(context);
    final isSelected = _selectedPreset == preset;
    return InkWell(
      onTap: onTap ?? () => _applyPreset(preset),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? colors.primary
              : colors.inputFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? colors.primary
                : colors.border,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  // --- VALIDATION HELPER ---
  Widget _buildValidationMessage() {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.tune_rounded,
              color: colors.warning,
              size: 32,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Select Envelope or Description',
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Date range is required, along with either an Envelope, a Description keyword, or both to generate your spending report.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // --- MAIN REPORT CONTENT ---
  Widget _buildReportContent(SpendingReportResult report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Scope summary pill
        _buildScopeHeader(report),
        const SizedBox(height: 14),

        // 3 Key Metrics Cards
        _buildMetricCards(report),
        const SizedBox(height: 14),

        // Visual Comparison & Funding Balance Card
        _buildComparisonCard(report),
        const SizedBox(height: 16),

        // Multi-category breakdown (if description was searched across multiple categories)
        if (report.categoryBreakdowns.length > 1) ...[
          _buildMultiCategoryBreakdown(report),
          const SizedBox(height: 16),
        ],

        // Detailed Transactions Tabs (Expenses vs Inflow Funding Sources)
        _buildDetailTabs(report),
      ],
    );
  }

  // Scope Header
  Widget _buildScopeHeader(SpendingReportResult report) {
    final colors = AppColors.of(context);
    final cat = report.filterCategory;
    final desc = report.filterDescription;

    String scopeTitle;
    IconData scopeIcon;
    Color scopeColor;

    if (cat != null && desc != null) {
      scopeTitle = '${cat.name} • "$desc"';
      scopeIcon = IconMapper.getIcon(cat.iconName);
      scopeColor = HexColor(cat.colorHex);
    } else if (cat != null) {
      scopeTitle = 'Envelope: ${cat.name}';
      scopeIcon = IconMapper.getIcon(cat.iconName);
      scopeColor = HexColor(cat.colorHex);
    } else {
      scopeTitle = 'Keyword: "$desc"';
      scopeIcon = Icons.search_rounded;
      scopeColor = colors.secondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: scopeColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(scopeIcon, color: scopeColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              scopeTitle,
              style: GoogleFonts.outfit(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${dateFormat.format(report.startDate)} – ${dateFormat.format(report.endDate)}',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // --- 3 KPI METRIC CARDS ---
  Widget _buildMetricCards(SpendingReportResult report) {
    final colors = AppColors.of(context);
    return Column(
      children: [
        // Primary Total Spent Banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colors.danger.withValues(alpha: 0.15),
                colors.cardBg,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: colors.danger.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.danger.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.shopping_bag_outlined,
                  color: colors.danger,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TOTAL SPENT',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        letterSpacing: 1,
                        fontWeight: FontWeight.bold,
                        color: colors.isDark ? const Color(0xFFFDA4AF) : const Color(0xFFBE123C),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currencyFormat.format(report.totalSpent),
                      style: GoogleFonts.outfit(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.danger.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${report.totalExpenseCount} expenses',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.isDark ? const Color(0xFFFDA4AF) : const Color(0xFFBE123C),
                      ),
                    ),
                  ),
                  if (report.totalExpenseCount > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Avg: ${currencyFormat.format(report.averageExpense)}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Two side-by-side cards: Paycheck Allocation vs Taken from Other Categories
        Row(
          children: [
            // 1. Allocated from Paychecks
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colors.success.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colors.success.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.payments_outlined,
                            color: colors.success,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'From Paychecks',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      currencyFormat.format(report.allocatedFromPaychecks),
                      style: GoogleFonts.outfit(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Allocated directly',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // 2. Taken from Other Categories
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colors.secondary.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colors.secondary.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.swap_horiz_rounded,
                            color: colors.secondary,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Other Envelopes',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.isDark ? const Color(0xFF67E8F9) : const Color(0xFF0E7490),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      currencyFormat.format(report.takenFromOtherCategories),
                      style: GoogleFonts.outfit(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Transfers & coverage',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- FUNDING VS SPENDING VISUAL COMPARISON ---
  Widget _buildComparisonCard(SpendingReportResult report) {
    final colors = AppColors.of(context);
    final totalFunding = report.totalFunding;
    final totalSpent = report.totalSpent;
    final netBalance = report.netBalance;

    final paycheckShare = totalFunding > 0
        ? (report.allocatedFromPaychecks / totalFunding).clamp(0.0, 1.0)
        : 0.0;
    final otherShare = totalFunding > 0
        ? (report.takenFromOtherCategories / totalFunding).clamp(0.0, 1.0)
        : 0.0;

    final isSurplus = netBalance >= 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Funding Inflows vs Spending',
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSurplus
                      ? colors.success.withValues(alpha: 0.15)
                      : colors.danger.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isSurplus
                      ? 'Surplus: +${currencyFormat.format(netBalance)}'
                      : 'Overspent: ${currencyFormat.format(netBalance)}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isSurplus
                        ? colors.success
                        : colors.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Stacked Funding Proportion Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 12,
              child: totalFunding > 0
                  ? Row(
                      children: [
                        if (paycheckShare > 0)
                          Expanded(
                            flex: (paycheckShare * 1000).toInt(),
                            child: Container(color: colors.success),
                          ),
                        if (otherShare > 0)
                          Expanded(
                            flex: (otherShare * 1000).toInt(),
                            child: Container(color: colors.secondary),
                          ),
                      ],
                    )
                  : Container(color: colors.border),
            ),
          ),
          const SizedBox(height: 8),

          // Inflow Legend
          Row(
            children: [
              _buildLegendDot(colors.success, 'Paycheck: ${(paycheckShare * 100).toStringAsFixed(0)}%'),
              const SizedBox(width: 14),
              _buildLegendDot(colors.secondary, 'Other Envelopes: ${(otherShare * 100).toStringAsFixed(0)}%'),
            ],
          ),
          Divider(color: colors.divider, height: 24),

          // Summary Stats Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total Funded (Inflows)',
                    style: GoogleFonts.inter(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currencyFormat.format(totalFunding),
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.success,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Total Spent (Outflows)',
                    style: GoogleFonts.inter(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currencyFormat.format(totalSpent),
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.danger,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendDot(Color color, String text) {
    final colors = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: GoogleFonts.inter(fontSize: 11, color: colors.textSecondary),
        ),
      ],
    );
  }

  // --- MULTI-CATEGORY BREAKDOWN (when searching across envelopes) ---
  Widget _buildMultiCategoryBreakdown(SpendingReportResult report) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Envelopes Touched (${report.categoryBreakdowns.length})',
            style: GoogleFonts.outfit(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: report.categoryBreakdowns.length,
            separatorBuilder: (_, i) => Divider(color: colors.divider, height: 16),
            itemBuilder: (context, index) {
              final catItem = report.categoryBreakdowns[index];
              final catColor = HexColor(catItem.category.colorHex);
              return Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: catColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      IconMapper.getIcon(catItem.category.iconName),
                      color: catColor,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          catItem.category.name,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          'Paycheck: ${currencyFormat.format(catItem.allocatedFromPaychecks)} • Other: ${currencyFormat.format(catItem.takenFromOtherCategories)}',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        currencyFormat.format(catItem.totalSpent),
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colors.danger,
                        ),
                      ),
                      Text(
                        '${catItem.expenseCount} tx',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // --- DETAIL TABS: EXPENSES VS FUNDING SOURCES ---
  Widget _buildDetailTabs(SpendingReportResult report) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            indicatorColor: colors.primary,
            indicatorWeight: 3,
            labelColor: colors.textPrimary,
            unselectedLabelColor: colors.textSecondary,
            labelStyle: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.bold),
            unselectedLabelStyle: GoogleFonts.outfit(fontSize: 14),
            tabs: [
              Tab(text: 'Expenses (${report.matchingExpenses.length})'),
              Tab(text: 'Funding Inflows (${report.fundingItems.length})'),
            ],
          ),
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              if (_tabController.index == 0) {
                return _buildExpensesList(report);
              } else {
                return _buildFundingSourcesList(report);
              }
            },
          ),
        ],
      ),
    );
  }

  // Expenses Tab Content
  Widget _buildExpensesList(SpendingReportResult report) {
    final colors = AppColors.of(context);
    if (report.matchingExpenses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: colors.iconMuted),
            const SizedBox(height: 12),
            Text(
              'No expenses match your filters.',
              style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    final categories = ref.read(categoriesProvider);
    final categoryMap = {for (final c in categories) c.id: c};

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16.0),
      itemCount: report.matchingExpenses.length,
      separatorBuilder: (_, i) => Divider(color: colors.divider, height: 16),
      itemBuilder: (context, index) {
        final tx = report.matchingExpenses[index];
        final cat = tx.category != null ? categoryMap[tx.category] : null;
        final catColor = cat != null ? HexColor(cat.colorHex) : const Color(0xFF64748B);

        return Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.danger.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_downward_rounded,
                color: colors.danger,
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.description.isEmpty ? 'Expense' : tx.description,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (cat != null) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: catColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          cat.name,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: catColor,
                          ),
                        ),
                        Text(' • ', style: TextStyle(color: colors.textMuted, fontSize: 11)),
                      ],
                      Text(
                        dateTimeFormat.format(tx.date),
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              '-${currencyFormat.format(tx.amount.abs())}',
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.danger,
              ),
            ),
          ],
        );
      },
    );
  }

  // Funding Inflows Tab Content
  Widget _buildFundingSourcesList(SpendingReportResult report) {
    final colors = AppColors.of(context);
    if (report.fundingItems.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                size: 48, color: colors.iconMuted),
            const SizedBox(height: 12),
            Text(
              'No funding allocations found in this date range.',
              style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16.0),
      itemCount: report.fundingItems.length,
      separatorBuilder: (_, i) => Divider(color: colors.divider, height: 16),
      itemBuilder: (context, index) {
        final item = report.fundingItems[index];
        final isPaycheck = item.isPaycheckAllocation;
        final iconColor = isPaycheck ? colors.success : colors.secondary;

        return Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isPaycheck ? Icons.payments_outlined : Icons.swap_horiz_rounded,
                color: iconColor,
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.description,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: iconColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isPaycheck ? 'Paycheck' : 'Transfer',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: iconColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          isPaycheck
                              ? '→ ${item.destinationCategoryName}'
                              : '${item.sourceCategoryName} → ${item.destinationCategoryName}',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: colors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        dateFormat.format(item.date),
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '+${currencyFormat.format(item.amount)}',
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: iconColor,
              ),
            ),
          ],
        );
      },
    );
  }
}

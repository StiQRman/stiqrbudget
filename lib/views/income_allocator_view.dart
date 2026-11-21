import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hexcolor/hexcolor.dart';
import 'package:intl/intl.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../providers/settings_provider.dart';
import '../services/allocation_engine.dart';
import '../models/category.dart';
import '../utils/app_theme.dart';
import '../utils/icon_mapper.dart';
import '../utils/responsive_layout.dart';

class IncomeAllocatorView extends ConsumerStatefulWidget {
  const IncomeAllocatorView({super.key});

  @override
  ConsumerState<IncomeAllocatorView> createState() => _IncomeAllocatorViewState();
}

class _IncomeAllocatorViewState extends ConsumerState<IncomeAllocatorView> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController(text: 'Paycheck');
  
  List<AllocationBreakdown> _suggestedAllocations = [];
  Map<String, TextEditingController> _controllers = {};
  double _enteredAmount = 0.0;
  bool _rulesCalculated = false;
  bool _isSaving = false;
  DateTime _selectedDate = DateTime.now();

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate.isAfter(now) ? now : _selectedDate,
      firstDate: DateTime(2020),
      lastDate: now,
      builder: (context, child) {
        final settingsState = ref.read(settingsProvider);
        final isDark = settingsState.themeMode == ThemeMode.dark ||
            (settingsState.themeMode == ThemeMode.system &&
                MediaQuery.platformBrightnessOf(context) == Brightness.dark);
        return Theme(
          data: isDark ? AppTheme.darkTheme : AppTheme.lightTheme,
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        final nowTime = DateTime.now();
        _selectedDate = DateTime(
          picked.year,
          picked.month,
          picked.day,
          nowTime.hour,
          nowTime.minute,
          nowTime.second,
        );
      });
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _calculateAllocations() {
    final amountText = _amountController.text.trim();
    if (amountText.isEmpty) {
      setState(() {
        _enteredAmount = 0.0;
        _suggestedAllocations = [];
        _controllers.clear();
        _rulesCalculated = false;
      });
      return;
    }

    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) return;

    final categories = ref.read(categoriesProvider);
    final transactions = ref.read(transactionsProvider);

    final suggestions = AllocationEngine.calculateAllocations(
      checkAmount: amount,
      categories: categories,
      allTransactions: transactions,
    );

    final suggestionMap = {
      for (final s in suggestions) s.category.id: s
    };

    final List<AllocationBreakdown> allAllocations = [];
    for (final cat in categories) {
      if (suggestionMap.containsKey(cat.id)) {
        allAllocations.add(suggestionMap[cat.id]!);
      } else {
        allAllocations.add(AllocationBreakdown(
          category: cat,
          amount: 0.0,
          description: cat.isUnallocated ? 'Remaining unallocated balance' : 'Manual allocation',
        ));
      }
    }

    // Ensure Unallocated is in the list
    final hasUnallocated = allAllocations.any((b) => b.category.isUnallocated);
    if (!hasUnallocated) {
      final unallocatedCat = categories.firstWhere(
        (cat) => cat.isUnallocated,
        orElse: () => Category(
          id: 'unallocated_fallback',
          name: 'Unallocated',
          balance: 0.0,
          colorHex: '#64748B',
          iconName: 'inbox',
          allocationType: AllocationType.manual,
          allocationValue: 0.0,
          user: '',
        ),
      );
      allAllocations.add(AllocationBreakdown(
        category: unallocatedCat,
        amount: 0.0,
        description: 'Remaining unallocated balance',
      ));
    }

    // Create controllers for each category's input field
    final Map<String, TextEditingController> newControllers = {};
    for (var suggestion in allAllocations) {
      newControllers[suggestion.category.id] = TextEditingController(
        text: suggestion.amount.toStringAsFixed(2),
      );
      // Listen to text changes to rebuild and update the total balance indicators in real-time
      newControllers[suggestion.category.id]!.addListener(() {
        setState(() {});
      });
    }

    setState(() {
      _enteredAmount = amount;
      _suggestedAllocations = allAllocations;
      _controllers = newControllers;
      _rulesCalculated = true;
    });
  }

  double get _totalAllocated {
    double total = 0.0;
    for (var controller in _controllers.values) {
      final value = double.tryParse(controller.text) ?? 0.0;
      total += value;
    }
    return double.parse(total.toStringAsFixed(2));
  }

  double get _remainingToAllocate {
    return double.parse((_enteredAmount - _totalAllocated).toStringAsFixed(2));
  }

  void _confirmAllocations() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_remainingToAllocate != 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please allocate the entire check balance (Zero-Based rule).'),
          backgroundColor: Colors.amber,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final categories = ref.read(categoriesProvider);
      final List<Map<String, dynamic>> distributions = [];

      for (var entry in _controllers.entries) {
        final categoryId = entry.key;
        final amount = double.tryParse(entry.value.text) ?? 0.0;
        if (amount <= 0) continue;

        final category = categories.where((c) => c.id == categoryId).firstOrNull ??
            _suggestedAllocations.where((s) => s.category.id == categoryId).firstOrNull?.category;
        if (category == null) continue;

        distributions.add({
          'category': category,
          'amount': amount,
        });
      }

      final notifier = ref.read(transactionsProvider.notifier);
      final success = await notifier.addIncomeWithDistributions(
        description: _descriptionController.text.trim(),
        amount: _enteredAmount,
        distributions: distributions,
        date: _selectedDate,
      );

      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        if (success) {
          Navigator.pop(context);
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Paycheck deposited and envelopes filled!'),
              backgroundColor: Colors.teal,
            ),
          );
        } else {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Failed to deposit paycheck. Try again.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final currencyFormat = NumberFormat.simpleCurrency();
    final remaining = _remainingToAllocate;
    final isBalanced = remaining == 0.0;

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
          'Add Income & Allocate',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 20,
            color: colors.textPrimary,
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ResponsiveCenter(
            maxWidth: 720,
            child: Form(
              key: _formKey,
              child: Column(
          children: [
            // Paycheck input section
            Container(
              color: colors.surfaceSecondary,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Amount field
                  TextFormField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: GoogleFonts.outfit(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Income Amount',
                      labelStyle: GoogleFonts.inter(color: colors.textSecondary, fontSize: 16),
                      prefixText: '\$ ',
                      prefixStyle: GoogleFonts.outfit(fontSize: 32, color: colors.textSecondary),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => _calculateAllocations(),
                    validator: (val) {
                      if (val == null || val.isEmpty) return 'Please enter an amount';
                      final num = double.tryParse(val);
                      if (num == null || num <= 0) return 'Must be greater than \$0';
                      return null;
                    },
                  ),
                  Divider(color: colors.border, height: 24),

                  // Description field
                  TextFormField(
                    controller: _descriptionController,
                    style: GoogleFonts.inter(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Description / Source',
                      labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    validator: (val) {
                      if (val == null || val.trim().isEmpty) return 'Required';
                      return null;
                    },
                  ),
                  Divider(color: colors.border, height: 24),

                  // Income Date selector
                  InkWell(
                    onTap: _pickDate,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_outlined, size: 18, color: Color(0xFF6366F1)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Income Date',
                                  style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 11),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isToday(_selectedDate)
                                      ? 'Today • ${DateFormat('MMM d, yyyy').format(_selectedDate)}'
                                      : DateFormat('EEEE, MMM d, yyyy').format(_selectedDate),
                                  style: GoogleFonts.inter(
                                    color: colors.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, color: colors.iconMuted),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Suggested distributions section
            Expanded(
              child: !_rulesCalculated
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.calculate_outlined, size: 64, color: colors.textMuted),
                          const SizedBox(height: 12),
                          Text(
                            'Enter an income amount to see distribution rules.',
                            style: GoogleFonts.inter(color: colors.textSecondary),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(20),
                      itemCount: _suggestedAllocations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final suggestion = _suggestedAllocations[index];
                        final cat = suggestion.category;
                        final envelopeColor = HexColor(cat.colorHex);
                        final controller = _controllers[cat.id];

                        return Container(
                          decoration: BoxDecoration(
                            color: colors.cardBg,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: colors.border,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: envelopeColor.withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  IconMapper.getIcon(cat.iconName),
                                  color: envelopeColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      cat.name,
                                      style: GoogleFonts.outfit(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      suggestion.description,
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 120,
                                child: TextFormField(
                                  controller: controller,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  style: GoogleFonts.outfit(
                                    fontWeight: FontWeight.bold,
                                    color: colors.textPrimary,
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.end,
                                  decoration: InputDecoration(
                                    prefixText: '\$ ',
                                    prefixStyle: GoogleFonts.inter(color: colors.textSecondary),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                    isDense: true,
                                    border: UnderlineInputBorder(
                                      borderSide: BorderSide(color: envelopeColor.withOpacity(0.5)),
                                    ),
                                    focusedBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: envelopeColor, width: 2),
                                    ),
                                  ),
                                  validator: (val) {
                                    if (val == null || val.isEmpty) return 'Required';
                                    final num = double.tryParse(val);
                                    if (num == null) return 'Invalid';
                                    if (num < 0) return 'Cannot be negative';
                                    return null;
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Zero-Based Indicator & Button Bar
            if (_rulesCalculated)
              SafeArea(
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.cardBg,
                    border: Border(
                      top: BorderSide(color: colors.border),
                    ),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Balance Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'TOTAL INCOME: ${currencyFormat.format(_enteredAmount)}',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Allocated: ${currencyFormat.format(_totalAllocated)}',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: isBalanced
                                  ? const Color(0xFF10B981).withOpacity(0.12)
                                  : const Color(0xFFF59E0B).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              isBalanced
                                  ? 'Balanced (Zero-Based)'
                                  : remaining > 0
                                      ? '\$${remaining.toStringAsFixed(2)} Left to Allocate'
                                      : '\$${remaining.abs().toStringAsFixed(2)} Over-allocated',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isBalanced
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFF59E0B),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Confirm Button
                      ElevatedButton(
                        onPressed: (isBalanced && !_isSaving) ? _confirmAllocations : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                'Confirm Deposit & Allocations',
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ],
                  ),
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
}

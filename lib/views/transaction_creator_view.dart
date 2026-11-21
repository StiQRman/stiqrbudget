import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hexcolor/hexcolor.dart';
import 'package:intl/intl.dart';
import '../providers/categories_provider.dart';
import '../providers/transactions_provider.dart';
import '../providers/settings_provider.dart';
import '../models/category.dart';
import '../models/transaction_model.dart';
import '../utils/app_theme.dart';
import '../utils/icon_mapper.dart';
import '../utils/responsive_layout.dart';

class TransactionCreatorView extends ConsumerStatefulWidget {
  const TransactionCreatorView({super.key});

  @override
  ConsumerState<TransactionCreatorView> createState() => _TransactionCreatorViewState();
}

class _TransactionCreatorViewState extends ConsumerState<TransactionCreatorView> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();

  bool _isExpenseMode = true; // Toggle between Expense and Transfer
  bool _isSplitMode = false; // Single Envelope vs Multi-Category Split

  Category? _selectedCategory; // For Single Envelope Expense
  Category? _selectedSourceCategory; // For Transfer
  Category? _selectedDestCategory; // For Transfer

  // Split allocation state: list of { 'category': Category?, 'controller': TextEditingController }
  final List<Map<String, dynamic>> _splits = [];

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
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountChanged);
    _initDefaultSplits();
  }

  void _onAmountChanged() {
    setState(() {});
  }

  void _initDefaultSplits() {
    _splits.clear();
    _splits.add({
      'category': null,
      'controller': TextEditingController(text: ''),
    });
    _splits.add({
      'category': null,
      'controller': TextEditingController(text: ''),
    });
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountChanged);
    _descriptionController.dispose();
    _amountController.dispose();
    for (final s in _splits) {
      (s['controller'] as TextEditingController).dispose();
    }
    super.dispose();
  }

  double get _totalEnteredAmount {
    return double.tryParse(_amountController.text.trim()) ?? 0.0;
  }

  double get _splitTotalAssigned {
    double sum = 0.0;
    for (final s in _splits) {
      final ctrl = s['controller'] as TextEditingController;
      final val = double.tryParse(ctrl.text.trim()) ?? 0.0;
      sum += val;
    }
    return ((sum * 100).roundToDouble()) / 100;
  }

  double get _splitRemaining {
    final rem = _totalEnteredAmount - _splitTotalAssigned;
    return ((rem * 100).roundToDouble()) / 100;
  }

  void _addSplit() {
    setState(() {
      _splits.add({
        'category': null,
        'controller': TextEditingController(text: ''),
      });
    });
  }

  void _removeSplit(int index) {
    if (_splits.length <= 1) return;
    setState(() {
      final removed = _splits.removeAt(index);
      (removed['controller'] as TextEditingController).dispose();
    });
  }

  void _fillMaxForSplit(int index) {
    final split = _splits[index];
    final Category? cat = split['category'];
    if (cat == null) return;

    final ctrl = split['controller'] as TextEditingController;
    final currentVal = double.tryParse(ctrl.text.trim()) ?? 0.0;
    final remainingExcludingSelf = _splitRemaining + currentVal;

    // The max we can pull from this envelope is min(category balance, needed amount)
    final available = cat.balance > 0 ? cat.balance : 0.0;
    final needed = remainingExcludingSelf > 0 ? remainingExcludingSelf : 0.0;
    final fillAmount = available < needed ? available : needed;

    setState(() {
      ctrl.text = fillAmount.toStringAsFixed(2);
    });
  }

  void _switchToSplitModeFromDeficit() {
    final categories = ref.read(categoriesProvider);
    final total = _totalEnteredAmount;

    setState(() {
      _isSplitMode = true;
      for (final s in _splits) {
        (s['controller'] as TextEditingController).dispose();
      }
      _splits.clear();

      if (_selectedCategory != null) {
        final cat = _selectedCategory!;
        final initialPortion = cat.balance > 0
            ? (cat.balance < total ? cat.balance : total)
            : 0.0;
        _splits.add({
          'category': cat,
          'controller': TextEditingController(text: initialPortion > 0 ? initialPortion.toStringAsFixed(2) : ''),
        });

        final remainder = total - initialPortion;
        // Suggest another category with balance > 0
        final nextCat = categories.where((c) => c.id != cat.id && c.balance > 0).firstOrNull;
        final nextPortion = nextCat != null
            ? (nextCat.balance < remainder ? nextCat.balance : remainder)
            : remainder;

        _splits.add({
          'category': nextCat,
          'controller': TextEditingController(text: nextPortion > 0 ? nextPortion.toStringAsFixed(2) : ''),
        });
      } else {
        _initDefaultSplits();
      }
    });
  }

  void _saveTransaction() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final description = _descriptionController.text.trim();
    final amount = double.parse(_amountController.text.trim());
    final notifier = ref.read(transactionsProvider.notifier);

    setState(() {
      _isSaving = true;
    });

    try {
      if (_isExpenseMode) {
        if (!_isSplitMode) {
          // --- Single Envelope Mode ---
          if (_selectedCategory == null) return;
          final category = _selectedCategory!;

          if (category.balance < amount) {
            // Insufficient funds: seamlessly switch to Split Mode so user can choose allocations
            setState(() {
              _isSaving = false;
            });
            _switchToSplitModeFromDeficit();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${category.name} has \$${category.balance.toStringAsFixed(2)}. Choose split envelopes below:'),
                backgroundColor: const Color(0xFF6366F1),
                duration: const Duration(seconds: 4),
              ),
            );
            return;
          }

          // Sufficient funds: process simple expense
          final success = await notifier.addSimpleTransaction(
            description: description,
            amount: -amount, // Make negative for expenses
            type: TransactionType.expense,
            category: category,
            date: _selectedDate,
          );
          _handleResult(success, 'Expense logged successfully!');
        } else {
          // --- Multi-Category Split Mode ---
          if (_splitRemaining != 0.0) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  _splitRemaining > 0
                      ? 'Please draw the remaining \$${_splitRemaining.toStringAsFixed(2)} to match total.'
                      : 'Split envelopes exceed total expense by \$${_splitRemaining.abs().toStringAsFixed(2)}.',
                ),
                backgroundColor: Colors.amber[800],
              ),
            );
            return;
          }

          final List<Map<String, dynamic>> splitsToSend = [];
          for (final split in _splits) {
            final cat = split['category'] as Category?;
            if (cat == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please select an envelope for all split rows.'),
                  backgroundColor: Colors.redAccent,
                ),
              );
              return;
            }

            final ctrl = split['controller'] as TextEditingController;
            final splitAmt = double.tryParse(ctrl.text.trim()) ?? 0.0;
            if (splitAmt <= 0) continue;

            if (splitAmt > cat.balance) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Cannot draw \$${splitAmt.toStringAsFixed(2)} from ${cat.name} (Only \$${cat.balance.toStringAsFixed(2)} available).'),
                  backgroundColor: Colors.redAccent,
                ),
              );
              return;
            }

            splitsToSend.add({
              'category': cat,
              'amount': splitAmt,
            });
          }

          if (splitsToSend.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please allocate amounts across envelopes.'),
                backgroundColor: Colors.redAccent,
              ),
            );
            return;
          }

          final success = await notifier.addSplitExpense(
            description: description,
            totalAmount: amount,
            splits: splitsToSend,
            date: _selectedDate,
          );
          _handleResult(success, 'Split expense logged across ${splitsToSend.length} envelopes!');
        }
      } else {
        // --- Transfer Mode ---
        if (_selectedSourceCategory == null || _selectedDestCategory == null) return;
        
        final source = _selectedSourceCategory!;
        final dest = _selectedDestCategory!;

        if (source.balance < amount) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Insufficient funds in ${source.name}. Available: \$${source.balance.toStringAsFixed(2)}'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }

        final success = await notifier.addTransfer(
          description: description.isEmpty ? 'Envelope Transfer' : description,
          amount: amount,
          source: source,
          destination: dest,
          date: _selectedDate,
        );
        _handleResult(success, 'Transfer completed!');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _handleResult(bool success, String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (success) {
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.teal),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('An error occurred. Please try again.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final categories = ref.watch(categoriesProvider);
    final currencyFormat = NumberFormat.simpleCurrency();
    final totalAmount = _totalEnteredAmount;

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
          _isExpenseMode ? 'Log Expense' : 'Transfer Cash',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 20,
            color: colors.textPrimary,
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = ResponsiveBreakpoints.isNarrow(constraints.maxWidth);
          return SingleChildScrollView(
            child: ResponsiveCenter(
              maxWidth: 680,
              padding: EdgeInsets.all(isNarrow ? 12.0 : 20.0),
              child: Form(
                key: _formKey,
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Mode Toggle: Expense vs Transfer
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: colors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _isExpenseMode = true;
                              _formKey.currentState?.reset();
                            });
                          },
                          child: Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: _isExpenseMode ? const Color(0xFF6366F1) : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Expense',
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.bold,
                                color: _isExpenseMode ? Colors.white : colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _isExpenseMode = false;
                              _formKey.currentState?.reset();
                            });
                          },
                          child: Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: !_isExpenseMode ? const Color(0xFF6366F1) : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Transfer',
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.bold,
                                color: !_isExpenseMode ? Colors.white : colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Amount Field
                TextFormField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: GoogleFonts.outfit(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '0.00',
                    hintStyle: GoogleFonts.outfit(color: colors.textMuted),
                    prefixText: '\$ ',
                    prefixStyle: GoogleFonts.outfit(fontSize: 38, color: colors.textSecondary),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  validator: (val) {
                    if (val == null || val.isEmpty) return 'Enter an amount';
                    final num = double.tryParse(val);
                    if (num == null || num <= 0) return 'Must be greater than \$0';
                    return null;
                  },
                ),
                const SizedBox(height: 20),

                // Description Field
                TextFormField(
                  controller: _descriptionController,
                  style: GoogleFonts.inter(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Description',
                    labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF6366F1)),
                    ),
                    filled: true,
                    fillColor: colors.inputFill,
                  ),
                  validator: (val) {
                    if (_isExpenseMode && (val == null || val.trim().isEmpty)) {
                      return 'Expense description is required';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Date Selector Tile
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: colors.inputFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_outlined, size: 20, color: Color(0xFF6366F1)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _isExpenseMode ? 'Expense Date' : 'Transfer Date',
                                style: GoogleFonts.inter(fontSize: 11, color: colors.textSecondary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _isToday(_selectedDate)
                                    ? 'Today • ${DateFormat('MMM d, yyyy').format(_selectedDate)}'
                                    : DateFormat('EEEE, MMM d, yyyy').format(_selectedDate),
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
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
                const SizedBox(height: 20),

                // Expense Envelope Selection (Single vs Split)
                if (_isExpenseMode) ...[
                  // Segmented Switcher: Single Envelope vs Split Across Envelopes
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colors.surfaceSecondary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isSplitMode = false),
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: !_isSplitMode ? const Color(0xFF6366F1) : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                'Single Envelope',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: !_isSplitMode ? Colors.white : colors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _isSplitMode = true),
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _isSplitMode ? const Color(0xFF06B6D4) : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.call_split, size: 16, color: _isSplitMode ? Colors.white : colors.textSecondary),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Split Envelopes',
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: _isSplitMode ? Colors.white : colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  if (!_isSplitMode) ...[
                    // --- Single Envelope Dropdown ---
                    DropdownButtonFormField<Category>(
                      value: _selectedCategory,
                      dropdownColor: colors.cardBg,
                      style: GoogleFonts.inter(color: colors.textPrimary),
                      decoration: InputDecoration(
                        labelText: 'Select Envelope',
                        labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: colors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF6366F1)),
                        ),
                        filled: true,
                        fillColor: colors.inputFill,
                      ),
                      items: categories.map((cat) {
                        final color = HexColor(cat.colorHex);
                        return DropdownMenuItem(
                          value: cat,
                          child: Row(
                            children: [
                              Icon(IconMapper.getIcon(cat.iconName), color: color, size: 18),
                              const SizedBox(width: 10),
                              Text(cat.name, style: GoogleFonts.inter(color: colors.textPrimary)),
                              const SizedBox(width: 8),
                              Text(
                                '(${currencyFormat.format(cat.balance)})',
                                style: GoogleFonts.inter(fontSize: 12, color: colors.textMuted),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setState(() {
                          _selectedCategory = val;
                        });
                      },
                      validator: (val) {
                        if (val == null) return 'Please select an envelope';
                        return null;
                      },
                    ),

                    // Deficit notice if envelope funds are insufficient
                    if (_selectedCategory != null &&
                        totalAmount > 0 &&
                        _selectedCategory!.balance < totalAmount) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.info_outline, color: Color(0xFFEF4444), size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${_selectedCategory!.name} has \$${_selectedCategory!.balance.toStringAsFixed(2)} available. Need \$${(totalAmount - _selectedCategory!.balance).toStringAsFixed(2)} more.',
                                    style: GoogleFonts.inter(fontSize: 12, color: colors.textPrimary, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _switchToSplitModeFromDeficit,
                                icon: const Icon(Icons.call_split, size: 16, color: Color(0xFF06B6D4)),
                                label: Text(
                                  'Split Across Multiple Envelopes',
                                  style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: const Color(0xFF06B6D4)),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFF06B6D4)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ] else ...[
                    // --- Multi-Category Split Mode Section ---
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
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Draw from Multiple Envelopes',
                                style: GoogleFonts.outfit(
                                  color: colors.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _splitRemaining == 0.0 && totalAmount > 0
                                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                      : const Color(0xFFEF4444).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _splitRemaining == 0.0 && totalAmount > 0
                                      ? 'Fully Allocated!'
                                      : _splitRemaining > 0
                                          ? 'Need \$${_splitRemaining.toStringAsFixed(2)}'
                                          : 'Over by \$${_splitRemaining.abs().toStringAsFixed(2)}',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: _splitRemaining == 0.0 && totalAmount > 0
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFFEF4444),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Choose exactly how much is taken out of each envelope:',
                            style: GoogleFonts.inter(color: colors.textSecondary, fontSize: 11),
                          ),
                          const SizedBox(height: 14),

                          // List of Split Envelope Rows
                          ...List.generate(_splits.length, (index) {
                            final split = _splits[index];
                            final Category? selCat = split['category'];
                            final ctrl = split['controller'] as TextEditingController;
                            final color = selCat != null ? HexColor(selCat.colorHex) : colors.textMuted;

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // Category Dropdown
                                  Expanded(
                                    flex: 3,
                                    child: DropdownButtonFormField<Category>(
                                      value: selCat,
                                      dropdownColor: colors.cardBg,
                                      style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 13),
                                      decoration: InputDecoration(
                                        hintText: 'Select envelope...',
                                        hintStyle: GoogleFonts.inter(color: colors.textMuted, fontSize: 12),
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: BorderSide(color: colors.border),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: const BorderSide(color: Color(0xFF6366F1)),
                                        ),
                                        filled: true,
                                        fillColor: colors.inputFill,
                                      ),
                                      items: categories.map((cat) {
                                        final cColor = HexColor(cat.colorHex);
                                        return DropdownMenuItem<Category>(
                                          value: cat,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(IconMapper.getIcon(cat.iconName), color: cColor, size: 16),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  '${cat.name} (${currencyFormat.format(cat.balance)})',
                                                  style: GoogleFonts.inter(color: colors.textPrimary, fontSize: 13),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                      onChanged: (cat) {
                                        setState(() {
                                          _splits[index]['category'] = cat;
                                        });
                                      },
                                      validator: (val) {
                                        if (val == null) return 'Required';
                                        return null;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),

                                  // Exact Amount Field
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      controller: ctrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      textAlign: TextAlign.end,
                                      style: GoogleFonts.outfit(color: colors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                                      decoration: InputDecoration(
                                        prefixText: '\$ ',
                                        prefixStyle: GoogleFonts.inter(color: colors.textSecondary, fontSize: 12),
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: BorderSide(color: colors.border),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(10),
                                          borderSide: BorderSide(color: color, width: 1.5),
                                        ),
                                        filled: true,
                                        fillColor: colors.inputFill,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                      validator: (val) {
                                        if (val == null || val.isEmpty) return 'Required';
                                        final num = double.tryParse(val);
                                        if (num == null) return 'Invalid';
                                        if (num <= 0) return '> \$0';
                                        if (selCat != null && num > selCat.balance) {
                                          return 'Max \$${selCat.balance.toStringAsFixed(2)}';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),

                                  // Max Quick-fill Button
                                  TextButton(
                                    onPressed: () => _fillMaxForSplit(index),
                                    style: TextButton.styleFrom(
                                      minimumSize: Size.zero,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                      backgroundColor: colors.cardBg,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: BorderSide(color: colors.border),
                                      ),
                                    ),
                                    child: Text(
                                      'Max',
                                      style: GoogleFonts.inter(color: const Color(0xFF06B6D4), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),

                                  // Delete Row Button (if > 1 rows)
                                  if (_splits.length > 1) ...[
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _removeSplit(index),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),

                          // Add Another Envelope Button
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _addSplit,
                              icon: const Icon(Icons.add, size: 16, color: Color(0xFF06B6D4)),
                              label: Text(
                                'Add Envelope',
                                style: GoogleFonts.inter(color: const Color(0xFF06B6D4), fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ] else ...[
                  // --- Transfer Mode Dropdowns ---
                  DropdownButtonFormField<Category>(
                    value: _selectedSourceCategory,
                    dropdownColor: colors.cardBg,
                    style: GoogleFonts.inter(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Source Envelope (From)',
                      labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF6366F1)),
                      ),
                      filled: true,
                      fillColor: colors.inputFill,
                    ),
                    items: categories.map((cat) {
                      final color = HexColor(cat.colorHex);
                      final isUnalloc = cat.isUnallocated;
                      return DropdownMenuItem(
                        value: cat,
                        child: Row(
                          children: [
                            Icon(IconMapper.getIcon(cat.iconName), color: color, size: 18),
                            const SizedBox(width: 10),
                            Text(
                              isUnalloc ? '${cat.name} (Ready to Distribute)' : cat.name,
                              style: GoogleFonts.inter(color: colors.textPrimary),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '(${currencyFormat.format(cat.balance)})',
                              style: GoogleFonts.inter(fontSize: 12, color: colors.textMuted),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedSourceCategory = val;
                      });
                    },
                    validator: (val) {
                      if (val == null) return 'Please select a source envelope';
                      return null;
                    },
                  ),
                  const SizedBox(height: 18),

                  DropdownButtonFormField<Category>(
                    value: _selectedDestCategory,
                    dropdownColor: colors.cardBg,
                    style: GoogleFonts.inter(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Destination Envelope (To)',
                      labelStyle: GoogleFonts.inter(color: colors.textSecondary),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF6366F1)),
                      ),
                      filled: true,
                      fillColor: colors.inputFill,
                    ),
                    items: categories.map((cat) {
                      final color = HexColor(cat.colorHex);
                      final isUnalloc = cat.isUnallocated;
                      return DropdownMenuItem(
                        value: cat,
                        child: Row(
                          children: [
                            Icon(IconMapper.getIcon(cat.iconName), color: color, size: 18),
                            const SizedBox(width: 10),
                            Text(
                              isUnalloc ? '${cat.name} (Ready to Distribute)' : cat.name,
                              style: GoogleFonts.inter(color: colors.textPrimary),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '(${currencyFormat.format(cat.balance)})',
                              style: GoogleFonts.inter(fontSize: 12, color: colors.textMuted),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedDestCategory = val;
                      });
                    },
                    validator: (val) {
                      if (val == null) return 'Please select a destination envelope';
                      if (_selectedSourceCategory != null && val.id == _selectedSourceCategory!.id) {
                        return 'Cannot transfer to the same envelope';
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 36),

                // Main Save Action Button
                ElevatedButton(
                  onPressed: _isSaving
                      ? null
                      : () {
                          _saveTransaction();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isExpenseMode && _isSplitMode
                        ? const Color(0xFF06B6D4)
                        : const Color(0xFF6366F1),
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
                          _isExpenseMode
                              ? (_isSplitMode ? 'Save Split Expense' : 'Save Expense')
                              : 'Transfer Funds',
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
          );
        },
      ),
    );
  }
}

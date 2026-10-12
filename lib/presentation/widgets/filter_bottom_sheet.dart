import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';
import '../../domain/entities/filter_criteria.dart';

class FilterBottomSheet extends StatefulWidget {
  final FilterCriteria criteria;
  final List<String> availableParts;
  final ValueChanged<FilterCriteria> onApply;

  const FilterBottomSheet({
    super.key,
    required this.criteria,
    required this.availableParts,
    required this.onApply,
  });

  static Future<void> show(
    BuildContext context, {
    required FilterCriteria criteria,
    required List<String> availableParts,
    required ValueChanged<FilterCriteria> onApply,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FilterBottomSheet(
        criteria: criteria,
        availableParts: availableParts,
        onApply: onApply,
      ),
    );
  }

  @override
  State<FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<FilterBottomSheet> {
  late GenderOption _gender;
  late FieldStatusType? _fieldStatus;
  late ReviewStatusType? _reviewStatus;
  late String? _selectedPart;
  late final TextEditingController _houseController;

  @override
  void initState() {
    super.initState();
    _gender = widget.criteria.gender;
    _fieldStatus = widget.criteria.fieldStatus;
    _reviewStatus = widget.criteria.reviewStatus;
    _selectedPart = widget.criteria.partNumber;
    _houseController = TextEditingController(text: widget.criteria.houseNumber);
  }

  @override
  void dispose() {
    _houseController.dispose();
    super.dispose();
  }

  int get _activeCount {
    int count = 0;
    if (_gender != GenderOption.all) count++;
    if (_selectedPart != null && _selectedPart!.isNotEmpty) count++;
    if (_fieldStatus != null) count++;
    if (_reviewStatus != null) count++;
    if (_houseController.text.trim().isNotEmpty) count++;
    return count;
  }

  void _clearAll() {
    setState(() {
      _gender = GenderOption.all;
      _fieldStatus = null;
      _reviewStatus = null;
      _selectedPart = null;
      _houseController.clear();
    });
  }

  void _apply() {
    final updated = widget.criteria.copyWith(
      gender: _gender,
      fieldStatus: _fieldStatus,
      clearFieldStatus: _fieldStatus == null,
      reviewStatus: _reviewStatus,
      clearReviewStatus: _reviewStatus == null,
      partNumber: _selectedPart,
      houseNumber: _houseController.text.trim().isNotEmpty ? _houseController.text.trim() : null,
      page: 1,
    );
    widget.onApply(updated);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? AppColors.dividerDark : AppColors.dividerLight,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      'Filters',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    if (_activeCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$_activeCount',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
                TextButton(
                  onPressed: _clearAll,
                  child: const Text('Clear All', style: TextStyle(color: AppColors.statusDeceased, fontSize: 13)),
                ),
              ],
            ),
          ),
          const Divider(),

          // Scrollable Filter Sections
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              children: [
                // 1. Electoral Part
                _buildSectionTitle('Electoral Area / Part'),
                if (widget.availableParts.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildChoiceChip(
                        label: 'All Parts',
                        selected: _selectedPart == null,
                        onSelected: (_) => setState(() => _selectedPart = null),
                      ),
                      ...widget.availableParts.map((p) => _buildChoiceChip(
                            label: 'Part $p',
                            selected: _selectedPart == p,
                            onSelected: (sel) => setState(() => _selectedPart = sel ? p : null),
                          )),
                    ],
                  ),
                ] else
                  const Text('All available electoral parts active', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 20),

                // 2. Gender Filter
                _buildSectionTitle('Gender'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: GenderOption.values.map((g) {
                    return _buildChoiceChip(
                      label: g.label,
                      selected: _gender == g,
                      onSelected: (_) => setState(() => _gender = g),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                // 3. Field Status
                _buildSectionTitle('Field Status'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildChoiceChip(
                      label: 'All Statuses',
                      selected: _fieldStatus == null,
                      onSelected: (_) => setState(() => _fieldStatus = null),
                    ),
                    ...FieldStatusType.values.map((fs) {
                      return _buildChoiceChip(
                        label: fs.label,
                        selected: _fieldStatus == fs,
                        activeColor: fs.color,
                        onSelected: (sel) => setState(() => _fieldStatus = sel ? fs : null),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 20),

                // 4. Review Status
                _buildSectionTitle('Review Queue Status'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildChoiceChip(
                      label: 'All Records',
                      selected: _reviewStatus == null,
                      onSelected: (_) => setState(() => _reviewStatus = null),
                    ),
                    ...ReviewStatusType.values.map((rs) {
                      return _buildChoiceChip(
                        label: rs.label,
                        selected: _reviewStatus == rs,
                        activeColor: rs.color,
                        onSelected: (sel) => setState(() => _reviewStatus = sel ? rs : null),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 20),

                // 5. House Number
                _buildSectionTitle('Specific House Number'),
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark ? AppColors.borderDark : AppColors.borderLight,
                      width: 0.8,
                    ),
                  ),
                  child: TextField(
                    controller: _houseController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 5/44 or 12/45A',
                      hintStyle: TextStyle(fontSize: 13),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),

          // Bottom Apply Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              border: Border(top: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8)),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  onPressed: _apply,
                  child: Text(
                    _activeCount > 0 ? 'Apply Filters ($_activeCount)' : 'Show All Voters',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primary),
      ),
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    Color? activeColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = activeColor ?? AppColors.primary;

    return GestureDetector(
      onTap: () => onSelected(!selected),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.14)
              : (isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : (isDark ? AppColors.borderDark : AppColors.borderLight),
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? color : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight),
          ),
        ),
      ),
    );
  }
}

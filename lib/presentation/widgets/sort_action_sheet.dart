import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../domain/entities/filter_criteria.dart';

class SortActionSheet extends StatelessWidget {
  final SortBy currentSortBy;
  final SortOrder currentOrder;
  final void Function(SortBy by, SortOrder order) onSelected;

  const SortActionSheet({
    super.key,
    required this.currentSortBy,
    required this.currentOrder,
    required this.onSelected,
  });

  static Future<void> show(
    BuildContext context, {
    required SortBy currentSortBy,
    required SortOrder currentOrder,
    required void Function(SortBy by, SortOrder order) onSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SortActionSheet(
        currentSortBy: currentSortBy,
        currentOrder: currentOrder,
        onSelected: onSelected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Sort Voters',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(CupertinoIcons.xmark, size: 14),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),

            // Order direction toggle
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _buildOrderButton(
                      context,
                      title: 'Ascending (↑)',
                      selected: currentOrder == SortOrder.asc,
                      onTap: () {
                        onSelected(currentSortBy, SortOrder.asc);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildOrderButton(
                      context,
                      title: 'Descending (↓)',
                      selected: currentOrder == SortOrder.desc,
                      onTap: () {
                        onSelected(currentSortBy, SortOrder.desc);
                        Navigator.pop(context);
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // Sort Fields
            ...SortBy.values.map((s) {
              final isSelected = currentSortBy == s;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(
                  s.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? AppColors.primary : null,
                  ),
                ),
                trailing: isSelected
                    ? const Icon(CupertinoIcons.checkmark_alt, color: AppColors.primary, size: 18)
                    : null,
                onTap: () {
                  onSelected(s, currentOrder);
                  Navigator.pop(context);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderButton(
    BuildContext context, {
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.12)
              : (isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.primary : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
          ),
        ),
      ),
    );
  }
}

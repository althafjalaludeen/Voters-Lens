import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_typography.dart';

class SearchBarWidget extends StatefulWidget {
  final String? initialValue;
  final ValueChanged<String> onChanged;
  final VoidCallback onFilterTap;
  final VoidCallback onSortTap;
  final int activeFilterCount;

  const SearchBarWidget({
    super.key,
    this.initialValue,
    required this.onChanged,
    required this.onFilterTap,
    required this.onSortTap,
    this.activeFilterCount = 0,
  });

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChange(String val) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      widget.onChanged(val);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Search Input Box
          Expanded(
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? AppColors.borderDark : AppColors.borderLight,
                  width: 0.8,
                ),
              ),
              child: TextField(
                controller: _controller,
                onChanged: _onTextChange,
                style: TextStyle(
                  fontSize: 14,
                  fontFamilyFallback: AppTypography.fontFallbacks,
                  color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                ),
                decoration: InputDecoration(
                  hintText: 'Search voters by name, EPIC, house...',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    fontFamilyFallback: AppTypography.fontFallbacks,
                    color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                  ),
                  prefixIcon: Icon(
                    CupertinoIcons.search,
                    size: 18,
                    color: isDark ? AppColors.textTertiaryDark : AppColors.textSecondaryLight,
                  ),
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(CupertinoIcons.clear_circled_solid, size: 16),
                          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                          onPressed: () {
                            _controller.clear();
                            widget.onChanged('');
                            setState(() {});
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Sort Button
          Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? AppColors.borderDark : AppColors.borderLight,
                width: 0.8,
              ),
            ),
            child: IconButton(
              icon: const Icon(CupertinoIcons.arrow_up_arrow_down, size: 18),
              color: isDark ? AppColors.textSecondaryDark : AppColors.textPrimaryLight,
              onPressed: widget.onSortTap,
              tooltip: 'Sort Voters',
            ),
          ),
          const SizedBox(width: 8),

          // Filter Button with Badge
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 42,
                width: 42,
                decoration: BoxDecoration(
                  color: widget.activeFilterCount > 0
                      ? AppColors.primary.withValues(alpha: 0.12)
                      : (isDark ? AppColors.surfaceDark : AppColors.surfaceLight),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.activeFilterCount > 0
                        ? AppColors.primary
                        : (isDark ? AppColors.borderDark : AppColors.borderLight),
                    width: 0.8,
                  ),
                ),
                child: IconButton(
                  icon: Icon(
                    CupertinoIcons.slider_horizontal_3,
                    size: 18,
                    color: widget.activeFilterCount > 0
                        ? AppColors.primary
                        : (isDark ? AppColors.textSecondaryDark : AppColors.textPrimaryLight),
                  ),
                  onPressed: widget.onFilterTap,
                  tooltip: 'Filter Voters',
                ),
              ),
              if (widget.activeFilterCount > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '${widget.activeFilterCount}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

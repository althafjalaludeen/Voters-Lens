import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_typography.dart';
import '../providers/voter_providers.dart';
import '../widgets/status_badge.dart';
import 'voter_profile_screen.dart';

class HouseholdViewScreen extends ConsumerWidget {
  const HouseholdViewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final households = ref.watch(householdListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Household Grouping', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      ),
      body: Column(
        children: [
          // Informational Notice Banner (Section 23)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
            child: Row(
              children: [
                const Icon(CupertinoIcons.info_circle_fill, size: 14, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Grouped by normalized house number — organizational convenience only.',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Household List
          Expanded(
            child: households.isEmpty
                ? const Center(child: Text('No households found in the current selection.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: households.length,
                    itemBuilder: (context, index) {
                      final h = households[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
                        ),
                        child: ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          leading: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(CupertinoIcons.house_fill, size: 18, color: AppColors.primary),
                          ),
                          title: Text(
                            'House ${h.houseNumber.isNotEmpty ? h.houseNumber : "Unnumbered"}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFamilyFallback: AppTypography.fontFallbacks,
                              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                            ),
                          ),
                          subtitle: Text(
                            '${h.voterCount} resident voter${h.voterCount == 1 ? "" : "s"}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                          ),
                          children: h.voters.map((v) {
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                              leading: Text(
                                '#${v.serialNumber}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                                ),
                              ),
                              title: Text(
                                v.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  fontFamilyFallback: AppTypography.fontFallbacks,
                                ),
                              ),
                              subtitle: Text(
                                '${v.epicNumber} • Age ${v.age} • ${v.gender}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: StatusBadge(status: v.fieldStatus.status, compact: true),
                              onTap: () {
                                ref.read(selectedVoterIdProvider.notifier).state = v.id;
                                Navigator.push(
                                  context,
                                  CupertinoPageRoute(builder: (_) => VoterProfileScreen(voterId: v.id)),
                                );
                              },
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

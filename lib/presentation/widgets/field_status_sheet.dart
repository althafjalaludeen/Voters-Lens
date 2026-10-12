import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';
import '../../domain/entities/voter.dart';

class FieldStatusSheet extends StatefulWidget {
  final Voter voter;
  final void Function(FieldStatusType status, String? notes, String? phoneNumber) onSave;

  const FieldStatusSheet({
    super.key,
    required this.voter,
    required this.onSave,
  });

  static Future<void> show(
    BuildContext context, {
    required Voter voter,
    required void Function(FieldStatusType status, String? notes, String? phoneNumber) onSave,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FieldStatusSheet(voter: voter, onSave: onSave),
    );
  }

  @override
  State<FieldStatusSheet> createState() => _FieldStatusSheetState();
}

class _FieldStatusSheetState extends State<FieldStatusSheet> {
  late FieldStatusType _selectedStatus;
  late final TextEditingController _notesController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.voter.fieldStatus.status;
    _notesController = TextEditingController(text: widget.voter.fieldStatus.notes);
    _phoneController = TextEditingController(text: widget.voter.fieldStatus.phoneNumber);
  }

  @override
  void dispose() {
    _notesController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _onStatusTap(FieldStatusType status) {
    if (status == FieldStatusType.reportedDeceased) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(CupertinoIcons.exclamationmark_triangle_fill, color: AppColors.statusDeceased, size: 22),
              SizedBox(width: 8),
              Text('Confirm Status', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ],
          ),
          content: const Text(
            'Record this as a local field observation?\n\n'
            'This records an audited field observation for local coordination. '
            'It does NOT alter or delete the official statutory electoral roll record.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.statusDeceased,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                setState(() => _selectedStatus = status);
              },
              child: const Text('Record Deceased'),
            ),
          ],
        ),
      );
    } else {
      setState(() => _selectedStatus = status);
    }
  }

  void _submit() {
    widget.onSave(
      _selectedStatus,
      _notesController.text.trim().isNotEmpty ? _notesController.text.trim() : null,
      _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null,
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.82,
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Update Field Observation', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'For: ${widget.voter.name} (${widget.voter.epicNumber})',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                      ),
                    ),
                  ],
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

          // Body
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              children: [
                const Text('Field Status Observation', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),

                // Status Choices
                ...FieldStatusType.values.map((st) {
                  final isSelected = _selectedStatus == st;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? st.color.withValues(alpha: 0.1)
                          : (isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected ? st.color : (isDark ? AppColors.borderDark : AppColors.borderLight),
                        width: isSelected ? 1.2 : 0.8,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(st.icon, color: st.color, size: 20),
                      title: Text(
                        st.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                          color: isSelected ? st.color : null,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(CupertinoIcons.checkmark_circle_fill, color: st.color, size: 20)
                          : null,
                      onTap: () => _onStatusTap(st),
                    ),
                  );
                }),
                const SizedBox(height: 16),

                // Resident Phone Number
                const Text('Resident Contact Number', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
                  ),
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 9876543210 (Local Field Info Only)',
                      hintStyle: TextStyle(fontSize: 13),
                      border: InputBorder.none,
                      prefixIcon: Icon(CupertinoIcons.phone, size: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Observation Notes
                const Text('Field Observation Notes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
                  ),
                  child: TextField(
                    controller: _notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Relocated to Bangalore for employment; confirmed by neighbor.',
                      hintStyle: TextStyle(fontSize: 13),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),

          // Bottom Save Button
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
                  onPressed: _submit,
                  child: const Text('Save Field Observation', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

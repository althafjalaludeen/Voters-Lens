import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class VoterPhotoWidget extends StatelessWidget {
  final String? photoPath;
  final double size;
  final double borderRadius;

  const VoterPhotoWidget({
    super.key,
    this.photoPath,
    this.size = 54,
    this.borderRadius = 10,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasValidFile = photoPath != null &&
        photoPath!.isNotEmpty &&
        File(photoPath!).existsSync();

    if (hasValidFile) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.file(
          File(photoPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildPlaceholder(isDark),
        ),
      );
    }

    return _buildPlaceholder(isDark);
  }

  Widget _buildPlaceholder(bool isDark) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: isDark ? AppColors.borderDark : AppColors.borderLight,
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.person_fill,
            size: size * 0.42,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
          ),
          if (size >= 80) ...[
            const SizedBox(height: 4),
            Text(
              'PHOTO\nUNAVAILABLE',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                letterSpacing: 0.2,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

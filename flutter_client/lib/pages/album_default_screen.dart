import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AlbumDefaultScreen extends StatelessWidget {
  const AlbumDefaultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgWarm,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.album_outlined, size: 58, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              '碟片详情',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '从发现音乐页面选择一张专辑来查看详情',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

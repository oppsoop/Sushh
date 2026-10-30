import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_client.dart';
import 'models.dart';

class Downloads {
  static const _channel = MethodChannel('worldfriends/downloads');

  /// Fetches a fresh authorized URL and saves a copy to Android Downloads.
  static Future<void> save(ApiClient api, MediaItem media, {void Function(double)? onProgress}) async {
    if (!Platform.isAndroid) throw ApiException(400, 'unsupported', 'Downloads are supported on Android.');
    final android = await DeviceInfoPlugin().androidInfo;
    if (android.version.sdkInt < 29 && !(await Permission.storage.request()).isGranted) {
      throw ApiException(403, 'storage_permission', 'Allow storage access to save this file.');
    }
    final info = await api.get('/media/${media.id}/url');
    final url = info['url']?.toString() ?? '';
    if (url.isEmpty) throw ApiException(500, 'download_failed', 'Could not get a download link.');
    final name = (media.originalName ?? 'worldfriends-${media.id}').replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final directory = await getTemporaryDirectory();
    final temp = File(path.join(directory.path, 'download-${media.id}'));
    try {
      await api.downloadToFile(url, temp, onProgress: onProgress);
      await _channel.invokeMethod<String>('save', {
        'path': temp.path, 'name': name, 'mime': media.mime.isEmpty ? 'application/octet-stream' : media.mime,
      });
    } finally {
      try { await temp.delete(); } catch (_) {}
    }
  }
}

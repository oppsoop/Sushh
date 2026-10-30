import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class MediaViewerScreen extends StatelessWidget {
  const MediaViewerScreen({super.key, required this.media});

  final MediaItem media;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          media.originalName ?? (media.isVideo ? 'Video' : 'Photo'),
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: 'Report media',
            icon: const Icon(Icons.flag_outlined),
            onPressed: () async {
              try {
                await context.read<AppState>().api.post('/reports', body: {
                  'targetType': 'media',
                  'targetId': media.id,
                  'reason': 'nudity',
                });
                if (context.mounted) showSnack(context, 'Report sent');
              } catch (_) {
                if (context.mounted) showSnack(context, 'Could not send the report', error: true);
              }
            },
          ),
        ],
      ),
      body: Center(
        child: media.isVideo
            ? _VideoPlayerView(url: media.playableUrl)
            : InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Image.network(
                  media.playableUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, size: 48),
                ),
              ),
      ),
    );
  }
}

class _VideoPlayerView extends StatefulWidget {
  const _VideoPlayerView({required this.url});

  final String url;

  @override
  State<_VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<_VideoPlayerView> {
  late final VideoPlayerController _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _controller.setLooping(false);
      _controller.play();
    }).catchError((Object error) {
      if (mounted) setState(() => _error = 'This video could not be played');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Text(_error!, style: const TextStyle(color: Colors.white70));
    }
    if (!_ready) return const CircularProgressIndicator();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: GestureDetector(
            onTap: () => setState(() {
              _controller.value.isPlaying ? _controller.pause() : _controller.play();
            }),
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(_controller),
                if (!_controller.value.isPlaying)
                  const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
              ],
            ),
          ),
        ),
        VideoProgressIndicator(_controller, allowScrubbing: true, colors: const VideoProgressColors(playedColor: WfColors.accent)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: () => setState(() {
                _controller.value.isPlaying ? _controller.pause() : _controller.play();
              }),
            ),
            IconButton(
              icon: const Icon(Icons.replay),
              onPressed: () => _controller.seekTo(Duration.zero),
            ),
          ],
        ),
      ],
    );
  }
}

class LocalImageViewer extends StatelessWidget {
  const LocalImageViewer({super.key, required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(child: Image.file(file)),
    );
  }
}

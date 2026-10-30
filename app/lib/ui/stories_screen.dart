import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({super.key, required this.groups, this.initialGroupIndex = 0});

  final List<StoryGroup> groups;
  final int initialGroupIndex;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late int _groupIndex = widget.initialGroupIndex;
  int _storyIndex = 0;
  Timer? _autoAdvance;
  double _progress = 0;

  StoryGroup get _group => widget.groups[_groupIndex];
  Story? get _story => _group.stories.isEmpty ? null : _group.stories[_storyIndex];

  @override
  void initState() {
    super.initState();
    _startStory();
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    super.dispose();
  }

  void _startStory() {
    _autoAdvance?.cancel();
    _progress = 0;
    final story = _story;
    if (story == null) return;
    final app = context.read<AppState>();
    if (!story.viewed) {
      story.viewed = true;
      app.api.post('/stories/${story.id}/view').catchError((_) => <String, dynamic>{});
    }
    const duration = Duration(seconds: 6);
    const tick = Duration(milliseconds: 100);
    var elapsed = Duration.zero;
    _autoAdvance = Timer.periodic(tick, (timer) {
      if (!mounted) return;
      elapsed += tick;
      setState(() => _progress = elapsed.inMilliseconds / duration.inMilliseconds);
      if (elapsed >= duration) _next();
    });
  }

  void _next() {
    if (_storyIndex + 1 < _group.stories.length) {
      setState(() => _storyIndex += 1);
      _startStory();
    } else if (_groupIndex + 1 < widget.groups.length) {
      setState(() {
        _groupIndex += 1;
        _storyIndex = 0;
      });
      _startStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _previous() {
    if (_storyIndex > 0) {
      setState(() => _storyIndex -= 1);
    } else if (_groupIndex > 0) {
      setState(() {
        _groupIndex -= 1;
        _storyIndex = 0;
      });
    }
    _startStory();
  }

  @override
  Widget build(BuildContext context) {
    final story = _story;
    if (story == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (details) {
          final width = MediaQuery.of(context).size.width;
          if (details.localPosition.dx < width * 0.3) {
            _previous();
          } else {
            _next();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (story.media?.isImage == true)
              Image.network(story.media!.playableUrl, fit: BoxFit.contain)
            else if (story.media != null)
              Container(
                color: Colors.black,
                child: const Center(child: Icon(Icons.videocam, size: 64, color: Colors.white24)),
              )
            else
              Container(color: WfColors.primaryDark),
            if (story.caption.isNotEmpty)
              Align(
                alignment: story.media == null ? Alignment.center : Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    story.caption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      children: [
                        for (var i = 0; i < _group.stories.length; i += 1)
                          Expanded(
                            child: Container(
                              height: 3,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: i < _storyIndex
                                    ? Colors.white
                                    : i == _storyIndex
                                        ? Colors.white.withOpacity(0.35 + _progress * 0.65)
                                        : Colors.white24,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Avatar(url: _group.user.avatarUrl, name: _group.user.label, size: 34),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_group.user.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(
                                timeAgo(story.createdAt),
                                style: const TextStyle(fontSize: 11, color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StoryComposerScreen extends StatefulWidget {
  const StoryComposerScreen({super.key});

  @override
  State<StoryComposerScreen> createState() => _StoryComposerScreenState();
}

class _StoryComposerScreenState extends State<StoryComposerScreen> {
  final _caption = TextEditingController();
  File? _image;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 1600);
    if (picked == null) return;
    setState(() => _image = File(picked.path));
  }

  Future<void> _publish() async {
    final app = context.read<AppState>();
    if (_image == null && _caption.text.trim().isEmpty) {
      setState(() => _error = 'Add a photo or write something');
      return;
    }
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      String? mediaId;
      if (_image != null) {
        final uploaded = await app.api.uploadFile(
          file: _image!,
          mimeType: 'image/jpeg',
          fields: {'kind': 'image'},
        );
        mediaId = (uploaded['media'] as Map<String, dynamic>?)?['id']?.toString();
      }
      await app.api.post('/stories', body: {
        if (mediaId != null) 'mediaId': mediaId,
        if (_caption.text.trim().isNotEmpty) 'caption': _caption.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      setState(() => _error = error.friendly);
    } catch (_) {
      setState(() => _error = 'Could not publish your story.');
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New story'),
        actions: [
          TextButton(
            onPressed: _posting ? null : _publish,
            child: _posting
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Share'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ErrorText(message: _error),
              Expanded(
                child: GestureDetector(
                  onTap: _pick,
                  child: Container(
                    decoration: BoxDecoration(
                      color: WfColors.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _image == null
                        ? const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_photo_alternate_outlined, size: 46, color: WfColors.textMuted),
                                SizedBox(height: 8),
                                Text('Tap to choose a photo', style: TextStyle(color: WfColors.textMuted)),
                              ],
                            ),
                          )
                        : Image.file(_image!, fit: BoxFit.cover),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _caption,
                maxLength: 200,
                decoration: const InputDecoration(hintText: 'Add a caption…', counterText: ''),
              ),
              const SizedBox(height: 4),
              const Text(
                'Stories disappear after 24 hours.',
                style: TextStyle(fontSize: 11, color: WfColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../core/call_service.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen audio/video call UI, driven by [CallService].
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.callId,
    required this.peer,
    required this.kind,
    this.outgoing = false,
  });

  final String callId;
  final FriendUser peer;
  final String kind;
  final bool outgoing;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final AppState _app = context.read<AppState>();
  bool _started = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_started) return;
      _started = true;
      final calls = _app.calls;
      if (widget.outgoing) {
        await calls.startCall(target: widget.peer, callKind: widget.kind, id: widget.callId);
      } else if (calls.state == CallState.ringing) {
        // handled by the caller with the accept button
      }
    });
  }

  Future<void> _hangup() async {
    if (_closing) return;
    _closing = true;
    await _app.calls.hangup();
    _app.calls.reset();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<CallService>();
    final isVideo = calls.kind == 'video';
    final state = calls.state;
    final peer = calls.peer ?? widget.peer;

    final statusText = switch (state) {
      CallState.dialing => 'Calling…',
      CallState.ringing => 'Incoming call',
      CallState.connecting => 'Connecting…',
      CallState.active => CallService.formatDuration(calls.elapsed),
      CallState.ended => 'Call ended',
      CallState.failed => calls.errorMessage ?? 'Call failed',
      CallState.idle => 'Call ended',
    };

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (isVideo && state == CallState.active)
              Positioned.fill(
                child: RTCVideoView(
                  calls.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF16233B), Color(0xFF0B1220)],
                    ),
                  ),
                ),
              ),
            if (!isVideo || state != CallState.active)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Avatar(url: peer.avatarUrl, name: peer.label, size: 118),
                    const SizedBox(height: 18),
                    Text(
                      peer.label,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(statusText, style: const TextStyle(fontSize: 14, color: WfColors.textMuted)),
                    if (state == CallState.dialing || state == CallState.ringing) ...[
                      const SizedBox(height: 20),
                      const _Pulse(),
                    ],
                  ],
                ),
              ),
            if (isVideo && state == CallState.active)
              Positioned(
                top: 68,
                right: 16,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 104,
                    height: 150,
                    child: ColoredBox(
                      color: Colors.black54,
                      child: RTCVideoView(
                        calls.localRenderer,
                        mirror: calls.frontCamera,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),
                  ),
                ),
              ),
            if (isVideo && state == CallState.active)
              Positioned(
                top: 16,
                left: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(peer.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(statusText, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: _Controls(
                  calls: calls,
                  isVideo: isVideo,
                  incoming: state == CallState.ringing,
                  onHangup: _hangup,
                ),
              ),
            ),
            if (state == CallState.failed || state == CallState.ended)
              Align(
                alignment: const Alignment(0, 0.55),
                child: TextButton(
                  onPressed: _hangup,
                  child: const Text('Back to chat'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.calls,
    required this.isVideo,
    required this.incoming,
    required this.onHangup,
  });

  final CallService calls;
  final bool isVideo;
  final bool incoming;
  final Future<void> Function() onHangup;

  @override
  Widget build(BuildContext context) {
    if (incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(
            icon: Icons.call_end,
            color: WfColors.danger,
            label: 'Decline',
            onTap: () async {
              await calls.declineCall();
              if (context.mounted) Navigator.of(context).maybePop();
            },
          ),
          _RoundButton(
            icon: Icons.call,
            color: WfColors.accent,
            label: 'Accept',
            onTap: () => calls.acceptCall(),
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(
          icon: calls.muted ? Icons.mic_off : Icons.mic,
          label: calls.muted ? 'Unmute' : 'Mute',
          onTap: () => calls.toggleMute(),
        ),
        _RoundButton(
          icon: calls.speakerOn ? Icons.volume_up : Icons.volume_off,
          label: 'Speaker',
          onTap: () => calls.toggleSpeaker(),
        ),
        if (isVideo) ...[
          _RoundButton(
            icon: calls.frontCamera ? Icons.cameraswitch : Icons.cameraswitch_outlined,
            label: 'Flip',
            onTap: () => calls.switchCamera(),
          ),
          _RoundButton(
            icon: calls.videoEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Camera',
            onTap: () => calls.toggleVideo(),
          ),
        ],
        _RoundButton(
          icon: Icons.call_end,
          color: WfColors.danger,
          label: 'End',
          onTap: onHangup,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(color: color ?? Colors.white12, shape: BoxShape.circle),
            child: Icon(icon, size: 26, color: Colors.white),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
      ],
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        width: 70 + 40 * _controller.value,
        height: 70 + 40 * _controller.value,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: WfColors.primary.withOpacity(0.5 * (1 - _controller.value)), width: 2),
        ),
      ),
    );
  }
}

/// Small banner shown inside the chat list when a call is ringing.
class IncomingCallBanner extends StatelessWidget {
  const IncomingCallBanner({super.key, required this.calls, required this.onOpen});

  final CallService calls;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final peer = calls.peer;
    if (calls.state != CallState.ringing || peer == null) return const SizedBox.shrink();
    return Material(
      color: WfColors.accent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.call, size: 18, color: Colors.black),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${peer.label} is calling',
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => calls.declineCall(),
                child: const Text('Decline', style: TextStyle(color: Colors.black87)),
              ),
              TextButton(onPressed: onOpen, child: const Text('Answer', style: TextStyle(color: Colors.black))),
            ],
          ),
        ),
      ),
    );
  }
}

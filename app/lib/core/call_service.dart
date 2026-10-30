import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'models.dart';

enum CallState { idle, dialing, ringing, connecting, active, ended, failed }

/// Audio/video calling over WebRTC.
///
/// Signalling travels over the app's existing websocket (call:invite,
/// call:answer, call:ice, call:reject, call:end). Media is peer-to-peer with a
/// public STUN server; no TURN relay is configured for the beta, so calls work
/// on normal mobile/Wi-Fi networks (symmetric-NAT-only callers may need a TURN
/// server - documented in docs/DEPLOYMENT.md).
class CallService extends ChangeNotifier {
  CallService({required this.sendSignal, required this.iceServersProvider});

  /// Sends a signalling frame over the websocket.
  final void Function(Map<String, dynamic> payload) sendSignal;
  final Future<List<dynamic>> Function() iceServersProvider;
  bool _canSendLocalIce = false;
  final List<Map<String, dynamic>> _queuedLocalIce = [];

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  final List<RTCIceCandidate> _pendingCandidates = [];

  CallState state = CallState.idle;
  String? callId;
  String kind = 'audio';
  FriendUser? peer;
  bool muted = false;
  bool speakerOn = false;
  bool videoEnabled = true;
  bool frontCamera = true;
  String? errorMessage;
  DateTime? startedAt;
  Duration elapsed = Duration.zero;
  Timer? _ticker;

  bool get isBusy => state == CallState.dialing || state == CallState.ringing || state == CallState.active || state == CallState.connecting;
  bool get isVideo => kind == 'video';

  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  Future<void> _ensureRenderers() async {
    if (localRenderer.srcObject == null) {
      try {
        await localRenderer.initialize();
      } catch (_) {}
    }
    if (remoteRenderer.srcObject == null) {
      try {
        await remoteRenderer.initialize();
      } catch (_) {}
    }
  }

  Future<void> _preparePeer() async {
    await _ensureRenderers();
    var iceConfig = _iceConfig;
    try {
      final servers = await iceServersProvider();
      if (servers.isNotEmpty) iceConfig = {..._iceConfig, 'iceServers': servers};
    } catch (_) {}
    _peer = await createPeerConnection(iceConfig);
    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      final frame = <String, dynamic>{
        'type': 'call:ice', 'callId': callId, 'toUserId': peer?.id, 'candidate': candidate.toMap(),
      };
      if (_canSendLocalIce) {
        sendSignal(frame);
      } else {
        _queuedLocalIce.add(frame);
      }
    };
    _peer!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };
    _peer!.onConnectionState = (connectionState) {
      if (connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state = CallState.active;
        startedAt ??= DateTime.now();
        _startTicker();
        notifyListeners();
      } else if (connectionState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail('Connection lost');
      }
    };
  }

  Future<MediaStream?> _getUserMedia({required bool video}) async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
              }
            : false,
      });
      _localStream = stream;
      localRenderer.srcObject = stream;
      return stream;
    } catch (error) {
      _fail('Could not access ${video ? 'camera or microphone' : 'microphone'}. Check app permissions.');
      return null;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = startedAt;
      if (start != null) {
        elapsed = DateTime.now().difference(start);
        notifyListeners();
      }
    });
  }

  Future<void> _fail(String message) async {
    if (callId != null && peer != null) {
      sendSignal({'type': 'call:end', 'callId': callId, 'toUserId': peer?.id, 'reason': 'failed'});
    }
    await _cleanup();
    errorMessage = message;
    state = CallState.failed;
    notifyListeners();
  }

  Future<void> handleCallFailed() => _fail('Call could not be connected.');

  /* ------------------------------ outgoing ------------------------------ */

  Future<void> startCall({
    required FriendUser target,
    required String callKind,
    required String id,
  }) async {
    if (isBusy) return;
    peer = target;
    kind = callKind;
    callId = id;
    state = CallState.dialing;
    errorMessage = null;
    elapsed = Duration.zero;
    notifyListeners();

    _canSendLocalIce = false;
    await _preparePeer();
    final stream = await _getUserMedia(video: callKind == 'video');
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await _peer!.addTrack(track, stream);
    }
    final offer = await _peer!.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': callKind == 'video'});
    await _peer!.setLocalDescription(offer);
    sendSignal({
      'type': 'call:invite',
      'callId': id,
      'toUserId': target.id,
      'kind': callKind,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });
    _canSendLocalIce = true;
    for (final frame in _queuedLocalIce) { sendSignal(frame); }
    _queuedLocalIce.clear();
    state = CallState.dialing;
    notifyListeners();
  }

  /* ------------------------------ incoming ------------------------------ */

  Future<void> handleIncoming(Map<String, dynamic> event) async {
    if (isBusy && callId == event['callId']) return;
    if (isBusy) {
      // Already on a call: politely decline the second one.
      sendSignal({'type': 'call:reject', 'callId': event['callId'], 'toUserId': (event['from'] as Map?)?['id']});
      return;
    }
    final fromJson = event['from'];
    peer = fromJson is Map<String, dynamic> ? FriendUser.fromJson(fromJson) : null;
    callId = (event['callId'] ?? '').toString();
    kind = (event['kind'] ?? 'audio').toString();
    state = CallState.ringing;
    errorMessage = null;
    notifyListeners();

    // Remember the offer; the peer connection is created once accepted.
    _pendingOffer = event['sdp'] is Map<String, dynamic> ? event['sdp'] as Map<String, dynamic> : null;
  }

  Map<String, dynamic>? _pendingOffer;

  Future<void> acceptCall() async {
    final offer = _pendingOffer;
    if (offer == null || callId == null) return;
    state = CallState.connecting;
    notifyListeners();

    _canSendLocalIce = true;
    await _preparePeer();
    final stream = await _getUserMedia(video: isVideo);
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await _peer!.addTrack(track, stream);
    }
    await _peer!.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?));
    await _drainCandidates();
    final answer = await _peer!.createAnswer();
    await _peer!.setLocalDescription(answer);
    sendSignal({
      'type': 'call:answer',
      'callId': callId,
      'toUserId': peer?.id,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });
    notifyListeners();
  }

  Future<void> declineCall() async {
    sendSignal({'type': 'call:reject', 'callId': callId, 'toUserId': peer?.id});
    await _cleanup();
    state = CallState.ended;
    notifyListeners();
  }

  /* ------------------------------ signalling in ------------------------------ */

  Future<void> handleAnswer(Map<String, dynamic> event) async {
    final sdp = event['sdp'];
    if (_peer == null || sdp is! Map) return;
    try {
      await _peer!.setRemoteDescription(
        RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
      );
      await _drainCandidates();
      state = CallState.connecting;
      notifyListeners();
    } catch (error) {
      _fail('Could not connect the call');
    }
  }

  Future<void> handleRemoteIce(Map<String, dynamic> event) async {
    final candidate = event['candidate'];
    if (candidate is! Map) return;
    final ice = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    );
    final remoteDescription = _peer == null ? null : await _peer!.getRemoteDescription();
    if (_peer == null || remoteDescription == null) {
      _pendingCandidates.add(ice);
      return;
    }
    try {
      await _peer!.addCandidate(ice);
    } catch (_) {
      _pendingCandidates.add(ice);
    }
  }

  Future<void> _drainCandidates() async {
    for (final candidate in List<RTCIceCandidate>.from(_pendingCandidates)) {
      try {
        await _peer?.addCandidate(candidate);
      } catch (_) {}
    }
    _pendingCandidates.clear();
  }

  Future<void> handleRemoteEnd({bool remoteRejected = false}) async {
    if (!isBusy) return;
    await _cleanup();
    state = CallState.ended;
    errorMessage = remoteRejected ? 'Call declined' : null;
    notifyListeners();
  }

  /* ------------------------------ controls ------------------------------ */

  Future<void> toggleMute() async {
    muted = !muted;
    final tracks = _localStream?.getAudioTracks() ?? [];
    for (final track in tracks) {
      track.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggleVideo() async {
    if (!isVideo) return;
    videoEnabled = !videoEnabled;
    final tracks = _localStream?.getVideoTracks() ?? [];
    for (final track in tracks) {
      track.enabled = videoEnabled;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (!isVideo) return;
    try {
      final tracks = _localStream?.getVideoTracks() ?? [];
      if (tracks.isNotEmpty) {
        await Helper.switchCamera(tracks.first);
        frontCamera = !frontCamera;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> hangup({bool notifyPeer = true}) async {
    if (notifyPeer && callId != null && peer != null) {
      sendSignal({'type': 'call:end', 'callId': callId, 'toUserId': peer?.id, 'reason': 'hangup'});
    }
    await _cleanup();
    state = CallState.ended;
    notifyListeners();
  }

  Future<void> _cleanup() async {
    _ticker?.cancel();
    _ticker = null;
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    try {
      await _peer?.close();
    } catch (_) {}
    _peer = null;
    _pendingCandidates.clear();
    _queuedLocalIce.clear();
    _canSendLocalIce = false;
    _pendingOffer = null;
    startedAt = null;
  }

  /// Resets back to idle when the call screen is dismissed.
  void reset() {
    callId = null;
    peer = null;
    state = CallState.idle;
    elapsed = Duration.zero;
    errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _cleanup();
    try {
      localRenderer.dispose();
      remoteRenderer.dispose();
    } catch (_) {}
    super.dispose();
  }

  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }
}

import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';

import '../source/playable.dart';

/// 包装 media_kit Player，不感知源类型。
class PlaybackController {
  final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);

  VideoController get videoController => _videoController;

  Stream<Duration> get position => _player.stream.position;
  Stream<Duration> get duration => _player.stream.duration;
  Stream<bool> get buffering => _player.stream.buffering;
  Stream<bool> get playing => _player.stream.playing;

  /// 播放错误流，供 §6 错误处理（swarm 断流/停滞上报）后续接入。
  Stream<String> get error => _player.stream.error;

  /// 音轨/字幕轨/视频轨列表，供枚举与选择。
  Stream<Tracks> get tracks => _player.stream.tracks;

  Future<void> open(Playable p) async {
    // 自定义 header 透传给 libmpv 的 http-header-fields。
    // 注：Playable.subtitles 的外挂字幕注入留后续里程碑，M1/M2 两个 Provider 均不填充该字段。
    await _player.open(
      Media(p.url.toString(), httpHeaders: p.headers),
      play: true,
    );
  }

  Future<void> playOrPause() => _player.playOrPause();
  Future<void> seek(Duration to) => _player.seek(to);

  Future<void> dispose() async {
    await _player.dispose();
  }
}

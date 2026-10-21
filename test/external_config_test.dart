import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/config/config_store.dart';
import 'package:pp_friend/src/config/external_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/settings_page.dart';

import 'support/avatar_fakes.dart';
import 'support/test_app.dart';
import 'support/voice_fakes.dart';

/// 测试里那份"手机上写的配置文件"长什么样。
String _fileBody({
  Object? baseUrl = 'https://pp1.example',
  Object? brainId = 'codex',
  Object? token = 'dummy-token',
}) => jsonEncode({
  'base_url': baseUrl,
  'brain_id': brainId,
  'token': ?token,
});

/// 一个不碰磁盘的假读取：直接返回给定的内容（或"文件不在"）。
ExternalConfigReader _reader(String? raw) => () async =>
    raw == null
        ? const ExternalConfigRead.absent()
        : parseExternalConfig(raw);

AssistantConfig _twoProfiles() => const AssistantConfig(
  profiles: [
    Profile(
      id: 'p_a',
      name: 'A',
      brain: BrainConfig(baseUrl: 'http://本地:8000', brainId: '本地-a'),
    ),
    Profile(
      id: 'p_b',
      name: 'B',
      brain: BrainConfig(baseUrl: 'http://别的:8000', brainId: '本地-b'),
    ),
  ],
  focusedProfileId: 'p_a',
);

/// 造一个启动路径和真机一样的 controller：走 `loadConfig`（不是直接
/// `updateConfig`），所以能验到"启动时导入"这件事本身。
Future<ConversationController> _boot(
  ExternalConfigReader reader, {
  bool seedLocalConfig = true,
}) async {
  // 先落下"上次运行存过的配置"，`loadConfig` 会把它读回来 —— 这也是
  // "App 里已经有配置"的那种常见情形。
  if (seedLocalConfig) await ConfigStore().save(_twoProfiles());

  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    // 这些用例一个请求都不该发；真发了就当场炸，而不是静默走网络。
    brainFactory: () => BrainClient(
      client: MockClient((_) async => throw StateError('不该发请求')),
    ),
    history: MemoryMessageStore(),
    avatars: FakeAvatarStore(),
    externalConfig: reader,
    segmenterFactory: ({
      required int sampleRate,
      required AssistantConfig config,
    }) async => FakeSegmenter(),
  );
  await controller.loadConfig();
  return controller;
}

/// 把编辑区滚到目标出现为止。
///
/// 编辑区是个 ListView，屏幕外的项根本不在树里 —— 不滚过去就 `findsNothing`。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  final list = find.byType(ListView).last;
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('解析配置文件', () {
    test('三个值都能读出来', () {
      final read = parseExternalConfig(_fileBody());

      expect(read.found, isTrue);
      expect(read.problem, isNull);
      expect(read.brain!.baseUrl, 'https://pp1.example');
      expect(read.brain!.brainId, 'codex');
      expect(read.brain!.token, 'dummy-token');
    });

    test('token 可以不写：留空表示这个部署没开鉴权', () {
      final read = parseExternalConfig(_fileBody(token: null));

      expect(read.found, isTrue, reason: 'token 是可选字段，不该因此整份作废');
      expect(read.brain!.token, '');
    });

    test('首尾空白会被去掉', () {
      final read = parseExternalConfig(
        _fileBody(baseUrl: '  https://pp1.example  ', brainId: ' codex '),
      );

      expect(read.brain!.baseUrl, 'https://pp1.example');
      expect(read.brain!.brainId, 'codex');
    });

    test('不是合法 JSON：给出原因，不抛', () {
      final read = parseExternalConfig('{ 这不是 json');

      expect(read.found, isFalse);
      expect(read.problem, contains('JSON 解析失败'));
    });

    test('顶层不是对象：给出原因，不抛', () {
      final read = parseExternalConfig('[1, 2, 3]');

      expect(read.found, isFalse);
      expect(read.problem, contains('顶层不是对象'));
    });

    test('缺 base_url 当错误，而不是解析成空地址', () {
      // 老实解析成空串的话，会拿一份空配置把用户手填好的地址盖掉 ——
      // 那比不读这个文件还糟。
      final read = parseExternalConfig(jsonEncode({'brain_id': 'codex'}));

      expect(read.found, isFalse);
      expect(read.problem, contains('base_url'));
    });

    test('字段类型不对：给出原因，不抛', () {
      final read = parseExternalConfig(_fileBody(baseUrl: 123));

      expect(read.found, isFalse);
      expect(read.problem, contains('base_url'));
    });
  });

  group('读固定路径', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pp-friend-config-');
    });
    tearDown(() => dir.delete(recursive: true));

    test('文件不在 → 不算错误', () async {
      final read = await readExternalConfig(resolveDir: () async => dir);

      expect(read.found, isFalse);
      expect(read.problem, isNull, reason: '没放文件是最常见的情况，不该报警');
    });

    test('拿不到外部目录（非 Android、没有平台通道）→ 也不算错误', () async {
      final read = await readExternalConfig(resolveDir: () async => null);

      expect(read.found, isFalse);
      expect(read.problem, isNull);
    });

    test('文件在 → 读到', () async {
      File(
        '${dir.path}/$externalConfigFileName',
      ).writeAsStringSync(_fileBody());

      final read = await readExternalConfig(resolveDir: () async => dir);

      expect(read.brain!.brainId, 'codex');
    });

    test('文件不是 UTF-8（比如从 PC 拷来的 GBK）→ 不抛，回落并给出原因', () async {
      // 读文件这条路会抛的不止权限一种：`readAsString` 遇到非法字节同样会
      // 抛（dart:io 把它包成 FileSystemException）。这里抛出去就会掀到
      // loadConfig，把整个启动拖垮 —— 而它只是"文件存错编码"。
      File(
        '${dir.path}/$externalConfigFileName',
      ).writeAsBytesSync([0x7b, 0xc4, 0xe3, 0xba, 0xc3, 0x7d]);

      final read = await readExternalConfig(resolveDir: () async => dir);

      expect(read.found, isFalse);
      // 只要求"有个原因"，不钉死 SDK 的措辞
      expect(read.problem, isNotNull);
      expect(read.problem, isNotEmpty);
    });
  });

  group('启动时导入', () {
    test('文件合法 → 覆盖聚焦档案并落盘，别的档案不动', () async {
      final controller = await _boot(_reader(_fileBody()));
      addTearDown(controller.dispose);

      expect(controller.config.brain.baseUrl, 'https://pp1.example');
      expect(controller.config.brain.brainId, 'codex');
      expect(controller.config.brain.token, 'dummy-token');
      expect(controller.externalConfigProblem, isNull);

      // 别的档案是"另一套部署"，不该被这份文件带走
      final other = controller.config.profiles.firstWhere(
        (p) => p.id == 'p_b',
      );
      expect(other.brain.baseUrl, 'http://别的:8000');
      expect(other.brain.brainId, '本地-b');

      // "并保存"：换一个 store 从同一份盘上读回来，值是文件里的
      final reloaded = await ConfigStore().load();
      expect(reloaded.focusedProfileId, 'p_a');
      expect(
        reloaded.brain.baseUrl,
        'https://pp1.example',
        reason: '没落盘的话，下次启动还得靠文件；文件一挪走就回到旧地址了',
      );
    });

    test('文件不在 → 用本地已保存的配置', () async {
      final controller = await _boot(_reader(null));
      addTearDown(controller.dispose);

      expect(controller.config.brain.baseUrl, 'http://本地:8000');
      expect(controller.config.brain.brainId, '本地-a');
      expect(controller.externalConfigProblem, isNull);
    });

    test('文件是坏 JSON → 不崩、安静回落，并记下原因', () async {
      final controller = await _boot(_reader('{ 这不是 json'));
      addTearDown(controller.dispose);

      expect(controller.config.brain.baseUrl, 'http://本地:8000');
      expect(controller.externalConfigProblem, contains('JSON 解析失败'));
    });

    test('文件读不动（IO 错）→ 回落，并记下原因', () async {
      final controller = await _boot(
        () async => const ExternalConfigRead.broken('Permission denied'),
      );
      addTearDown(controller.dispose);

      expect(controller.config.brain.brainId, '本地-a');
      expect(controller.externalConfigProblem, 'Permission denied');
    });

    test('本地一份配置都没有（比如刚装好）→ 先补一个档案，再填进去', () async {
      final controller = await _boot(_reader(_fileBody()), seedLocalConfig: false);
      addTearDown(controller.dispose);

      expect(
        controller.config.focusedProfile,
        isNotNull,
        reason: '`normalized()` 补出来的那个档案得先存在，地址才有地方放',
      );
      expect(controller.config.brain.baseUrl, 'https://pp1.example');
      expect(controller.config.profiles.length, 1);
    });
  });

  group('界面', () {
    testWidgets('读不出来时，配置页顶部有一条小字（不拦住任何操作）', (tester) async {
      final controller = await _boot(_reader('{ 这不是 json'));
      addTearDown(controller.dispose);

      await tester.pumpWidget(testApp(SettingsPage(controller: controller)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('配置文件读不出来：'), findsOneWidget);
      // 页面照常用：三个输入框还在，能改能保存
      expect(find.byType(TextField), findsWidgets);
    });

    testWidgets('一切正常时页面顶部不多任何东西', (tester) async {
      final controller = await _boot(_reader(null));
      addTearDown(controller.dispose);

      await tester.pumpWidget(testApp(SettingsPage(controller: controller)));
      await tester.pumpAndSettle();

      expect(find.textContaining('配置文件读不出来：'), findsNothing);
    });

    testWidgets('Brain 段下面写着那个固定路径', (tester) async {
      final controller = await _boot(_reader(null));
      addTearDown(controller.dispose);

      await tester.pumpWidget(testApp(SettingsPage(controller: controller)));
      await tester.pumpAndSettle();

      // 文案里得报出完整路径，不然用户不知道该把文件放哪儿
      await _scrollTo(tester, find.textContaining(externalConfigFileName));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'brain_config.dart';

/// 固定配置文件的名字。**手机上的说明文案里写着这个路径**，
/// 改这里就要同时改三份 l10n 的 `externalConfigHint`。
const String externalConfigFileName = 'pp-friend-config.json';

/// 读固定外部配置文件的那一下。
///
/// 抽成类型是为了让 `flutter test` 能注入一个不碰磁盘的假实现 ——
/// `testWidgets` 把测试体跑在假时钟里，真实的文件 IO 在那里永远不会完成。
typedef ExternalConfigReader = Future<ExternalConfigRead> Function();

/// 拿 App 的外部目录（Android 上就是 `Android/data/<包名>/files`）。
typedef ExternalDirResolver = Future<Directory?> Function();

/// 读固定配置文件的结果，三种：读到了、文件不在、读不出来。
///
/// 做成一个类型而不是"返回配置或者抛异常"，是为了让调用方一眼看出
/// **"文件不在"不是错误**：绝大多数人就是在设置页里手填的，盘上没有这个
/// 文件，那种情况下界面上不该留下任何痕迹。
class ExternalConfigRead {
  const ExternalConfigRead({this.brain, this.problem});

  /// 文件不在，或者这个环境根本没有外部目录。
  const ExternalConfigRead.absent() : brain = null, problem = null;

  /// 文件在，但用不了。[problem] 是给人看的原因，会被原样拼进界面提示里。
  const ExternalConfigRead.broken(this.problem) : brain = null;

  /// 解析出来的配置。文件不在或者读不出来时是 null。
  final BrainConfig? brain;

  /// 读不出来的原因。一切正常时是 null。
  final String? problem;

  bool get found => brain != null;
}

/// 默认实现：App 自己的外部目录下的 [externalConfigFileName]。
///
/// 只读这一个固定路径，**不做任何目录扫描** —— 用户知道文件放哪儿，
/// 随便扫会把这个"约定"变成一堆猜不透的优先级规则。
Future<ExternalConfigRead> readExternalConfig({
  ExternalDirResolver resolveDir = resolveExternalDir,
}) async {
  final dir = await resolveDir();
  if (dir == null) return const ExternalConfigRead.absent();

  try {
    final file = File('${dir.path}/$externalConfigFileName');
    if (!await file.exists()) return const ExternalConfigRead.absent();
    return parseExternalConfig(await file.readAsString());
  } catch (e) {
    // 文件在、但读不动：权限不对、卡坏了、半截写入。
    // **这里故意什么都兜住**，因为这条路跑在启动路径上：漏出去会掀掉整个
    // `loadConfig`，而它最坏也就是"一份可选文件读不出来"。
    //
    // 兜的种类不止一种：权限是 `FileSystemException`；文件里不是 UTF-8
    // （从 PC 拷一份 GBK 的过来就会这样）时，dart:io 把解码失败也包装成
    // `FileSystemException` 抛出来。所以一个 catch 就够了，别按类型去分。
    return ExternalConfigRead.broken('$e');
  }
}

/// 解析配置文件的内容。
///
/// 键名是 snake_case（`base_url` / `brain_id` / `token`）：这是一份给手写、
/// 给脚本生成的文件，不是 App 内部那份配置（那份是 camelCase），两边故意
/// 不共用键名 —— 免得有人以为能拿内部那份文件去喂它。
///
/// **缺 `base_url` / `brain_id` 当错误。** 这两个是"连哪儿、跟谁说话"，
/// 缺了就等于没配；老实解析成空串的话，会拿一份空配置把用户手填好的地址
/// 盖掉 —— 那比不读这个文件还糟。`token` 允许缺、允许空（部署没开鉴权时
/// 就是这样）。
ExternalConfigRead parseExternalConfig(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    return ExternalConfigRead.broken('JSON 解析失败：${e.message}');
  }
  if (decoded is! Map) return const ExternalConfigRead.broken('JSON 顶层不是对象');

  final baseUrl = _text(decoded['base_url']);
  if (baseUrl == null || baseUrl.isEmpty) {
    return const ExternalConfigRead.broken('base_url 缺失或不是非空字符串');
  }
  final brainId = _text(decoded['brain_id']);
  if (brainId == null || brainId.isEmpty) {
    return const ExternalConfigRead.broken('brain_id 缺失或不是非空字符串');
  }
  // token 可以不写；写了就必须是字符串，不然用户以为鉴权配好了其实没配上。
  final token = decoded.containsKey('token') ? _text(decoded['token']) : '';
  if (token == null) return const ExternalConfigRead.broken('token 不是字符串');

  return ExternalConfigRead(
    brain: BrainConfig(baseUrl: baseUrl, brainId: brainId, token: token),
  );
}

/// 是字符串就返回去掉首尾空白的它，否则 null（"字段不在"也走这一条）。
String? _text(Object? value) => value is String ? value.trim() : null;

/// 拿 App 的外部目录。**失败返回 null，不抛。**
///
/// 非 Android 平台、`flutter test` 里没有平台通道、用户把外部存储摘了 ——
/// 都会走到这里。这些都不是"配置文件有问题"，只是"这里没有那份文件"。
Future<Directory?> resolveExternalDir() async {
  try {
    return await getExternalStorageDirectory();
  } catch (_) {
    return null;
  }
}

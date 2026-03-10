import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final packageName = input.packageName;
    final nativeDir = input.packageRoot.resolve('native/linux/x86_64/');

    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: 'src/native_lib.dart',
        linkMode: DynamicLoadingBundled(),
        file: nativeDir.resolve('libzenoh_dart.so'),
      ),
    );

    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: 'src/libzenohc.dart',
        linkMode: DynamicLoadingBundled(),
        file: nativeDir.resolve('libzenohc.so'),
      ),
    );
  });
}

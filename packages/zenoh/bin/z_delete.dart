import 'package:args/args.dart';
import 'package:zenoh/zenoh.dart';

const defaultKey = 'demo/example/zenoh-dart-put';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help')
    ..addOption(
      'key',
      abbr: 'k',
      defaultsTo: defaultKey,
      help: 'The key expression to delete',
    );

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    print(e.message);
    print('Usage: z_delete [OPTIONS]');
    print(parser.usage);
    return;
  }

  if (args.flag('help')) {
    print('Usage: z_delete [OPTIONS]');
    print(parser.usage);
    return;
  }

  final key = args.option('key')!;

  print('Opening session...');
  final session = Session.open();

  print("Deleting resource '$key'...");
  session.delete(key);

  session.close();
}

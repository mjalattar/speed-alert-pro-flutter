import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Loads [dotenv] from optional local [assets/env/.env] merged with committed [assets/env/env.example].
/// Local keys win on duplicates (local block is parsed first).
Future<void> loadAppEnv() async {
  final sb = StringBuffer();
  try {
    sb.writeln(await rootBundle.loadString('assets/env/.env'));
  } catch (_) {}
  sb.writeln(await rootBundle.loadString('assets/env/env.example'));
  dotenv.loadFromString(envString: sb.toString(), isOptional: true);
}

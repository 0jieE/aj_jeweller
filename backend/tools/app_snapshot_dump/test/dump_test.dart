import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:davao_aj_jewellers/core/data/app_repository.dart';

void main() {
  test('dump the demo snapshot', () {
    final repo = AppRepository();
    final out = Platform.environment['SNAPSHOT_OUT']!;
    File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(repo.toSnapshot()));
  });
}

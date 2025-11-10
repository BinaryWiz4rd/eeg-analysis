import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soloproject/main.dart';

void main() {
  testWidgets('EEG Analyzer app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EEGAnalyzerApp());

    expect(find.text('EEG Signal Analysis'), findsOneWidget);

    expect(find.text('Raw EEG Signal'), findsOneWidget);
    expect(find.text('Frequency Spectrum'), findsOneWidget);

    expect(find.text('Delta'), findsOneWidget);
    expect(find.text('Theta'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });
}

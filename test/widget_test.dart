// Smoke test básico.
//
// OJO: la app usa APIs solo-Web (dart:js_interop, package:web, dart:ui_web),
// por lo que la detección de manos no funciona en el entorno de test del VM.
// Este test solo verifica que la UI base se construye sin lanzar.

import 'package:flutter_test/flutter_test.dart';

import 'package:desparche_con_manos/main.dart';

void main() {
  testWidgets('La app arranca y muestra las instrucciones',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DesparcheApp());
    await tester.pump();

    expect(find.textContaining('Haz un gesto'), findsOneWidget);
  });
}

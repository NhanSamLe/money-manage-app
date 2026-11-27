import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/ui/labeled_field.dart';
import 'package:moma/core/validators.dart';

void main() {
  final form = GlobalKey<FormState>();
  late TextEditingController email;
  late TextEditingController other;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: Form(
        key: form,
        child: Column(
          children: [
            LabeledField(
              label: 'Email',
              controller: email,
              validator: V.email,
              autofocus: true,
            ),
            LabeledField(
              label: 'Tên',
              controller: other,
              validator: V.displayName,
            ),
          ],
        ),
      ),
    ),
  );

  setUp(() {
    email = TextEditingController();
    other = TextEditingController();
  });

  testWidgets('opening the page shows no errors', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.textContaining('Vui lòng'), findsNothing);
    expect(find.text('Email không hợp lệ.'), findsNothing);
  });

  testWidgets(
    'no error while typing for the first time, error after leaving the field, live afterwards',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.enterText(find.byType(TextField).first, 'led');
      await tester.pump();
      expect(find.text('Email không hợp lệ.'), findsNothing); // still typing

      await tester.tap(find.byType(TextField).last); // leave the email field
      await tester.pump();
      expect(find.text('Email không hợp lệ.'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'ledaonhansam@gmail.com',
      );
      await tester.pump();
      expect(
        find.text('Email không hợp lệ.'),
        findsNothing,
      ); // clears as soon as it is valid
    },
  );

  testWidgets(
    'pressing the form button flags untouched fields, and they clear as the user types',
    (tester) async {
      await tester.pumpWidget(app());
      expect(form.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Vui lòng nhập email.'), findsOneWidget);
      expect(find.text('Vui lòng nhập tên.'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'Lê Đào Nhân Sâm');
      await tester.pump();
      expect(find.text('Vui lòng nhập tên.'), findsNothing);
      expect(
        find.text('Vui lòng nhập email.'),
        findsOneWidget,
      ); // untouched one stays until fixed
    },
  );
}

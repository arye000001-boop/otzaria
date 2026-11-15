import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show MaterialApp, showDialog;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria/core/windowing/snap_layouts_max_button.dart';
import 'package:otzaria/core/windowing/window_caption_hit_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late int armResult;
  Completer<int>? armReply;
  late int pressedCount;
  late bool lastHovered;
  late bool lastPressed;

  setUp(() {
    calls = [];
    armResult = 1;
    armReply = null;
    pressedCount = 0;
    lastHovered = false;
    lastPressed = false;
    SnapLayoutsMaxButton.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SnapLayoutsMaxButton.channel, (call) async {
          calls.add(call);
          if (call.method != 'arm') return null;
          return armReply?.future ?? armResult;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SnapLayoutsMaxButton.channel, null);
    SnapLayoutsMaxButton.debugReset();
  });

  Widget app({double topInset = 0, bool covered = false}) => Directionality(
    textDirection: TextDirection.rtl,
    child: Stack(
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 100, top: 4),
            child: SnapLayoutsMaxButton(
              topInset: topInset,
              onPressed: () => pressedCount++,
              builder: (context, hovered, pressed) {
                lastHovered = hovered;
                lastPressed = pressed;
                return const SizedBox(width: 46, height: 32);
              },
            ),
          ),
        ),
        if (covered)
          const Positioned.fill(
            child: ColoredBox(color: Color(0x80000000)),
          ),
      ],
    ),
  );

  Offset center(WidgetTester tester) =>
      tester.getCenter(find.byType(SnapLayoutsMaxButton));

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(center(tester));
    await tester.pump();
    return mouse;
  }

  Future<void> fromNative(
    WidgetTester tester,
    String method,
    Map<String, Object> args,
  ) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SnapLayoutsMaxButton.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {},
        );
    await tester.pump();
  }

  testWidgets('hover arms the button with its physical bounds', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await hover(tester);

    final arms = calls.where((c) => c.method == 'arm').toList();
    expect(arms, hasLength(1));
    final args = arms.single.arguments as Map;
    expect(args['left'], 150);
    expect(args['top'], 6);
    expect(args['right'], 219);
    expect(args['bottom'], 54);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('native hover, press and click reach the button', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final mouse = await hover(tester);
    final token = (calls.single.arguments as Map)['token'] as int;

    await fromNative(tester, 'state', {
      'token': token,
      'armed': true,
      'hovered': true,
      'pressed': true,
    });
    expect(lastHovered, isTrue);
    expect(lastPressed, isTrue);

    await fromNative(tester, 'click', {'token': token});
    expect(pressedCount, 1);

    await fromNative(tester, 'state', {
      'token': token,
      'armed': false,
      'hovered': false,
      'pressed': false,
    });
    expect(lastHovered, isFalse);
    expect(lastPressed, isFalse);

    // After the system disarms it, the next hover arms it again.
    await mouse.moveTo(center(tester) + const Offset(1, 0));
    await tester.pump();
    expect(calls.where((c) => c.method == 'arm'), hasLength(2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('removing an armed button disarms it', (tester) async {
    await tester.pumpWidget(app());
    await hover(tester);
    final token = (calls.single.arguments as Map)['token'];

    await tester.pumpWidget(const SizedBox());
    expect(calls.last.method, 'disarm');
    expect((calls.last.arguments as Map)['token'], token);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('an unsupported system stops further arming', (tester) async {
    armResult = -1;
    await tester.pumpWidget(app());
    final mouse = await hover(tester);
    await mouse.moveTo(center(tester) + const Offset(1, 0));
    await tester.pump();
    expect(calls.where((c) => c.method == 'arm'), hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('other platforms never call the runner', (tester) async {
    await tester.pumpWidget(app());
    await hover(tester);
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('the top inset stays out of the armed bounds', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(topInset: 8));
    await hover(tester);
    final args = calls.single.arguments as Map;
    expect(args['top'], 12);
    expect(args['bottom'], 36);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a disarm that overtakes the arm reply does not block arming', (
    tester,
  ) async {
    armReply = Completer<int>();
    await tester.pumpWidget(app());
    final mouse = await hover(tester);
    final token = (calls.single.arguments as Map)['token'] as int;

    await fromNative(tester, 'state', {
      'token': token,
      'armed': false,
      'hovered': false,
      'pressed': false,
    });
    armReply!.complete(1);
    await tester.pump();
    armReply = null;

    await mouse.moveTo(center(tester) + const Offset(1, 0));
    await tester.pump();
    expect(calls.where((c) => c.method == 'arm'), hasLength(2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a layer opened over an armed button disarms it', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    final mouse = await hover(tester);
    final token = (calls.single.arguments as Map)['token'];
    await fromNative(tester, 'state', {
      'token': token as int,
      'armed': true,
      'hovered': true,
      'pressed': false,
    });
    expect(calls.where((c) => c.method == 'disarm'), isEmpty);

    await tester.pumpWidget(app(covered: true));
    await tester.pump();
    expect(calls.last.method, 'disarm');
    expect((calls.last.arguments as Map)['token'], token);
    expect(lastHovered, isFalse);
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a dialog barrier keeps a caption-region button armed', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => WindowCaptionHitTestScope(child: child!),
        home: Builder(
          builder: (c) {
            context = c;
            return Align(
              alignment: Alignment.topLeft,
              child: WindowCaptionRegion(
                child: SnapLayoutsMaxButton(
                  onPressed: () => pressedCount++,
                  builder: (context, hovered, pressed) =>
                      const SizedBox(width: 46, height: 32),
                ),
              ),
            );
          },
        ),
      ),
    );
    final mouse = await hover(tester);
    expect(calls.single.method, 'arm');

    showDialog<void>(
      context: context,
      builder: (_) => const Center(child: SizedBox(width: 50, height: 50)),
    );
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'disarm'), isEmpty);
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

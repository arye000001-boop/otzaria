import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// בונה את הכפתור עם מצב הריחוף והלחיצה שמגיע מ-Windows.
typedef SnapLayoutsButtonBuilder =
    Widget Function(BuildContext context, bool hovered, bool pressed);

/// כפתור ההגדלה, שב-Windows 11 פותח בריחוף את Snap Layouts (#4021). מהריחוף
/// ועד היציאה Windows מטפל בסמן, והמצב והקליק חוזרים מה-runner.
class SnapLayoutsMaxButton extends StatefulWidget {
  const SnapLayoutsMaxButton({
    super.key,
    required this.onPressed,
    required this.builder,
    this.topInset = 0,
  });

  final VoidCallback onPressed;
  final SnapLayoutsButtonBuilder builder;

  /// רצועה עליונה (לוגית) שנשארת של Flutter — פס שינוי הגודל של חלון שאינו מוגדל.
  final double topInset;

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('otzaria/snap_layouts');

  static final Map<int, _SnapLayoutsMaxButtonState> _buttons = {};
  static int _nextToken = 1;
  static bool _unsupported = false;
  static bool _handlerInstalled = false;

  @visibleForTesting
  static void debugReset() {
    _buttons.clear();
    _unsupported = false;
    _handlerInstalled = false;
  }

  static Future<void> _handle(MethodCall call) async {
    final args = call.arguments;
    if (args is! Map) return;
    final button = _buttons[args['token']];
    if (button == null) return;
    switch (call.method) {
      case 'state':
        button._applyNativeState(
          armed: args['armed'] == true,
          hovered: args['hovered'] == true,
          pressed: args['pressed'] == true,
        );
      case 'click':
        button.widget.onPressed();
    }
  }

  @override
  State<SnapLayoutsMaxButton> createState() => _SnapLayoutsMaxButtonState();
}

class _SnapLayoutsMaxButtonState extends State<SnapLayoutsMaxButton> {
  final int _token = SnapLayoutsMaxButton._nextToken++;
  // ייתכן שכבר בוטל בנייטיב: `state` עוקף את התשובה ל-`arm`. לכן אינו חוסם דריכה.
  bool _armed = false;
  Rect? _armedBounds;
  bool _arming = false;
  bool _watching = false;
  bool _hovered = false;
  bool _pressed = false;

  static bool get _enabled =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !SnapLayoutsMaxButton._unsupported;

  @override
  void initState() {
    super.initState();
    SnapLayoutsMaxButton._buttons[_token] = this;
    if (!SnapLayoutsMaxButton._handlerInstalled) {
      SnapLayoutsMaxButton._handlerInstalled = true;
      SnapLayoutsMaxButton.channel.setMethodCallHandler(
        SnapLayoutsMaxButton._handle,
      );
    }
  }

  @override
  void dispose() {
    SnapLayoutsMaxButton._buttons.remove(_token);
    if (_armed) {
      unawaited(_invoke<void>('disarm', {'token': _token}));
    }
    super.dispose();
  }

  void _applyNativeState({
    required bool armed,
    required bool hovered,
    required bool pressed,
  }) {
    _armed = armed;
    if (_hovered == hovered && _pressed == pressed) return;
    setState(() {
      _hovered = hovered;
      _pressed = pressed;
    });
  }

  /// הגבולות הלוגיים ביחס לתצוגה; null כשאין עדיין layout.
  Rect? _logicalBounds() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  /// בפיקסלים פיזיים, כמו אזור-הלקוח של ה-FLUTTERVIEW, בלי [SnapLayoutsMaxButton.topInset].
  Rect? _physicalBounds() {
    final bounds = _logicalBounds();
    if (bounds == null) return null;
    final inset = widget.topInset.clamp(0, bounds.height).toDouble();
    final logical = Rect.fromLTRB(
      bounds.left,
      bounds.top + inset,
      bounds.right,
      bounds.bottom,
    );
    final ratio = View.of(context).devicePixelRatio;
    return Rect.fromLTRB(
      logical.left * ratio,
      logical.top * ratio,
      logical.right * ratio,
      logical.bottom * ratio,
    );
  }

  Future<void> _arm() async {
    if (!_enabled || _arming) return;
    final bounds = _physicalBounds();
    if (bounds == null) return;
    _arming = true;
    final result = await _invoke<int>('arm', {
      'token': _token,
      'left': bounds.left,
      'top': bounds.top,
      'right': bounds.right,
      'bottom': bounds.bottom,
    });
    _arming = false;
    if (result == null || result < 0) {
      SnapLayoutsMaxButton._unsupported = true;
      return;
    }
    if (!mounted) {
      if (result == 1) unawaited(_invoke<void>('disarm', {'token': _token}));
      return;
    }
    if (result == 1) {
      _armed = true;
      _armedBounds = bounds;
      _watchArmed();
    }
  }

  /// בלי תזוזת עכבר Windows לא בודק פגיעה מחדש: שכבה שנפתחה מעל הכפתור,
  /// או כפתור שזז, מבטלים את הדריכה כאן.
  void _watchArmed() {
    if (_watching) return;
    _watching = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _watching = false;
      if (!mounted || !_armed) return;
      if (_physicalBounds() == _armedBounds && _isTopmost()) {
        _watchArmed();
        return;
      }
      _disarm();
    });
  }

  bool _isTopmost() {
    final box = context.findRenderObject();
    final bounds = _logicalBounds();
    if (bounds == null) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      bounds.center,
      View.of(context).viewId,
    );
    return result.path.any((entry) => identical(entry.target, box));
  }

  void _disarm() {
    _armed = false;
    unawaited(_invoke<void>('disarm', {'token': _token}));
    if (_hovered || _pressed) {
      setState(() => _hovered = _pressed = false);
    }
  }

  Future<T?> _invoke<T>(String method, Map<String, Object> args) async {
    try {
      return await SnapLayoutsMaxButton.channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => unawaited(_arm()),
      child: widget.builder(context, _hovered, _pressed),
    );
  }
}

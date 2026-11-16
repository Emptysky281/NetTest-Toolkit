import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nettest/core/session.dart';
import 'package:nettest/ui/app_state.dart';
import 'package:nettest/ui/widgets.dart';

const _viewKey = ValueKey('log-under-test');

class _Harness {
  _Harness(this.state, this.dir);
  final AppState state;
  final Directory dir;
  int sequence = 0;

  void append(int count, {bool varied = true}) {
    for (var i = 0; i < count; i++) {
      final n = sequence++;
      final lines = varied ? [0, 1, 2, 30, 180, 4, 0][n % 7] : 0;
      final bytes = lines == 0
          ? null
          : Uint8List.fromList(
              utf8.encode(
                List.generate(lines, (j) => 'response-$n line-$j').join('\n'),
              ),
            );
      final item = LogItem(
        Ev(1, 'rx', 'log-row-$n'),
        bytes,
        bytes?.length,
        LogSrc.single,
      );
      state.logs.add(item);
      state.pageLogs[LogSrc.single]!.add(item);
    }
    for (final logs in [state.logs, state.pageLogs[LogSrc.single]!]) {
      if (logs.length > logKeep) logs.removeRange(0, logs.length - logKeep);
    }
    state.logVersion.value++;
  }

  void dispose() {
    state.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

Future<_Harness> _mount(
  WidgetTester tester, {
  LogSrc? src,
  int initial = 0,
  bool varied = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1180, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final dir = Directory.systemTemp.createTempSync('nettest-log-scroll-');
  final h = _Harness(AppState(settingsDir: dir.path), dir);
  addTearDown(h.dispose);
  h.append(initial, varied: varied);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LogView(h.state, key: _viewKey, src: src),
      ),
    ),
  );
  await tester.pump();
  return h;
}

ScrollPosition _position(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(_viewKey),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

Future<void> _frames(WidgetTester tester) async {
  // Finite frames, not pumpAndSettle: AppState intentionally keeps a 100 ms timer.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _expectLatest(WidgetTester tester, _Harness h) {
  expect(
    _position(tester).extentAfter,
    lessThanOrEqualTo(1),
    reason: 'the viewport must stay at the live tail',
  );
  final marker = find.textContaining('log-row-${h.sequence - 1}');
  expect(marker, findsOneWidget);
  final panel = tester.getRect(find.byKey(_viewKey));
  expect(
    tester.getRect(marker).overlaps(panel),
    isTrue,
    reason: 'the latest short row must actually be visible',
  );
}

Future<void> _wheel(WidgetTester tester, Offset delta) async {
  final at = tester.getCenter(find.byKey(_viewKey));
  await tester.sendEventToBinding(
    PointerScrollEvent(position: at, scrollDelta: delta),
  );
  await tester.pump();
}

(String, double) _visibleAnchor(WidgetTester tester) {
  final panel = tester.getRect(find.byKey(_viewKey));
  final texts = find.descendant(
    of: find.byKey(_viewKey),
    matching: find.byType(Text),
  );
  for (final element in texts.evaluate()) {
    final text = (element.widget as Text).data ?? '';
    if (!text.contains('log-row-')) continue;
    final rect = tester.getRect(find.byWidget(element.widget));
    if (rect.top > panel.top + 40 && rect.bottom < panel.bottom - 40) {
      return (text, rect.top);
    }
  }
  fail('no fully visible log row was available as a browsing anchor');
}

void _desktopTest(String name, WidgetTesterCallback callback) {
  testWidgets(
    name,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

void main() {
  _desktopTest('large variable-height log batches remain on the live tail', (
    tester,
  ) async {
    final h = await _mount(tester, initial: 700);
    try {
      h.append(1, varied: false);
      await _frames(tester);
      _expectLatest(tester, h);
      for (var batch = 0; batch < 8; batch++) {
        h.append(85);
        h.append(1, varied: false);
        await _frames(tester);
        _expectLatest(tester, h);
      }
    } finally {
      h.dispose();
    }
  });

  _desktopTest('rolling 5000-row log cap does not make the tail jump upwards', (
    tester,
  ) async {
    final h = await _mount(tester, src: LogSrc.single, initial: logKeep);
    try {
      for (var batch = 0; batch < 5; batch++) {
        h.append(110);
        h.append(1, varied: false);
        await _frames(tester);
        expect(h.state.logsFor(LogSrc.single), hasLength(logKeep));
        _expectLatest(tester, h);
      }
    } finally {
      h.dispose();
    }
  });

  _desktopTest(
    'mouse-wheel browsing stays on the same content while logs arrive and expire',
    (tester) async {
      final h = await _mount(tester, initial: logKeep, varied: false);
      try {
        await _frames(tester);
        await _wheel(tester, const Offset(0, -900));
        final anchor = _visibleAnchor(tester);
        h.append(50, varied: false);
        await _frames(tester);
        expect(find.text(anchor.$1), findsOneWidget);
        expect(
          tester.getTopLeft(find.text(anchor.$1)).dy,
          closeTo(anchor.$2, 1),
        );
        expect(_position(tester).extentAfter, greaterThan(600));
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest(
    'disabling automatic scrolling freezes the viewport; enabling it resumes latest',
    (tester) async {
      final h = await _mount(tester, initial: 120, varied: false);
      try {
        await _frames(tester);
        h.state.autoscroll = false;
        h.state.logVersion.value++;
        await tester.pump();
        final anchor = _visibleAnchor(tester);
        h.append(60, varied: false);
        await _frames(tester);
        expect(
          tester.getTopLeft(find.text(anchor.$1)).dy,
          closeTo(anchor.$2, 1),
        );
        h.state.autoscroll = true;
        h.state.logVersion.value++;
        await _frames(tester);
        _expectLatest(tester, h);
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest('clearing a paused log resets follow for the next response', (
    tester,
  ) async {
    final h = await _mount(tester, initial: 100, varied: false);
    try {
      await _frames(tester);
      await _wheel(tester, const Offset(0, -900));
      h.state.clearLog();
      await tester.pump();
      h.append(80);
      h.append(1, varied: false);
      await _frames(tester);
      _expectLatest(tester, h);
    } finally {
      h.dispose();
    }
  });

  _desktopTest(
    'payload mode changes and desktop resizing keep latest in view',
    (tester) async {
      final h = await _mount(tester, initial: 200);
      try {
        h.append(1, varied: false);
        await _frames(tester);
        for (final show in [false, true]) {
          h.state.showPayload = show;
          h.state.logVersion.value++;
          await _frames(tester);
          _expectLatest(tester, h);
        }
        h.state.showHex = true;
        h.state.logVersion.value++;
        await _frames(tester);
        _expectLatest(tester, h);
        await tester.binding.setSurfaceSize(const Size(900, 480));
        await _frames(tester);
        _expectLatest(tester, h);
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest(
    'every painted frame stays at latest during consecutive large batches',
    (tester) async {
      final h = await _mount(tester, initial: 900);
      try {
        for (var batch = 0; batch < 16; batch++) {
          h.append(35);
          h.append(1, varied: false);
          // Check the first layout, not just a eventually-settled position: the bug
          // was a visible jump between frames even if a later jump reached the end.
          await tester.pump(const Duration(milliseconds: 16));
          _expectLatest(tester, h);
        }
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest(
    'returning to the bottom resumes follow after manual wheel browsing',
    (tester) async {
      final h = await _mount(tester, initial: 300, varied: false);
      try {
        await _wheel(tester, const Offset(0, -1000));
        h.append(80);
        h.append(1, varied: false);
        await _frames(tester);
        expect(_position(tester).extentAfter, greaterThan(600));
        await _wheel(tester, const Offset(0, 1000000));
        await _frames(tester);
        _expectLatest(tester, h);
        h.append(85);
        h.append(1, varied: false);
        await tester.pump();
        _expectLatest(tester, h);
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest('a response taller than the viewport shows its final lines', (
    tester,
  ) async {
    final h = await _mount(tester, initial: 200);
    try {
      h.append(1, varied: false);
      final payload = List.generate(
        300,
        (i) => 'large-response-line-$i',
      ).join('\n');
      final bytes = Uint8List.fromList(utf8.encode(payload));
      final item = LogItem(Ev(1, 'rx', 'large response'), bytes);
      h.state.logs.add(item);
      h.state.logVersion.value++;
      await tester.pump();
      expect(_position(tester).extentAfter, lessThanOrEqualTo(1));
      final content = find.text(payload);
      expect(content, findsOneWidget);
      final panel = tester.getRect(find.byKey(_viewKey));
      final rect = tester.getRect(content);
      expect(rect.height, greaterThan(panel.height));
      expect(rect.bottom, inInclusiveRange(panel.bottom - 20, panel.bottom));
    } finally {
      h.dispose();
    }
  });

  _desktopTest(
    'touch/scrollbar-style dragging pauses without snapping back to tail',
    (tester) async {
      final h = await _mount(tester, initial: 400, varied: false);
      try {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(_viewKey)),
        );
        await gesture.moveBy(const Offset(0, 700));
        await tester.pump();
        h.append(50, varied: false);
        await tester.pump();
        expect(_position(tester).extentAfter, greaterThan(600));
        await gesture.up();
        await _frames(tester);
        final anchor = _visibleAnchor(tester);
        h.append(50, varied: false);
        await _frames(tester);
        expect(
          tester.getTopLeft(find.text(anchor.$1)).dy,
          closeTo(anchor.$2, 1),
        );
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest('an offstage desktop log returns at the latest output', (
    tester,
  ) async {
    final h = await _mount(tester, initial: 300);
    final selected = ValueNotifier(0);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: selected,
              builder: (_, index, _) => IndexedStack(
                index: index,
                children: [
                  LogView(h.state, key: _viewKey),
                  const SizedBox.expand(),
                ],
              ),
            ),
          ),
        ),
      );
      selected.value = 1;
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        h.append(120);
        await tester.pump();
      }
      h.append(1, varied: false);
      await tester.pump();
      selected.value = 0;
      await tester.pump();
      _expectLatest(tester, h);
    } finally {
      h.dispose();
      selected.dispose();
    }
  });

  _desktopTest(
    'real queued TX/RX flushes remain at latest on a function page',
    (tester) async {
      final h = await _mount(tester, src: LogSrc.single, initial: 180);
      try {
        final sink = h.state.sinkFor(LogSrc.single);
        for (var batch = 0; batch < 6; batch++) {
          for (var i = 0; i < 60; i++) {
            final body = Uint8List.fromList(
              utf8.encode(('response line\n' * (i % 9 + 1))),
            );
            sink(Ev(1, 'rx', 'response-$batch-$i', body));
          }
          sink(Ev(1, 'http', 'flush-end-$batch'));
          await tester.pump(const Duration(milliseconds: 100));
          expect(_position(tester).extentAfter, lessThanOrEqualTo(1));
          final marker = find.textContaining('flush-end-$batch');
          expect(marker, findsOneWidget);
          expect(
            tester
                .getRect(marker)
                .overlaps(tester.getRect(find.byKey(_viewKey))),
            isTrue,
          );
        }
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest(
    'evicting the entire browsing anchor clamps to surviving history safely',
    (tester) async {
      final h = await _mount(tester, initial: 300, varied: false);
      try {
        await _wheel(tester, const Offset(0, -900));
        h.append(logKeep + 100, varied: false);
        await _frames(tester);
        expect(tester.takeException(), isNull);
        final oldest = h.state.logs.first.e.msg;
        expect(find.textContaining(oldest), findsOneWidget);
        expect(_position(tester).extentAfter, greaterThan(600));
      } finally {
        h.dispose();
      }
    },
  );

  _desktopTest(
    'horizontal payload scrolling does not disable vertical following',
    (tester) async {
      final h = await _mount(tester, initial: 100, varied: false);
      try {
        final payload = 'very-long-response-data-' * 150;
        final item = LogItem(
          Ev(1, 'rx', 'wide payload'),
          Uint8List.fromList(utf8.encode(payload)),
        );
        h.state.logs.add(item);
        h.state.logVersion.value++;
        await tester.pump();
        final box = tester.getRect(find.text(payload));
        final panel = tester.getRect(find.byKey(_viewKey));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: Offset(panel.center.dx, box.center.dy),
            scrollDelta: const Offset(600, 0),
          ),
        );
        await tester.pump();
        h.append(60);
        h.append(1, varied: false);
        await tester.pump();
        _expectLatest(tester, h);
      } finally {
        h.dispose();
      }
    },
  );
}

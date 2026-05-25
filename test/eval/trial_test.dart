import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

void main() {
  group('Trial.cacheSalt', () {
    Trial t({
      String runName = 'r',
      String taskId = 'task_x',
      int trialIndex = 0,
    }) => Trial(
      runName: runName,
      suiteName: 's',
      taskId: taskId,
      trialIndex: trialIndex,
      startedAt: DateTime(2025),
      endedAt: DateTime(2025),
      status: TrialStatus.passed,
    );

    test('format is taskId#trialIndex', () {
      expect(t(taskId: 'foo', trialIndex: 3).cacheSalt, 'foo#3');
    });

    test('does NOT include runName (cross-run replay friendly)', () {
      final a = t(runName: 'run_a').cacheSalt;
      final b = t(runName: 'run_b').cacheSalt;
      expect(a, b);
    });

    test('different trialIndex → different salt', () {
      final i0 = t(trialIndex: 0).cacheSalt;
      final i1 = t(trialIndex: 1).cacheSalt;
      expect(i0, isNot(i1));
    });

    test('different taskId → different salt', () {
      final a = t(taskId: 'a').cacheSalt;
      final b = t(taskId: 'b').cacheSalt;
      expect(a, isNot(b));
    });
  });
}

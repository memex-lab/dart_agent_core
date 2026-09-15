import 'package:dart_agent_core/eval.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  group('TrialResult.allGradersPassed', () {
    test('only passed:null scores → false (no grader decided)', () {
      final result = TrialResult(
        trial: makeTrial(
          runName: 'r',
          suiteName: 's',
          taskId: 't',
          status: TrialStatus.passed,
        ),
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {}),
        scores: [nullScore('judge'), nullScore('human')],
      );
      expect(result.allGradersPassed, isFalse);
    });

    test('empty scores → false', () {
      final result = TrialResult(
        trial: makeTrial(
          runName: 'r',
          suiteName: 's',
          taskId: 't',
          status: TrialStatus.passed,
        ),
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {}),
        scores: const [],
      );
      expect(result.allGradersPassed, isFalse);
    });

    test('null scores ignored when at least one grader decided pass', () {
      final result = TrialResult(
        trial: makeTrial(
          runName: 'r',
          suiteName: 's',
          taskId: 't',
          status: TrialStatus.passed,
        ),
        transcript: emptyTranscript(),
        outcome: const Outcome(environmentState: {}),
        scores: [okScore('code'), nullScore('judge')],
      );
      expect(result.allGradersPassed, isTrue);
    });
  });

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

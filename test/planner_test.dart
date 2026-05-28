import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

class _MockStatefulAgent extends Mock implements StatefulAgent {
  @override
  String get name => 'test-agent';
}

void main() {
  group('StepStatus 解析', () {
    test('PlanStep.fromJson 能解析 pending/in_progress/completed/cancelled', () {
      for (final status in StepStatus.values) {
        final step = PlanStep.fromJson({
          'description': 'do ${status.name}',
          'status': status.name,
        });
        expect(step.status, status);
        expect(step.description, 'do ${status.name}');

        // toJson 往返
        final roundTrip = PlanStep.fromJson(step.toJson());
        expect(roundTrip.status, status);
        expect(roundTrip.description, step.description);
      }
    });

    test('PlanState toJson/fromJson 保留所有步骤', () {
      final original = PlanState(steps: [
        PlanStep(description: 'a', status: StepStatus.pending),
        PlanStep(description: 'b', status: StepStatus.in_progress),
        PlanStep(description: 'c', status: StepStatus.completed),
        PlanStep(description: 'd', status: StepStatus.cancelled),
      ]);

      final decoded =
          PlanState.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(decoded.steps.length, 4);
      expect(decoded.steps.map((e) => e.status).toList(), [
        StepStatus.pending,
        StepStatus.in_progress,
        StepStatus.completed,
        StepStatus.cancelled,
      ]);
      expect(decoded.steps.map((e) => e.description).toList(),
          ['a', 'b', 'c', 'd']);
    });
  });

  group('SystemPromptHistoryItem', () {
    test('toJson/fromJson 往返不丢失字段', () {
      final item = SystemPromptHistoryItem(
        content: 'You are a helpful assistant',
        validFromMessageIndex: 7,
      );
      final decoded = SystemPromptHistoryItem.fromJson(
          jsonDecode(jsonEncode(item.toJson())));
      expect(decoded.content, item.content);
      expect(decoded.validFromMessageIndex, item.validFromMessageIndex);
    });
  });

  group('ToolsHistoryItem', () {
    test('toJson/fromJson 往返不丢失字段', () {
      final item = ToolsHistoryItem(
        tools: [
          {'name': 'read', 'description': 'read a file'},
          {'name': 'write', 'description': 'write a file'},
        ],
        validFromMessageIndex: 3,
      );
      final decoded = ToolsHistoryItem.fromJson(
          jsonDecode(jsonEncode(item.toJson())));
      expect(decoded.validFromMessageIndex, 3);
      expect(decoded.tools.length, 2);
      expect(decoded.tools[0]['name'], 'read');
      expect(decoded.tools[1]['name'], 'write');
    });
  });

  group('AgentState', () {
    test('empty() 创建正确的默认值', () {
      final state = AgentState.empty();
      expect(state.sessionId, isNotEmpty);
      expect(state.isRunning, isFalse);
      expect(state.history.messages, isEmpty);
      expect(state.history.episodicMemories, isEmpty);
      expect(state.usages, isEmpty);
      expect(state.currentLoopUsages, isEmpty);
      expect(state.metadata, isEmpty);
      expect(state.systemReminders, isEmpty);
      expect(state.systemPromptHistory, isEmpty);
      expect(state.toolsHistory, isEmpty);
      expect(state.plan, isNull);
      expect(state.lastError, isNull);
      expect(state.totalLoopCount, 0);
      expect(state.currentLoopCount, 0);
    });

    test('toJson/fromJson 往返不丢失字段（含 systemPromptHistory、toolsHistory）',
        () {
      final state = AgentState(
        sessionId: 'sess-1',
        totalLoopCount: 2,
        currentLoopCount: 1,
        lastError: 'boom',
        isRunning: true,
        metadata: {'k': 'v'},
        systemReminders: {'r1': 'remember this'},
        plan: PlanState(steps: [
          PlanStep(description: 'step', status: StepStatus.in_progress),
        ]),
        activeSkills: ['skill_a'],
        systemPromptHistory: [
          SystemPromptHistoryItem(
              content: 'sys prompt v1', validFromMessageIndex: 0),
          SystemPromptHistoryItem(
              content: 'sys prompt v2', validFromMessageIndex: 5),
        ],
        toolsHistory: [
          ToolsHistoryItem(
            tools: [
              {'name': 'tool_a', 'description': 'first'}
            ],
            validFromMessageIndex: 0,
          ),
          ToolsHistoryItem(
            tools: [
              {'name': 'tool_b', 'description': 'second'}
            ],
            validFromMessageIndex: 4,
          ),
        ],
      );

      final decoded =
          AgentState.fromJson(jsonDecode(jsonEncode(state.toJson())));

      expect(decoded.sessionId, 'sess-1');
      expect(decoded.totalLoopCount, 2);
      expect(decoded.currentLoopCount, 1);
      expect(decoded.lastError, 'boom');
      expect(decoded.isRunning, isTrue);
      expect(decoded.metadata, {'k': 'v'});
      expect(decoded.systemReminders, {'r1': 'remember this'});
      expect(decoded.activeSkills, ['skill_a']);
      expect(decoded.plan, isNotNull);
      expect(decoded.plan!.steps.single.description, 'step');
      expect(decoded.plan!.steps.single.status, StepStatus.in_progress);

      expect(decoded.systemPromptHistory.length, 2);
      expect(decoded.systemPromptHistory[0].content, 'sys prompt v1');
      expect(decoded.systemPromptHistory[1].validFromMessageIndex, 5);

      expect(decoded.toolsHistory.length, 2);
      expect(decoded.toolsHistory[0].tools.single['name'], 'tool_a');
      expect(decoded.toolsHistory[1].validFromMessageIndex, 4);
    });
  });

  group('Planner write_todos 工具', () {
    late _MockStatefulAgent agent;
    late Planner planner;
    late AgentState state;
    late Tool writeTodos;

    setUp(() {
      agent = _MockStatefulAgent();
      state = AgentState.empty();
      planner = Planner(agent, null);
      writeTodos =
          planner.tools.firstWhere((t) => t.name == 'write_todos');
    });

    Future<AgentToolResult> runWriteTodos(List<Map<String, dynamic>> todos) {
      final ctx = AgentCallToolContext(
        state: state,
        agent: agent,
        batchCallId: 'batch-1',
      );
      return runZoned<Future<AgentToolResult>>(
        () async => await (writeTodos.executable as Function)(todos),
        zoneValues: {AgentCallToolContext.ZoneKey: ctx},
      );
    }

    test('注册 write_todos 工具且参数 schema 包含 todos', () {
      expect(writeTodos.name, 'write_todos');
      expect(writeTodos.description, contains('subtasks'));
      final properties =
          writeTodos.parameters['properties'] as Map<String, dynamic>;
      expect(properties.containsKey('todos'), isTrue);
    });

    test('写入 todos 后返回内容包含 todo 列表文本，并更新 state.plan', () async {
      final result = await runWriteTodos([
        {'description': '搜索资料', 'status': 'in_progress'},
        {'description': '撰写大纲', 'status': 'pending'},
        {'description': '完成初稿', 'status': 'completed'},
        {'description': '过时任务', 'status': 'cancelled'},
      ]);

      expect(result.content, isA<TextPart>());
      final text = (result.content as TextPart).text;
      expect(text, contains('Successfully updated the todo list'));
      expect(text, contains('搜索资料'));
      expect(text, contains('[in_progress]'));
      expect(text, contains('撰写大纲'));
      expect(text, contains('[pending]'));
      expect(text, contains('完成初稿'));
      expect(text, contains('[completed]'));
      expect(text, contains('过时任务'));
      expect(text, contains('[cancelled]'));

      expect(result.metadata?['planner_tool'], 'write_todos');
      expect(result.metadata?['todos'], isA<List>());

      expect(state.plan, isNotNull);
      expect(state.plan!.steps.length, 4);
      expect(state.plan!.steps.map((e) => e.status).toList(), [
        StepStatus.in_progress,
        StepStatus.pending,
        StepStatus.completed,
        StepStatus.cancelled,
      ]);
    });

    test('未知的 status 字符串会退化为 pending', () async {
      await runWriteTodos([
        {'description': '某任务', 'status': 'something-unknown'},
      ]);

      expect(state.plan!.steps.single.status, StepStatus.pending);
    });

    test('再次调用 write_todos 会替换整个 plan', () async {
      await runWriteTodos([
        {'description': '旧任务', 'status': 'pending'},
      ]);
      expect(state.plan!.steps.single.description, '旧任务');

      await runWriteTodos([
        {'description': '新任务 A', 'status': 'in_progress'},
        {'description': '新任务 B', 'status': 'pending'},
      ]);

      expect(state.plan!.steps.length, 2);
      expect(state.plan!.steps.first.description, '新任务 A');
      expect(state.plan!.steps.first.status, StepStatus.in_progress);
    });
  });
}

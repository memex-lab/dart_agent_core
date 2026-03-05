import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:logging/logging.dart';

final _plannerLogger = Logger('planner');

enum PlanMode { none, auto, must }

enum StepStatus { pending, in_progress, completed, cancelled }

class PlanStep {
  final String description;
  StepStatus status;

  PlanStep({required this.description, this.status = StepStatus.pending});

  factory PlanStep.fromJson(Map<String, dynamic> json) {
    return PlanStep(
      description: json['description'],
      status: StepStatus.values.firstWhere((e) => e.name == json['status']),
    );
  }

  Map<String, dynamic> toJson() {
    return {'description': description, 'status': status.name};
  }
}

class PlanState {
  List<PlanStep> steps;

  PlanState({required this.steps});

  factory PlanState.fromJson(Map<String, dynamic> json) {
    return PlanState(
      steps: (json['steps'] as List)
          .map((step) => PlanStep.fromJson(step))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'steps': steps.map((step) => step.toJson()).toList()};
  }
}

class Planner {
  final StatefulAgent agent;
  final AgentController? controller;
  late final List<Tool> _tools;

  Planner(this.agent, this.controller) {
    _initializeTools();
  }

  void _initializeTools() {
    final writeTodosTool = Tool(
      name: 'write_todos',
      description:
          "This tool can help you list out the current subtasks that are required to be completed for a given user request. The list of subtasks helps you keep track of the current task, organize complex queries and help ensure that you don't miss any steps. With this list, the user can also see the current progress you are making in executing a given task.\n\nDepending on the task complexity, you should first divide a given task into subtasks and then use this tool to list out the subtasks that are required to be completed for a given user request.\nEach of the subtasks should be clear and distinct. \n\nUse this tool for complex queries that require multiple steps. If you find that the request is actually complex after you have started executing the user task, create a todo list and use it. If execution of the user task requires multiple steps, planning and generally is higher complexity than a simple Q&A, use this tool.\n\nDO NOT use this tool for simple tasks that can be completed in less than 2 steps. If the user query is simple and straightforward, do not use the tool. If you can respond with an answer in a single turn then this tool is not required.\n\n## Task state definitions\n\n- pending: Work has not begun on a given subtask.\n- in_progress: Marked just prior to beginning work on a given subtask. You should only have one subtask as in_progress at a time.\n- completed: Subtask was successfully completed with no errors or issues. If the subtask required more steps to complete, update the todo list with the subtasks. All steps should be identified as completed only when they are completed.\n- cancelled: As you update the todo list, some tasks are not required anymore due to the dynamic nature of the task. In this case, mark the subtasks as cancelled.\n\n\n## Methodology for using this tool\n1. Use this todo list as soon as you receive a user request based on the complexity of the task.\n2. Keep track of every subtask that you update the list with.\n3. Mark a subtask as in_progress before you begin working on it. You should only have one subtask as in_progress at a time.\n4. Update the subtask list as you proceed in executing the task. The subtask list is not static and should reflect your progress and current plans, which may evolve as you acquire new information.\n5. Mark a subtask as completed when you have completed it.\n6. Mark a subtask as cancelled if the subtask is no longer needed.\n7. You must update the todo list as soon as you start, stop or cancel a subtask. Don't batch or wait to update the todo list.\n\n\n## Examples of When to Use the Todo List\n\n<example>\nUser request: Plan a 3-day trip to Kyoto for me, including hotel booking and strict budget control.\n\nToDo list created by the agent:\n1. Search for available flights to Kyoto (actually Osaka/KIX) for the specified dates and select the best option within budget.\n2. Search for hotels in central Kyoto (e.g., Gion or Downtown) that fit the budget range.\n3. Research top 5 budget-friendly tourist attractions and create a daily itinerary draft.\n4. Estimate total cost for transport, accommodation, and food to ensure it meets the strict budget.\n5. Present the draft itinerary and cost breakdown to the user for approval.\n6. Upon approval, proceed to pretend booking (or provide booking links) for the selected flight and hotel.\n7. Finalize the trip summary and provide packing tips.\n\n<reasoning>\nThe agent used the todo list to break the task into distinct, manageable steps:\n1. A trip planning request involves multiple distinct activities (flights, hotels, itinerary, budgeting) that cannot be done in a single turn.\n2. The request has specific constraints (strict budget) that need to be checked against multiple steps (Tasks 1, 2, 4).\n3. Logical dependency: The itinerary and cost estimate (Task 5) must be approved before finalizing bookings (Task 6).\n</reasoning>\n</example>\n\n\n## Examples of When NOT to Use the Todo List\n\n<example>\nUser request: What is the capital of France?\n\nAgent:\n<Responds directly: \"The capital of France is Paris.\">\n\n<reasoning>\nThe agent did not use the todo list because this is a simple factual query that can be answered in a single turn without complex planning.\n</reasoning>\n</example>\n",
      parameters: {
        "type": "object",
        "properties": {
          "todos": {
            "type": "array",
            "description":
                "The complete list of todo items. This will replace the existing list.",
            "items": {
              "type": "object",
              "description": "A single todo item.",
              "properties": {
                "description": {
                  "type": "string",
                  "description": "The description of the task.",
                },
                "status": {
                  "type": "string",
                  "description": "The current status of the task.",
                  "enum": ["pending", "in_progress", "completed", "cancelled"],
                },
              },
              "required": ["description", "status"],
            },
          },
        },
        "required": ["todos"],
      },
      executable: _writeTodos,
    );

    _tools = [writeTodosTool];
  }

  List<Tool> get tools => _tools;

  Future<AgentToolResult> _writeTodos(List<dynamic> todos) async {
    final state = AgentCallToolContext.current!.state;

    // Convert raw JSON list to structured PlanSteps
    final newSteps = todos.map((item) {
      final map = item as Map<String, dynamic>;
      final description = map['description'] as String;
      final statusStr = map['status'] as String;

      StepStatus status;
      switch (statusStr) {
        case 'completed':
          status = StepStatus.completed;
          break;
        case 'in_progress':
          status = StepStatus.in_progress;
          break;
        case 'cancelled':
          status = StepStatus.cancelled;
          break;
        case 'pending':
        default:
          status = StepStatus.pending;
          break;
      }

      return PlanStep(description: description, status: status);
    }).toList();

    // Create or update the plan
    state.plan = PlanState(steps: newSteps);

    _printPlanUpdateLog(state);

    final buffer = StringBuffer();
    buffer.writeln(
      "Successfully updated the todo list. The current list is now:",
    );
    for (int i = 0; i < newSteps.length; i++) {
      final step = newSteps[i];
      final index = i + 1;
      String statusText;
      switch (step.status) {
        case StepStatus.completed:
          statusText = "completed";
          break;
        case StepStatus.in_progress:
          statusText = "in_progress";
          break;
        case StepStatus.cancelled:
          statusText = "cancelled";
          break;
        case StepStatus.pending:
          statusText = "pending";
          break;
      }
      buffer.writeln("$index. [$statusText] ${step.description}");
    }

    controller?.publish(PlanChangedEvent(agent, state.plan!));

    return AgentToolResult(
      content: TextPart(buffer.toString()),
      metadata: {'planner_tool': 'write_todos', 'todos': todos},
    );
  }

  void _printPlanUpdateLog(AgentState state) {
    final plan = state.plan;
    if (plan == null) return;
    final buffer = StringBuffer();
    buffer.writeln("========== 📝 ToDo List Updated (${agent.name}) =========");
    for (var step in plan.steps) {
      String icon;
      switch (step.status) {
        case StepStatus.completed:
          icon = "✅";
          break;
        case StepStatus.in_progress:
          icon = "👉";
          break;
        case StepStatus.cancelled:
          icon = "🚫";
          break;
        default:
          icon = "⏳";
      }
      buffer.writeln("- $icon ${step.description}");
    }
    _plannerLogger.info(buffer.toString());
  }
}

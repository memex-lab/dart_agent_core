import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

void main() {
  group('McpToolDef', () {
    // ── 构造 ──────────────────────────────────────────────────────

    test('creates with required fields', () {
      final tool = McpToolDef(
        name: 'get_weather',
        description: 'Get current weather',
        inputSchema: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
        },
      );

      expect(tool.name, 'get_weather');
      expect(tool.description, 'Get current weather');
      expect(tool.inputSchema['type'], 'object');
    });

    test('creates with empty inputSchema', () {
      final tool = McpToolDef(
        name: 'no_params',
        description: 'Tool without parameters',
        inputSchema: {'type': 'object', 'properties': {}},
      );

      expect(tool.inputSchema['properties'], isEmpty);
    });

    test('creates with complex nested inputSchema', () {
      final tool = McpToolDef(
        name: 'complex',
        description: 'Complex tool',
        inputSchema: {
          'type': 'object',
          'properties': {
            'nested': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['nested'],
        },
      );

      expect(tool.inputSchema['required'], ['nested']);
    });

    // ── fromJson ──────────────────────────────────────────────────

    group('fromJson', () {
      test('parses minimal JSON', () {
        final json = {
          'name': 'minimal_tool',
          'description': 'A minimal tool',
          'inputSchema': {'type': 'object'},
        };

        final tool = McpToolDef.fromJson(json);

        expect(tool.name, 'minimal_tool');
        expect(tool.description, 'A minimal tool');
        expect(tool.inputSchema['type'], 'object');
      });

      test('parses full JSON', () {
        final json = {
          'name': 'full_tool',
          'description': 'Full-featured tool',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'param1': {'type': 'string', 'description': 'First param'},
              'param2': {
                'type': 'integer',
                'description': 'Second param',
                'default': 42,
              },
            },
            'required': ['param1'],
          },
        };

        final tool = McpToolDef.fromJson(json);

        expect(tool.name, 'full_tool');
        expect(tool.description, 'Full-featured tool');
        expect(tool.inputSchema['properties']['param1']['type'], 'string');
        expect(tool.inputSchema['properties']['param2']['default'], 42);
      });
    });
  });

  // ── McpResourceDef ────────────────────────────────────────────

  group('McpResourceDef', () {
    test('creates with required fields', () {
      final resource = McpResourceDef(
        uri: 'file:///data/config.json',
        name: 'config',
      );

      expect(resource.uri, 'file:///data/config.json');
      expect(resource.name, 'config');
      expect(resource.description, isNull);
      expect(resource.mimeType, isNull);
    });

    test('creates with all fields', () {
      final resource = McpResourceDef(
        uri: 'https://api.example.com/data',
        name: 'api-data',
        description: 'API data resource',
        mimeType: 'application/json',
      );

      expect(resource.uri, 'https://api.example.com/data');
      expect(resource.name, 'api-data');
      expect(resource.description, 'API data resource');
      expect(resource.mimeType, 'application/json');
    });

    group('fromJson', () {
      test('parses minimal JSON', () {
        final json = {'uri': 'test://resource', 'name': 'test'};

        final resource = McpResourceDef.fromJson(json);

        expect(resource.uri, 'test://resource');
        expect(resource.name, 'test');
        expect(resource.description, isNull);
        expect(resource.mimeType, isNull);
      });

      test('parses full JSON', () {
        final json = {
          'uri': 'https://example.com/resource',
          'name': 'example',
          'description': 'An example resource',
          'mimeType': 'text/plain',
        };

        final resource = McpResourceDef.fromJson(json);

        expect(resource.uri, 'https://example.com/resource');
        expect(resource.name, 'example');
        expect(resource.description, 'An example resource');
        expect(resource.mimeType, 'text/plain');
      });
    });
  });

  // ── McpPromptDef ──────────────────────────────────────────────

  group('McpPromptDef', () {
    group('fromJson', () {
      test('parses minimal JSON', () {
        final json = {'name': 'greeting'};

        final prompt = McpPromptDef.fromJson(json);

        expect(prompt.name, 'greeting');
        expect(prompt.description, isNull);
        expect(prompt.arguments, isNull);
      });

      test('parses prompt with description', () {
        final json = {
          'name': 'code_review',
          'description': 'Generate a code review',
        };

        final prompt = McpPromptDef.fromJson(json);

        expect(prompt.name, 'code_review');
        expect(prompt.description, 'Generate a code review');
      });

      test('parses prompt with arguments', () {
        final json = {
          'name': 'analyze',
          'description': 'Analyze data',
          'arguments': [
            {
              'name': 'dataset',
              'description': 'Dataset to analyze',
              'required': true,
            },
            {
              'name': 'format',
              'description': 'Output format',
              'required': false,
            },
          ],
        };

        final prompt = McpPromptDef.fromJson(json);

        expect(prompt.name, 'analyze');
        expect(prompt.arguments, hasLength(2));
        expect(prompt.arguments![0].name, 'dataset');
        expect(prompt.arguments![0].description, 'Dataset to analyze');
        expect(prompt.arguments![0].required, isTrue);
        expect(prompt.arguments![1].name, 'format');
        expect(prompt.arguments![1].required, isFalse);
      });

      test('parses prompt with arguments missing "required" field', () {
        final json = {
          'name': 'optional_args',
          'arguments': [
            {'name': 'arg1'},
          ],
        };

        final prompt = McpPromptDef.fromJson(json);

        expect(prompt.arguments![0].name, 'arg1');
        expect(prompt.arguments![0].required, isNull);
      });
    });
  });

  // ── McpPromptArgument ─────────────────────────────────────────

  group('McpPromptArgument', () {
    test('fromJson with all fields', () {
      final json = {
        'name': 'language',
        'description': 'Programming language',
        'required': true,
      };

      final arg = McpPromptArgument.fromJson(json);

      expect(arg.name, 'language');
      expect(arg.description, 'Programming language');
      expect(arg.required, isTrue);
    });

    test('fromJson with name only', () {
      final json = {'name': 'input'};

      final arg = McpPromptArgument.fromJson(json);

      expect(arg.name, 'input');
      expect(arg.description, isNull);
      expect(arg.required, isNull);
    });
  });
}

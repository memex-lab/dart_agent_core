import 'dart:io';
import 'package:dart_agent_core/dart_agent_core.dart';

String getStockValue(String symbol) {
  if (symbol.toUpperCase() == 'GOOG') return '\$150.25';
  if (symbol.toUpperCase() == 'AAPL') return '\$180.12';
  return 'Stock not found';
}

void main() async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? 'YOUR_API_KEY';

  final client = GeminiClient(apiKey: apiKey);
  final modelConfig = ModelConfig(model: 'gemini-2.5-pro', temperature: 0.5);

  final stockTool = Tool(
    name: 'get_stock_value',
    description: 'Get the current stock price for a symbol.',
    executable: getStockValue,
    parameters: {
      'type': 'object',
      'properties': {
        'symbol': {
          'type': 'string',
          'description': 'The ticker symbol, e.g. GOOG',
        },
      },
      'required': ['symbol'],
    },
  );

  final agent = StatefulAgent(
    name: 'gemini_agent',
    client: client,
    tools: [stockTool],
    modelConfig: modelConfig,
    state: AgentState.empty(),
    systemPrompts: ['You are a helpful financial assistant.'],
  );

  print('Sending message to Gemini agent to check a stock...');
  final responses = await agent.run([
    UserMessage.text(
      'What is the current price of Google (GOOG) and Apple (AAPL)?',
    ),
  ]);

  print('Agent response:\n${(responses.last as ModelMessage).textOutput}');
}

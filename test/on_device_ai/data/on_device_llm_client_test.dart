import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_llm_client.dart';
import 'package:mozhi/on_device_ai/data/on_device_runtime.dart';
import 'package:mozhi/platform/device_conditions.dart';

import 'helpers.dart';

class _FakeConditions extends Fake implements DeviceConditions {
  DeviceConditionsSnapshot snapshot = DeviceConditionsSnapshot.unknown;
  int refreshes = 0;

  @override
  Future<DeviceConditionsSnapshot> refresh() async {
    refreshes++;
    return snapshot;
  }
}

void main() {
  late FakeLlamaEngine engine;
  late OnDeviceRuntime runtime;
  late OnDeviceLlmClient client;

  OnDeviceLlmClient clientFor(String model) => OnDeviceLlmClient(
    LlmEndpoint(
      provider: LlmProvider.onDevice,
      baseUrl: Uri(scheme: 'device', host: model),
    ),
    runtime: runtime,
  );

  LlmRequest request(
    List<LlmMessage> messages, {
    String model = '',
    double? temperature,
    double? topP,
    int? topK,
    double? repeatPenalty,
    int? maxTokens,
    bool jsonOutput = false,
    List<String> stop = const [],
  }) => LlmRequest(
    model: model,
    messages: messages,
    temperature: temperature,
    topP: topP,
    topK: topK,
    repeatPenalty: repeatPenalty,
    maxTokens: maxTokens,
    jsonOutput: jsonOutput,
    stop: stop,
  );

  setUp(() {
    engine = FakeLlamaEngine();
    runtime = OnDeviceRuntime(
      engine: engine,
      catalog: testCatalog,
      pathOf: (id) async => id == 'missing' ? null : '/m/$id',
    );
    client = clientFor('gemma');
  });

  tearDown(() => runtime.dispose());

  group('streamChat', () {
    test('maps the request to the engine', () async {
      final text = await client
          .streamChat(
            request(
              [
                const LlmMessage.system('Be brief.'),
                const LlmMessage.user('Hello'),
                const LlmMessage.assistant('Hallo'),
                const LlmMessage.system('Reply in JSON.'),
                const LlmMessage.user('Again'),
              ],
              jsonOutput: true,
              stop: ['</s>'],
            ),
          )
          .join();
      expect(text, 'Hi');
      final sent = engine.requests.single;
      expect(
        [for (final m in sent.messages) (m.role, m.content)],
        [
          (LlamaRole.system, 'Be brief.\n\nReply in JSON.'),
          (LlamaRole.user, 'Hello'),
          (LlamaRole.assistant, 'Hallo'),
          (LlamaRole.user, 'Again'),
        ],
      );
      expect(sent.jsonOutput, isTrue);
      expect(sent.stop, ['</s>']);
      // The reply is bounded by the prompt (the fake counts a token per
      // character).
      const prompt = 'Be brief.\n\nReply in JSON.HelloHalloAgain'.length;
      expect(
        sent.maxTokens,
        prompt * OnDeviceLlmClient.replyTokensPerPromptToken +
            OnDeviceLlmClient.replyTokenMargin,
      );
      // The catalogue's sampling, else the engine's.
      expect(sent.sampling.temperature, 1);
      expect(sent.sampling.topP, 0.95);
      expect(sent.sampling.topK, 64);
      expect(sent.sampling.repeatPenalty, const LlamaSampling().repeatPenalty);
      expect(sent.sampling.minP, const LlamaSampling().minP);
    });

    test("the request's sampling and output cap win", () async {
      await client
          .streamChat(
            request(
              [const LlmMessage.user('Hi')],
              temperature: 0.2,
              topP: 0.5,
              topK: 10,
              repeatPenalty: 1.1,
              maxTokens: 100,
            ),
          )
          .drain<void>();
      final sent = engine.requests.single;
      expect(sent.sampling.temperature, 0.2);
      expect(sent.sampling.topP, 0.5);
      expect(sent.sampling.topK, 10);
      expect(sent.sampling.repeatPenalty, 1.1);
      expect(sent.maxTokens, 100);
      expect(sent.messages.single.role, LlamaRole.user);
    });

    group('without a cap of the request', () {
      Future<int> capOf(String text, {int? maxTokens}) async {
        engine.requests.clear();
        await client
            .streamChat(request([LlmMessage.user(text)], maxTokens: maxTokens))
            .drain<void>();
        return engine.requests.single.maxTokens;
      }

      test('the reply is bounded by the prompt', () async {
        engine.tokens = (_) => 100;
        // Three times the prompt's tokens and a margin, far less than the
        // context leaves (3996 tokens).
        expect(await capOf('Hi'), 300 + OnDeviceLlmClient.replyTokenMargin);
        // A cap of 0 or less would run until the context is full.
        expect(
          await capOf('Hi', maxTokens: 0),
          300 + OnDeviceLlmClient.replyTokenMargin,
        );
        expect(
          await capOf('Hi', maxTokens: -1),
          300 + OnDeviceLlmClient.replyTokenMargin,
        );
      });

      test('by its characters when they are more than its tokens', () async {
        // A prompt in a script the tokenizer packs well; the reply may be
        // in one with a token per character.
        engine.tokens = (_) => 10;
        expect(
          await capOf('x' * 1000),
          1000 + OnDeviceLlmClient.replyTokenMargin,
        );
      });

      test('prompt and reply always fit the context', () async {
        engine.tokens = (_) => 3000;
        expect(await capOf('long'), 4096 - 3000);
        expect(await capOf('long', maxTokens: 2000), 4096 - 3000);
        expect(await capOf('long', maxTokens: 50), 50);
      });

      test('a reply that reaches the bound is cut off', () async {
        engine
          ..reply = ((_) => Stream.fromIterable(['again ', 'again ']))
          ..finishReason = LlamaFinishReason.length;
        final events = <Object>[];
        await client
            .streamChat(request([const LlmMessage.user('Repeat forever.')]))
            .handleError(events.add)
            .forEach(events.add);
        expect(events.last, isA<LlmTruncatedException>());
        expect(
          (events.last as LlmTruncatedException).partialText,
          'again again ',
        );
        expect(
          engine.requests.single.maxTokens,
          OnDeviceLlmClient.replyTokensFor(
            promptTokens: 'Repeat forever.'.length,
            promptLength: 'Repeat forever.'.length,
          ),
        );
      });
    });

    test('uses the model of the request, else of the endpoint', () async {
      await client
          .streamChat(request([const LlmMessage.user('Hi')], model: 'hy-mt2'))
          .drain<void>();
      expect(engine.loads.single.$1, '/m/hy-mt2');
      // Hy-MT2's sampling from the catalogue.
      expect(engine.requests.single.sampling.topK, 20);
    });

    test('Qwen3 is asked not to reason first', () async {
      await clientFor('qwen')
          .streamChat(
            request([
              const LlmMessage.system('Translate.'),
              const LlmMessage.user('Hi'),
              const LlmMessage.assistant('Hallo'),
              const LlmMessage.user('Again'),
            ]),
          )
          .drain<void>();
      expect(
        [for (final m in engine.requests.single.messages) m.content],
        ['Translate.', 'Hi', 'Hallo', 'Again /no_think'],
      );
      // Other families are asked as they are.
      await client
          .streamChat(request([const LlmMessage.user('Again')]))
          .drain<void>();
      expect(engine.requests.last.messages.single.content, 'Again');
    });

    test('drops reasoning blocks', () async {
      engine.reply = (_) =>
          Stream.fromIterable(['<think>\n\n</th', 'ink>\n\n', 'Hallo']);
      expect(
        await client.streamChat(request([const LlmMessage.user('x')])).join(),
        'Hallo',
      );
    });

    test('rejects images', () async {
      await expectLater(
        client.streamChat(
          request([
            const LlmMessage.user(
              'What is this?',
              images: [
                LlmImage(bytes: [1]),
              ],
            ),
          ]),
        ),
        emitsError(
          isA<LlmApiException>().having(
            (e) => e.message,
            'message',
            OnDeviceLlmClient.imagesMessage,
          ),
        ),
      );
      expect(engine.loads, isEmpty);
    });

    test('a prompt that leaves too little room fails at once', () async {
      engine.tokens = (_) => 4096 - 511;
      await expectLater(
        client.streamChat(request([const LlmMessage.user('long')])),
        emitsError(
          isA<LlmApiException>().having(
            (e) => e.message,
            'message',
            OnDeviceLlmClient.contextMessage,
          ),
        ),
      );
      expect(engine.requests, isEmpty);
    });

    test('engine errors become LLM errors', () async {
      final cases = <Object, Matcher>{
        const LlmApiException('as is'): isA<LlmApiException>().having(
          (e) => e.message,
          'message',
          'as is',
        ),
        StateError('native'): isA<LlmApiException>()
            .having((e) => e.message, 'message', contains('stopped with'))
            .having((e) => e.body, 'body', contains('native')),
      };
      for (final MapEntry(key: error, value: matcher) in cases.entries) {
        engine.reply = (_) => Stream.error(error);
        await expectLater(
          client.streamChat(request([const LlmMessage.user('x')])),
          emitsError(matcher),
        );
      }
    });

    test('a reply the engine ended at its limit is cut off', () async {
      engine
        ..reply = ((_) => Stream.fromIterable(['Hal', 'lo']))
        ..finishReason = LlamaFinishReason.length;
      final events = <Object>[];
      await client
          .streamChat(request([const LlmMessage.user('x')]))
          .handleError(events.add)
          .forEach(events.add);
      expect(events, [
        'Hal',
        'lo',
        isA<LlmTruncatedException>()
            .having((e) => e.partialText, 'partialText', 'Hallo')
            .having((e) => e.reason, 'reason', 'length'),
      ]);
      await expectLater(
        client.chat(request([const LlmMessage.user('x')])),
        throwsA(isA<LlmTruncatedException>()),
      );
    });

    test('cancelling stops the generation, and the next one runs', () async {
      final pieces = StreamController<String>();
      engine.reply = (_) => pieces.stream;
      final subscription = client
          .streamChat(request([const LlmMessage.user('x')]))
          .listen(null);
      await pumpEventQueue();
      pieces.add('Hal');
      await pumpEventQueue();
      await subscription.cancel();
      expect(engine.cancelledGenerations, 1);
      engine.reply = (_) => Stream.value('Next');
      expect(await client.chat(request([const LlmMessage.user('y')])), 'Next');
      await pieces.close();
    });

    test('cancelling while queued never generates', () async {
      final gate = Completer<void>();
      final busy = runtime.run('gemma', (_) => gate.future);
      final subscription = client
          .streamChat(request([const LlmMessage.user('x')]))
          .listen(null);
      await pumpEventQueue();
      await subscription.cancel();
      gate.complete();
      await busy;
      await pumpEventQueue();
      expect(engine.requests, isEmpty);
    });

    test('pausing pauses the generation', () async {
      final pieces = StreamController<String>();
      engine.reply = (_) => pieces.stream;
      final received = <String>[];
      final subscription = client
          .streamChat(request([const LlmMessage.user('x')]))
          .listen(received.add);
      await pumpEventQueue();
      subscription.pause();
      pieces.add('a');
      await pumpEventQueue();
      expect(received, isEmpty);
      subscription.resume();
      await pumpEventQueue();
      expect(received, ['a']);
      await pieces.close();
      await subscription.cancel();
    });

    test('a model that is not installed fails', () async {
      await expectLater(
        clientFor('missing').streamChat(request([const LlmMessage.user('x')])),
        emitsError(isA<LlmApiException>()),
      );
    });
  });

  test('chat joins the deltas', () async {
    engine.reply = (_) => Stream.fromIterable(['Hal', 'lo']);
    expect(await client.chat(request([const LlmMessage.user('x')])), 'Hallo');
  });

  test('listModels lists the installed models by id', () async {
    runtime = OnDeviceRuntime(
      engine: engine,
      catalog: testCatalog,
      pathOf: (id) async => id == 'hy-mt2' ? null : '/m/$id',
    );
    final models = await clientFor('gemma').listModels();
    expect(models.map((m) => m.id), ['gemma', 'qwen']);
    expect(models.first.displayName, 'Model gemma');
    expect(models.first.contextWindow, 4096);
  });

  group('warmUp', () {
    test('loads the model', () async {
      final statuses = <OnDeviceAiStatus>[];
      runtime.status.listen(statuses.add);
      expect(await client.warmUp('gemma'), isTrue);
      expect(engine.loads.single.$1, '/m/gemma');
      expect(engine.requests, isEmpty);
      await pumpEventQueue();
      expect(statuses, const [OnDeviceAiLoading('gemma'), OnDeviceAiIdle()]);
      // An empty model name: the endpoint's.
      expect(await client.warmUp(''), isTrue);
    });

    test('is false when the model cannot be loaded', () async {
      expect(await client.warmUp('missing'), isFalse);
    });

    test('loads nothing while the phone is hot or saves battery', () async {
      final conditions = _FakeConditions();
      final guarded = OnDeviceLlmClient(
        client.endpoint,
        runtime: runtime,
        deviceConditions: conditions,
      );
      for (final strained in const [
        DeviceConditionsSnapshot(thermal: ThermalStatus.severe),
        DeviceConditionsSnapshot(powerSave: true),
      ]) {
        conditions.snapshot = strained;
        expect(await guarded.warmUp('gemma'), isFalse);
      }
      expect(engine.loads, isEmpty);
      expect(conditions.refreshes, 2);
      // A request still loads it (the user asked).
      await guarded
          .streamChat(request([const LlmMessage.user('Hi')]))
          .drain<void>();
      expect(engine.loads, hasLength(1));
      // Cool again: warm-ups load.
      conditions.snapshot = const DeviceConditionsSnapshot(
        thermal: ThermalStatus.moderate,
      );
      await runtime.unload();
      expect(await guarded.warmUp('gemma'), isTrue);
      expect(engine.loads, hasLength(2));
    });
  });

  test('has the default timeout and closes without effect', () {
    expect(client.timeout, LlmClient.defaultTimeout);
    expect(client.endpoint.provider, LlmProvider.onDevice);
    client.close();
  });
}

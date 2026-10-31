# dart2js: a captured local assigned in `catch` is read from a stale temporary

A standalone reproduction to file with the Dart SDK
(<https://github.com/dart-lang/sdk/issues>, area `web-dart2js`). It has
nothing to do with the app beyond being where the bug was found (wave 3:
every successful offline download in the web app was reported as failed;
`OfflineModelsCubit._attempt` documents the workaround).

## The bug

A nullable local is

1. declared (initialised to `null`) before a `try`,
2. assigned only in the `catch`,
3. captured by a closure, and
4. read after the `try`/`catch`.

dart2js compiles the read in step 4 to a JavaScript temporary that holds the
value stored in the `catch` (`t2 = t1.failure = error`) instead of reading
the variable (`t1.failure`). On the path that did not go through the
`catch`, that temporary still holds whatever it held before the `try`
(here `$.calls`, from the line `calls.add(calls.length)`), so a value that
is `null` reads as non-null. The closure itself reads the variable and sees
`null`.

It happens with and without `async`, and at every optimisation level
(`-O0` to `-O4`, minified or not). Without the closure, or when nothing was
stored in that temporary before (it is then `undefined`, which happens to
compare equal to `null`), the output is right.

## How to run it

With the Dart SDK (found with 3.13.5 stable on Linux x64) and Node.js
(22.22.0; any browser works too):

```sh
cd tool/repro/dart2js_catch_closure

# The VM: the expected output.
dart run main.dart

# dart2js. Node needs `self`, which dart2js's output uses.
dart compile js -O1 -o /tmp/out.js main.dart
node -e "globalThis.self = globalThis; require('/tmp/out.js')"
```

In a browser instead of Node: an HTML page next to `out.js` with
`<script src="out.js"></script>`, then look at the console.

## Expected output (the VM, and what dart2js should print)

```text
A successful action:
succeeded: true, failure: null
A failing action:
succeeded: false, failure: Bad state: boom
A successful action (sync):
succeeded: true, failure: null
A failing action (sync):
succeeded: false, failure: Bad state: boom
```

## Actual output (dart2js, `-O0` to `-O4`)

```text
A successful action:
succeeded: false, failure: null
A failing action:
succeeded: false, failure: Bad state: boom
A successful action (sync):
succeeded: false, failure: null
A failing action (sync):
succeeded: false, failure: Bad state: boom
```

`succeeded` is `false` although `failure` is `null`.

## The generated JavaScript (`-O1`)

`attemptSync`, the shorter of the two:

```js
attemptSync(action) {
  var error, exception, t1 = {},
    t2 = $.calls;
  B.JSArray_methods.add$1(t2, t2.length);
  t1.failure = null;
  try {
    action.call$0();
  } catch (exception) {
    error = A.unwrapException(exception);
    t2 = t1.failure = error;
  }
  A.print("succeeded: " + (t2 == null) + ", failure: " + A.S(new A.attemptSync_closure(t1).call$0()));
},
```

`t2 == null` should be `t1.failure == null`: `t2` is only the variable's
value when the `catch` ran. The `async` version (`attempt`) does the same
across the states of its state machine (`t2 = t1.failure = error;` in the
`catch` state, `(t2 == null)` in the state after it).

## Workaround

Return the outcome from a helper instead of assigning a captured local in
`catch` (as `OfflineModelsCubit._attempt` does), or do not capture the
local in a closure.

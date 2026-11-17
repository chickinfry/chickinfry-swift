# Swift SDK conformance driver

The driver calls the generated plain and authenticated clients. It uses the
runtime's session store and conditional conformance SPI; it does not implement
HTTP, refresh policy, retries, or case verdicts.

Prepare an owned staging root with this repository and three generated SDK packages
at `sdk/plain`, `sdk/auth`, and `sdk/requiredAuth`. Their package metadata must expose the modules
`ChickinfryClientPlain`, `ChickinfryClientAuth`, and `ChickinfryClientRequiredAuth`, preserve generated Swift source
bytes, and use the same staged runtime through local dependencies.

The driver executable requires macOS 13 or later. Build once with an installed Swift 6.4 toolchain:

```sh
swift build --package-path Tools/Conformance --scratch-path /owned/output/build \
  --disable-automatic-resolution -c debug --product swift-sdk-driver \
  -Xswiftc -DCHICKINFRY_CONFORMANCE -Xswiftc -warnings-as-errors
```

Run the resulting executable directly with `--plain-sdk /owned/stage/sdk/plain
--auth-sdk /owned/stage/sdk/auth --required-auth-sdk /owned/stage/sdk/requiredAuth`. Standard input and output carry protocol 1
JSON Lines. Initial credentials come exclusively from inherited anonymous pipe
descriptor 3, consumed through EOF before handshake. They never become process
arguments, environment variables, files, or output values.

`client.transport` provides `client.observe` snapshots during execution and after
SDK errors. Each event has exactly `sequence`, `callId`, `elapsedMs`, `phase`,
`httpStatus`, `readBytes`, `retainedBytes`, and `peakRetainedBytes`. Sequence
numbers are global; elapsed milliseconds use a monotonic clock from SDK entry.
`complete: true` describes the snapshot interval, not SDK completion; the
`completed` event marks the latter. Events survive until case shutdown.

The runtime records headers in the response or redirect delegate, reads when the
data delegate receives a chunk **before retaining it**, and limit on the first
exchange-local overflow. It records cancellation when requesting task cancellation
and when the completion delegate observes `URLError.cancelled`; `reader-closed`
is that delegate's terminal callback, and `completed` is the SDK invocation exit.
It does not manufacture cancellation for successful responses. Intermediate
exchange reads remain immediate and cumulative; headers and terminal events for
an exchange whose outcome is not yet known are projected when selected. Retention
includes all live runtime accumulator and response owners across exchanges, with
a lifetime peak that does not reset after release.

On Apple platforms the redirect delegate cancels the task before declining the
redirect, so URLSession does not wait for a large redirect body. Every 3xx,
including a small error envelope, fails as `invalid_response` with its HTTP status.

Retention measures buffers owned by the SDK and runtime. It does **not** assign
zero to opaque URLSession buffers: OS allocations cannot be instrumented by these
hooks and are assessed separately using the HTTP/1.1 peer's actual closure during
prefix transmission and sent-byte comparison for 8 MiB and 64 MiB bodies. Process
resident growth can detect failure but cannot establish a retained-byte bound.
The loopback tests use HTTP/1.1. Default URLSession can negotiate HTTP/2 for remote
HTTPS; that receive-window retention remains unverified and is not a passing
measurement. Linux FoundationNetworking transport requires separate validation.

The independent oracle reads the runtime-owned accumulator and response handoff
directly. UTF-8 validation streams code units without allocating another body
copy. The response owner keeps its accounting alive through decoding and error
unwinding. This oracle covers SDK-owned body buffers only: it cannot validate
opaque OS buffers, remote HTTPS receive windows, or unmeasured HTTP/2 paths.

Run driver tests in the same staging root with `swift test --package-path
Tools/Conformance -Xswiftc -DCHICKINFRY_CONFORMANCE`. Runtime tests also run
without the define, where the SPI is absent. No third-party dependency is needed.

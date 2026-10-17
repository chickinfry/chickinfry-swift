# Swift SDK conformance driver

The driver calls the generated plain and authenticated clients. It uses the
runtime's session store and conditional conformance SPI; it does not implement
HTTP, refresh policy, retries, or case verdicts.

Prepare an owned staging root with this repository and two generated SDK packages
at `sdk/plain` and `sdk/auth`. Their package metadata must expose the modules
`ChickinfryClientPlain` and `ChickinfryClientAuth`, preserve generated Swift source
bytes, and use the same staged runtime through local dependencies.

The driver executable requires macOS 13 or later. Build once with an installed Swift 6.4 toolchain:

```sh
swift build --package-path Tools/Conformance --scratch-path /owned/output/build \
  --disable-automatic-resolution -c debug --product swift-sdk-driver \
  -Xswiftc -DCHICKINFRY_CONFORMANCE -Xswiftc -warnings-as-errors
```

Run the resulting executable directly with `--plain-sdk /owned/stage/sdk/plain
--auth-sdk /owned/stage/sdk/auth`. Standard input and output carry protocol 1
JSON Lines. Initial credentials come exclusively from inherited anonymous pipe
descriptor 3, consumed through EOF before handshake. They never become process
arguments, environment variables, files, or output values.

`client.transport` is intentionally not advertised, and `client.observe` returns
`unimplemented`. Apple URLSession can retain redirect bodies after redirection is declined,
before its response and data delegate callbacks run. The existing hooks cannot establish
the underlying retained-byte bound. Shared transport cases therefore remain
incomplete; an instrumented diagnostic build is not support evidence.

The independent oracle reads the runtime-owned accumulator and response handoff
directly. UTF-8 validation streams code units without allocating another body
copy. The response owner keeps its accounting alive through decoding and error
unwinding. This oracle covers SDK-owned body buffers only: it cannot validate
opaque OS buffers, remote HTTPS receive windows, or unmeasured HTTP/2 paths.

Run driver tests in the same staging root with `swift test --package-path
Tools/Conformance -Xswiftc -DCHICKINFRY_CONFORMANCE`. Runtime tests also run
without the define, where the SPI is absent. No third-party dependency is needed.

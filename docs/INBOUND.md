# Inbound: how a consumer gets to the router

Status: design only. The tunnel and the forward host are not built.

## The path

```
consumer client ──TCP──▶ forward host:3333 ══ tunnel ══▶ Mac: proxy-router :3333
```

1. The provider runs the Mac router on `127.0.0.1:3333` and opens an **outbound**
   tunnel to a public forward host. The Mac needs no inbound port.
2. The forward host listens on TCP `:3333`. For each connection it opens one
   stream on the tunnel and copies bytes in both directions. It does not parse
   the frames.
3. The listing holds one address: `<forward-host>:3333`.

## What the forward host sees

The session is sealed to the engine's X25519 public value, and that value sits
inside the payload the attested key signs. The forward host sees ciphertext,
its sizes, and its timing. It holds no key. If it swaps the public value, the
signature check fails.

It sees the client's address and the connection time. It is a denial-of-service
point: a client that floods it can starve other clients. The provider must rate
limit it.

## What the provider must not do

- Parse or log the payload. The frames are opaque.
- Terminate the sealed session. The forward host only copies bytes.
- Reuse a forward host account across providers: the listing address is the
  provider's only public name.

## Failure modes

| Failure | What the consumer sees |
|---|---|
| Forward host down | connection refused |
| Tunnel down, forward host up | connection accepted, then no bytes |
| Wrong address in the listing | connection refused |
| Address resolves to a client-side interceptor | the signature check fails, because the engine's public value is in the signed payload |

## What is not built

- The tunnel program on the Mac.
- The forward host.
- The listing integration: the router's provider record does not hold the
  address yet.
- A health check that removes a dead provider from the listing.

## Open question

A forward host that ends the TCP session cannot read the frames, but it can drop
them. A consumer cannot tell a forward host from one that terminates the
session until it checks the engine's signature. That check must run in the
consumer's client, not in the provider's router, or a provider that runs a
stock router escapes it.

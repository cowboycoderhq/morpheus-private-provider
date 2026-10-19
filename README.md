# morpheus-private-provider

A one-click way to put a Mac on the [Morpheus](https://mor.org) network as a
**private** inference provider: the consumer's router can check that the
provider cannot read the prompts, without trusting the provider.

> **Status: in development. Not private yet, and not for use.**
> Nothing in this repo makes a privacy claim to a consumer today. No listing
> made with it carries "private", "sealed" or "TEE" until a consumer's router
> can verify it. The open items are listed under [Status](#status).

## Why this exists

Morpheus exists for decentralized private inference. A provider that can read
the prompts offers nothing that a centralized API does not already offer. So
this project has one goal, and it does not ship a non-private mode as a product:

**easy + decentralized + private, verified by the consumer.**

## How it fits upstream

This repo follows the structure that the Morpheus maintainers asked for in
[MorpheusAIs/Morpheus-Lumerin-Node#908](https://github.com/MorpheusAIs/Morpheus-Lumerin-Node/pull/908):

- **The router is upstream's, unchanged.** The app runs the published
  proxy-router image, pinned by digest:

  ```
  ghcr.io/morpheusais/morpheus-lumerin-node:v7.15.0
  @sha256:c52e9f12725d7c85e09eec11e0c06ae2b0970d12d1c770dc4daa4cc66f961ea4
  ```

  The digest was read from the registry on 2026-10-19. A digest update is a
  reviewed commit.
- **This repo holds what is around the router:** the button, the setup
  wizard, the registration, model and bid screens (modeled on MyProvider), and
  the Mac-specific pieces: the attested engine and the pinned model processes.

## Privacy model (target)

Upstream's TEE chain (`docs/concepts/tee-overview.mdx`) lets a consumer verify
a provider without trusting it: the consumer's router checks a CI-built,
signed image and hardware measurements. The Mac target is the same shape:

1. **Code identity.** The engine runs under Apple App Attest. Each session's
   assertion carries the engine's code-directory hash, and the consumer-side
   check refuses any hash that is not pinned. A rebuilt binary that logs
   prompts has a different hash and fails.
2. **Who publishes the pin.** The engine and the model processes are built in
   CI from a public commit, and a second party can rebuild them and get the
   same hash. Then the pin is a fact about public source, not about the
   operator.
3. **No readable prompt outside protected processes.** Prompts are encrypted
   from the consumer to the engine. The engine decrypts inside a hardened,
   sandboxed process and passes data to the model process over an unnamed
   socket pair whose peer it checks. Tokenizing and the chat template run
   inside the engine.
4. **Consumer-side verification.** A verifier for an Apple attestation class,
   with its own on-chain tag, proposed upstream beside the TDX/SEV verifier.

## Getting consumers to the router (inbound :3333)

Consumers reach a provider's router on **TCP port 3333** (morrpc). A Mac at
home has no stable public address and should not expose its home IP. The
path:

```
consumer router ──TCP──▶ relay (public host, :3333) ══ tunnel ══▶ Mac: proxy-router :3333
```

- **The relay** is a public host with a stable address. It accepts TCP on
  :3333 and forwards the stream through an outbound tunnel that the Mac opens
  (no inbound port on the Mac, no administrator prompt).
- **What the relay sees:** ciphertext and timing. Prompts are encrypted to the
  provider's key, and the relay holds no key and no attested identity.
- **The listing address:** the provider's on-chain endpoint is
  `<relay-host>:3333`. The relay host, the tunnel and how a provider gets one
  are documented in `docs/INBOUND.md` (to be written).

## Status

| Part | State |
|---|---|
| Pinned upstream router | Digest above; app not built yet |
| Wizard and screens | Not started in this repo |
| App Attest code identity, consumer-side check | Built in a router fork; refuses unknown code hashes (unit tests) |
| Reproducible, CI-built engine | v1 engine: unsigned rebuilds on two Macs matched the signed build; CI build and second-party rebuild not done |
| Root cannot read a hardened engine child's memory | Measured on one M5 (macOS 27.2 beta, 2026-10-12) on a test process the engine launched the way it launches the model: task, read and inspect ports and dtrace refused; an ordinary control process was readable |
| GPU memory through IOKit | Not tested |
| Swap | Root can open the swap files; encryption reported by macOS; readable-prompt search not valid yet |
| Panic dumps | Stated assumption (XNU source: log and stack snapshot only in Full Security) |
| Tokenizing inside the engine | Not done (today a Python server holds the prompt text) |
| Inbound :3333 path | Described above; `docs/INBOUND.md` not written |

## License

To be decided.

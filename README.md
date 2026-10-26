# morpheus-private-provider

A one-click way to put a Mac on the [Morpheus](https://mor.org) network as a
**private** inference provider. The goal: the consumer's router checks which
engine and which model answer, and the provider cannot read the prompts.

> **Status: v0.1.0 is a source and measurement release. It is not for
> production use.** No router on the Morpheus network runs the consumer check
> today, and no outside party can run it against these pins yet (see
> [Who can check what](#who-can-check-what)). Nothing goes on a Morpheus
> listing as "private", "sealed" or "TEE" until a consumer's router can verify
> it, as we agreed on
> [#908](https://github.com/MorpheusAIs/Morpheus-Lumerin-Node/pull/908).

## Why this exists

Morpheus exists for decentralized private inference. A provider that can read
the prompts offers nothing that a centralized API does not already offer. So
this project has one goal, and it does not ship a non-private mode as a
product:

**easy + decentralized + private, verified by the consumer.**

## What is in this release

| Folder | Content |
|---|---|
| `engine/` | The sealed engine (Swift). It holds the App Attest key, decrypts the consumer's prompt, tokenizes it, and starts the model process (the "child") under a pinned CD hash. |
| `child/` | The model process: a fork of [incoai/splash](https://github.com/incoai/splash) 1.0.2 (Apache-2.0) with a sealed build (`-DSPLASH_SEALED`): exception-port guard, self-checks, sandbox, descriptor-only model loading, chunked private KV memory. |
| `router/` | The consumer-side check as a patch to the Morpheus proxy-router (`sealed-consumer.patch`, base commit in `router/BASE.txt`). |
| `model/` | The sealed manifest of the model package and how to assemble the package. |
| `harness/` | The acceptance harness (`sealed-accept/`), the child negative suite (`neg/`), the root test kit (`tools/tee-rootpass.sh`, `tools/tee-rootkit/`) and helper tools. |
| `records/` | The claim, the closure matrix, the measurement records, audit reports and the result table of the accept run. See `records/README.md`. |
| `docs/REBUILD.md` | How to rebuild the child, the model hash and the engine executable, and what to compare. |

## Pins of this release

| Part | Value |
|---|---|
| Child CD hash (ad-hoc signature, identifier `sealed.splash`) | `8083a3388742668a68027de726b2a5eaef049ac6` |
| Child executable, unsigned, SHA-256 | `51499416ad246a5970a77e44af26f8ac78b43bbd7314c37d7fe0100a629180fa` |
| Child build ID | `src-997348af029254a3c4c679c14adb7bae8c9eea8982aef57fde422ff4ea88231b` |
| Engine executable, unsigned, SHA-256 | `5b3c9d1ff38f9bbb4e13f3a8e706fbad2b3faa25e5ab17599066b90ebbb1a3e7` |
| Engine CD hash (App Attest) | Withheld in this release (see below) |
| Model hash (v2: sealed manifest, tokenizer, child CD hash) | `57b2151c5135eb2d7376beab591ad221f6345c8654d8e4220a386747d0bd1477` |
| Model weights | [`audreyt/Qwen3.8-27B-Splash-abliterated`](https://huggingface.co/audreyt/Qwen3.8-27B-Splash-abliterated) at revision `78a6b379758eb6bf0740ef74581cd3432b144efc` |
| Source commits (private repos, exported here) | engine `aff678e7`, child `aa32be84`, harness `8f7490b6` |

The pins passed level A (138 of 138) and level B (155 PASS and 4 EXEMPT of 159) on the project's first M5 (`records/accept-results-Mac17,7-27.2-beta-20261025ThhmmssZ.md`), at engine commit `beba4427`, child commit `aa32be84` and harness commit `a7f245d0`. The table above names the exported commits. Five code changes came after those accept commits. The router model-hash test uses synthetic bytes. The stake-claimer comment gives no date, duration, or amount. The bundle comment does not name the profile. `matrix.py` reads revoked pins from a file this release omits. `neg/run-ckv.sh` takes the dense binary as an argument. The other later commits are documents.

A second Mac, as a second user account of the project,
rebuilt the child to the same bytes and CD hash, and its engine rebuild
matched the signed engine (`records/SECOND-MAC-REBUILD-2026-10-25-r5.txt`).

**Why the engine CD hash is withheld:** the CD hash covers the team ID and
the bundle ID of a borrowed development App ID. With the source public, the
CD hash would let a reader test a guess of that team. It will be published
with a dedicated App ID. The engine executable hash above does not depend on
the App ID.

## What the measurements claim

The full claim, its evidence and its limits are in
`records/CLAIM-v2-2026-10-24.md`. It was measured on the pins above. On a Mac
in Full Security, with the macOS kernel, GPU driver and sandbox not damaged:

1. **Prompt content:** root cannot read the content of the prompt from the
   memory of the engine or the child.
2. **Reply content:** root cannot read the content of the reply from the
   memory of the engine or the child, or from the connection to the consumer.
3. **Model integrity:** root cannot change the model without a change to the
   model hash that the consumer checks.
4. **No surface:** the child cannot open `IOSurfaceRootUserClient`, and the
   public Metal share APIs return nothing under the child's sandbox.
5. **Identity:** the engine that answers is the binary whose CD hash the
   consumer pins. The consumer checks that CD hash on each assertion.

## Limits and open gaps

This list is a summary. The full list is in the claim.

- **Not a TEE.** Apple Silicon has no memory encryption that locks out the
  owner. A kernel exploit, a GPU driver defect or a macOS defect breaks the
  claim.
- **The consumer trusts the provider's settings.** No attestation shows the
  consumer that the Mac runs in Full Security with SIP on, or how swap and
  sleep are set.
- **Length and timing:** root on the provider Mac sees the prompt and reply
  token counts and the timing. The network sees the prompt byte length and
  the reply timing. A refusal status code tells one bit.
- **Speculative-step pattern (open gap):** root can read the number of tokens
  in each decoding step. At temperature 0 the sequence repeats for the same
  prompt, so root can check a guessed prompt. `sealed-chat` sends temperature
  0. At temperature 0.6 the sequence does not repeat, but its mean still
  separates kinds of text. See `records/SPEC-TEMP-2026-10-25.md`.
- **Shared prefix cache (open gap):** the child keeps one prefix cache for
  all consumers. A prefix that another consumer sent a short time before gets
  a much faster first token, so any consumer can test a guessed prefix. Root
  is not needed. See `records/PREFIX-CACHE-GAP-2026-10-25.md`.
- **Not tested:** some paths are stated assumptions or not tested (for example
  P8 and panic dumps). Four root arms are EXEMPT, each with its cause. See the
  claim and `records/OPEN-ITEMS-CLOSURE-2026-10-24.md`.

## Who can check what

| Check | Outside party, with this release |
|---|---|
| Child bytes and CD hash | Yes: `docs/REBUILD.md` |
| Model hash and the weight files | Yes: `docs/REBUILD.md` |
| Engine executable bytes | Yes: `docs/REBUILD.md` |
| Engine CD hash against the signed app | No: the signed app and the App ID are withheld |
| Consumer check of a live provider | No: it needs the App ID, and the published router does not have the check (`router/sealed-consumer.patch` only) |
| The security measurements | No: they ran on the project's Macs. The harness is published, but a run needs an App Attest signed engine |

## How it fits upstream

This repo follows the structure that the Morpheus maintainers asked for in
[#908](https://github.com/MorpheusAIs/Morpheus-Lumerin-Node/pull/908): its
own repo, with the upstream router image pinned by digest.

- **The router is upstream's.** The app is to run the published proxy-router
  image, pinned by digest:

  ```
  ghcr.io/morpheusais/morpheus-lumerin-node:v7.15.0
  @sha256:c52e9f12725d7c85e09eec11e0c06ae2b0970d12d1c770dc4daa4cc66f961ea4
  ```

  The digest was read from the registry on 2026-10-19.
- **This repo holds what is around the router:** the button, the setup
  wizard, the registration, model and bid screens, and the Mac pieces: the
  attested engine and the pinned model process.

## Getting consumers to the router (inbound :3333)

This path is not built yet. Consumers reach a provider's router on **TCP port
3333** (morrpc). A Mac at home has no stable public address and should not
show its home IP:

```
consumer router ──TCP──▶ relay (public host, :3333) ══ tunnel ══▶ Mac: proxy-router :3333
```

- **The relay** will be a public host with a stable address. It will accept
  TCP on :3333 and send the stream through an outbound tunnel that the Mac
  opens.
- **What the relay will see:** ciphertext, its sizes and its timing. The
  relay holds no key.
- **The listing address:** `<relay-host>:3333`. `docs/INBOUND.md` is not
  written yet.

## Open items

| Item | State |
|---|---|
| Shared prefix cache (cross-consumer timing) | Open gap, documented |
| Speculative-step pattern (temperature-0 guess check) | Open gap, documented |
| Outside rebuild of the pins | Not done |
| Dedicated App ID, signed engine and its CD hash in a release | Not done |
| Consumer check in the published router | Not in upstream; patch only |
| One-click app, wizard and screens | Not started |
| `docs/INBOUND.md` | Not written |

## License

Apache-2.0 (`LICENSE`), copyright 2026 Cowboy Coder. `child/` is a fork of
incoai/splash and keeps its Apache-2.0 license (`child/LICENSE`).
`router/sealed-consumer.patch` changes the MIT-licensed Morpheus proxy-router;
the changed files keep the upstream MIT license.

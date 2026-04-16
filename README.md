# SN3 Teutonic miner

Production Docker image for mining Bittensor subnet 3 under the **Teutonic** mechanism (Jacob Steeves' stealth restart on top of the post-Covenant netuid 3). Wraps [unarbos/teutonic](https://github.com/unarbos/teutonic) `miner.py` in a dashboard-aware loop with wallet mounting, optional auto-registration, and a healthcheck.

> **Not Templar.** The on-chain name still says "deprecated" because the original SN3 owner rugged on 2026-04-10. Teutonic is the current live mechanism. Do not run old `one-covenant/templar` or `tplr-ai` code against netuid 3 — it will not earn.

## Mechanism in one paragraph

King-of-the-hill pretraining. Each miner downloads the current king model (seed: [`unconst/Teutonic-I`](https://huggingface.co/unconst/Teutonic-I), Gemma3 903M bf16), perturbs or fine-tunes weights on CulturaX, pushes to a HuggingFace repo, and submits an on-chain reveal commitment with `subtensor.set_reveal_commitment(..., blocks_until_reveal=3)`. The validator runs a paired t-test (alpha=0.001) against the reigning king. Winner takes 100% of miner emission until dethroned. Reigns cycle every 1-4h.

## Prerequisites

- **GPU:** 1x NVIDIA A100 80GB (or better). Minimum VRAM observed: ~16 GB for Gemma3-903M bf16 perturbation; ~30-40 GB comfortable headroom for training-based strategies.
- **Host:** NVIDIA Container Toolkit installed, CUDA 12.x driver (image is built on CUDA 12.8 runtime).
- **Bittensor wallet** with a coldkey funded for registration (~0.68 TAO at time of writing) and at least one hotkey.
- **HuggingFace token** with write access to your namespace.

## Environment variables

| Var | Required | Default | Purpose |
|---|---|---|---|
| `HF_TOKEN` | yes | — | HuggingFace write token. Do **not** bake into image. |
| `HF_USER` | yes | — | Your HF username (currently informational; miner.py uses `unconst/Teutonic-I-<suffix>` repo pattern). |
| `BT_WALLET_NAME` | yes | — | Coldkey name (matches folder under `~/.bittensor/wallets/`). |
| `BT_WALLET_HOTKEY` | yes | — | Hotkey file name (e.g. `h0`). |
| `REGISTER` | no | `false` | If `true`, auto-register when missing (subject to `MAX_REGISTER_TAO`). |
| `MAX_REGISTER_TAO` | no | `1.0` | Refuse to auto-register if current cost exceeds this (TAO). |
| `TEUTONIC_NOISE` | no | `0.001` | Weight perturbation scale passed to miner.py. |
| `TEUTONIC_SUFFIX` | no | `<hotkey>` | Challenger repo suffix: `unconst/Teutonic-I-<suffix>`. |
| `TEUTONIC_FORCE` | no | `true` | Pass `--force` to miner.py to bypass "already seen hotkey" soft-warning. |
| `POLL_INTERVAL_SEC` | no | `60` | Dashboard poll interval. |
| `MIN_SUBMIT_GAP_SEC` | no | `600` | Minimum seconds between submissions. |
| `TEUTONIC_NETUID` | no | `3` | Subnet. |
| `TEUTONIC_NETWORK` | no | `finney` | Chain endpoint. |

## Wallet mounting

Mount your wallet directory to `/wallet`. Two layouts work:

**Full wallet (recommended; required if `REGISTER=true`):**
```
~/.bittensor/wallets/<name>/
├── coldkey            # encrypted, needed to sign reg tx
├── coldkeypub.txt
└── hotkeys/
    └── <hotkey>
```
Mount: `-v ~/.bittensor/wallets/teutonic:/wallet:ro`

**Hotkey-only (safer; skip auto-register):**
```
/some/path/
├── coldkeypub.txt
└── hotkeys/
    └── <hotkey>
```
Or flat layout:
```
/some/path/
├── coldkeypub.txt
└── <hotkey>
```
Mount: `-v /some/path:/wallet:ro`

## Pull

```bash
docker pull ghcr.io/bigailabs/sn3-teutonic-miner:latest
```

(Or tag a release: `ghcr.io/bigailabs/sn3-teutonic-miner:v0.1`)

## Run (1x A100)

```bash
docker run --rm -it \
  --gpus all \
  -v ~/.bittensor/wallets/teutonic:/wallet:ro \
  -e HF_TOKEN=$HF_TOKEN \
  -e HF_USER=tabak25 \
  -e BT_WALLET_NAME=teutonic \
  -e BT_WALLET_HOTKEY=h0 \
  -e REGISTER=false \
  -e MAX_REGISTER_TAO=1.0 \
  -e TEUTONIC_NOISE=0.001 \
  --name teutonic-miner \
  ghcr.io/bigailabs/sn3-teutonic-miner:latest
```

## Expected startup logs

```
2026-04-16T22:00:03Z [teutonic-miner] starting SN3 Teutonic miner
2026-04-16T22:00:03Z [teutonic-miner] teutonic commit pinned: 1d86c2dbcc9e9b6cb2a8a9aefb1e66337d6d37e4
2026-04-16T22:00:03Z [teutonic-miner] env validated | wallet=teutonic hotkey=h0 hf_user=tabak25
2026-04-16T22:00:03Z [teutonic-miner] wallet files ok | hotkey=/wallet/hotkeys/h0 coldkey=/wallet/coldkey coldkeypub=/wallet/coldkeypub.txt
2026-04-16T22:00:03Z [teutonic-miner] wallet staged at /home/miner/.bittensor/wallets/teutonic
2026-04-16T22:00:03Z [teutonic-miner] hotkey ss58: 5FExAMpLE...
2026-04-16T22:00:09Z [teutonic-miner] registration check ok — REGISTERED uid=42
2026-04-16T22:00:09Z [teutonic-miner] launching miner loop | noise=0.001 poll=60s min_gap=600s
2026-04-16T22:00:10Z [teutonic-miner] INFO wrapper up | hotkey=h0 ss58=5FExAMpLE... ...
2026-04-16T22:00:11Z [teutonic-miner] INFO dash ok | king=04b513d912bc@1ac47961 ...
2026-04-16T22:00:11Z [teutonic-miner] INFO running miner.py | reasons=boot
22:00:14 INFO miner starting | hotkey=h0 repo=unconst/Teutonic-I-h0 noise=0.0010
22:00:15 INFO hotkey registered as uid=42 on subnet 3
22:00:16 INFO discovered king from dashboard: 22oseni/Teutonic-I-boo7@1ac47961
22:00:45 INFO uploading to unconst/Teutonic-I-h0
22:01:05 INFO reveal committed at block 7983700
22:01:05 INFO done!
```

## Verifying you are mining

**1. Live dashboard (fastest):**
```bash
curl -s https://s3.hippius.com/teutonic-sn3/dashboard.json \
  | jq --arg hk "$HOTKEY_SS58" '
      [.queue[], (.recent // .recent_submissions // [])[]]
      | map(select(.hotkey == $hk))
    '
```
You should see your hotkey in the queue within 1-2 minutes of submit.

**2. On-chain commitment:**
```bash
btcli subnet metagraph --netuid 3 --subtensor.network finney
```
Look for your UID. A commitment reveals within ~3 blocks (~36s) after submit.

**3. Log grep:**
```bash
docker logs teutonic-miner 2>&1 | grep -E "reveal committed|submitted challenger|uploaded to|i am king"
```

## Realistic revenue

Numbers as of 2026-04-16 (TAO=$245.59, SN3 alpha=0.02597 TAO, ~$6.38/alpha):

| Scenario | TAO-equivalent/day | USD/day |
|---|---|---|
| **Floor** — never dethrone king | 0 | $0 |
| **Realistic** — win 1-3 duels, hold 1-3h each | 2-10 TAO-equiv | $490-$2,500 |
| **Ceiling** — hold king all 24h | ~77 TAO-equiv | ~$19k |

Reasoning: total SN3 miner-bucket emission is roughly 77 TAO-equivalent/day (~41% of subnet emission, emitted as alpha). The king takes 100% of that bucket; everyone else earns 0 until they dethrone. With reigns cycling every 1-4h there are 6-24 king transitions per day. If your strategy is competitive you might hold the crown for 1-3 hours total.

**Big caveats:**
- Alpha price has fallen ~61% in 7 days (rug aftermath). Liquidity is thin; exiting size may move price.
- Sam Dare (Covenant) still owns the subnet slot. If he rugs again or tries to reclaim control, alpha could go to zero.
- "Only perturb" strategies (default `TEUTONIC_NOISE=0.001`) are unlikely to consistently beat a well-fine-tuned king. Plan to iterate on a real fine-tuning strategy on CulturaX.

## Security notes

- **No secrets baked in.** HF token, wallet files, and taostats key are passed at runtime.
- **Container runs as UID 1000** (`miner`), not root.
- **Wallet mount is read-only (`:ro`)** — container copies keys into `~/.bittensor` inside the container and never writes back. Rotate the HF token after initial setup regardless.
- **Auto-register is off by default** (`REGISTER=false`). If you enable it, it refuses to proceed when the reg cost exceeds `MAX_REGISTER_TAO`.
- **Taostats key:** a shared bigailabs key is baked into entrypoint.sh for the registration-cost lookup. Override with `-e TAOSTATS_AUTH=...` if you want your own.

## Known issues

- `miner.py` repo name pattern is hardcoded to `unconst/Teutonic-I-<suffix>`. Your HF account will need push access to that org, **or** you'll need to fork `unarbos/teutonic` and patch the `challenger_repo` line. The unarbos code appears to rely on a shared org — expect this to change.
- The wrapper triggers a resubmit every `MIN_SUBMIT_GAP_SEC` (default 10 min). If the subnet tightens rate-limits you'll see `miner.py` exit non-zero; the wrapper backs off exponentially to 30 min max.
- No multi-GPU parallelism. 2x A100 host? You can run two containers with different hotkeys and different `TEUTONIC_SUFFIX` (and different `CUDA_VISIBLE_DEVICES=0` / `=1`) to get two independent challengers.
- Teutonic is moving fast. The pinned commit in the Dockerfile is `1d86c2dbcc9e9b6cb2a8a9aefb1e66337d6d37e4`. When upstream changes miner.py flags or behavior, rebuild with `--build-arg TEUTONIC_SHA=<new>` and cut a new image tag.

## Publishing notes (maintainers)

On first push the GHCR package is private by default. After the first successful CI run, make it public:
```bash
gh api --method PATCH /user/packages/container/sn3-teutonic-miner \
  --field visibility=public
# or for the org:
gh api --method PATCH /orgs/bigailabs/packages/container/sn3-teutonic-miner \
  --field visibility=public
```

## License

MIT. Patches welcome.

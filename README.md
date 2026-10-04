# tebako-release

The tebako factories' release machinery — the **single owner** of the per-leg
publish uploader and the no-fold OpenPGP release signer that every runtime
factory (ruby, python, openjdk, …) consumes. Ecosystem invariant 10: the
machinery exists exactly once; factories declare their identity and policy
through a small adapter file and pin this gem — they never carry copies.

## What ships here

- **`TebakoRelease::Uploader`** (`tebako-release upload`) — the spec 13 §2a
  de-rendezvoused publish: each build leg uploads only the write-once names
  it owns (payloads byte-immutable per name, per-asset `.sha256` sidecars,
  per-package `.manifest.json` shards), with the convergence, rate-limit
  ride-out, and settled-ledger machinery earned against the named incidents
  of the v0.16.x line.
- **`TebakoRelease::Signer`** (`tebako-release sign`) — spec 09 §5's no-fold
  signing: every served name gets its own detached `.asc`, provenance-checked
  against the release listing's digest, with the young-release-object
  served-bytes convergence.
- **`TebakoRelease::Bundler`** — spec 36's deterministic bundle builder:
  one `<stem>.tar.gz` per leg (exe + env image + support DLLs + a closing
  in-bundle SHA256SUMS; fixed member order, mtime=0 — identical inputs
  yield identical bytes). A factory opts into the bundle-era publish shape
  through its adapter (`bundle_publish? → true`); the per-file shape stays
  the default for pre-bundle lines. Bundle-era lines whose consumers
  include the lazy arm additionally opt into co-publish
  (`per_file_alongside_bundle? → true`, spec 36 §3): the staged members
  are served as standalone assets beside the bundle, the shard carries
  the `per_file_assets` witness (runtime-manifest MINOR 2), the facet
  signature declarations return, and the audit expects the union.
- **`TebakoRelease::Blksum`** — the spec 39 §3 block-group digest sidecar
  (`<image>.blksum.json`: one sha256 per 4 MiB group of env-image bytes,
  the lazy mount's range-GET trust anchor). The uploader derives it
  in-process from the staged image at entry-build time — a pure function
  of the served bytes, the same class as the `.sha256` sidecars — pins it
  in the shard (`image.blksum {filename, sha256}`), and uploads it as a
  standalone asset in both publish eras. The render is byte-exact with
  `tpkg::lazy::Blksum::render`, golden-pinned in `spec/blksum_spec.rb`.
- **`TebakoRelease::Platform`** — the release-side platform vocabulary
  (the `(os, arch) → host_id` table; mirrors `tpkg::Platform`, drift fails
  loudly in factory CI).

## Consuming factory contract

A factory adds the gem, pinned through its `contract.yml` SSOT:

```ruby
# Gemfile
gem "tebako-release",
    git: "https://github.com/tamatebako/tebako-release.git",
    tag: YAML.load_file("contract.yml").fetch("release_tooling")
```

and declares itself once in `scripts/release_adapter.rb`:

```ruby
TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-ruby",   # whose releases this run manages
  language: "ruby",                          # EXPECTED_RUBY_MATRIX, ruby_version key
  title_prefix: "Tebako runtime packages",
  contract_yml: File.expand_path("../contract.yml", __dir__),
  adapter: RubyReleaseAdapter.new            # capable_pair? / capabilities / dll_install_name
)
```

CI then calls `bundle exec tebako-release upload` (publish legs) and
`bundle exec tebako-release sign` (sign legs). Sign-only consumers can skip
the adapter and set `TEBAKO_RELEASE_REPO` instead.

## force_rebuild, the release-object rule

Payload assets are byte-immutable per name — the uploader **never** deletes a
published payload asset to replace it (delete → re-upload of the same name is
the 422 wedge; tebako-runtime-ruby#189). A forced republication recreates the
**release object** once, coordinator-side, before any leg fans out
(`gh release delete <tag> --cleanup-tag false` … the first leg's
race-safe create re-makes it), turning every leg's publish into pure creates.
Operator-run re-uploads follow the same rule by hand.

## Convergence and rate-limit discipline

Every GitHub API call in the gem rides one internal wrapper
(`TebakoRelease::Convergence`), with per-operation-class semantics.
Unconditional calls (plain reads, idempotent writes) ride quota responses
out: a 403/429 rate-limit answer is never fatal — the wrapper sleeps to the
response's named window (`x-ratelimit-reset`, else `Retry-After`), or backs
off exponentially from 30 s up to a 10-minute cap when the response names no
window — and transport drops retry with escalating waits. Read-after-create
calls poll for the fresh release object's visibility on a bounded delay
list; delete-then-upload replaces poll the single-asset endpoint until the
deletion is visibly absent (plus a short name-release grace) before
re-uploading, so the 422 propagation race never wedges a leg. The patience
is bounded twice — eight absorbed quota responses per call, and a two-window
(~2 h) wall-clock ceiling per process — and then the leg fails with a named,
resumable error; the metadata replace loop additionally carries a hard
15-minute deadline. Convergence polls ride the single-asset endpoint (one
request per poll, never a re-paginated listing), so a catalog fleet stays
far inside the token's hourly request window. Every retry logs a stderr line
with the attempt, the wait, and the call's target, so a ride-out is visible
in the CI log instead of looking like a hang.

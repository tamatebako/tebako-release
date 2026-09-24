# tebako-release-tooling

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
  the default for pre-bundle lines.
- **`TebakoRelease::Platform`** — the release-side platform vocabulary
  (the `(os, arch) → host_id` table; mirrors `tpkg::Platform`, drift fails
  loudly in factory CI).

## Consuming factory contract

A factory adds the gem, pinned through its `contract.yml` SSOT:

```ruby
# Gemfile
gem "tebako-release",
    git: "https://github.com/tamatebako/tebako-release-tooling.git",
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

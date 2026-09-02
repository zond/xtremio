# Vendored crates

## stremio-watched-bitfield

Verbatim copy of `stremio-core/stremio-watched-bitfield` at the pinned
stremio-core rev (see `stremio-core` in `../Cargo.toml`), MIT licensed
(`LICENSE.md` is stremio-core's), with exactly one change:

```toml
flate2 = "1"        # upstream: flate2 = "1.0.*"
```

**Why:** upstream pins `flate2 = "1.0.*"` (< 1.1) while stream-server's tree
(zip, async-compression via async_zip and librqbit) requires `flate2 >= 1.1`.
Cargo cannot select two 1.x versions of one crate, so the combined dependency
graph fails to resolve. The copy is wired in through
`[patch."https://github.com/Stremio/stremio-core"]` in `../Cargo.toml`, which
replaces the workspace member stremio-core itself depends on.

**How to drop it:** once upstream relaxes the pin (a one-line PR to
Stremio/stremio-core), delete this directory and the `[patch]` section.
Until then, re-copy the sources here whenever the pinned stremio-core rev is
bumped and re-apply the one-line change.

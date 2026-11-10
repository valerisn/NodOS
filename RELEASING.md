# Cutting a release

The pipeline is tested. A manual run of the Release workflow does everything
except publish, so rehearse before tagging.

## One-time setup: the signing key

Releases are signed, and `nodos update` refuses anything unsigned, so do this
before the first release:

```sh
bash scripts/release-keygen.sh
git add src/update/signing.pub && git commit -m "Publish the release signing public key"
```

It builds the small `release-sign` tool, makes a key pair, stores the secret in
GitHub as the `NODOS_SIGNING_KEY` Actions secret, writes a backup to
`~/.nodos/release-signing-key.txt` (put that in a password manager; GitHub
cannot show the secret again), and writes the public key to
`src/update/signing.pub`, which is compiled into every build. The release
workflow refuses to publish a tag without the secret and checks its signature
against `signing.pub` before uploading.

## Reproducible builds

CI builds the Linux x86_64 binary twice from two directories with empty caches
and fails if the bytes differ, so anyone can rebuild a tagged release and
compare it with the published file:

```sh
git clone --branch vX.Y.Z https://github.com/valerisn/NodOS && cd NodOS
zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-linux-musl --prefix /tmp/out
sha256sum /tmp/out/bin/nodos   # compare with the tarball's binary
```

Use the Zig version named in `build.zig.zon`.

## Rehearse

```sh
gh workflow run release.yml --ref main
gh run watch
gh run download <run-id> -n nodos-release-files -D /tmp/nodos-release
sha256sum -c /tmp/nodos-release/SHA256SUMS   # run inside that directory
# once signing is set up the artifact also holds SHA256SUMS.sig
```

Check the tarball has the binary, `scripts/install.sh`, `packaging/` and the
docs, and that `nodos version` prints the version you expect.

## Release

1. Be on `main` with a green CI run.
2. Set the version in `build.zig.zon` (drop `-dev`), for example `0.1.0`.
3. Move the `[Unreleased]` entries in `CHANGELOG.md` under a dated `[0.1.0]`
   heading and open a fresh empty `[Unreleased]`.
4. Commit: `Release 0.1.0`.
5. Tag and push: `git tag v0.1.0 && git push origin main v0.1.0`.

The tag must equal `v` plus the version in `build.zig.zon`; the workflow
refuses to publish a mismatch. It builds and tests, packages both Linux
targets, checks the binary reports the right version, and creates the GitHub
release with generated notes and `SHA256SUMS`.

6. Afterwards, bump `build.zig.zon` to the next `-dev` version.
7. Add the real release badge to the README.

## Before the first public release

The honest list is in [ROADMAP.md](ROADMAP.md). The ones that matter most: run
it on a real home server for a while, run a long fuzzing campaign, and get an
independent look at the security model in `docs/security/README.md`. Releases
are signed, and the signature is what protects an update.

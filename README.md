# ghostty-release-kit

Builds, tests and releases [Ghostty](https://ghostty.org) for **Windows** (x64 and Arm64): an
early, unofficial port. The Ghostty code lives in the fork,
[congzhangzh/ghostty](https://github.com/congzhangzh/ghostty); this repository holds only what
turns a commit of it into a release: the pin, the build, the tests and the release notes.
[docs/PLAN.md](docs/PLAN.md) is the plan: what upstream already had, what the port adds, and
what comes next; [docs/REPORT-20261122.md](docs/REPORT-20261122.md) reports the plan, the
design and the progress as the first release went out.

## Install

Take the newest [release](../../releases/latest), unzip `ghostty-<version>-windows-x86_64.zip`
(or `-aarch64` on Windows on Arm) and run `ghostty.exe`. One file, no installer; the
`README.txt` beside it says what works and what does not yet.

## What the port is

Upstream Ghostty already had the parts under the app on Windows (ConPTY, fonts, libghostty-vt)
but no app. The port adds, on upstream `main`:

- an OpenGL renderer path through **WGL** (upstream's renderer only knew surfaceless EGL);
- a Windows platform in libghostty's embedded runtime, and a call for hosts to take the
  rendered frames;
- `windows/`, **`ghostty.exe`**: a Win32 host on libghostty, as the macOS app is a Swift host
  on it;
- fixes to Windows paths upstream never ran: the C API's start, the pty read thread's
  shutdown, an LLP64 ABI slip in the OpenGL bindings, unwind tables in release builds.

## From a fix to a release

| Where | What |
|---|---|
| fork, `feature-windows` | The port, one commit per part, on upstream `main` |
| fork, `integration-windows` | upstream `main` plus the feature branches, rebuilt whenever one of them or the base moves |
| kit, run with `ref` | Tests a fork branch before it is picked: `gh workflow run kit.yml -R congzhangzh/ghostty-release-kit -f ref=integration-windows` |
| fork, `release-YYYYMMDD.N` | A tested `integration-windows` commit, picked as a release; never moves |
| kit, `sources.lock` | Pins that commit; the push to `main` builds and tests it and publishes the rolling release |

**Rolling releases**, as our other kits make them: every push to `main` that passes publishes
the release `<YYYYMMDD>.<N>`, as GitHub's latest release, once, never replaced. A push that
changes nothing the zips are made of (the pin, `ci/build.sh`, `ci/README.txt`) publishes
nothing; [`ci/changes.sh`](ci/changes.sh) decides, and the notes of each release carry a
`kit-key` naming those inputs. Pull requests and runs with `ref` only build and test.

The version is `<upstream version>+r<YYYYMMDD>.<N>`, e.g. `1.4.1-dev+r20261122.1`, where
`r<YYYYMMDD>.<N>` names the fork's release branch.

## What a run does

[`.github/workflows/kit.yml`](.github/workflows/kit.yml), on `ubuntu-latest`:

1. [`ci/resolve.sh`](ci/resolve.sh) reads [`sources.lock`](sources.lock), fetches the fork and
   checks the pin: the pinned commit must still be the tip of its release branch, and the
   pinned upstream base an ancestor of it.
2. [`ci/build.sh`](ci/build.sh) cross-compiles with Zig, for `x86_64-windows-gnu` and
   `aarch64-windows-gnu`: libghostty (ReleaseFast), then `ghostty.exe` linked against its
   static library, zipped with Ghostty's license and [`ci/README.txt`](ci/README.txt).
3. [`ci/test-wine.sh`](ci/test-wine.sh) runs the x64 build under Wine on a virtual X server,
   with OpenGL from Mesa's llvmpipe, and checks one layer at a time: the window appears; typed
   keys reach `cmd.exe` through ConPTY (the command writes a marker file); the renderer drew
   the text (the screenshot gains text pixels); `exit` closes the window and ends the process.
   The Arm64 build is built but not run: Wine on x64 cannot run it.
4. On `main`, for the pin only, and only when the test passed,
   [`ci/publish-release.py`](ci/publish-release.py) publishes the rolling release unless its
   inputs or its version are already released: a draft with the assets first, then the
   release, which creates the tag, so a failure leaves at most a draft. Every run also keeps
   its build, the test log and the screenshots as a workflow artifact.

The same runs locally on Linux with Zig, Wine, Xvfb, xdotool and ImageMagick:

```sh
eval "$(ci/resolve.sh . /some/work/ghostty)"
git -C /some/work/ghostty checkout -q "$SHA"
ci/build.sh /some/work/ghostty "$VERSION" out x86_64 aarch64
xvfb-run -a ci/test-wine.sh "out/work/pkg-x86_64/ghostty-$VERSION-windows-x86_64/ghostty.exe" out/test
```

## Upstream

Ghostty's [AI usage policy](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md)
asks for full disclosure and a human who fully understands every change. Nothing here is
submitted upstream by an agent; what is worth offering upstream is taken there by a person,
in their own words and code.

## License

The kit's own files (`ci/`, `.github/`, `docs/`, this README) are under the Apache License 2.0
([`LICENSE`](LICENSE)). Ghostty is MIT licensed; each zip carries its license.
